-- Reading photos from Lightroom into plain tables for the pure modules, finding photos by path, and the file
-- operations Delivery needs. Shared by every command. Every SDK call is wrapped, so that a failing call becomes a
-- logged problem instead of stopping the command. Must run inside an LrTasks task.
local LrFileUtils = import 'LrFileUtils'
local LrTasks = import 'LrTasks'

local Log = require 'Log'
local PathMap = require 'PathMap'
local Selection = require 'Selection'

local PhotoAccess = {}

local warned = {}

-- Forgets which failures were already logged (call at the start of a run, so each run logs them once).
function PhotoAccess.resetWarnings()
    warned = {}
end

-- Calls fn; returns its value, or nil when it raised an error (logged once per what and run).
function PhotoAccess.try(what, fn)
    local ok, value = LrTasks.pcall(fn)
    if ok then
        return value
    end
    if not warned[what] then
        warned[what] = true
        Log.warn('%s failed: %s (logged once)', what, tostring(value))
    end
    return nil
end

-- photo.localIdentifier as a positive integer, or nil.
local function catalogId(value)
    local number = tonumber(value)
    if number and number >= 1 and number == math.floor(number) then
        return number
    end
    return nil
end

-- A plain description of one photo for the pure modules.
function PhotoAccess.describe(photo, index)
    local function raw(key)
        return PhotoAccess.try('getRawMetadata(' .. key .. ')', function()
            return photo:getRawMetadata(key)
        end)
    end
    local smartPreview = raw('smartPreviewInfo')
    local fileFormat = raw('fileFormat')
    local width, height = Selection.dimensions(raw('dimensions'))
    local fileName = PhotoAccess.try('getFormattedMetadata(fileName)', function()
        return photo:getFormattedMetadata('fileName')
    end)
    return {
        index = index,
        photo = photo,
        fileName = type(fileName) == 'string' and fileName or '?',
        path = raw('path'),
        isVideo = raw('isVideo') == true or fileFormat == 'VIDEO',
        isVirtualCopy = raw('isVirtualCopy') == true,
        smartPreviewPath = type(smartPreview) == 'table' and smartPreview.smartPreviewPath or nil,
        localId = catalogId(PhotoAccess.try('photo.localIdentifier', function()
            return photo.localIdentifier
        end)),
        width = width,
        height = height,
    }
end

-- Describes a list of photos; progress (optional) is { portion(done, total), isCanceled() }.
-- Returns the descriptions, or nil when cancelled.
function PhotoAccess.describeAll(photos, progress)
    local described = {}
    for i, photo in ipairs(photos) do
        if progress and progress.isCanceled() then
            return nil
        end
        described[i] = PhotoAccess.describe(photo, i)
        if progress then
            progress.portion(i, #photos)
        end
    end
    return described
end

-- The photos the user selected. Lightroom's getTargetPhotos() returns the whole filmstrip when nothing is
-- selected; getTargetPhoto() returns nil then, so it tells the two apart. Returns the photos and whether there
-- was a selection. When getTargetPhoto() cannot be called, getTargetPhotos() is taken as the selection.
function PhotoAccess.selection(catalog)
    local photos = PhotoAccess.try('catalog:getTargetPhotos', function()
        return catalog:getTargetPhotos()
    end) or {}
    local ok, active = LrTasks.pcall(function()
        return catalog:getTargetPhoto()
    end)
    if not ok then
        Log.warn('catalog:getTargetPhoto failed: %s; taking getTargetPhotos as the selection', tostring(active))
        return photos, #photos > 0
    end
    if active == nil then
        return {}, false
    end
    return photos, #photos > 0
end

local function isWindowsPath(path)
    return path:match('^%a:') ~= nil or path:match('^[/\\][/\\]') ~= nil
end

-- The photo of the catalog whose original is at path, or nil. Windows paths are also looked up without regard to
-- case, because the prefix in the settings may be spelled differently from the catalog. The photo's own path is
-- compared with path afterwards (PathMap.fileKey), so a looser match is never taken for another file.
function PhotoAccess.findByPath(catalog, path)
    local photo = PhotoAccess.try('catalog:findPhotoByPath', function()
        return catalog:findPhotoByPath(path)
    end)
    if not photo and isWindowsPath(path) then
        photo = PhotoAccess.try('catalog:findPhotoByPath (not case-sensitive)', function()
            return catalog:findPhotoByPath(path, false)
        end)
    end
    if not photo then
        return nil
    end
    local actual = PhotoAccess.try('getRawMetadata(path)', function()
        return photo:getRawMetadata('path')
    end)
    if type(actual) ~= 'string' or PathMap.fileKey(actual) ~= PathMap.fileKey(path) then
        Log.warn('findPhotoByPath("%s") gave a photo at "%s"; not taken', path, tostring(actual))
        return nil
    end
    return photo
end

local function exists(path)
    local kind = LrFileUtils.exists(path)
    return kind ~= nil and kind ~= false
end

local function writeFile(path, data)
    local file, openError = io.open(path, 'wb')
    if not file then
        return false, openError
    end
    local written, writeError = file:write(data)
    local closed, closeError = file:close()
    if not written or not closed then
        return false, writeError or closeError or 'write failed'
    end
    return true
end

-- The file operations Delivery needs, for one photo.
function PhotoAccess.fileSystem(photo)
    return {
        exists = exists,
        makeFolder = function(path)
            return LrTasks.pcall(LrFileUtils.createAllDirectories, path)
        end,
        writeFile = writeFile,
        move = function(from, to)
            return LrTasks.pcall(LrFileUtils.move, from, to)
        end,
        delete = function(path)
            return LrTasks.pcall(LrFileUtils.delete, path)
        end,
        buildSmartPreview = function()
            return LrTasks.pcall(function()
                return photo:buildSmartPreview()
            end)
        end,
    }
end

return PhotoAccess
