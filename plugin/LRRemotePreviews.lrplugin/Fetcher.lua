-- «Fetch ready smart previews»: brings what the server has finished into the catalog, for the selected photos or
-- for everything this catalog sent. Used by the Fetch command, the status dialog and the automatic fetch.
-- Resumable and idempotent: a photo that already has a smart preview is left out, nothing is ever overwritten, and
-- what a run did not get to is fetched by the next one. The caller holds the fetch lock (Pipeline.withLease).
-- Must run inside an LrTasks task.
local LrDialogs = import 'LrDialogs'
local LrPrefs = import 'LrPrefs'
local LrProgressScope = import 'LrProgressScope'

local CatalogState = require 'CatalogState'
local FetchPlan = require 'FetchPlan'
local Log = require 'Log'
local PathMap = require 'PathMap'
local PhotoAccess = require 'PhotoAccess'
local Pipeline = require 'Pipeline'
local RunSummary = require 'RunSummary'
local Selection = require 'Selection'
local ServerClient = require 'ServerClient'
local Settings = require 'Settings'

local Fetcher = {}

Fetcher.CANCELLED_TEXT = 'Stopped. Smart previews already placed stay; the next fetch continues with the rest.'

local function classifyOptions(info, mappings)
    return {
        extensions = info.capabilities.extensions,
        mappings = mappings,
        availableRoots = Selection.availableRoots(info),
    }
end

