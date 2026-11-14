-- The automatic send (off by default): in each look of the automatic loop (AutoFetch, AutoFetchLoop), the raw photos
-- added to the catalog since the last look that have no smart preview and whose path maps to an available server root
-- are sent at once, tagged with this catalog's clientId, so that the automatic fetch (or «Fetch ready smart previews»)
-- brings their smart previews in. Quiet: no dialogs; one log line per photo sent and one per look that did something.
--
-- Since version 0.8.0 the photos are found with one read of the catalog through sqlite3 (CatalogRead), an external
-- process that does not hold up Lightroom's window: their folder, file name, file UUID, import and whether Lightroom
-- has a smart preview for them. No call into the catalog (getAllPhotos, findPhotoByPath) is made on this path; such
-- calls are very slow while Lightroom imports (seen with 0.6.0 and 0.7.0: minutes). A photo is sent in the look that
-- finds it; one Lightroom import is one job, created by its first photos and added to by the later ones (JobGroups);
-- photos of no import are sent per look. Against a server without appendItems every look creates new jobs, as before.
--
-- It contacts the server only when it has photos to send: a look with no new photo makes no request, and neither does
-- one whose new photos all fail the checks that need no server (virtual copies, videos, smart preview present, no path
-- mapping, a file type the server did not take when last asked). The server's info is kept for a few minutes, so a
-- burst of an import costs one request (two when the info is due again). Every job it creates or adds to is pending
-- (PendingJobs, marked as having catalog ids as refs), so the automatic fetch follows it.
local LrApplication = import 'LrApplication'
local LrDate = import 'LrDate'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'

local AutoSendPlan = require 'AutoSendPlan'
local CatalogRead = require 'CatalogRead'
local FastState = require 'FastState'
local JobGroups = require 'JobGroups'
local JobStats = require 'JobStats'
local Jobs = require 'Jobs'
local Log = require 'Log'
local PendingJobs = require 'PendingJobs'
local Pipeline = require 'Pipeline'
local RunSummary = require 'RunSummary'
local Selection = require 'Selection'
local ServerClient = require 'ServerClient'
local Settings = require 'Settings'
local SqliteRunner = require 'SqliteRunner'

local AutoSend = {}

AutoSend.TOOL_SECONDS = 600 -- how long a found sqlite3 tool is used before it is looked for again
AutoSend.INFO_SECONDS = 300 -- how long the server's info is used before it is asked for again

local cache = {}

local function idText(id)
    return string.format('%d', id)
end

-- The time in seconds, with fractions where Lightroom gives them (LrDate.currentTime).
function AutoSend.clock()
    local ok, value = LrTasks.pcall(LrDate.currentTime)
    if ok and type(value) == 'number' then
        return value
    end
    return os.time()
end

-- The sqlite3 tool, found once and kept for TOOL_SECONDS (finding it runs "sqlite3 -version"). Returns the tool, or
-- nil plus a message.
function AutoSend.tool(settings)
    local now = os.time()
    if cache.tool and cache.toolPath == settings.sqlitePath and now - cache.toolAt < AutoSend.TOOL_SECONDS then
        return cache.tool
    end
    local tool, problem = SqliteRunner.locate(settings.sqlitePath, _PLUGIN and _PLUGIN.path)
    if not tool then
        cache.tool = nil
        return nil, problem
    end
    cache.tool, cache.toolPath, cache.toolAt = tool, settings.sqlitePath, now
    return tool
end

-- The server's info, kept for INFO_SECONDS; what it can do is also stored (FastState.saveCapabilities). Returns the
-- info, or nil plus a problem.
function AutoSend.serverInfo(settings, store)
    local now = os.time()
    if cache.info and cache.infoUrl == settings.serverUrl and now - cache.infoAt < AutoSend.INFO_SECONDS then
        return cache.info
    end
    local info, problem = ServerClient.fetchInfo(settings)
    if not info then
        cache.info = nil
        return nil, problem
    end
    cache.info, cache.infoUrl, cache.infoAt = info, settings.serverUrl, now
    FastState.saveCapabilities(store, info, now)
    return info
end

-- Forgets the kept info (after a request failed, the next one asks again).
function AutoSend.forgetInfo()
    cache.info = nil
end

