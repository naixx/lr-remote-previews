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
-- While an import is in progress nothing is downloaded (FetchGo): the ready items wait here, and when the import is
-- over they are fetched in one go. Otherwise the loop's task downloads the ready files as they come (several at once,
-- DownloadQueue), checks each DNG and places it (Delivery through Pipeline.deliver: temporary name, rename, never over
-- an existing file), holding the fetch lock while it places, and without any call into the catalog: what it needs (the
-- file UUID that names the smart preview, the file name and pixel size for the check) was read from the catalog by the
-- send (FastState) or is read again with sqlite3 by catalog id (CatalogRead.byIdSql). Lightroom does not take a placed
-- file by itself; the placed photos are registered afterwards with one catalog:buildSmartPreviews(photos) call
-- (RegisterQueue), never while an import is in progress. The log tells the two steps apart («placed», «registered»).
--
-- An interrupted fetch finishes by itself: what is placed but not registered is kept in the preferences
-- (RegisterQueue); a job stays pending until every ready item is dealt with, so after a restart its task reads the
-- ready items again and a file already placed is not downloaded again; a download the server could not serve (NAS
-- asleep, network gone) waits for the back-off without counting a try; a failed download or a file that fails the
-- check is tried again MAX_TRIES times; a temporary file left by an interrupted placing is deleted (Pipeline).
local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'

local AutoSend = require 'AutoSend'
local CatalogRead = require 'CatalogRead'
local CatalogState = require 'CatalogState'
local DownloadQueue = require 'DownloadQueue'
local FastState = require 'FastState'
local FetchGo = require 'FetchGo'
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
FastFetch.MAX_BACKLOG = 5000 -- items of one job received and not yet placed before its task stops asking for more
FastFetch.RETRY_SECONDS = 30 -- a failed download, check or write is tried again after this
FastFetch.MAX_TRIES = 3
FastFetch.CAPABILITIES_SECONDS = 3600 -- what the server can do is asked again after this, while something is pending
FastFetch.BUSY_STEP = 0.2 -- seconds between two steps of the loop while files are on their way
FastFetch.WAIT_STEP = 0.5 -- the same while a waiting request is open

local watchers = {} -- [job id text] = { id, key, since, sent, shortened, answer, jobSeq, running, stop, gone, failing,
--                                       lowestFailed }
local inbox = {} -- { { job = id, item = item, readyAt = clock } }
local open = {} -- [job id text] = items received from the job and not yet dealt with
local retries = {} -- { entry, ... } waiting for entry.due (entry.afterBackoff: or for the server to answer again)
local finished = {} -- [job id text] = label: done jobs whose totals are logged once their registrations are done
local queue -- the DownloadQueue, owned by the loop's task
local registerList -- RegisterQueue of the catalog
local registerCatalog
local registerDirty = false
local runTag
local goState = FetchGo.new()
local forceRegister = false -- a fetch in one go has ended: register what it placed with the next step
local backoffHit = false -- a download found the server away: take the queued downloads back
local batchUsable -- false once catalog:buildSmartPreviews is missing or raised an error (this session)
local tempsChecked = false -- the temporary file of an interrupted placing has been looked for

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
local RETRYABLE = { downloadFailed = true, writeFailed = true, notInCache = true, checkFailed = true }

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

local function saveRegister(store, catalogPath)
    if registerDirty then
        RegisterQueue.save(store, catalogPath, registerList)
        registerDirty = false
    end
end

local function queueRegistration(entry, placedAt)
    if RegisterQueue.add(registerList, { id = entry.localId, job = entry.job, ready = entry.readyAt, placed = placedAt,
        at = os.time() }) then
        registerDirty = true
    end
end

