-- What the automatic send and the automatic fetch read from the catalog, with one read-only SELECT through sqlite3
-- (SqliteRunner.query), and the parsing of its output. Pure Lua 5.1: no Lightroom imports. Since version 0.8.0 the
-- automatic path finds new photos this way instead of through the SDK (catalog:getAllPhotos, findPhotoByPath), because
-- plug-in calls into the catalog are very slow while Lightroom imports, and an external process does not hold up
-- Lightroom's window. Nothing writes (decision record 0002).
--
-- The tables and columns, as found in Lightroom Classic 15.6 catalogs (read with sqlite3 from a copy, read-only):
--   Adobe_images (id_local, rootFile, fileFormat, fileWidth, fileHeight, masterImage, ...): one row per photo;
--     id_local is the SDK's photo.localIdentifier; masterImage is set for a virtual copy; fileFormat 'RAW', 'VIDEO'...
--   AgLibraryFile (id_local, id_global, baseName, extension, folder): id_global is the file UUID that names the smart
--     preview (SmartPreviewPath).
--   AgLibraryFolder (id_local, pathFromRoot, rootFolder) and AgLibraryRootFolder (id_local, absolutePath): the folder
--     as "Z:/2026/" + "2026.06.20 - shoot/", forward slashes, each with a trailing one.
--   AgLibraryImport (id_local, importDate, ...): one row per import, written when the import starts (seen: the row of
--     an import started by the plug-in's trigger existed at once; its photos came minutes later, with larger ids);
--     importDate is local time with its offset, "2026-11-14T15:15:56.060+01:00".
--   AgLibraryImportImage (image, import): which import added a photo.
--   AgDNGProxyInfo (fileUUID, status): the smart previews Lightroom knows. Seen: status 'V' for every smart preview it
--     registered, 'D' for ones whose photo was removed. Any row whose status is not 'D' counts as a smart preview here,
--     so that a photo with one is left alone.
-- The file, folder and import rows are joined with LEFT JOIN: a photo whose rows are not all there yet is reported as
-- incomplete (the automatic send then waits for them) instead of being missed.
--
-- Every text is read through hex(), so that any character arrives as plain ASCII whatever the tool's code page.
local SmartPreviewPath = require 'SmartPreviewPath'

local CatalogRead = {}

-- The columns of one photo line ('p'), after the tag: 13 fields in all.
local COLUMNS = "i.id_local, ifnull(f.id_global, ''), hex(ifnull(r.absolutePath, '')), "
    .. "hex(ifnull(fo.pathFromRoot, '')), hex(ifnull(f.baseName, '')), hex(ifnull(f.extension, '')), "
    .. 'ifnull(ii.import, 0), CAST(ifnull(i.fileWidth, 0) AS INTEGER), CAST(ifnull(i.fileHeight, 0) AS INTEGER), '
    .. "ifnull(i.masterImage, 0), hex(ifnull(i.fileFormat, '')), "
    .. "(SELECT count(p.id_local) FROM AgDNGProxyInfo p WHERE p.fileUUID = f.id_global AND NOT p.status = 'D')"

local FROM = 'FROM Adobe_images i LEFT JOIN AgLibraryFile f ON f.id_local = i.rootFile '
    .. 'LEFT JOIN AgLibraryFolder fo ON fo.id_local = f.folder '
    .. 'LEFT JOIN AgLibraryRootFolder r ON r.id_local = fo.rootFolder '
    .. 'LEFT JOIN AgLibraryImportImage ii ON ii.image = i.id_local'

local function isCount(value)
    return type(value) == 'number' and value >= 0 and value == math.floor(value) and value < 2 ^ 53
end

local function integer(value)
    return string.format('%d', value)
end

-- The SELECT for the photos above mark ('p' lines) and the import records above mark ('i' lines: id, import date).
-- Or nil plus a message for a bad mark.
function CatalogRead.newSql(mark)
    if not isCount(mark) then
        return nil, 'not a catalog id: ' .. tostring(mark)
    end
    local n = integer(mark)
    return "SELECT 'p', " .. COLUMNS .. ' ' .. FROM .. ' WHERE i.id_local > ' .. n
        .. " UNION ALL SELECT 'i', id_local, '', hex(ifnull(importDate, '')), '', '', '', 0, 0, 0, 0, '', 0"
        .. ' FROM AgLibraryImport WHERE id_local > ' .. n .. ';'
end

-- The SELECT for the photos with these catalog ids ('p' lines), for the automatic fetch when it no longer has what
-- the send read (after a restart of Lightroom). Or nil plus a message.
function CatalogRead.byIdSql(ids)
    if type(ids) ~= 'table' or #ids == 0 then
        return nil, 'no catalog ids given'
    end
    local parts = {}
    for i, id in ipairs(ids) do
        if not isCount(id) or id == 0 then
            return nil, 'not a catalog id: ' .. tostring(id)
        end
        parts[i] = integer(id)
    end
    return "SELECT 'p', " .. COLUMNS .. ' ' .. FROM .. ' WHERE i.id_local IN (' .. table.concat(parts, ',') .. ');'
end

-- The SELECT for the largest catalog id of photos and of imports ('m' lines): where the automatic send starts.
function CatalogRead.markSql()
    return "SELECT 'm', ifnull(max(id_local), 0) FROM Adobe_images UNION ALL SELECT 'm', ifnull(max(id_local), 0) "
        .. 'FROM AgLibraryImport;'
end

local function unhex(hex)
    return (hex:gsub('%x%x', function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

local function isHex(text)
    return text ~= nil and #text % 2 == 0 and text:find('^%x*$') ~= nil
end

local function fileName(baseName, extension)
    if extension == '' then
        return baseName
    end
    return baseName .. '.' .. extension
end

local function isWindowsFolder(folder)
    return folder:match('^%a:') ~= nil or folder:match('^//') ~= nil or folder:match('^\\\\') ~= nil
end

-- The local path of a file from its folder as the catalog spells it ("Z:/2026/shoot/") and its name: Windows paths
-- (a drive letter, or // for a network share) get backslashes, others stay as they are.
function CatalogRead.localPath(folder, name)
    if type(folder) ~= 'string' or folder == '' or type(name) ~= 'string' or name == '' then
        return nil
    end
    local path = folder:gsub('[/\\]*$', '') .. '/' .. name
    if isWindowsFolder(folder) then
        path = path:gsub('/', '\\')
    end
    return path
end

-- The last name in a folder path ("Z:/2026/2026.06.20 - shoot/" gives "2026.06.20 - shoot"), or nil.
function CatalogRead.folderName(folder)
    if type(folder) ~= 'string' then
        return nil
    end
    local name = folder:gsub('[/\\]+$', ''):match('([^/\\]+)$')
    if name == nil or name:match('^%a:$') then
        return nil
    end
    return name
end

local function photoFrom(fields)
    local id = tonumber(fields[1])
    local uuid = fields[2]
    local root, folderPath, base, extension = unhex(fields[3]), unhex(fields[4]), unhex(fields[5]), unhex(fields[6])
    local width, height = tonumber(fields[8]), tonumber(fields[9])
    local photo = {
        id = id,
        importId = tonumber(fields[7]) or 0,
        width = (width and width > 0) and width or nil,
        height = (height and height > 0) and height or nil,
        virtualCopy = (tonumber(fields[10]) or 0) ~= 0,
        format = unhex(fields[11]),
        hasSmartPreview = (tonumber(fields[12]) or 0) > 0,
    }
    photo.video = photo.format == 'VIDEO'
    if uuid == '' or root == '' or base == '' then
        photo.incomplete = true -- the file, folder or root row is not there (yet)
        return photo
    end
    if not SmartPreviewPath.isValidUuid(uuid) then
        photo.badUuid = uuid
    else
        photo.fileUuid = uuid:upper()
    end
    photo.folder = root .. folderPath
    photo.fileName = fileName(base, extension)
    photo.path = CatalogRead.localPath(photo.folder, photo.fileName)
    return photo
end

-- Parses the output of newSql, byIdSql or markSql. Returns
--   { photos = { { id, fileUuid, folder, fileName, path, importId (0: none), width, height (nil when unknown),
--                  virtualCopy, video, format, hasSmartPreview, incomplete (true when rows are missing),
--                  badUuid (the text, when the file id is not a UUID) }, ... } in ascending id order,
--     imports = { { id, date }, ... } in ascending id order, mark = the largest 'm' value or nil }
-- plus a list of problems (lines of another form). A photo id that comes twice is kept once.
function CatalogRead.parse(text)
    local result, problems, seen = { photos = {}, imports = {}, mark = nil }, {}, {}
    for line in tostring(text or ''):gmatch('[^\r\n]+') do
        local tag, rest = line:match('^([pim])|(.*)$')
        local fields = {}
        if rest then
            for field in (rest .. '|'):gmatch('([^|]*)|') do
                fields[#fields + 1] = field
            end
        end
        if tag == 'p' and #fields == 12 and tonumber(fields[1]) and isHex(fields[3]) and isHex(fields[4])
            and isHex(fields[5]) and isHex(fields[6]) and isHex(fields[11]) and fields[2]:find('^[%w%-]*$') then
            local photo = photoFrom(fields)
            if not seen[photo.id] then
                seen[photo.id] = true
                result.photos[#result.photos + 1] = photo
            end
        elseif tag == 'i' and #fields == 12 and tonumber(fields[1]) and isHex(fields[3]) then
            result.imports[#result.imports + 1] = { id = tonumber(fields[1]), date = unhex(fields[3]) }
        elseif tag == 'm' and #fields == 1 and fields[1]:find('^%d+$') then
            result.mark = math.max(result.mark or 0, tonumber(fields[1]))
        else
            problems[#problems + 1] = 'unexpected line: ' .. line:sub(1, 200)
        end
    end
    table.sort(result.photos, function(a, b)
        return a.id < b.id
    end)
    table.sort(result.imports, function(a, b)
        return a.id < b.id
    end)
    return result, problems
end

return CatalogRead
