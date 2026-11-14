-- Help > Plug-in Extras > Diagnostics: smart preview report (all photos).
-- Writes what Lightroom itself says about every photo's smart preview to a tab-separated file next to the
-- catalog: file name, the SDK's "uuid" (the image id, not the file UUID that names the DNG), smart preview
-- size and path (empty when Lightroom sees no smart preview). Read-only: it only asks for metadata.
local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local Log = require 'Log'
local TextWrap = require 'TextWrap'

local TITLE = 'Smart preview report'

LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getAllPhotos()
    local lines = { 'name\tsdk uuid\tsmart preview bytes\tsmart preview path' }
    local with = 0
    for _, photo in ipairs(photos) do
        local info = photo:getRawMetadata('smartPreviewInfo') or {}
        local path = info.smartPreviewPath or ''
        if path ~= '' then
            with = with + 1
        end
        lines[#lines + 1] = table.concat({
            tostring(photo:getFormattedMetadata('fileName') or '?'),
            tostring(photo:getRawMetadata('uuid') or '?'),
            tostring(info.smartPreviewSize or ''),
            path,
        }, '\t')
    end
    local out = LrPathUtils.child(LrPathUtils.parent(catalog:getPath()),
        'smart-preview-report-' .. os.date('%H%M%S') .. '.txt')
    local f, err = io.open(out, 'w')
    if not f then
        Log.error('report: cannot write %s: %s', out, tostring(err))
        LrDialogs.message(TITLE, 'Cannot write ' .. TextWrap.shortPath(out) .. ': ' .. tostring(err), 'critical')
        return
    end
    f:write(table.concat(lines, '\n'), '\n')
    f:close()
    Log.info('report: %d photos, %d with a smart preview, written to %s', #photos, with, out)
    LrDialogs.message(TITLE, string.format('%d photos, %d with a smart preview.\n\n%s', #photos, with,
        TextWrap.shortPath(out)), 'info')
end)
