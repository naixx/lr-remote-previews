-- Library > Plug-in Extras > Send to the server.
--
-- For the selected photos: the same checks as «Build smart previews on the server» (the server, the selection, the
-- file UUIDs read with sqlite3, read-only), then one job per maxItemsPerJob photos, tagged with this catalog's
-- clientId (Pipeline.sendJobs, which «Add a folder without previews...» uses too), and back at once. Nothing is
-- downloaded or placed; Lightroom may be closed afterwards. The smart previews are brought in later by «Fetch ready
-- smart previews» (or the automatic fetch).
local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrPrefs = import 'LrPrefs'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'

local Log = require 'Log'
local PhotoAccess = require 'PhotoAccess'
local Pipeline = require 'Pipeline'
local RunSummary = require 'RunSummary'
local Settings = require 'Settings'

local TITLE = 'Send to the server'

local function run(context)
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()
    if #photos == 0 then
        LrDialogs.message(TITLE, 'Select the photos first.', 'info')
        return
    end
    PhotoAccess.resetWarnings()
    local settings = Settings.read(LrPrefs.prefsForPlugin())
    for _, problem in ipairs(Settings.mappingProblems(settings)) do
        Log.warn('settings: %s', problem)
    end
    Log.info('send: %d photo(s) selected, %d path mapping(s)', #photos, #Settings.mappings(settings))

    local progress = LrProgressScope { title = TITLE, functionContext = context }
    PhotoAccess.try('progress:setCancelable', function()
        progress:setCancelable(true)
    end)
    local function stop(text, style)
        progress:done()
        LrDialogs.message(TITLE, text, style or 'info')
    end

    local summary = RunSummary.new(#photos)
    local prepared, problem = Pipeline.prepareSend(settings, catalog, photos, summary, Pipeline.progressUi(progress))
    if not prepared then
        if problem.cancelled then
            return progress:done()
        end
        return stop(problem.message, problem.style)
    end
    local entries = prepared.entries
    if LrDialogs.confirm(TITLE, summary:plan(#entries), 'Send', 'Cancel') ~= 'ok' then
        Log.info('send: not confirmed')
        return progress:done()
    end

    local sent = Pipeline.sendJobs(settings, catalog:getPath(), prepared, summary, Pipeline.progressUi(progress))
    if #sent.jobIds == 0 then
        return stop(sent.failedParts, 'critical')
    end
    local text = summary:sendText({
        jobIds = sent.jobIds,
        ready = sent.ready,
        rejected = sent.rejected,
        failedParts = sent.failedParts,
        fetchHint = Pipeline.FETCH_HINT,
        logHint = Pipeline.LOG_HINT,
    })
    Log.info('send: summary:\n%s', text)
    stop(text, sent.failedParts and 'warning' or 'info')
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext('LRRemotePreviews.send', function(context)
        local ok, err = LrTasks.pcall(run, context)
        if not ok then
            Log.error('send: unexpected error: %s', tostring(err))
            LrDialogs.message(TITLE, 'Unexpected error: ' .. tostring(err) .. '\n\n' .. Pipeline.LOG_HINT, 'critical')
        end
    end)
end)
