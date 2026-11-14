-- Library > Plug-in Extras > Build smart previews on the server.
--
-- For the selected photos: ask the server what it can do; keep the photos it can build; read their file UUIDs
-- from the catalog with sqlite3 (read-only); create one job tagged with this catalog's clientId; poll it; deliver
-- every finished DNG into the smart preview store (downloaded several at a time, checked, written under a temporary
-- name and renamed one at a time, never over an existing file) and let Lightroom register it with
-- photo:buildSmartPreview(); show a summary and log a line per photo. While it waits for the job it holds the fetch
-- lock, so the automatic fetch does not deliver the same files meanwhile.
--
-- The decisions live in pure, unit-tested modules (Selection, FileIds, Jobs, JobTracker, JobRunner, DownloadQueue,
-- Delivery, RunSummary, Lease); Pipeline connects them to the SDK, and this file runs the steps.
local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrPrefs = import 'LrPrefs'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'

local JobRunner = require 'JobRunner'
local JobTracker = require 'JobTracker'
local Jobs = require 'Jobs'
local Log = require 'Log'
local PhotoAccess = require 'PhotoAccess'
local Pipeline = require 'Pipeline'
local RunSummary = require 'RunSummary'
local ServerClient = require 'ServerClient'
local Settings = require 'Settings'

local TITLE = 'Build smart previews on the server'

-- Steps 4 to 6, holding the fetch lock: the job, polling and delivery, the summary. Returns the summary text and
-- the dialog style.
local function buildAndWait(settings, catalog, entries, summary, progress, lease, maxItems)
    local function isCanceled()
        lease.refresh() -- a lost lock is only logged here: cancelling the user's job for it would be worse
        return progress:isCanceled()
    end

    -- 4. The job.
    progress:setCaption('Sending the job')
    local clientId = Pipeline.clientId(catalog:getPath())
    local body, bodyError = Jobs.createBody(entries, { clientId = clientId })
    if not body then
        return 'Cannot build the job request: ' .. bodyError, 'critical'
    end
    local created, createProblem = ServerClient.createJob(settings, body)
    if not created then
        Log.warn('build: creating the job failed: %s', createProblem.message)
        return Jobs.createProblemText(createProblem, maxItems), 'critical'
    end
    local jobId = created.job.id
    local refsOk, refsProblem = Jobs.checkRefs(created.items, entries)
    if not refsOk then
        ServerClient.cancelJob(settings, jobId)
        return 'The server\'s answer does not match the request (' .. refsProblem .. '). The job was cancelled.',
            'critical'
    end
    summary.sent = #entries
    Log.info('build: job %d created with %d item(s)', jobId, #entries)

    -- 5. Polling; ready files go into the download queue, which places them one at a time in this task.
    local byRef, refs = {}, {}
    for i, entry in ipairs(entries) do
        byRef[entry.ref] = entry
        refs[i] = entry.ref
    end
    local queue = Pipeline.newQueue(settings, summary)
    local function handle(item)
        local entry = byRef[item.ref]
        if item.state == 'ready' then
            entry.itemId = item.id
            entry.result = item.result
            queue:add(entry)
        elseif item.state == 'failed' or item.state == 'rejected' then
            local code = (item.error and item.error.code) or 'unknown'
            local message = item.error and item.error.message
            Pipeline.record(summary, entry, item.state, code .. (message and (': ' .. message) or ''), code)
        else
            Pipeline.record(summary, entry, 'cancelled')
        end
    end
    local result = JobRunner.run({
        fetchItems = function(since)
            return ServerClient.fetchItems(settings, jobId, since)
        end,
        handle = handle,
        isCanceled = isCanceled,
        sleep = function(seconds)
            queue:pump(isCanceled)
            LrTasks.sleep(seconds)
        end,
        cancelJob = function()
            return ServerClient.cancelJob(settings, jobId)
        end,
        progress = function(tracker)
            progress:setPortionComplete(tracker.final, tracker.total)
            progress:setCaption(string.format('%d of %d finished on the server, %d placed', tracker.final,
                tracker.total, summary:placed()))
        end,
        log = function(...)
            Log.info(...)
        end,
    }, JobTracker.new(refs), created.items)

    local stoppedWhileFetching = false
    if not result.cancelled then
        progress:setCaption('Fetching the last smart previews')
        stoppedWhileFetching = not queue:drain(isCanceled)
    end
    for _, entry in ipairs(queue:stop()) do
        Pipeline.record(summary, entry, 'notDelivered')
    end
    for _, entry in ipairs(entries) do
        if not entry.outcome then
            Pipeline.record(summary, entry, 'notDelivered')
        end
    end
    Log.info('downloads: at most %d were in flight at once', queue.maxInFlight)

    -- 6. The summary.
    local aborted = result.aborted
    if aborted then
        aborted = aborted .. ' Job ' .. jobId .. ' was left on the server; what it builds stays in its cache, so '
            .. '«Fetch ready smart previews» brings those files later.'
        Log.warn('build: stopped: %s', aborted)
    end
    local text = summary:text({
        cancelled = result.cancelled or stoppedWhileFetching,
        cancelledText = stoppedWhileFetching and ('Stopped. The server has finished job ' .. jobId .. '; the smart '
            .. 'previews not placed yet can be fetched later with «Fetch ready smart previews».') or nil,
        cancelProblem = result.cancelProblem and result.cancelProblem.message,
        aborted = aborted,
        logHint = Pipeline.LOG_HINT,
    })
    Log.info('build: summary:\n%s', text)
    return text, (aborted or summary:troubled()) and 'warning' or 'info'
end

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
    Log.info('build: %d photo(s) selected, %d path mapping(s)', #photos, #Settings.mappings(settings))

    local progress = LrProgressScope { title = TITLE, functionContext = context }
    PhotoAccess.try('progress:setCancelable', function()
        progress:setCancelable(true)
    end)
    local function stop(text, style)
        progress:done()
        LrDialogs.message(TITLE, text, style or 'info')
    end

    -- 1 to 3. The server, the selection, the file UUIDs.
    local summary = RunSummary.new(#photos)
    local prepared, problem = Pipeline.prepareSend(settings, catalog, photos, summary, Pipeline.progressUi(progress))
    if not prepared then
        if problem.cancelled then
            return progress:done()
        end
        return stop(problem.message, problem.style)
    end
    local entries = prepared.entries
    local maxItems = prepared.info.capabilities.maxItemsPerJob
    if maxItems and #entries > maxItems then
        return stop(string.format('%d photos would be sent, but the server takes at most %d per job. '
            .. 'Select fewer photos, or use «Send to the server», which splits them into several jobs.', #entries,
            maxItems))
    end
    if LrDialogs.confirm(TITLE, summary:plan(#entries), 'Build', 'Cancel') ~= 'ok' then
        Log.info('build: not confirmed')
        return progress:done()
    end

    local started, text, style = Pipeline.withLease('«Build smart previews on the server»', function(lease)
        return buildAndWait(settings, catalog, entries, summary, progress, lease, maxItems)
    end)
    if not started then
        return stop(text, 'info')
    end
    stop(text, style)
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext('LRRemotePreviews.buildSmartPreviews', function(context)
        local ok, err = LrTasks.pcall(run, context)
        if not ok then
            Log.error('build: unexpected error: %s', tostring(err))
            LrDialogs.message(TITLE, 'Unexpected error: ' .. tostring(err) .. '\n\n' .. Pipeline.LOG_HINT, 'critical')
        end
    end)
end)