-- After a failed contact the send asks the server again only after PendingJobs.BACKOFF (1, 2, 5, 10, 30, then 60
-- minutes), while it goes on reading the catalog. Returns the time of the next try, or nil when it may ask now.
function AutoSend.waitUntil(now)
    if cache.retryAt and now < cache.retryAt then
        return cache.retryAt
    end
    return nil
end

local function contacted(ok, now)
    if ok then
        cache.failures, cache.retryAt = 0, nil
    else
        cache.failures = (cache.failures or 0) + 1
        cache.retryAt = now + PendingJobs.backoff(cache.failures)
    end
end

-- One read of the catalog (CatalogRead), read-only. Returns the parsed result, or nil plus a message.
function AutoSend.read(tool, catalogPath, sql)
    local text, err = SqliteRunner.query(tool.tool, catalogPath, sql, true)
    if not text then
        return nil, err
    end
    local parsed, problems = CatalogRead.parse(text)
    for _, problem in ipairs(problems) do
        Log.warn('automatic send: sqlite3 output: %s', problem)
    end
    return parsed
end

local function add(counts, key, n)
    counts[key] = (counts[key] or 0) + (n or 1)
end

-- Stores the state, unless the option was switched off while the look ran (the Plug-in Manager then forgot the
-- state, and switching it on again must start afresh).
local function saveState(store, catalogPath, state)
    if Settings.read(store).autoSend then
        AutoSendPlan.save(store, catalogPath, state)
    end
end

