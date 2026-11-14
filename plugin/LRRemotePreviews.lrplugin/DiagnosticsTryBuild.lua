-- Help > Plug-in Extras > Diagnostics: try buildSmartPreview on selected photos.
-- Calls photo:buildSmartPreview() on the selected photos (1 to 20) and writes what it returned ('created',
-- 'existed' or 'failed') with the smart preview info before and after to a tab-separated file next to the
-- catalog. In a real catalog it does what Library > Previews > Build Smart Previews does for those photos.
local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local Log = require 'Log'

local TITLE = 'Try buildSmartPreview'
local MAX_PHOTOS = 20

local function smartPreviewState(photo)
    local info = photo:getRawMetadata('smartPreviewInfo') or {}
    return tostring(info.smartPreviewSize or '') .. '\t' .. tostring(info.smartPreviewPath or '')
end

LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()
    if #photos == 0 or #photos > MAX_PHOTOS then
        LrDialogs.message(TITLE, 'Select 1 to ' .. MAX_PHOTOS .. ' photos first (' .. #photos .. ' selected).', 'info')
        return
    end
    local lines = { 'name\tresult\tbytes before\tpath before\tbytes after\tpath after' }
    local tally = {}
    for _, photo in ipairs(photos) do
        local before = smartPreviewState(photo)
        local ok, result = LrTasks.pcall(function()
            return photo:buildSmartPreview()
        end)
        result = ok and tostring(result) or ('error: ' .. tostring(result))
        tally[result] = (tally[result] or 0) + 1
        local name = tostring(photo:getFormattedMetadata('fileName') or '?')
        Log.info('buildSmartPreview %s: %s', name, result)
        lines[#lines + 1] = table.concat({ name, result, before, smartPreviewState(photo) }, '\t')
    end
    local out = LrPathUtils.child(LrPathUtils.parent(catalog:getPath()),
        'smart-preview-trybuild-' .. os.date('%H%M%S') .. '.txt')
    local f, err = io.open(out, 'w')
    if not f then
        Log.error('try build: cannot write %s: %s', out, tostring(err))
        LrDialogs.message(TITLE, 'Cannot write ' .. out .. ': ' .. tostring(err), 'critical')
        return
    end
    f:write(table.concat(lines, '\n'), '\n')
    f:close()
    local summary = {}
    for k, n in pairs(tally) do
        summary[#summary + 1] = k .. ': ' .. n
    end
    table.sort(summary)
    Log.info('try build: %s, written to %s', table.concat(summary, ', '), out)
    LrDialogs.message(TITLE, table.concat(summary, ', ') .. '\n\n' .. out, 'info')
end)
