-- The two read-only SELECTs of «Import a folder without the dialog...» and the parsing of their output. Pure Lua 5.1:
-- no Lightroom imports. They run through SqliteRunner.query, read-only like every catalog read of the plug-in
-- (decision record 0002); nothing writes.
--
-- The catalog tables, as found in Lightroom Classic 15.6 catalogs (schema read with sqlite3, read-only):
--   Adobe_variablesTable (id_local, id_global, name, type, value): the settings of the previous import are rows whose
--     name starts with "AgImportDialog_", for example importBehavior = "refInPlace" after an import with «Add».
--   Adobe_images (id_local, id_global, rootFile, ...): one row per photo; rootFile -> AgLibraryFile.id_local.
--   AgLibraryFile (id_local, baseName, extension, folder, sidecarExtensions, ...); folder -> AgLibraryFolder.
--   AgLibraryFolder (id_local, pathFromRoot, rootFolder); rootFolder -> AgLibraryRootFolder.
--   AgLibraryRootFolder (id_local, absolutePath): absolutePath with forward slashes and a trailing one ("Z:/"),
--     pathFromRoot likewise ("2026/2026.06.20 - shoot/").
--   AgLibraryImport (id_local, importDate, imageCount, name): one row per import.
-- id_local values of all these tables come from one counter (Adobe_entityIDCounter), so photos added after the mark
-- (the largest id_local of Adobe_images and AgLibraryImport now) have larger ids. That they always do is what the
-- catalog suggests and what the automatic send relies on too; it is not documented.
--
-- Every text is read through hex(), so that any character arrives as plain ASCII whatever the tool's code page.
local ImportQuery = {}

-- The settings of the previous import that the plug-in reads (ImportPlan judges them).
ImportQuery.VARIABLES = {
    'AgImportDialog_importBehavior',
    'AgImportDialog_previewBuildQuality',
    'AgImportDialog_generateDNGProxies',
    'AgImportDialog_doCopyToBackupFolder',
    'AgImportDialog_crSettingsID',
    'AgImportDialog_metadataPresetID',
    'AgImportDialog_ignoreSuspectedDuplicates',
    'AgImportDialog_importServiceProvider',
    'AgImportDialog_suppressImportDialog',
}

local function isCount(value)
    return type(value) == 'number' and value >= 0 and value == math.floor(value) and value < 2 ^ 53
end

local function unhex(hex)
    return (hex:gsub('%x%x', function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

local function isHex(text)
    return text ~= nil and #text % 2 == 0 and text:find('^%x*$') ~= nil
end

-- The SELECT for the state before an import: the settings of the previous import ('v' lines) and the largest catalog
-- ids of photos and of imports ('m' lines).
function ImportQuery.stateSql()
    local names = {}
    for i, name in ipairs(ImportQuery.VARIABLES) do
        names[i] = "'" .. name .. "'"
    end
    return "SELECT 'v', hex(name), hex(value) FROM Adobe_variablesTable WHERE name IN (" .. table.concat(names, ', ')
        .. ") UNION ALL SELECT 'm', ifnull(max(id_local), 0), '' FROM Adobe_images"
        .. " UNION ALL SELECT 'm', ifnull(max(id_local), 0), '' FROM AgLibraryImport;"
end

-- Parses stateSql's output. Returns { variables = { [name] = value }, mark = the largest id (or nil when no 'm' line
-- came), duplicates = { name, ... } (names with two different values; such a name is left out of variables) },
-- plus a list of problems (lines of another form).
function ImportQuery.parseState(text)
    local state, problems, values = { variables = {}, mark = nil, duplicates = {} }, {}, {}
    for line in tostring(text or ''):gmatch('[^\r\n]+') do
        local nameHex, valueHex = line:match('^v|(%x*)|(%x*)$')
        local mark = line:match('^m|(%d+)|$')
        if isHex(nameHex) and isHex(valueHex) then
            local name, value = unhex(nameHex), unhex(valueHex)
            if values[name] ~= nil and values[name] ~= value then
                state.duplicates[#state.duplicates + 1] = name
                values[name] = false
            elseif values[name] == nil then
                values[name] = value
            end
        elseif mark then
            state.mark = math.max(state.mark or 0, tonumber(mark))
        else
            problems[#problems + 1] = 'unexpected line: ' .. line:sub(1, 200)
        end
    end
    for name, value in pairs(values) do
        if value ~= false then
            state.variables[name] = value
        end
    end
    table.sort(state.duplicates)
    return state, problems
end

-- The SELECT for the photos and imports added since mark: 'p' lines (id, image UUID, root path, folder path, base
-- name, extension, sidecar extensions) and 'i' lines (id, import date). Or nil plus a message for a bad mark.
function ImportQuery.newSinceSql(mark)
    if not isCount(mark) then
        return nil, 'not a catalog id: ' .. tostring(mark)
    end
    local n = string.format('%d', mark)
    return "SELECT 'p', i.id_local, i.id_global, hex(r.absolutePath), hex(fo.pathFromRoot), hex(f.baseName), "
        .. "hex(f.extension), hex(ifnull(f.sidecarExtensions, '')) FROM Adobe_images i "
        .. 'JOIN AgLibraryFile f ON f.id_local = i.rootFile JOIN AgLibraryFolder fo ON fo.id_local = f.folder '
        .. 'JOIN AgLibraryRootFolder r ON r.id_local = fo.rootFolder WHERE i.id_local > ' .. n
        .. " UNION ALL SELECT 'i', id_local, '', hex(importDate), '', '', '', '' FROM AgLibraryImport"
        .. ' WHERE id_local > ' .. n .. ';'
end

-- The name of a file: baseName plus '.' plus extension (no dot without an extension).
local function fileName(baseName, extension)
    if extension == '' then
        return baseName
    end
    return baseName .. '.' .. extension
end

-- Parses newSinceSql's output. Returns { photos = { { id, uuid, folder (root path + folder path, as the catalog
-- spells it), name, sidecars }, ... } in ascending id order, imports = { { id, date }, ... } }, plus a list of
-- problems. A photo id that comes twice is kept once.
function ImportQuery.parseNewSince(text)
    local result, problems, seen = { photos = {}, imports = {} }, {}, {}
    for line in tostring(text or ''):gmatch('[^\r\n]+') do
        local id, uuid, rootHex, folderHex, baseHex, extensionHex, sidecarHex =
            line:match('^p|(%d+)|([%w%-]*)|(%x*)|(%x*)|(%x*)|(%x*)|(%x*)$')
        local importId, dateHex = line:match('^i|(%d+)||(%x*)||||$')
        local hexOk = isHex(rootHex) and isHex(folderHex) and isHex(baseHex) and isHex(extensionHex)
            and isHex(sidecarHex)
        if id and hexOk then
            local number = tonumber(id)
            if not seen[number] then
                seen[number] = true
                result.photos[#result.photos + 1] = { id = number, uuid = uuid,
                    folder = unhex(rootHex) .. unhex(folderHex), name = fileName(unhex(baseHex), unhex(extensionHex)),
                    sidecars = unhex(sidecarHex) }
            end
        elseif importId and isHex(dateHex) then
            result.imports[#result.imports + 1] = { id = tonumber(importId), date = unhex(dateHex) }
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

return ImportQuery
