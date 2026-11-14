-- The automatic fetch of the jobs whose refs are the photos' catalog ids (sent since version 0.8.0: by the automatic
-- send and by «Build smart previews on the server»; PendingJobs marks them byId). Called by the automatic loop
-- (AutoFetch) every second; must run in that loop's task. Other pending jobs are fetched the way 0.7.0 did
-- (AutoFetch.fetchOnce, Fetcher.everything).
--
-- For each such pending job one task keeps a request open: GET .../items?since=<largest seq>&state=ready&wait=<s>
-- (WaitPlan), so a smart preview is known here within a moment of the server finishing it; against a server that
-- cannot wait (before server 0.6.0) the task asks once per interval of the settings instead. Requests exist only
-- while the job is pending: with nothing pending there is none (the NAS can sleep). A failed request (no answer, an
-- error answer) backs off for the whole catalog (PendingJobs.contacted: 1, 2, 5, 10, 30, then 60 minutes); an answer
-- with no items after the wait is the normal case and is followed by the next request at once.
--
-- The loop's task then downloads the ready files (several at once, DownloadQueue), checks each DNG and places it
-- (Delivery: temporary name, rename, never over an existing file), holding the fetch lock while it places, and without
-- any call into the catalog: what it needs (the file UUID that names the smart preview, the file name and pixel size
-- for the check) was read from the catalog by the send (FastState) or is read again with sqlite3 by catalog id
-- (CatalogRead.byIdSql). Registering a placed file with Lightroom (photo:buildSmartPreview(), which needs the photo
-- object) waits while an import is in progress (RegisterQueue) and is done in batches afterwards. A file that is placed
-- but not registered is harmless: Lightroom takes such files by itself. The log tells the two apart («placed»,
-- «registered»).
local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'

local AutoSend = require 'AutoSend'
local CatalogRead = require 'CatalogRead'
local CatalogState = require 'CatalogState'
local Delivery = require 'Delivery'
local DownloadQueue = require 'DownloadQueue'
local FastState = require 'FastState'
local JobStats = require 'JobStats'
local Log = require 'Log'
local PendingJobs = require 'PendingJobs'
local PhotoAccess = require 'PhotoAccess'
local Pipeline = require 'Pipeline'
local RegisterQueue = require 'RegisterQueue'
local RunSummary = require 'RunSummary'
local ServerClient = require 'ServerClient'
local Settings = require 'Settings'
local SmartPreviewPath = require 'SmartPreviewPath'
local SqliteCommand = require 'SqliteCommand'
local WaitPlan = require 'WaitPlan'

local FastFetch = {}

FastFetch.LABEL = 'the automatic fetch'
FastFetch.MAX_BACKLOG = 500 -- items of one job received and not yet placed before its task stops asking for more
FastFetch.RETRY_SECONDS = 30 -- a failed download or write is tried again after this
FastFetch.MAX_TRIES = 3
FastFetch.CAPABILITIES_SECONDS = 3600 -- what the server can do is asked again after this, while something is pending
FastFetch.BUSY_STEP = 0.2 -- seconds between two steps of the loop while files are on their way
FastFetch.WAIT_STEP = 0.5 -- the same while a waiting request is open

local watchers = {} -- [job id text] = { id, key, since, sent, shortened, answer, jobSeq, running, stop, gone, failing,
--                                       lowestFailed }
local inbox = {} -- { { job = id, item = item, readyAt = clock } }
local open = {} -- [job id text] = items received from the job and not yet dealt with
local retries = {} -- { entry, ... } waiting for entry.due
local finished = {} -- [job id text] = label: done jobs whose totals are logged once their registrations are done
local queue -- the DownloadQueue, owned by the loop's task
local registerList -- RegisterQueue of the catalog
local registerCatalog
local registerDirty = false
local runTag

local function idText(id)
    return string.format('%d', id)
end

local function prefs()
    return LrPrefs.prefsForPlugin()
end

local function baseName(path)
    return tostring(path or ''):match('([^/\\]+)$') or ''
end

local function labelOf(jobId)
    return FastState.label(jobId)
end

