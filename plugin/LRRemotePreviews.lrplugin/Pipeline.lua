-- The steps the commands share, connected to the SDK: file UUIDs from the catalog (sqlite3, read-only), looking files
-- up on the server, downloading several smart previews at once and placing them one at a time, and the lock that
-- keeps two fetches from running together. The decisions live in pure modules (FileIds, DownloadQueue, Delivery,
-- Lease, RunSummary); this file wires them to Lightroom. Must run inside an LrTasks task.
--
-- A ui table is passed to the long steps: { caption(text), portion(done, total), isCanceled() }; the automatic
-- fetch passes one that shows nothing.
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'

local CatalogState = require 'CatalogState'
local ClientId = require 'ClientId'
local Delivery = require 'Delivery'
local DownloadQueue = require 'DownloadQueue'
local FileIds = require 'FileIds'
local Lease = require 'Lease'
local Log = require 'Log'
local PhotoAccess = require 'PhotoAccess'
local RunSummary = require 'RunSummary'
local Selection = require 'Selection'
local ServerClient = require 'ServerClient'
local Settings = require 'Settings'
local SqliteRunner = require 'SqliteRunner'

local Pipeline = {}

Pipeline.LOG_HINT = 'Every photo is listed in LRRemotePreviews.log in Lightroom\'s log folder (Lightroom Classic '
    .. '15.6 on Windows: %LOCALAPPDATA%\\Adobe\\Lightroom\\Logs\\LrClassicLogs).'
Pipeline.FETCH_HINT = 'When they are ready, use Library > Plug-in Extras > Fetch ready smart previews, or turn on '
    .. 'the automatic fetch in File > Plug-in Manager > LR Remote Previews.'
Pipeline.LOOKUP_CHUNK = 1000 -- files per lookup request (at most maxItemsPerJob)

local counter = 0

-- A text that is unique per call within a session and very likely across sessions: 'lrrp-1731577800-123456-7'.
-- Used for temporary file names and as the owner of the lock.
function Pipeline.runTag()
    counter = counter + 1
    return string.format('lrrp-%d-%d-%d', os.time(), math.random(1000000), counter)
end

-- This catalog's clientId (CatalogState); made up and stored on first use. The seed mixes the time, the processor
-- clock, a counter, math.random and the catalog path (ClientId).
function Pipeline.clientId(catalogPath)
    return CatalogState.ensureClientId(LrPrefs.prefsForPlugin(), catalogPath, function()
        counter = counter + 1
        local clock = (os.clock and os.clock() or 0) * 1000000
        local id = ClientId.generate(ClientId.newRandom(os.time(), clock, counter, math.random(2147483646),
            catalogPath))
        Log.info('this catalog\'s clientId is now %s', id)
        return id
    end)
end

-- A ui that shows nothing and is never cancelled (for tests of single steps and the automatic fetch).
function Pipeline.quietUi(isCanceled)
    return {
        caption = function() end,
        portion = function() end,
        isCanceled = isCanceled or function()
            return false
        end,
    }
end

-- Records the outcome of one photo: in the photo's table, the summary and the log.
function Pipeline.record(summary, entry, key, detail, code)
    entry.outcome = key
    summary:outcome(key, code)
    Log.info('%s', RunSummary.photoLine(entry.fileName, key, detail))
end

-- Records a photo that is left out.
function Pipeline.skip(summary, photo, reason, detail)
    photo.outcome = reason
    summary:skip(reason)
    Log.info('%s', RunSummary.photoLine(photo.fileName, reason, detail))
end

-- Reads the file UUIDs of the photos from the catalog (sqlite3, read-only) and gives each its smart preview path
-- (FileIds.assign). Photos that cannot have one are recorded as skipped in summary.
-- Returns the entries, or nil plus a message ('cancelled' when ui said so).
function Pipeline.resolveFileIds(settings, catalogPath, photos, summary, ui)
    ui.caption('Looking for sqlite3')
    local tool, toolProblem = SqliteRunner.locate(settings.sqlitePath, _PLUGIN and _PLUGIN.path)
    if not tool then
        Log.warn('%s', toolProblem)
        return nil, toolProblem
    end
    Log.info('sqlite3 %s, %s', tool.version, SqliteRunner.describe(tool))
    local ids = FileIds.ids(photos)
    local rows = {}
    if #ids > 0 then
        ui.caption('Reading file ids from the catalog')
        local problems
        rows, problems = SqliteRunner.lookup(tool.tool, catalogPath, ids, ui.isCanceled)
        if not rows then
            if ui.isCanceled() then
                return nil, 'cancelled'
            end
            Log.warn('reading the catalog failed: %s', problems)
            return nil, 'Reading the file ids from the catalog failed: ' .. problems
        end
        for _, problem in ipairs(problems) do
            Log.warn('sqlite3 output: %s', problem)
        end
    end
    local assigned = FileIds.assign(photos, rows, catalogPath)
    for _, skipped in ipairs(assigned.skipped) do
        Pipeline.skip(summary, skipped.photo, skipped.reason, skipped.detail)
    end
    return assigned.entries
