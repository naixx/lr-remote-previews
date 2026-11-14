-- Library > Plug-in Extras > Build smart previews on the server.
--
-- For the selected photos: ask the server whether it can build, leave out the photos it cannot take, read their file
-- UUIDs from the catalog with sqlite3 (read-only), create one job per maxItemsPerJob photos tagged with this
-- catalog's clientId (Pipeline.prepareSend, Pipeline.sendJobs), and return at once. Nothing is downloaded or placed
-- here: the jobs are pending (PendingJobs), and the automatic fetch brings their smart previews in when they are
-- ready (or «Fetch ready smart previews» at once). Lightroom may be closed meanwhile.
--
-- Version 0.7.0 made this the one send command (it was «Send to the server»; the build command that waited with a
-- progress bar and delivered is gone). It asks no confirmation. When every selected photo was taken, it shows only a
-- short notice; a dialog appears only when something needs the user: photos left out, refused by the server, a part
-- not sent, the server unreachable, an error.
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

local TITLE = 'Build smart previews on the server'

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
    local ui = Pipeline.progressUi(progress)
    local prepared, problem = Pipeline.prepareSend(settings, catalog, photos, summary, ui)
    if not prepared then
        if problem.cancelled then
            return progress:done()
        end
        return stop(problem.message, problem.style)
    end
    local sent = Pipeline.sendJobs(settings, catalog:getPath(), prepared, summary, ui)
    if #sent.jobIds == 0 then
        return stop(sent.failedParts, 'critical')
    end
    local context2 = { jobIds = sent.jobIds, ready = sent.ready, rejected = sent.rejected,
        failedParts = sent.failedParts, fetchHint = Pipeline.FETCH_HINT, logHint = Pipeline.LOG_HINT }
    local text = summary:sendText(context2)
    Log.info('send: summary:\n%s', text)
    if summary:sendNeedsAttention(context2) then
        return stop(text, sent.failedParts and 'warning' or 'info')
    end
    progress:done()
    LrTasks.pcall(function()
        LrDialogs.showBezel(summary:sentNotice(settings.autoFetch), 4)
    end)
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext('LRRemotePreviews.build', function(context)
        local ok, err = LrTasks.pcall(run, context)
        if not ok then
            Log.error('send: unexpected error: %s', tostring(err))
            LrDialogs.message(TITLE, 'Unexpected error: ' .. tostring(err) .. '\n\n' .. Pipeline.LOG_HINT, 'critical')
        end
    end)
end)