-- Looks the eligible photos up, records pending/absent/rejected, finds the file UUIDs of the ready ones, downloads
-- and places them. Returns { cancelled = bool, aborted = message | nil }.
local function lookUpAndDeliver(settings, info, catalogPath, eligible, summary, ui)
    if #eligible == 0 then
        return {}
    end
    local answers, problem = Pipeline.lookup(settings, info, eligible, ui)
    if not answers then
        if problem.kind == 'cancelled' then
            return { cancelled = true }
        end
        return { aborted = problem.message }
    end
    local ready = {}
    for _, photo in ipairs(eligible) do
        local answer = answers[photo]
        if answer.state == 'ready' then
            photo.result = answer.result
            photo.key = answer.result and answer.result.key
            ready[#ready + 1] = photo
        elseif answer.state == 'rejected' then
            local code = (answer.error and answer.error.code) or 'unknown'
            local message = answer.error and answer.error.message
            Pipeline.record(summary, photo, 'rejected', code .. (message and (': ' .. message) or ''), code)
        else
            Pipeline.record(summary, photo, answer.state) -- 'pending' or 'absent'
        end
    end
    if #ready == 0 then
        return {}
    end
    local entries, idProblem = Pipeline.resolveFileIds(settings, catalogPath, ready, summary, ui)
    if not entries then
        if idProblem == 'cancelled' then
            return { cancelled = true }
        end
        return { aborted = idProblem }
    end
    if not Pipeline.deliverAll(settings, entries, summary, ui) then
        return { cancelled = true }
    end
    return {}
end

-- For the selected photos. photos: LrPhoto objects. Returns
--   { summary, text, troubled, cancelled } or { problem = message } when nothing could be started.
function Fetcher.selection(settings, info, catalog, photos, ui)
    PhotoAccess.resetWarnings()
    local mappings = Settings.mappings(settings)
    local serverProblem = Selection.serverProblem(info, mappings, { fetchOnly = true })
    if serverProblem then
        return { problem = serverProblem }
    end
    Log.info('fetch: %d selected photo(s)', #photos)
    ui.caption('Reading the selection')
    local described = PhotoAccess.describeAll(photos, ui)
    local summary = RunSummary.new(#photos)
    if not described then
        return { summary = summary, cancelled = true, text = Fetcher.CANCELLED_TEXT }
    end
    local selection = Selection.classify(described, classifyOptions(info, mappings))
    for _, skipped in ipairs(selection.skipped) do
        Pipeline.skip(summary, skipped.photo, skipped.reason, skipped.detail)
    end
    summary.sent = #selection.eligible
    local result = lookUpAndDeliver(settings, info, catalog:getPath(), selection.eligible, summary, ui)
    local text = summary:text({
        header = string.format('%d photo(s) selected, %d looked up on the server.', #photos, #selection.eligible),
        skipHeading = 'Left out',
        cancelled = result.cancelled,
        cancelledText = Fetcher.CANCELLED_TEXT,
        aborted = result.aborted,
        stoppedBefore = #selection.eligible == 0 and 'Nothing to look up.' or nil,
        logHint = Pipeline.LOG_HINT,
    })
    Log.info('fetch: summary:\n%s', text)
    return { summary = summary, text = text, cancelled = result.cancelled,
        troubled = result.aborted ~= nil or summary:troubled() }
end

-- Finds the photo for a job item ({ root, path }) by mapping the path back to this computer. cache: local path ->
-- photo or false. Returns the photo, or nil plus a skip reason and detail.
local function photoForItem(catalog, item, mappings, cache)
    local paths, why = PathMap.localPaths(item.root or '', item.path, mappings)
    if not paths then
        return nil, 'badPath', why
    end
    if #paths == 0 then
        return nil, 'badPath', 'no path mapping leads to the server root ' .. tostring(item.root)
    end
    for _, path in ipairs(paths) do
        if cache[path] == nil then
            cache[path] = PhotoAccess.findByPath(catalog, path) or false
        end
        if cache[path] then
            return cache[path]
        end
    end
    return nil, 'notInCatalog', table.concat(paths, ' or ')
end

-- For everything this catalog sent. getInfo() -> info | nil, problem is called only when there is something to
-- fetch (the automatic fetch asks every minute, mostly for nothing). Returns
--   { summary, text, troubled, cancelled, nothingNew = bool } or { problem = message }.
function Fetcher.everything(settings, getInfo, catalog, ui, quiet)
    PhotoAccess.resetWarnings()
    local prefs = LrPrefs.prefsForPlugin()
    local catalogPath = catalog:getPath()
    local clientId = CatalogState.clientId(prefs, catalogPath)
    if not clientId then
        return { problem = 'This catalog has not sent anything to the server yet (only «Send to the server» and '
            .. '«Build smart previews on the server» of version 0.3.0 or newer mark a job as this catalog\'s).',
            nothingNew = true }
    end
    ui.caption('Asking the server for this catalog\'s jobs')
    local jobs, listProblem = ServerClient.listJobs(settings, clientId, quiet)
    if not jobs then
        return { problem = listProblem.message }
    end
    local plan = FetchPlan.plan(jobs, CatalogState.jobs(prefs, catalogPath), clientId)
    local records = plan.records
    local queuedOrBuilding, failed, listed = 0, 0, 0
    for _, job in ipairs(jobs) do
        if job.clientId == clientId then
            listed = listed + 1
            queuedOrBuilding = queuedOrBuilding + job.counts.queued + job.counts.building
            failed = failed + job.counts.failed
        end
    end
    if plan.foreign > 0 then
        Log.warn('fetch: the server listed %d job(s) of other clients for this clientId; ignored', plan.foreign)
    end
    if #jobs >= 200 then
        Log.warn('fetch: the server listed the maximum of 200 jobs; older jobs of this catalog are not looked at')
    end
    Log.info('fetch everything: %d job(s) of this catalog, %d to read, %d fetched before, %d waiting', listed,
        #plan.read, plan.done, plan.waiting)

    local summary = RunSummary.new(0)
    local notes = {}
    if queuedOrBuilding > 0 or failed > 0 then
        notes[#notes + 1] = string.format('On the server: %d photo(s) of this catalog queued or being built, %d failed '
            .. '(Server status can retry failed ones).', queuedOrBuilding, failed)
    end

    local function finish(result)
        result.summary = summary
        CatalogState.saveJobs(prefs, catalogPath, records)
        local header = string.format('This catalog\'s jobs on the server: %d (%d read now, %d fully fetched '
            .. 'before, %d with nothing ready yet). %d finished file(s) looked at.', listed, #plan.read, plan.done,
            plan.waiting, summary.selected)
        result.text = summary:text({
            header = header,
            skipHeading = 'Left out',
            cancelled = result.cancelled,
            cancelledText = Fetcher.CANCELLED_TEXT,
            aborted = result.aborted,
            notes = notes,
            stoppedBefore = summary.selected == 0 and not result.aborted and not result.cancelled
                and 'Nothing new to fetch.' or nil,
            logHint = Pipeline.LOG_HINT,
        })
        result.troubled = result.aborted ~= nil or summary:troubled()
        result.nothingNew = summary.selected == 0 and not result.aborted
        if not quiet or summary.selected > 0 or result.aborted then
            Log.info('fetch everything: summary:\n%s', result.text)
        end
        return result
    end

    if #plan.read == 0 then
        return finish({})
    end
    local info, infoProblem = getInfo()
    if not info then
        return { problem = infoProblem.message }
    end
    local mappings = Settings.mappings(settings)
    local serverProblem = Selection.serverProblem(info, mappings, { fetchOnly = true })
    if serverProblem then
        return { problem = serverProblem }
    end

    -- 1. The ready items of every job that may have something new.
    local readJobs = {}
    for _, entry in ipairs(plan.read) do
        local id = string.format('%d', entry.job.id)
        ui.caption('Reading job ' .. id)
        local items, problem = ServerClient.readItems(settings, entry.job.id, entry.since, 'ready', ui.isCanceled)
        if items then
            readJobs[#readJobs + 1] = { job = entry.job, since = entry.since, items = items }
        elseif problem.kind == 'cancelled' then
            return finish({ cancelled = true })
        elseif problem.gone then
            records[id] = nil
            Log.info('fetch: job %s is gone from the server', id)
        else
            notes[#notes + 1] = 'Job ' .. id .. ' could not be read: ' .. problem.message
        end
    end

    -- 2. The photos of those items, by path.
    ui.caption('Finding the photos in the catalog')
    local cache, byKey, photos, total = {}, {}, {}, 0
    for _, entry in ipairs(readJobs) do
        total = total + #entry.items
    end
    local seen = 0
    for _, entry in ipairs(readJobs) do
        for _, item in ipairs(entry.items) do
            if ui.isCanceled() then
                return finish({ cancelled = true })
            end
            seen = seen + 1
            ui.portion(seen, total)
            local photo, reason, detail = photoForItem(catalog, item, mappings, cache)
            if not photo then
                item.outcome = reason
                summary.selected = summary.selected + 1
                summary:skip(reason)
                Log.info('%s', RunSummary.photoLine(item.path, reason, detail))
            else
                local described = PhotoAccess.describe(photo, #photos + 1)
                local key = PathMap.fileKey(described.path)
                item.fileKey = key
                if not byKey[key] then
                    byKey[key] = described
                    photos[#photos + 1] = described
                end
            end
        end
    end
    summary.selected = summary.selected + #photos

    -- 3. The same checks as for a selection, then lookup and delivery.
    local selection = Selection.classify(photos, classifyOptions(info, mappings))
    for _, skipped in ipairs(selection.skipped) do
        Pipeline.skip(summary, skipped.photo, skipped.reason, skipped.detail)
    end
    summary.sent = #selection.eligible
    local result = lookUpAndDeliver(settings, info, catalogPath, selection.eligible, summary, ui)

    -- 4. What to remember about each job read.
    for _, entry in ipairs(readJobs) do
        records[string.format('%d', entry.job.id)] = FetchPlan.advance(entry.job, entry.since, entry.items,
            function(item)
                if item.outcome then
                    return item.outcome
                end
                local photo = item.fileKey and byKey[item.fileKey]
                return photo and photo.outcome or 'notDelivered'
            end)
    end
    return finish(result)
end

-- How many ready items of this catalog's jobs have not been dealt with by a fetch yet: an upper bound (some may
-- have been placed in another way meanwhile). Returns a number, or nil when a job could not be read.
function Fetcher.countWaiting(settings, jobs, records, clientId)
    local plan = FetchPlan.plan(jobs, records, clientId)
    local total = 0
    for _, entry in ipairs(plan.read) do
        local items, problem = ServerClient.readItems(settings, entry.job.id, entry.since, 'ready')
        if items then
            total = total + #items
        elseif not problem.gone then
            return nil
        end
    end
    return total
end

-- A fetch started by the user: takes the fetch lock, shows a progress bar that can be cancelled, then the summary.
-- scope: 'selection' (photos: the selected LrPhoto objects) or 'everything'. context: a function context.
function Fetcher.runInteractive(context, title, catalog, scope, photos)
    local settings = Settings.read(LrPrefs.prefsForPlugin())
    local label = scope == 'selection' and 'a manual fetch for selected photos' or 'a manual fetch'
    local started, outcome = Pipeline.withLease(label, function(lease)
        local progress = LrProgressScope { title = title, functionContext = context }
        PhotoAccess.try('progress:setCancelable', function()
            progress:setCancelable(true)
        end)
        local ui = {
            caption = function(text)
                progress:setCaption(text)
            end,
            portion = function(done, total)
                progress:setPortionComplete(done, total)
            end,
            isCanceled = function()
                return progress:isCanceled() or not lease.refresh()
            end,
        }
        ui.caption('Asking the server')
        local info, infoProblem = ServerClient.fetchInfo(settings)
        local result
        if not info then
            result = { problem = infoProblem.message }
        elseif scope == 'selection' then
            result = Fetcher.selection(settings, info, catalog, photos, ui)
        else
            result = Fetcher.everything(settings, function()
                return info
            end, catalog, ui)
        end
        progress:done()
        return result
    end)
    if not started then
        LrDialogs.message(title, outcome, 'info')
    elseif outcome.problem then
        LrDialogs.message(title, outcome.problem, outcome.nothingNew and 'info' or 'critical')
    else
        LrDialogs.message(title, outcome.text, outcome.troubled and 'warning' or 'info')
    end
end

return Fetcher