end

-- The first steps of sending (shared by «Send to the server» and «Build smart previews on the server»): ask the
-- server whether it can build, sort the photos, read their file UUIDs. photos: LrPhoto objects.
-- Returns { info, entries }, or nil plus { message, style } to show, or nil plus { cancelled = true }.
function Pipeline.prepareSend(settings, catalog, photos, summary, ui)
    local mappings = Settings.mappings(settings)
    ui.caption('Asking the server')
    local info, infoProblem = ServerClient.fetchInfo(settings)
    if not info then
        return nil, { message = infoProblem.message, style = 'critical' }
    end
    local serverProblem = Selection.serverProblem(info, mappings)
    if serverProblem then
        Log.warn('%s', serverProblem)
        return nil, { message = serverProblem, style = 'critical' }
    end
    ui.caption('Reading the selection')
    local described = PhotoAccess.describeAll(photos, ui)
    if not described then
        return nil, { cancelled = true }
    end
    local selection = Selection.classify(described, {
        extensions = info.capabilities.extensions,
        mappings = mappings,
        availableRoots = Selection.availableRoots(info),
    })
    for _, skipped in ipairs(selection.skipped) do
        Pipeline.skip(summary, skipped.photo, skipped.reason, skipped.detail)
    end
    local nothing = { message = nil, style = 'info' }
    if #selection.eligible == 0 then
        nothing.message = summary:text({ stoppedBefore = 'Nothing to send.', logHint = Pipeline.LOG_HINT })
        return nil, nothing
    end
    local entries, idProblem = Pipeline.resolveFileIds(settings, catalog:getPath(), selection.eligible, summary, ui)
    if not entries then
        if idProblem == 'cancelled' then
            return nil, { cancelled = true }
        end
        return nil, { message = idProblem, style = 'critical' }
    end
    if #entries == 0 then
        nothing.message = summary:text({ stoppedBefore = 'Nothing to send.', logHint = Pipeline.LOG_HINT })
        return nil, nothing
    end
    return { info = info, entries = entries }
end

-- A ui for a progress scope (LrProgressScope). isCanceled (optional) replaces the scope's own check.
function Pipeline.progressUi(progress, isCanceled)
    return {
        caption = function(text)
            progress:setCaption(text)
        end,
        portion = function(done, total)
            progress:setPortionComplete(done, total)
        end,
        isCanceled = isCanceled or function()
            return progress:isCanceled()
        end,
    }
end

