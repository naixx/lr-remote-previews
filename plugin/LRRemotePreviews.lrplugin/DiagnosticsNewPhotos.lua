-- Help > Plug-in Extras > Diagnostics: new photos for the automatic send.
-- Shows what the automatic send would see now, by both ways it can find new photos (AutoSend.lua), so that what the
-- SDK does not document can be checked in Lightroom: that photos added by an import get larger catalog ids
-- (photo.localIdentifier) than every photo before them, how long catalog:getAllPhotos() and the scan take, and
-- whether catalog:findPhotos with "touchTime" (Edit Date) "inLast" finds freshly imported photos. Read-only: it
-- sends nothing, writes nothing and does not move the automatic send's mark. The result goes to a dialog and the log.
local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'

local AutoSend = require 'AutoSend'
local AutoSendPlan = require 'AutoSendPlan'
local Log = require 'Log'
local PhotoAccess = require 'PhotoAccess'

local TITLE = 'New photos for the automatic send'
local SHOWN = 10
local WINDOW_HOURS = 24

local function clock()
    return os.clock and os.clock() or 0
end

local function describeLine(entry)
    local photo = PhotoAccess.describe(entry.photo, 1)
    return string.format('    %d  %s  %s  %s', entry.id, photo.fileName,
        photo.smartPreviewPath and 'has a smart preview' or 'no smart preview', tostring(photo.path))
end

local function run()
    local catalog = LrApplication.activeCatalog()
    local state = AutoSendPlan.load(LrPrefs.prefsForPlugin(), catalog:getPath())
    local mark = state and state.mark or nil
    local lines = {}
    local function add(line)
        lines[#lines + 1] = line
    end
    if state then
        add(string.format('The automatic send has dealt with every photo up to catalog id %d (the largest id it has '
            .. 'seen: %d).', state.mark, state.seen))
    else
        add('The automatic send is not watching this catalog yet (it is off, or has not had its first round).')
    end

    local started = clock()
    local all, maxId, count = AutoSend.scanAll(catalog, 0, function()
        return false
    end)
    local scanTime = clock() - started
    if not all then
        add('catalog:getAllPhotos and the scan failed: ' .. tostring(maxId))
    else
        add(string.format('Photos in the catalog: %d; largest catalog id: %d; reading them and their ids took %.2f s '
            .. '(processor time).', count, maxId, scanTime))
        add('The photos with the largest catalog ids (after an import, these should be the new photos):')
        for i = #all, math.max(1, #all - SHOWN + 1), -1 do
            add(describeLine(all[i]))
        end
        if mark then
            local above = 0
            for _, entry in ipairs(all) do
                if entry.id > mark then
                    above = above + 1
                end
            end
            add(string.format('Photos above the automatic send\'s mark: %d.', above))
        end
    end

    started = clock()
    local recent, recentProblem = AutoSend.findRecentlyEdited(catalog, 0, WINDOW_HOURS, function()
        return false
    end)
    local findTime = clock() - started
    if not recent then
        add('catalog:findPhotos (touchTime in the last ' .. WINDOW_HOURS .. ' hours) failed: '
            .. tostring(recentProblem))
    else
        add(string.format('The fallback, catalog:findPhotos with touchTime (Edit Date) in the last %d hours, found %d '
            .. 'photo(s) in %.2f s. Freshly imported photos should be among them for the fallback to work:',
            WINDOW_HOURS, #recent, findTime))
        for i = #recent, math.max(1, #recent - SHOWN + 1), -1 do
            add(describeLine(recent[i]))
        end
    end
    local text = table.concat(lines, '\n')
    Log.info('diagnostics, new photos:\n%s', text)
    LrDialogs.message(TITLE, text, 'info')
end

LrTasks.startAsyncTask(function()
    local ok, err = LrTasks.pcall(run)
    if not ok then
        Log.error('diagnostics, new photos: unexpected error: %s', tostring(err))
        LrDialogs.message(TITLE, 'Unexpected error: ' .. tostring(err), 'critical')
    end
end)
