-- Which of the selected photos are sent to the server, and why the others are not. Pure Lua 5.1: the caller
-- reads the photos' metadata from Lightroom into plain tables first, so this runs in unit tests.
--
-- A photo, as the caller describes it:
--   { fileName = 'IMG_0001.ARW', path = 'Z:\\2026\\IMG_0001.ARW', isVideo = false, isVirtualCopy = false,
--     smartPreviewPath = nil | '<path>', ... any other fields are kept }
local PathMap = require 'PathMap'
local ServerInfo = require 'ServerInfo'

local Selection = {}

-- Reasons for leaving a photo out, in the order they are checked and listed.
Selection.REASONS = { 'video', 'noPath', 'hasSmartPreview', 'unsupportedFormat', 'noMapping', 'rootUnavailable',
    'sameFile' }

local SETTINGS_HINT = 'File > Plug-in Manager > LR Remote Previews'

-- The ids of the roots the server lists as available: { [id] = true }.
function Selection.availableRoots(info)
    local available = {}
    for _, root in ipairs(info.roots or {}) do
        if root.available then
            available[root.id] = true
        end
    end
    return available
end

-- Why the server cannot be used, or nil when it can. info: ServerInfo.normalize's result; mappings:
-- Settings.mappings(). options.fetchOnly: the command only fetches what is already built, so the server needs no
-- converter.
function Selection.serverProblem(info, mappings, options)
    options = options or {}
    if not info.apiSupported then
        return 'The server speaks API ' .. tostring(info.api) .. ', this plug-in speaks API ' .. ServerInfo.API_VERSION
            .. '. Update the plug-in or the server.'
    end
    if not options.fetchOnly and not info.converter.installed then
        return 'Adobe DNG Converter is not installed on the server, so it cannot build smart previews. '
            .. 'See the server documentation for how to install it.'
    end
    if #info.capabilities.extensions == 0 then
        return 'The server accepts no file types.'
    end
    if #mappings == 0 then
        return 'No path mapping is set up. Enter at least one local prefix and server root id in '
            .. SETTINGS_HINT .. '.'
    end
    local available = Selection.availableRoots(info)
    local states = {}
    for _, mapping in ipairs(mappings) do
        if available[mapping.rootId] then
            return nil
        end
        local root = ServerInfo.findRoot(info, mapping.rootId)
        states[#states + 1] = mapping.rootId .. ' (' .. (root and 'not available' or 'not on this server') .. ')'
    end
    return 'None of the server roots in the path mappings can be used: ' .. table.concat(states, ', ') .. '.'
end

-- The extension of a path's last segment, lower case with the dot ('.arw'), or nil.
function Selection.extension(path)
    local name = path:match('([^/\\]+)$')
    local extension = name and name:match('(%.[^.]+)$')
    return extension and extension:lower() or nil
end

-- Width and height from Lightroom's 'dimensions' metadata: a table { width =, height = } or a text such as
-- '6000 x 4000'. Returns nil when the value has neither form.
function Selection.dimensions(value)
    local width, height
    if type(value) == 'table' then
        width, height = tonumber(value.width), tonumber(value.height)
    elseif type(value) == 'string' then
        local w, h = value:gsub('\195\151', 'x'):match('^%s*(%d+)%s*[xX]%s*(%d+)%s*$') -- also '6000 × 4000'
        width, height = tonumber(w), tonumber(h)
    end
    if width and height and width > 0 and height > 0 then
        return width, height
    end
    return nil
end

local function reasonFor(photo, options)
    if photo.isVideo then
        return 'video'
    end
    if type(photo.path) ~= 'string' or photo.path == '' then
        return 'noPath'
    end
    if type(photo.smartPreviewPath) == 'string' and photo.smartPreviewPath ~= '' then
        return 'hasSmartPreview'
    end
    local extension = Selection.extension(photo.path)
    if not extension or not options.extensionSet[extension] then
        return 'unsupportedFormat', extension or '(none)'
    end
    local mapped, why = PathMap.map(photo.path, options.mappings)
    if not mapped then
        return 'noMapping', why
    end
    if not options.availableRoots[mapped.rootId] then
        return 'rootUnavailable', mapped.rootId
    end
    return nil, mapped
end

-- Sorts the photos. options: { extensions = { '.arw', ... } (lower case), mappings = { ... },
-- availableRoots = { [id] = true } }.
-- Returns { eligible = { photo, ... }, skipped = { { photo = ..., reason = ..., detail = ... }, ... },
--           counts = { [reason] = n } }.
-- An eligible photo gets rootId and relativePath. Photos keep their order. Of several photos with the same
-- file (a photo and its virtual copies) the first one that is not a virtual copy is sent, or the first virtual
-- copy when only copies are selected; the others are skipped as 'sameFile'.
function Selection.classify(photos, options)
    local extensionSet = {}
    for _, extension in ipairs(options.extensions or {}) do
        extensionSet[extension:lower()] = true
    end
    local settings = {
        extensionSet = extensionSet,
        mappings = options.mappings or {},
        availableRoots = options.availableRoots or {},
    }

    local result = { eligible = {}, skipped = {}, counts = {} }
    local verdicts = {}
    for i, photo in ipairs(photos) do
        local reason, detail = reasonFor(photo, settings)
        verdicts[i] = { reason = reason, detail = detail }
    end

    -- Same file: originals first, then virtual copies.
    local taken = {}
    for pass = 1, 2 do
        for i, photo in ipairs(photos) do
            local verdict = verdicts[i]
            if not verdict.reason and (photo.isVirtualCopy and 2 or 1) == pass then
                local key = PathMap.fileKey(photo.path)
                if taken[key] then
                    verdict.reason, verdict.detail = 'sameFile', photos[taken[key]].fileName
                else
                    taken[key] = i
                end
            end
        end
    end

    for i, photo in ipairs(photos) do
        local verdict = verdicts[i]
        if verdict.reason then
            result.skipped[#result.skipped + 1] = { photo = photo, reason = verdict.reason, detail = verdict.detail }
            result.counts[verdict.reason] = (result.counts[verdict.reason] or 0) + 1
        else
            photo.rootId = verdict.detail.rootId
            photo.relativePath = verdict.detail.relativePath
            result.eligible[#result.eligible + 1] = photo
        end
    end
    return result
end

return Selection