-- Checks and places one downloaded file (in the loop's task, inside DownloadQueue:pump, holding the fetch lock).
-- A download the server could not serve (unreachable, not there behind its proxy) is fetched again after the back-off,
-- without a try counted; a download that failed otherwise, a DNG that failed the check and a file that could not be
-- written are tried again RETRY_SECONDS later, MAX_TRIES times in all, then logged and left.
local function deliver(entry, data, problem)
    local function again(why, bytes)
        entry.tries = (entry.tries or 0) + 1
        if entry.tries < FastFetch.MAX_TRIES then
            entry.due = os.time() + FastFetch.RETRY_SECONDS
            retries[#retries + 1] = entry
            FetchGo.count(goState, 'again', bytes)
            Log.info('%s', RunSummary.photoLine(entry.fileName, 'notDelivered', string.format('%s; tried again in %d s '
                .. '(try %d of %d)', why, FastFetch.RETRY_SECONDS, entry.tries, FastFetch.MAX_TRIES)))
            return true
        end
        FetchGo.count(goState, 'left', bytes)
        return false
    end
    local givenUp = '; given up after ' .. FastFetch.MAX_TRIES .. ' tries'
    if not data then
        local message = problem and problem.message or 'no file'
        local kind = WaitPlan.downloadFailure(problem)
        if kind == 'final' then
            FetchGo.count(goState, 'left', 0)
            return leaveOut(entry.job, entry.seq, entry.fileName, 'notInCache', message, true)
        elseif kind == 'backoff' then
            local store = prefs()
            local decision, retryAt = PendingJobs.decide(store, registerCatalog, os.time())
            if decision ~= 'wait' then
                retryAt = PendingJobs.contacted(store, registerCatalog, false, os.time())
                Log.warn('automatic fetch: downloading failed: %s; the downloads wait until %s', message,
                    os.date('%H:%M', retryAt))
            end
            entry.due, entry.afterBackoff = retryAt or (os.time() + FastFetch.RETRY_SECONDS), true
            retries[#retries + 1] = entry
            backoffHit = true
            FetchGo.count(goState, 'again', 0)
            return
        end
        if not again('download failed: ' .. message, 0) then
            leaveOut(entry.job, entry.seq, entry.fileName, 'downloadFailed', message .. givenUp, true)
        end
        return
    end
    local outcome, detail = Pipeline.deliver(entry, data, PhotoAccess.fileSystem(nil),
        runTag .. '-' .. entry.job .. '-' .. entry.ref)
    if outcome == 'placed' then
        local placedAt = AutoSend.clock()
        queueRegistration(entry, placedAt)
        FetchGo.count(goState, 'placed', #data)
        local took = math.max(0, placedAt - entry.readyAt)
        JobStats.add(FastState.stats, entry.job, 'placed', took)
        Log.info('%s', RunSummary.photoLine(entry.fileName, 'placed', string.format('%s, %s; ready -> placed %s; '
            .. 'not registered yet', detail, entry.dest, JobStats.seconds(took))))
        settleItem(entry.job)
    elseif outcome == 'checkFailed' or outcome == 'writeFailed' then
        local why = (outcome == 'checkFailed' and 'the file did not pass the check: ' or 'write failed: ')
            .. tostring(detail)
        if not again(why, #data) then
            leaveOut(entry.job, entry.seq, entry.fileName, outcome, tostring(detail) .. givenUp, true)
        end
    elseif outcome == 'destinationExists' then
        -- Placed meanwhile by another fetch: Lightroom does not take it by itself, so it is registered too.
        queueRegistration(entry, AutoSend.clock())
        FetchGo.count(goState, 'left', #data)
        leaveOut(entry.job, entry.seq, entry.fileName, outcome, tostring(detail) .. '; registered later', false)
    else
        FetchGo.count(goState, 'left', #data)
        leaveOut(entry.job, entry.seq, entry.fileName, outcome, detail, false)
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

-- Takes back every download not yet placed (they wait in retries): when an import begins, and when the server is away.
local function takeBackQueue(afterBackoff, due)
    if queue == nil or queue:isIdle() then
        return 0
    end
    local left = queue:stop()
    queue = nil
    for _, entry in ipairs(left) do
        entry.due, entry.afterBackoff = due, afterBackoff or nil
        retries[#retries + 1] = entry
    end
    return #left
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

-- Turns the received ready items into download entries (or settles them when they need nothing). A photo whose smart
-- preview file is already in place (placed before Lightroom quit, not registered yet) is not downloaded again; it is
-- queued for registration.
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
            elseif LrFileUtils.exists(dest) then
                queueRegistration({ localId = data.id, job = received.job, readyAt = received.readyAt },
                    AutoSend.clock())
                JobStats.add(FastState.stats, received.job, 'placed', 0)
                Log.info('%s', RunSummary.photoLine(data.fileName, 'placed', dest .. ' is there already (placed '
                    .. 'before); not downloaded again; not registered yet'))
                settleItem(received.job)
            else
                q:add({ job = received.job, seq = item.seq, ref = item.ref, itemId = item.id, result = item.result,
                    key = item.result.key, fileName = data.fileName, width = data.width, height = data.height,
                    dest = dest, localId = data.id, readyAt = received.readyAt })
            end
        end
    end
end

-- Adds the downloads to try again that are due: by time, or (after the server was away) at once: it is called only
-- while the catalog's back-off does not hold requests back.
local function retryDue(settings)
    if #retries == 0 then
        return
    end
    local now, left = os.time(), {}
    local q = ensureQueue(settings)
    for _, entry in ipairs(retries) do
        if now >= entry.due or entry.afterBackoff then
            entry.afterBackoff = nil
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

local function localIdOf(photo)
    return tonumber(PhotoAccess.try('photo.localIdentifier', function()
        return photo.localIdentifier
    end))
end

-- created: Lightroom answered 'created', so it built the smart preview itself (from the original, over the network)
-- although the placed file was checked to be there: a warning.
local CREATED = "Lightroom answered 'created': it built the smart preview itself"

local function registeredLine(entry, fileName, how)
    local took = entry.ready and math.max(0, AutoSend.clock() - entry.ready) or nil
    if entry.job then
        JobStats.add(FastState.stats, entry.job, 'registered', took)
    end
    local log = how == CREATED and Log.warn or Log.info
    log('%s', RunSummary.photoLine(fileName, 'registered', how .. '; ready -> registered ' .. JobStats.seconds(took)))
end

-- Puts back the entries a call did not register (sorted as RegisterQueue.outcome gives it); logs the failed ones.
-- why: what Lightroom did. Returns RegisterQueue.putBack's word.
local function putBack(sorted, names, why)
    local word, givenUp = RegisterQueue.putBack(registerList, sorted, os.time())
    local dropped = {}
    for _, entry in ipairs(givenUp) do
        dropped[entry.id] = true
        if entry.job then
            JobStats.fail(FastState.stats, entry.job)
        end
    end
    for _, entry in ipairs(sorted.failed) do
        local after = dropped[entry.id] and ('given up after ' .. entry.tries .. ' tries; the file stays where it was '
            .. 'placed') or (entry.single and 'tried again with a call of its own')
            or ('tried again in ' .. RegisterQueue.RETRY .. ' s')
        Log.info('%s', RunSummary.photoLine(names[entry.id], 'notRegistered', (why[entry.id] or 'Lightroom did not '
            .. 'register it') .. '; ' .. after))
    end
    return word
end

-- Registers photos one call each (photo:buildSmartPreview()), the way 0.8.1 did; for photos that calls for many did
-- not register, and when catalog:buildSmartPreviews is not available.
local function registerEach(items, names, lease)
    local failed, why = {}, {}
    for i, it in ipairs(items) do
        if lease and not lease.refresh() then
            for j = i, #items do
                RegisterQueue.add(registerList, items[j].entry)
            end
            break
        end
        local ok, answer = LrTasks.pcall(function()
            return it.photo:buildSmartPreview()
        end)
        if ok and (answer == 'existed' or answer == 'created') then
            registeredLine(it.entry, names[it.entry.id], answer == 'existed' and 'Lightroom answered existed'
                or CREATED)
        else
            why[it.entry.id] = ok and ("Lightroom answered '" .. tostring(answer) .. "'")
                or ('buildSmartPreview raised an error: ' .. tostring(answer))
            failed[#failed + 1] = it.entry
        end
    end
    if #failed > 0 then
        putBack({ failed = failed, untried = {}, existed = {}, created = {} }, names, why)
    end
end

-- One catalog:buildSmartPreviews call for these photos ({ { entry, photo } }). Returns false when the function is not
-- there or raised an error (the photos then get calls of their own).
local function registerTogether(catalog, items, names)
    local okGet, fn = pcall(function()
        return catalog.buildSmartPreviews
    end)
    if not okGet or type(fn) ~= 'function' then
        Log.info('automatic fetch: catalog:buildSmartPreviews is not available in this Lightroom; the photos are '
            .. 'registered one call each')
        return false
    end
    local photos, entries = {}, {}
    for i, it in ipairs(items) do
        photos[i], entries[i] = it.photo, it.entry
    end
    local started = AutoSend.clock()
    local ok, result = LrTasks.pcall(function()
        return catalog:buildSmartPreviews(photos)
    end)
    local seconds = AutoSend.clock() - started
    if not ok then
        Log.warn('automatic fetch: catalog:buildSmartPreviews for %d photo(s) raised an error after %.1f s: %s; the '
            .. 'photos are registered one call each from now on', #photos, seconds, tostring(result))
        return false
    end
    local sorted = RegisterQueue.outcome(entries, result, localIdOf)
    Log.info('automatic fetch: one registration call (catalog:buildSmartPreviews) for %d photo(s) took %.1f s: '
        .. '%d existed, %d created, %d failed, %d not reached', #photos, seconds, #sorted.existed, #sorted.created,
        #sorted.failed, #sorted.untried)
    for _, entry in ipairs(sorted.existed) do
        registeredLine(entry, names[entry.id], 'Lightroom answered existed')
    end
    for _, entry in ipairs(sorted.created) do
        registeredLine(entry, names[entry.id], CREATED)
    end
    local word = putBack(sorted, names, {})
    if word == 'failed' and #sorted.untried > 0 then
        Log.info('automatic fetch: the call stopped at a failure; the %d photo(s) it did not reach are registered with '
            .. 'the next call', #sorted.untried)
    elseif word == 'held' then
        Log.info('automatic fetch: %d photo(s) were not registered (the call was cancelled or stopped); they are '
            .. 'registered after the next fetch in one go or at the next start', #sorted.untried)
    end
    return true
end

-- Registers the placed photos that are due (holding the fetch lock). Before calling into the catalog, the photos are
-- read again with sqlite3: one that Lightroom already counts as having a smart preview needs no call, and a photo is
-- included only when its smart preview file is in place (without it Lightroom would build one from the original, over
-- the network). The photo objects come from catalog:findPhotoByPath, one lookup per photo.
local function registerPlaced(settings, catalog, catalogPath, lease, force)
    local taken = RegisterQueue.takeDue(registerList, os.time(), force)
    local all = {}
    for _, list in ipairs({ taken.batch, taken.singles }) do
        for _, entry in ipairs(list) do
            all[#all + 1] = entry
        end
    end
    if #all == 0 then
        return
    end
    registerDirty = true
    local ids = {}
    for i, entry in ipairs(all) do
        ids[i] = entry.id
    end
    local rows, problem = readPhotos(settings, catalogPath, ids)
    if not rows then
        Log.warn('automatic fetch: reading the catalog failed: %s; registration tried again later', tostring(problem))
        for _, entry in ipairs(all) do
            entry.notBefore = os.time() + RegisterQueue.RETRY
            RegisterQueue.add(registerList, entry)
        end
        return
    end
    local names, together, each, notFound = {}, {}, {}, {}
    for _, entry in ipairs(all) do
        local row = rows[entry.id]
        names[entry.id] = row and row.fileName or ('catalog id ' .. entry.id)
        local dest = row and row.fileUuid and SmartPreviewPath.dngPath(catalogPath, row.fileUuid)
        if not row or row.incomplete or not dest then
            Log.info('catalog id %d: no longer in the catalog; its smart preview file stays where it was placed',
                entry.id)
            if entry.job then
                JobStats.fail(FastState.stats, entry.job)
            end
        elseif row.hasSmartPreview then
            registeredLine(entry, row.fileName, 'Lightroom counts it as having a smart preview already')
        elseif not LrFileUtils.exists(dest) then
            Log.info('%s', RunSummary.photoLine(row.fileName, 'notRegistered', 'the placed file is no longer there ('
                .. dest .. '); not registered, so that Lightroom does not build one from the original'))
            if entry.job then
                JobStats.fail(FastState.stats, entry.job)
            end
        else
            local photo = PhotoAccess.findByPath(catalog, row.path)
            if not photo or localIdOf(photo) ~= entry.id then
                notFound[#notFound + 1] = entry
            elseif entry.single or batchUsable == false then
                each[#each + 1] = { entry = entry, photo = photo }
            else
                together[#together + 1] = { entry = entry, photo = photo }
            end
        end
    end
    if #notFound > 0 then
        local why = {}
        for _, entry in ipairs(notFound) do
            why[entry.id] = 'Lightroom did not find the photo by its path'
        end
        putBack({ failed = notFound, untried = {}, existed = {}, created = {} }, names, why)
    end
    if #together > 0 and not registerTogether(catalog, together, names) then
        batchUsable = false
        for _, it in ipairs(together) do
            each[#each + 1] = it
        end
    end
    if #each > 0 then
        registerEach(each, names, lease)
    end
    for _, entry in ipairs(all) do
        if entry.job then
            logTotals(entry.job)
        end
    end
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

-- The fetch in one go around an import (FetchGo): logs its start and end, takes queued downloads back when an import
-- begins. Returns true while nothing may be downloaded or placed (an import in progress).
local function followImport(importing, settings)
    local idle = #inbox == 0 and (queue == nil or queue:isIdle())
    local event = FetchGo.step(goState, importing, idle, AutoSend.clock(), #inbox + #retries)
    if event == 'begin' then
        if goState.go then
            goState.go.finished = AutoSend.clock()
            Log.info('automatic fetch: the fetch in one go stops for a new import: %s', FetchGo.totals(goState.go))
            goState.go = nil
        end
        local back = takeBackQueue(false, 0)
        Log.info('automatic fetch: an import is in progress; nothing is downloaded until it is over (the server '
            .. 'builds meanwhile)%s', back > 0 and string.format('; %d download(s) taken back', back) or '')
    elseif event == 'start' then
        Log.info('automatic fetch: the import is taken as over; fetching the %d smart preview(s) ready so far in one '
            .. 'go (%d download(s) at once)', goState.go.ready, settings.downloadConcurrency)
    elseif event == 'finish' then
        Log.info('automatic fetch: the fetch in one go is done: %s', FetchGo.totals(goState.last))
        forceRegister = true
    end
    return goState.holding
end

-- One step of the automatic fetch for the byId jobs. importing: an import is in progress (nothing is downloaded, placed
-- or registered); shouldStop() -> true when the loop must end. Returns a short text for the log (or nil), and the
-- seconds to the next step when it should come sooner than the loop's step: BUSY_STEP while files are on their way or
-- to be registered, WAIT_STEP while a waiting request is open (so that a ready file is picked up within a moment),
-- else nil.
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
    local decision, retryAt = PendingJobs.decide(store, catalogPath, now)
    local serverWait = decision == 'wait'
    if next(byId) ~= nil and settings.serverUrl ~= '' then
        local known = false
        if serverWait then
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

    local holding = followImport(importing, settings)
    if not holding and not serverWait then
        resolveInbox(settings, catalogPath)
        retryDue(settings)
    end
    local q = queue
    local idle = #inbox == 0 and (q == nil or q:isIdle())
    local registerDue = not holding and goState.go == nil
        and RegisterQueue.due(registerList, os.time(), forceRegister, idle)
    if forceRegister and not holding and goState.go == nil and not registerDue then
        forceRegister = false -- nothing to register after that fetch in one go
    end
    local placing = not holding and q ~= nil and (q:finishedCount() > 0 or (q.inline and not q:isIdle()))
    if placing or registerDue or not tempsChecked then
        local lease = Pipeline.acquireLease(FastFetch.LABEL, true)
        if lease then
            local ok, err = LrTasks.pcall(function()
                if not tempsChecked then
                    Pipeline.cleanRecordedTemp()
                    tempsChecked = true
                end
                if placing then
                    q:pump(function()
                        return shouldStop() or backoffHit or not lease.refresh()
                    end)
                end
                if registerDue then
                    local force = forceRegister
                    forceRegister = false
                    registerPlaced(settings, catalog, catalogPath, lease, force)
                end
            end)
            lease.release()
            if not ok then
                Log.error('automatic fetch: placing stopped with an error: %s', tostring(err))
            end
        end
    end
    if backoffHit then
        backoffHit = false
        local _, waitUntil = PendingJobs.decide(store, catalogPath, os.time())
        takeBackQueue(true, waitUntil or (os.time() + FastFetch.RETRY_SECONDS))
    end
    saveRegister(store, catalogPath)

    for key, w in pairs(watchers) do
        if w.gone and (open[key] or 0) == 0 then
            finishJob(w, catalogPath, true)
        elseif not w.running and byId[key] and WaitPlan.done(w.answer, open[key]) and #retries == 0 then
            finishJob(w, catalogPath, false)
        end
    end
    saveRegister(store, catalogPath)
    if text == nil then
        if next(byId) ~= nil and settings.serverUrl == '' then
            text = 'no server URL is set; nothing done'
        elseif #registerList > 0 then
            text = holding and 'the placed smart previews are registered when the import has finished'
                or 'registering the placed smart previews'
        elseif #pending == 0 then
            text = 'nothing pending for this catalog; the server is not asked'
        end
    end
    if holding and #inbox > 0 then
        text = string.format('%s; %d smart preview(s) ready, fetched when the import is over', text or 'an import is '
            .. 'in progress', #inbox)
    end
    local nextStep
    local busy = (not holding and not serverWait and #inbox > 0) or (queue ~= nil and not queue:isIdle())
        or (not holding and RegisterQueue.due(registerList, os.time(), forceRegister, false))
    if busy then
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