-- Sends one batch (JobGroups.plan): adds it to its job or creates a new one. Records the job as pending, what is
-- needed to place each smart preview (FastState), and one log line per photo. Returns true, or false plus a message
-- (nothing of the batch was sent then). parts: the last part number used per import in this look.
local function sendBatch(context, batch)
    local entries = {}
    for _, photo in ipairs(batch.photos) do
        entries[#entries + 1] = { ref = idText(photo.id), rootId = photo.rootId, relativePath = photo.relativePath }
    end
    local settings, store, catalogPath, info = context.settings, context.store, context.catalogPath, context.info
    local answer, problem, added
    if batch.jobId then
        local body, bodyError = Jobs.appendBody(entries)
        if not body then
            return false, 'cannot build the request: ' .. bodyError
        end
        answer, problem = ServerClient.appendItems(settings, batch.jobId, body)
        if answer then
            added = true
        elseif JobGroups.afterAppendFailure(problem) == 'newJob' then
            Log.info('automatic send: job %d takes no more photos (%s); a new job takes them', batch.jobId,
                problem.message)
            batch.part = batch.part + 1
        else
            return false, problem.message
        end
    end
    if not answer then
        -- A part number this look has used already (a refused addition went into a new job) moves on.
        local used = context.parts[batch.key or '']
        if used and batch.part <= used then
            batch.part = used + 1
        end
        batch.label = JobGroups.partLabel(batch.base, batch.part)
        local body, bodyError = Jobs.createBody(entries, { clientId = Pipeline.clientId(catalogPath),
            label = batch.label })
        if not body then
            return false, 'cannot build the job request: ' .. bodyError
        end
        answer, problem = ServerClient.createJob(settings, body)
        if not answer then
            return false, Jobs.createProblemText(problem, info.capabilities.maxItemsPerJob)
        end
    end
    local jobId = answer.job.id
    local refsOk, refsProblem = Jobs.checkRefs(answer.items, entries)
    if not refsOk then
        if not added then
            ServerClient.cancelJob(settings, jobId)
        end
        return false, 'the server\'s answer does not match the request (' .. refsProblem .. ')'
    end
    local now = os.time()
    PendingJobs.add(store, catalogPath, { jobId }, now, { byId = true })
    if added then
        JobGroups.added(context.groups, batch.key, #entries, now)
    else
        JobGroups.created(context.groups, batch.key, jobId, #entries, batch.base, batch.part, now)
        context.parts[batch.key or ''] = batch.part
        FastState.setLabel(jobId, batch.label)
    end
    local sentAt = AutoSend.clock()
    local byRef = {}
    for _, photo in ipairs(batch.photos) do
        byRef[idText(photo.id)] = photo
    end
    local outcome = context.outcome
    for _, item in ipairs(answer.items) do
        local photo = byRef[item.ref]
        local seen = FastState.firstSeen[photo.id]
        local took = seen and math.max(0, sentAt - seen) or nil
        FastState.remember(jobId, item.ref, { id = photo.id, fileUuid = photo.fileUuid, fileName = photo.fileName,
            width = photo.width, height = photo.height, path = photo.path, seenAt = seen, sentAt = sentAt })
        if item.state == 'rejected' then
            local code = (item.error and item.error.code) or 'unknown'
            add(outcome.rejected, code)
            JobStats.fail(FastState.stats, jobId)
            Log.info('%s', RunSummary.photoLine(photo.fileName, 'rejected', 'job ' .. jobId .. ', ' .. code))
        else
            if item.state == 'ready' then
                outcome.ready = outcome.ready + 1
            end
            JobStats.add(FastState.stats, jobId, 'sent', took)
            Log.info('%s', RunSummary.photoLine(photo.fileName, 'sent', string.format(
                'job %d, %s; first seen in the catalog -> sent %s', jobId, item.state, JobStats.seconds(took))))
        end
        FastState.firstSeen[photo.id] = nil
    end
    outcome.sent = outcome.sent + #entries
    outcome.jobs[#outcome.jobs + 1] = { id = jobId, count = #entries, added = added == true }
    return true
end

-- Deals with the photos a read found above the mark (AutoSendPlan: what is new, what waits, what is taken now), sends
-- what is taken, and stores the state. Returns the text for the log (nil when nothing happened) and the number of
-- photos no earlier look had seen.
local function sendFound(store, settings, catalogPath, state, parsed, now)
    local plan = AutoSendPlan.sort(state, parsed.photos, #parsed.imports > 0, now)
    local seenAt = AutoSend.clock()
    for _, photo in ipairs(parsed.photos) do
        if not state.handled[photo.id] and FastState.firstSeen[photo.id] == nil then
            FastState.firstSeen[photo.id] = seenAt
        end
    end
    local visible = {}
    for i, photo in ipairs(parsed.photos) do
        visible[i] = photo.id
    end
    local leftOut, done, candidates = {}, {}, {}
    add(leftOut, 'gaveUp', #plan.gaveUp)
    for _, id in ipairs(plan.gaveUp) do
        done[#done + 1] = id
    end
    for _, photo in ipairs(plan.take) do
        if photo.virtualCopy then
            add(leftOut, 'virtualCopy')
            done[#done + 1] = photo.id
        elseif photo.badUuid then
            add(leftOut, 'noFileId')
            done[#done + 1] = photo.id
            Log.warn('automatic send: catalog id %d has a file id that is not a UUID (%s); left out', photo.id,
                photo.badUuid)
        else
            candidates[#candidates + 1] = { id = photo.id, importId = photo.importId, folder = photo.folder,
                fileName = photo.fileName, path = photo.path, fileUuid = photo.fileUuid, width = photo.width,
                height = photo.height, isVideo = photo.video,
                smartPreviewPath = photo.hasSmartPreview and '(registered in the catalog)' or nil }
        end
    end
    local function finish(text)
        AutoSendPlan.handle(state, done)
        for _, id in ipairs(done) do
            FastState.firstSeen[id] = nil
        end
        if AutoSendPlan.advance(state, visible, now) then
            Log.info('automatic send: no new photo for %d s and nothing waits; every photo up to catalog id %d is '
                .. 'dealt with', AutoSendPlan.MARK_QUIET, state.mark)
        end
        state.looked = now
        saveState(store, catalogPath, state)
        return text
    end
    if #candidates == 0 and #done == 0 then
        if plan.waiting > 0 and plan.new > 0 then
            return finish(AutoSendPlan.roundText({ later = plan.waiting })), plan.new
        end
        return finish(nil), plan.new
    end

    -- First what can be told without the server (the photo, the path mappings, and the file types the server took when
    -- it was last asked; any type when it never was). When that leaves nothing, the server is not asked.
    local known = AutoSendPlan.knownExtensions(store)
    local mappings = Settings.mappings(settings)
    local locally = Selection.classify(candidates, { extensions = known, anyExtension = known == nil,
        mappings = mappings, anyRoot = true })
    for _, skipped in ipairs(locally.skipped) do
        add(leftOut, skipped.reason)
        done[#done + 1] = skipped.photo.id
    end
    if #locally.eligible == 0 then
        return finish(AutoSendPlan.roundText({ leftOut = leftOut, later = plan.waiting })
            .. ' (the server was not asked)'), plan.new
    end

    -- Photos not sent by this look stay unhandled: a later look reads and sends them.
    local retryAt = AutoSend.waitUntil(now)
    if retryAt then
        return finish(string.format('%d photo(s) to send; the server did not answer; next try at %s',
            #locally.eligible, os.date('%H:%M', retryAt))), plan.new
    end
    local info, infoProblem = AutoSend.serverInfo(settings, store)
    if not info then
        contacted(false, now)
        return finish('not done: ' .. infoProblem.message .. string.format(' (next try at %s)',
            os.date('%H:%M', cache.retryAt))), plan.new
    end
    local serverProblem = Selection.serverProblem(info, mappings)
    if serverProblem then
        AutoSend.forgetInfo()
        return finish('not done: ' .. serverProblem), plan.new
    end
    AutoSendPlan.rememberExtensions(store, info.capabilities.extensions)
    local sorted = Selection.classify(locally.eligible, { extensions = info.capabilities.extensions,
        mappings = mappings, availableRoots = Selection.availableRoots(info) })
    for _, skipped in ipairs(sorted.skipped) do
        add(leftOut, skipped.reason)
        done[#done + 1] = skipped.photo.id
    end

    local groups = JobGroups.load(store, catalogPath, now)
    local importDates = {}
    for _, import in ipairs(parsed.imports) do
        importDates[import.id] = import.date
    end
    local batches = JobGroups.plan(sorted.eligible, groups, importDates, CatalogRead.folderName,
        { maxItems = info.capabilities.maxItemsPerJob, append = info.capabilities.appendItems })
    local context = { store = store, settings = settings, catalogPath = catalogPath, info = info, groups = groups,
        parts = {}, outcome = { sent = 0, jobs = {}, ready = 0, rejected = {}, leftOut = leftOut,
            later = plan.waiting } }
    for i, batch in ipairs(batches) do
        local ok, why = sendBatch(context, batch)
        if ok then
            for _, photo in ipairs(batch.photos) do
                done[#done + 1] = photo.id
            end
        else
            local unsent = 0
            for j = i, #batches do
                unsent = unsent + #batches[j].photos
            end
            context.outcome.unsent, context.outcome.problem = unsent, why
            AutoSend.forgetInfo()
            contacted(false, now)
            break
        end
    end
    if not context.outcome.unsent then
        contacted(true, now)
    end
    JobGroups.save(store, catalogPath, groups)
    return finish(AutoSendPlan.roundText(context.outcome)), plan.new
end

-- One look of the automatic send. shouldStop() -> true when the loop must end (a look that comes back after that, for
-- example from a read that took very long, changes nothing). Returns a short text for the log (nil when there was
-- nothing to do; the loop logs the same text only once in a row), the number of photos found that no earlier look had
-- seen (for WatchMode: photos read again because they wait for their rows, their import link or the server do not
-- count), and the import records read above the mark ({ { id, date } }).
function AutoSend.sendOnce(shouldStop)
    local store = LrPrefs.prefsForPlugin()
    local settings = Settings.read(store)
    if settings.serverUrl == '' then
        return 'no server URL is set; nothing done', 0, {}
    end
    local catalogPath = LrApplication.activeCatalog():getPath()
    local tool, toolProblem = AutoSend.tool(settings)
    if not tool then
        return 'not done: ' .. toolProblem, 0, {}
    end
    local now = os.time()
    local state = AutoSendPlan.load(store, catalogPath)
    if not state then
        local parsed, err = AutoSend.read(tool, catalogPath, CatalogRead.markSql())
        if shouldStop and shouldStop() then
            return nil, 0, {}
        end
        if not parsed or not parsed.mark then
            return 'not done: reading the catalog failed: ' .. tostring(err or 'no answer'), 0, {}
        end
        saveState(store, catalogPath, AutoSendPlan.prime(parsed.mark, now))
        return string.format('watching this catalog for new photos from now on (photos up to catalog id %d are left '
            .. 'alone)', parsed.mark), 0, {}
    end
    local parsed, err = AutoSend.read(tool, catalogPath, CatalogRead.newSql(state.mark))
    if shouldStop and shouldStop() then
        return nil, 0, {}
    end
    if not parsed then
        return 'not done: reading the catalog failed: ' .. tostring(err), 0, {}
    end
    local text, new = sendFound(store, settings, catalogPath, state, parsed, now)
    return text, new, parsed.imports
end

return AutoSend
