-- Matches photos to the file records read from the catalog with sqlite3 (SqliteCommand.parseLookup's rows) and gives
-- each photo the path of its smart preview. Shared by every command that sends or fetches. Pure Lua 5.1: no
-- Lightroom imports.
local SmartPreviewPath = require 'SmartPreviewPath'
local SqliteCommand = require 'SqliteCommand'

local FileIds = {}

-- The catalog ids (photo.localId) of the photos that have one, in order.
function FileIds.ids(photos)
    local ids = {}
    for _, photo in ipairs(photos) do
        if type(photo.localId) == 'number' then
            ids[#ids + 1] = photo.localId
        end
    end
    return ids
end

-- photos: { { fileName, localId, ... }, ... }; rows: keyed by catalog id ({ fileUuid, baseName, extension });
-- catalogPath: the catalog file. Returns
--   { entries = { photo, ... }, skipped = { { photo, reason, detail }, ... } }
-- Every entry gets fileUuid, dest (the smart preview path) and ref (its number among the entries, as a string).
-- Reasons: 'noLocalId' (Lightroom gave no catalog id), 'noFileId' (not in the catalog database, or no valid
-- UUID), 'fileIdMismatch' (the database names another file than Lightroom), 'sameFile' (an earlier photo has the
-- same file UUID).
function FileIds.assign(photos, rows, catalogPath)
    local result = { entries = {}, skipped = {} }
    local byUuid = {}
    for _, photo in ipairs(photos) do
        local row = type(photo.localId) == 'number' and rows[photo.localId] or nil
        local reason, detail, dest
        if type(photo.localId) ~= 'number' then
            reason = 'noLocalId'
        elseif not row then
            reason, detail = 'noFileId', 'catalog id ' .. string.format('%d', photo.localId)
        elseif SqliteCommand.fileNameOf(row):lower() ~= tostring(photo.fileName):lower() then
            reason, detail = 'fileIdMismatch', 'the catalog database names "' .. SqliteCommand.fileNameOf(row)
                .. '" for catalog id ' .. string.format('%d', photo.localId)
        elseif byUuid[row.fileUuid] then
            reason, detail = 'sameFile', byUuid[row.fileUuid].fileName
        else
            dest, detail = SmartPreviewPath.dngPath(catalogPath, row.fileUuid)
            if not dest then
                reason = 'noFileId'
            end
        end
        if reason then
            result.skipped[#result.skipped + 1] = { photo = photo, reason = reason, detail = detail }
        else
            photo.dest = dest
            photo.fileUuid = row.fileUuid
            photo.ref = tostring(#result.entries + 1)
            byUuid[row.fileUuid] = photo
            result.entries[#result.entries + 1] = photo
        end
    end
    return result
end

return FileIds