-- Asks the server what it has for the photos (POST /api/v1/lookup, in chunks). photos: { rootId, relativePath,
-- ... }. Returns a table photo -> lookup answer { state, error, result }, or nil plus a problem
-- ({ kind = 'cancelled' } when ui said so).
function Pipeline.lookup(settings, info, photos, ui)
    local chunkSize = math.min(Pipeline.LOOKUP_CHUNK, info.capabilities.maxItemsPerJob or Pipeline.LOOKUP_CHUNK)
    local answers = {}
    local done = 0
    while done < #photos do
        if ui.isCanceled() then
            return nil, { kind = 'cancelled', message = 'Cancelled.' }
        end
        local chunk, request = {}, {}
        for i = done + 1, math.min(done + chunkSize, #photos) do
            local photo = photos[i]
            chunk[#chunk + 1] = photo
            request[#request + 1] = { ref = tostring(i), rootId = photo.rootId, relativePath = photo.relativePath }
        end
        ui.caption(string.format('Asking the server about %d file(s)', #photos))
        local byRef, problem = ServerClient.lookup(settings, request)
        if not byRef then
            return nil, problem
        end
        for i, photo in ipairs(chunk) do
            answers[photo] = byRef[request[i].ref]
        end
        done = done + #chunk
        ui.portion(done, #photos)
    end
    return answers
end

-- The environment of a DownloadQueue in Lightroom: download tasks are LrTasks, waiting is LrTasks.sleep.
local function queueEnv(download, deliver)
    return {
        download = download,
        deliver = deliver,
        startTask = function(fn)
            LrTasks.startAsyncTask(fn, 'LR Remote Previews download')
        end,
        sleep = function(seconds)
            LrTasks.sleep(seconds)
        end,
        pcall = LrTasks.pcall,
        log = function(...)
            Log.warn(...)
        end,
    }
end

-- Checks and places one downloaded file and records the outcome. entry: { fileName, width, height, dest, photo,
-- ref, result }.
function Pipeline.place(summary, entry, data, problem, runTag)
    if not data then
        if problem and problem.code == 'not_in_cache' then
            return Pipeline.record(summary, entry, 'notInCache', problem.message)
        end
        return Pipeline.record(summary, entry, 'downloadFailed', problem and problem.message)
    end
    local outcome, detail = Delivery.deliver(entry, entry.result, data, PhotoAccess.fileSystem(entry.photo),
        runTag .. '-' .. entry.ref)
    if outcome == 'delivered' or outcome == 'deliveredOther' or outcome == 'destinationExists' then
        detail = (detail and detail ~= entry.dest) and (detail .. ', ' .. entry.dest) or entry.dest
    end
    Pipeline.record(summary, entry, outcome, detail)
end

-- A queue that downloads entries (by entry.key with GET /api/v1/files/{key}, else by entry.itemId with GET
-- /api/v1/items/{id}/file) with settings.downloadConcurrency downloads at once, and places them one at a time in
-- the calling task. onPlaced(entry) (optional) is called after each one.
function Pipeline.newQueue(settings, summary, onPlaced)
    local runTag = Pipeline.runTag()
    local queue = DownloadQueue.new(queueEnv(
        function(entry)
            if entry.key then
                return ServerClient.downloadByKey(settings, entry.key)
            end
            return ServerClient.download(settings, entry.itemId)
        end,
        function(entry, data, problem)
            Pipeline.place(summary, entry, data, problem, runTag)
            if onPlaced then
                onPlaced(entry)
            end
        end
    ), { concurrency = settings.downloadConcurrency })
    Log.info('downloads: up to %d at once', queue.concurrency)
    return queue
end

-- Downloads and places every entry. Entries the run did not get to (cancel) are recorded as 'notDelivered'.
-- Returns true when every entry has an outcome, false when cancelled.
function Pipeline.deliverAll(settings, entries, summary, ui)
    local placed = 0
    ui.caption(string.format('Fetching %d smart preview(s)', #entries))
    local queue = Pipeline.newQueue(settings, summary, function(entry)
        placed = placed + 1
        ui.portion(placed, #entries)
        ui.caption(string.format('%d of %d fetched (%s)', placed, #entries, entry.fileName))
    end)
    for _, entry in ipairs(entries) do
        queue:add(entry)
    end
    local finished = queue:drain(ui.isCanceled)
    if not finished then
        for _, entry in ipairs(queue:stop()) do
            Pipeline.record(summary, entry, 'notDelivered')
        end
    end
    Log.info('downloads: at most %d were in flight at once', queue.maxInFlight)
    return finished
end

-- Takes the fetch lock (Lease) for a task described by label ('the automatic fetch'). Returns a lease
-- { refresh() -> still held, release() }, or nil plus the message for the user.
function Pipeline.acquireLease(label)
    local prefs = LrPrefs.prefsForPlugin()
    local owner = Pipeline.runTag()
    local ok, holder = Lease.acquire(prefs, owner, label, os.time())
    if not ok then
        Log.info('fetch lock held by %s; %s not started', tostring(holder.label), label)
        return nil, Lease.busyText(holder, os.time())
    end
    local lease = { lost = false }
    function lease.refresh()
        if not lease.lost and not Lease.refresh(prefs, owner, os.time()) then
            lease.lost = true
            Log.warn('the fetch lock of %s was lost (taken by another task after it expired)', label)
        end
        return not lease.lost
    end
    function lease.release()
        Lease.release(prefs, owner)
    end
    return lease
end

-- Runs fn(lease) holding the fetch lock; the lock is released afterwards, also when fn raises (the error is
-- raised again). Returns true plus fn's results, or false plus the busy message.
function Pipeline.withLease(label, fn)
    local lease, busy = Pipeline.acquireLease(label)
    if not lease then
        return false, busy
    end
    -- The results are counted with select('#', ...): Lightroom's Lua has no table.maxn (seen in Lightroom
    -- Classic 15.6: "attempt to call field 'maxn' (a nil value)"), and the length operator stops at a nil.
    local function finish(ok, ...)
        lease.release()
        if not ok then
            error((...), 0)
        end
        return true, ...
    end
    return finish(LrTasks.pcall(fn, lease))
end

return Pipeline
