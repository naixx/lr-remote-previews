-- Where Lightroom Classic keeps a photo's smart preview. Pure Lua 5.1: no Lightroom imports.
--
--   <catalog folder>/<catalog base name> Smart Previews.lrdata/<U[1]>/<U[1..4]>/<U>.dng
--
-- U is the file UUID (AgLibraryFile.id_global in the catalog database), upper-case with dashes.
-- It is NOT what photo:getRawMetadata('uuid') returns (that is the image's id). Example:
--   catalog C:\Photos\Main\Main.lrcat, U = 62823DFE-E7D3-40FF-938C-518FDECC6CF6 gives
--   C:\Photos\Main\Main Smart Previews.lrdata\6\6282\62823DFE-E7D3-40FF-938C-518FDECC6CF6.dng
--
-- The separator follows the catalog path: a Windows path (drive letter, UNC, or any backslash) gets '\',
-- with any forward slashes turned into backslashes; anything else gets '/'.
-- Functions return nil plus a message on bad input.
local SmartPreviewPath = {}

local UUID_PATTERN = '^' .. string.rep('%x', 8) .. '%-' .. string.rep('%x', 4) .. '%-' .. string.rep('%x', 4)
    .. '%-' .. string.rep('%x', 4) .. '%-' .. string.rep('%x', 12) .. '$'

-- True for 8-4-4-4-12 hexadecimal digits (either case), nothing else around them.
function SmartPreviewPath.isValidUuid(uuid)
    return type(uuid) == 'string' and uuid:match(UUID_PATTERN) ~= nil
end

-- The UUID in upper case, as Lightroom names the files; or nil plus a message.
function SmartPreviewPath.normalizeUuid(uuid)
    if not SmartPreviewPath.isValidUuid(uuid) then
        return nil, 'not a file UUID: ' .. tostring(uuid)
    end
    return uuid:upper()
end

local function isWindowsPath(path)
    return path:match('^%a:') ~= nil or path:match('^[/\\][/\\]') ~= nil or path:find('\\', 1, true) ~= nil
end

-- The separator used for paths next to this catalog: '\' or '/'.
function SmartPreviewPath.separator(catalogPath)
    if type(catalogPath) == 'string' and isWindowsPath(catalogPath) then
        return '\\'
    end
    return '/'
end

-- The smart preview store of a catalog: <catalog folder><sep><base name> Smart Previews.lrdata
function SmartPreviewPath.storeFolder(catalogPath)
    if type(catalogPath) ~= 'string' or catalogPath == '' then
        return nil, 'no catalog path given'
    end
    local folder, file
    if SmartPreviewPath.separator(catalogPath) == '\\' then
        folder, file = catalogPath:gsub('/', '\\'):match('^(.*\\)([^\\]*)$')
    else
        folder, file = catalogPath:match('^(.*/)([^/]*)$')
    end
    if not folder then
        return nil, 'the catalog path has no folder: ' .. catalogPath
    end
    local base = file:match('^(.+)%.[lL][rR][cC][aA][tT]$')
    if not base then
        return nil, 'not a .lrcat file: ' .. catalogPath
    end
    return folder .. base .. ' Smart Previews.lrdata'
end

-- The full path of the smart preview DNG for a file UUID; or nil plus a message.
function SmartPreviewPath.dngPath(catalogPath, fileUuid)
    local store, storeError = SmartPreviewPath.storeFolder(catalogPath)
    if not store then
        return nil, storeError
    end
    local uuid, uuidError = SmartPreviewPath.normalizeUuid(fileUuid)
    if not uuid then
        return nil, uuidError
    end
    return table.concat({ store, uuid:sub(1, 1), uuid:sub(1, 4), uuid .. '.dng' },
        SmartPreviewPath.separator(catalogPath))
end

return SmartPreviewPath