-- Sleeps up to seconds in steps of one, ending early when the task must stop.
local function pause(w, shouldStop, seconds)
    local left = seconds
    while left > 0 and not w.stop and not shouldStop() do
        LrTasks.sleep(math.min(1, left))
        left = left - 1
    end
end

-- The task of one job: waiting requests, ready items into the inbox.
local function watch(w, catalogPath, shouldStop)
    local store = prefs()
    while not w.stop and not shouldStop() do
        local settings = Settings.read(store)
        local now = os.time()
        if not settings.autoFetch or settings.serverUrl == '' or not PendingJobs.has(store, catalogPath, w.id, now) then
            break
        end
        local decision, retryAt = PendingJobs.decide(store, catalogPath, now)
        if decision == 'wait' then
            pause(w, shouldStop, math.max(1, retryAt - now))
        elseif (open[w.key] or 0) >= FastFetch.MAX_BACKLOG then
            pause(w, shouldStop, 1)
        elseif w.answer and not w.answer.active and w.answer.drained then
            break -- the job is not active and everything ready has been read: nothing to wait for
        else
            local capabilities = FastState.capabilities(store) or {}
            local wait = WaitPlan.wait(capabilities.waits, w.shortened)
            local asked = AutoSend.clock()
            local page, problem = ServerClient.readReady(settings, w.id, w.since, wait, WaitPlan.timeout(wait))
            if page then
                PendingJobs.contacted(store, catalogPath, true, os.time())
                if w.failing then
                    Log.info('automatic fetch: job %d: the server answers again', w.id)
                    w.failing = false
                end
                local answer = WaitPlan.answer(page, w.since)
                local readyAt = AutoSend.clock()
                for _, item in ipairs(answer.ready) do
                    inbox[#inbox + 1] = { job = w.id, item = item, readyAt = readyAt }
                    open[w.key] = (open[w.key] or 0) + 1
                end
                w.since, w.answer, w.jobSeq = answer.since, answer, page.job.seq
                local seconds = WaitPlan.pause(answer, wait ~= nil, settings.autoFetchInterval, readyAt - asked)
                if seconds > 0 then
                    pause(w, shouldStop, seconds)
                end
            else
                local kind = WaitPlan.failure(problem, wait)
                if kind == 'shorten' and WaitPlan.wait(capabilities.waits, (w.shortened or 0) + 1) == wait then
                    kind = 'failed'
                end
                if kind == 'gone' then
                    w.gone = true
                    break
                elseif kind == 'shorten' then
                    w.shortened = (w.shortened or 0) + 1
                    Log.info('automatic fetch: a waiting request for job %d ran out of time on this side; asking the '
                        .. 'server to wait %d s from now on', w.id, WaitPlan.wait(capabilities.waits, w.shortened))
                else
                    local nextTry = PendingJobs.contacted(store, catalogPath, false, os.time())
                    if not w.failing then
                        Log.warn('automatic fetch: job %d: %s (next try at %s)', w.id, problem.message,
                            os.date('%H:%M', nextTry))
                        w.failing = true
                    end
                end
            end
        end
    end
    w.running = false
end

local function startWatcher(job, catalogPath, records, shouldStop)
    local key = idText(job.id)
    local old = watchers[key]
    local record = records[key]
    local w = {
        id = job.id, key = key, sent = job.sent, running = true,
        since = math.max(old and old.since or 0, record and record.since or 0),
        shortened = old and old.shortened or nil, lowestFailed = old and old.lowestFailed or nil,
    }
    watchers[key] = w
    LrTasks.startAsyncTask(function()
        local ok, err = LrTasks.pcall(watch, w, catalogPath, shouldStop)
        if not ok then
            w.running = false
            Log.error('automatic fetch: the task of job %d stopped with an error: %s', job.id, tostring(err))
        end
    end, 'LR Remote Previews job ' .. key)
end

-- An item of a job that needs nothing more in this session.
local function settleItem(jobId)
    local key = idText(jobId)
    open[key] = math.max(0, (open[key] or 1) - 1)
end

-- Outcomes that a later fetch may still fix (FetchPlan does not count them as final): the record of the job is kept
-- below such an item, so «Fetch ready smart previews» tries it again.
local RETRYABLE = { downloadFailed = true, writeFailed = true, notInCache = true }

-- Records an item that was not placed: one log line; outcome and detail as RunSummary names them. failed: it counts
-- as failed in the job's totals.
local function leaveOut(jobId, seq, fileName, outcome, detail, failed)
    Log.info('%s', RunSummary.photoLine(fileName, outcome, detail))
    if failed then
        JobStats.fail(FastState.stats, jobId)
    end
    local w = watchers[idText(jobId)]
    if RETRYABLE[outcome] and w and seq and (w.lowestFailed == nil or seq < w.lowestFailed) then
        w.lowestFailed = seq
    end
    settleItem(jobId)
end

local function loadRegister(catalogPath)
    if registerCatalog ~= catalogPath then
        registerList = RegisterQueue.load(prefs(), catalogPath)
        registerCatalog = catalogPath
        registerDirty = false
    end
end

-- Checks and places one downloaded file (in the loop's task, inside DownloadQueue:pump, holding the fetch lock).
local function deliver(entry, data, problem)
    local function again(why)
        entry.tries = (entry.tries or 0) + 1
        if entry.tries < FastFetch.MAX_TRIES then
            entry.due = os.time() + FastFetch.RETRY_SECONDS
            retries[#retries + 1] = entry
            Log.info('%s', RunSummary.photoLine(entry.fileName, 'notDelivered', why .. '; tried again in '
                .. FastFetch.RETRY_SECONDS .. ' s'))
            return true
        end
        return false
    end
    if not data then
        local message = problem and problem.message or 'no file'
        if problem and problem.code == 'not_in_cache' then
            return leaveOut(entry.job, entry.seq, entry.fileName, 'notInCache', message, true)
        end
        if not again('download failed: ' .. message) then
            leaveOut(entry.job, entry.seq, entry.fileName, 'downloadFailed', message, true)
        end
        return
    end
    local outcome, detail = Delivery.deliver(entry, entry.result, data, PhotoAccess.fileSystem(nil),
        runTag .. '-' .. entry.job .. '-' .. entry.ref)
    if outcome == 'placed' then
        local placedAt = AutoSend.clock()
        RegisterQueue.add(registerList, { id = entry.localId, job = entry.job, ready = entry.readyAt,
            placed = placedAt })
        registerDirty = true
        local took = math.max(0, placedAt - entry.readyAt)
        JobStats.add(FastState.stats, entry.job, 'placed', took)
        Log.info('%s', RunSummary.photoLine(entry.fileName, 'placed', string.format('%s, %s; ready -> placed %s; '
            .. 'not registered yet', detail, entry.dest, JobStats.seconds(took))))
        settleItem(entry.job)
    elseif outcome == 'writeFailed' and again('write failed: ' .. tostring(detail)) then
        return
    else
        local failed = outcome == 'checkFailed' or outcome == 'writeFailed'
        leaveOut(entry.job, entry.seq, entry.fileName, outcome, detail, failed)
    end
end

local function ensureQueue(settings)
    if queue == nil or (queue:isIdle() and queue.concurrency ~= settings.downloadConcurrency) then
        runTag = Pipeline.runTag()
        queue = DownloadQueue.new(Pipeline.queueEnv(function(entry)
            if entry.key then
                return ServerClient.downloadByKey(settings, entry.key)
            end
            return ServerClient.download(settings, entry.itemId)
        end, deliver), { concurrency = settings.downloadConcurrency })
    end
    return queue
end

-- Reads the photos of these catalog ids from the catalog (sqlite3). Returns { [id] = photo }, or nil plus a message.
local function readPhotos(settings, catalogPath, ids)
    local rows = {}
    if #ids == 0 then
        return rows
    end
    local tool, problem = AutoSend.tool(settings)
    if not tool then
        return nil, problem
    end
    for _, chunk in ipairs(SqliteCommand.chunks(ids)) do
        local parsed, err = AutoSend.read(tool, catalogPath, CatalogRead.byIdSql(chunk))
        if not parsed then
            return nil, err
        end
        for _, photo in ipairs(parsed.photos) do
            rows[photo.id] = photo
        end
    end
    return rows
end

local function catalogId(ref)
    local id = tonumber(ref)
    if id and id >= 1 and id == math.floor(id) and tostring(ref):match('^%d+$') then
        return id
    end
    return nil
end

-- Turns the received ready items into download entries (or settles them when they need nothing).
local function resolveInbox(settings, catalogPath)
    if #inbox == 0 then
        return
    end
    local batch = inbox
    inbox = {}
    local missing = {}
    for _, received in ipairs(batch) do
        received.data = FastState.placementOf(received.job, received.item.ref)
        local id = catalogId(received.item.ref)
        if not received.data and id then
            missing[#missing + 1] = id
        end
    end
    local rows, problem = readPhotos(settings, catalogPath, missing)
    if not rows then
        Log.warn('automatic fetch: reading the catalog failed: %s; tried again', tostring(problem))
        for _, received in ipairs(batch) do
            inbox[#inbox + 1] = received
        end
        return
    end
    local q = ensureQueue(settings)
    for _, received in ipairs(batch) do
        local item, data = received.item, received.data
        local name = baseName(item.path)
        if not data then
            local row = rows[catalogId(item.ref) or -1]
            if row then
                data = { id = row.id, fileUuid = row.fileUuid, fileName = row.fileName, width = row.width,
                    height = row.height, path = row.path, hasSmartPreview = row.hasSmartPreview,
                    incomplete = row.incomplete or row.badUuid ~= nil }
            end
        end
        if not data then
            leaveOut(received.job, item.seq, name, 'notInCatalog', 'catalog id ' .. tostring(item.ref), true)
        elseif data.incomplete or not data.fileUuid then
            leaveOut(received.job, item.seq, name, 'noFileId', 'catalog id ' .. tostring(item.ref), true)
        elseif data.hasSmartPreview then
            leaveOut(received.job, item.seq, data.fileName, 'hasSmartPreview', nil, false)
        elseif name:lower() ~= tostring(data.fileName):lower() then
            leaveOut(received.job, item.seq, name, 'fileIdMismatch', 'catalog id ' .. tostring(item.ref) .. ' is "'
                .. tostring(data.fileName) .. '"', true)
        elseif not item.result then
            leaveOut(received.job, item.seq, data.fileName, 'notInCache', 'the server no longer has the file', true)
        else
            local dest, destError = SmartPreviewPath.dngPath(catalogPath, data.fileUuid)
            if not dest then
                leaveOut(received.job, item.seq, data.fileName, 'writeFailed', destError, true)
            else
                q:add({ job = received.job, seq = item.seq, ref = item.ref, itemId = item.id, result = item.result,
                    key = item.result.key, fileName = data.fileName, width = data.width, height = data.height,
                    dest = dest, localId = data.id, readyAt = received.readyAt })
            end
        end
    end
end

local function retryDue(settings)
    if #retries == 0 then
        return
    end
    local now, left = os.time(), {}
    local q = ensureQueue(settings)
    for _, entry in ipairs(retries) do
        if now >= entry.due then
            q:add(entry)
        else
            left[#left + 1] = entry
        end
    end
    retries = left
end

local function logTotals(jobId)
    local key = idText(jobId)
    if finished[key] ~= nil and RegisterQueue.count(registerList, jobId) == 0 then
        Log.info('automatic fetch: %s', JobStats.summary(FastState.stats, jobId, finished[key] or nil))
        finished[key] = nil
        JobStats.forget(FastState.stats, jobId)
    end
end

-- Registers a batch of placed files with Lightroom (holding the fetch lock). Before calling into the catalog, the
-- photos are read again with sqlite3: one that Lightroom already counts as having a smart preview needs no call.
local function registerSome(settings, catalog, catalogPath, lease)
    local batch = RegisterQueue.take(registerList, false, RegisterQueue.BATCH)
    if #batch == 0 then
        return 0
    end
    registerDirty = true
    local ids = {}
    for i, entry in ipairs(batch) do
        ids[i] = entry.id
    end
    local rows, problem = readPhotos(settings, catalogPath, ids)
    if not rows then
        Log.warn('automatic fetch: reading the catalog failed: %s; registration tried again later', tostring(problem))
        for i = #batch, 1, -1 do
            table.insert(registerList, 1, batch[i])
        end
        return 0
    end
    local done = 0
    for _, entry in ipairs(batch) do
        local row = rows[entry.id]
        local now = AutoSend.clock()
        local took = entry.ready and math.max(0, now - entry.ready) or nil
        if not row or row.incomplete then
            Log.info('catalog id %d: no longer in the catalog; its smart preview file stays where it was placed',
                entry.id)
            if entry.job then
                JobStats.fail(FastState.stats, entry.job)
            end
        elseif row.hasSmartPreview then
            if entry.job then
                JobStats.add(FastState.stats, entry.job, 'registered', took)
            end
            Log.info('%s', RunSummary.photoLine(row.fileName, 'registered', 'Lightroom had taken the file by itself; '
                .. 'ready -> registered ' .. JobStats.seconds(took)))
        else
            local photo = PhotoAccess.findByPath(catalog, row.path)
            local localId = photo and PhotoAccess.try('photo.localIdentifier', function()
                return photo.localIdentifier
            end)
            if not photo or tonumber(localId) ~= entry.id then
                Log.info('%s', RunSummary.photoLine(row.fileName, 'notRegistered', 'Lightroom did not find the photo; '
                    .. 'the file stays, Lightroom takes it by itself'))
            else
                local ok, answer = LrTasks.pcall(function()
                    return photo:buildSmartPreview()
                end)
                if ok and answer == 'existed' then
                    if entry.job then
                        JobStats.add(FastState.stats, entry.job, 'registered', took)
                    end
                    Log.info('%s', RunSummary.photoLine(row.fileName, 'registered', 'Lightroom answered existed; '
                        .. 'ready -> registered ' .. JobStats.seconds(took)))
                else
                    Log.info('%s', RunSummary.photoLine(row.fileName, 'notRegistered', ok
                        and ("Lightroom answered '" .. tostring(answer) .. "'")
                        or ('buildSmartPreview raised an error: ' .. tostring(answer))))
                end
            end
        end
        done = done + 1
        if lease and not lease.refresh() then
            break
        end
    end
    for _, entry in ipairs(batch) do
        if entry.job then
            logTotals(entry.job)
        end
    end
    return done
end

-- The largest seq up to which every ready item of the job needs nothing more: the record kept per job (CatalogState),
-- so that «Fetch ready smart previews» and a later task of the same job do not read it again.
local function safeSince(w)
    if w.lowestFailed then
        return math.min(w.since, w.lowestFailed - 1)
    end
    return w.since
end

local function finishJob(w, catalogPath, gone)
    local store = prefs()
    PendingJobs.finish(store, catalogPath, { w.id }, os.time())
    local records = CatalogState.jobs(store, catalogPath)
    if gone then
        records[w.key] = nil
    else
        records[w.key] = { since = safeSince(w), doneSeq = w.lowestFailed == nil and w.jobSeq or nil }
    end
    CatalogState.saveJobs(store, catalogPath, records)
    watchers[w.key] = nil
    FastState.forgetJob(w.id)
    Log.info('automatic fetch: job %d %s', w.id, gone and 'is gone from the server; no longer followed'
        or 'needs nothing more from the server; no longer followed')
    -- The one short notice of a job: when it is done (not for every file: during an import that would be all the
    -- time).
    local placed = JobStats.count(FastState.stats, w.id, 'placed')
    if placed > 0 then
        LrTasks.pcall(function()
            LrDialogs.showBezel(string.format('%d smart preview%s arrived from the server', placed,
                placed == 1 and '' or 's'), 3)
        end)
    end
    finished[w.key] = labelOf(w.id) or false
    logTotals(w.id)
end

-- What the server can do, asked for when not known (or old) while something is pending. Returns true when known.
local function knowCapabilities(store, settings, catalogPath)
    local capabilities = FastState.capabilities(store)
    if capabilities and os.time() - capabilities.at < FastFetch.CAPABILITIES_SECONDS then
        return true
    end
    local info, problem = AutoSend.serverInfo(settings, store)
    if not info then
        local nextTry = PendingJobs.contacted(store, catalogPath, false, os.time())
        return false, string.format('not done: %s (next try at %s)', problem.message, os.date('%H:%M', nextTry))
    end
    return true
end

-- Stops every job task (the loop ends).
function FastFetch.stopAll()
    for _, w in pairs(watchers) do
        w.stop = true
    end
end

-- The number of placed files not yet registered (for the status dialog), from the stored queue.
function FastFetch.unregistered(store, catalogPath)
    return #RegisterQueue.load(store, catalogPath)
end

-- One step of the automatic fetch for the byId jobs. importing: an import is in progress (registration waits);
-- shouldStop() -> true when the loop must end. Returns a short text for the log (or nil), and the seconds to the next
-- step when it should come sooner than the loop's step: BUSY_STEP while files are on their way or to be registered,
-- WAIT_STEP while a waiting request is open (so that a ready file is picked up within a moment), else nil.
function FastFetch.step(importing, shouldStop)
    local store = prefs()
    local settings = Settings.read(store)
    local catalog = LrApplication.activeCatalog()
    local catalogPath = catalog:getPath()
    loadRegister(catalogPath)
    local now = os.time()
    local pending = PendingJobs.list(store, catalogPath, now)
    local byId = {}
    for _, job in ipairs(pending) do
        if job.byId then
            byId[idText(job.id)] = job
        end
    end
    for key, w in pairs(watchers) do
        if not byId[key] then
            w.stop = true
            if not w.running and (open[key] or 0) == 0 then
                watchers[key] = nil
            end
        end
    end
    local text
    if next(byId) ~= nil and settings.serverUrl ~= '' then
        local decision, retryAt = PendingJobs.decide(store, catalogPath, now)
        local known = false
        if decision == 'wait' then
            text = string.format('the server did not answer; next try at %s', os.date('%H:%M', retryAt))
        else
            known, text = knowCapabilities(store, settings, catalogPath)
        end
        if known then
            local records = CatalogState.jobs(store, catalogPath)
            for key, job in pairs(byId) do
                local w = watchers[key]
                local restart = w == nil
                if w and not w.running and not w.gone then
                    -- A task that ended because its job was done is started again only when items were added to the
                    -- job since (the send marks it pending again with a later time).
                    local drained = w.answer ~= nil and not w.answer.active and w.answer.drained
                    restart = not drained or job.sent > (w.sent or 0)
                end
                if restart then
                    startWatcher(job, catalogPath, records, shouldStop)
                end
            end
            local following = 0
            for _ in pairs(byId) do
                following = following + 1
            end
            text = string.format('following %d job(s) on the server', following)
        end
    end

    resolveInbox(settings, catalogPath)
    retryDue(settings)
    local q = queue
    local registerDue = not importing and #registerList > 0
    if (q and (q:finishedCount() > 0 or (q.inline and not q:isIdle()))) or registerDue then
        local lease = Pipeline.acquireLease(FastFetch.LABEL, true)
        if lease then
            local ok, err = LrTasks.pcall(function()
                if q then
                    q:pump(function()
                        return shouldStop() or not lease.refresh()
                    end)
                end
                if registerDue then
                    registerSome(settings, catalog, catalogPath, lease)
                end
            end)
            lease.release()
            if not ok then
                Log.error('automatic fetch: placing stopped with an error: %s', tostring(err))
            end
        end
    end

    for key, w in pairs(watchers) do
        if w.gone and (open[key] or 0) == 0 then
            finishJob(w, catalogPath, true)
        elseif not w.running and byId[key] and WaitPlan.done(w.answer, open[key]) and #retries == 0 then
            finishJob(w, catalogPath, false)
        end
    end
    if registerDirty then
        RegisterQueue.save(store, catalogPath, registerList)
        registerDirty = false
    end
    if text == nil then
        if next(byId) ~= nil and settings.serverUrl == '' then
            text = 'no server URL is set; nothing done'
        elseif #registerList > 0 then
            text = importing and 'the placed smart previews are registered when the import has finished'
                or 'registering the placed smart previews'
        elseif #pending == 0 then
            text = 'nothing pending for this catalog; the server is not asked'
        end
    end
    local nextStep
    if #inbox > 0 or (queue ~= nil and not queue:isIdle()) or (not importing and #registerList > 0) then
        nextStep = FastFetch.BUSY_STEP
    else
        for _, w in pairs(watchers) do
            if w.running then
                nextStep = FastFetch.WAIT_STEP
                break
            end
        end
    end
    return text, nextStep
end

return FastFetch
