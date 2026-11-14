-- The automatic send (off by default): in each round of the automatic loop (AutoFetch), raw photos added to the
-- catalog since the last look that have no smart preview and whose path maps to an available server root are sent
-- as one job, labelled as automatic and tagged with this catalog's clientId, so that the automatic fetch (or «Fetch
-- ready smart previews») brings them in. Quiet: no dialogs; the loop logs one line per round that did something.
-- The decisions are AutoSendPlan's (pure, tested); this file connects them to the SDK. Every SDK call is protected:
-- a failure ends the round with a text for the log, and the next round tries again.
--
-- Finding new photos. The SDK has no import event, findPhotos has no criterion for the import date or for smart
-- previews, and the «Previous Import» collection (catalog.kPreviousImport) can only be reached by making it the
-- user's active source (catalog:setActiveSources), which a background task must not do. So:
--   * primary: catalog:getAllPhotos() and photo.localIdentifier compared with the remembered mark (AutoSendPlan);
--     metadata is read only for photos above the mark. The loop yields every AutoSendPlan.YIELD_EVERY photos.
--   * FALLBACK, used only when getAllPhotos fails, and never for the first look of a catalog: catalog:findPhotos
--     with the documented criterion "touchTime" (Edit Date), operation "inLast", N hours. That an import gives a
--     photo an Edit Date is NOT documented and not verified; if it does not, the fallback finds nothing.
local LrApplication = import 'LrApplication'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'

local AutoSendPlan = require 'AutoSendPlan'
local FileIds = require 'FileIds'
local Jobs = require 'Jobs'
local PhotoAccess = require 'PhotoAccess'
local Pipeline = require 'Pipeline'
local Selection = require 'Selection'
local ServerClient = require 'ServerClient'
local Settings = require 'Settings'
local SqliteRunner = require 'SqliteRunner'

local AutoSend = {}

AutoSend.LABEL = 'Lightroom import (automatic)'
AutoSend.LEASE_LABEL = 'the automatic send'

local function localId(photo)
    return photo.localIdentifier
end

-- Goes through photos (protected). Returns found, maxId, count, or nil plus a message.
local function scanPhotos(photos, mark, shouldStop)
    local ok, found, maxId, count = LrTasks.pcall(AutoSendPlan.scan, photos, localId, mark, {
        yield = function()
            LrTasks.yield()
        end,
        shouldStop = shouldStop,
    })
    if not ok then
        return nil, 'reading photo.localIdentifier failed: ' .. tostring(found)
    end
    if not found then
        return nil, maxId
    end
    return found, maxId, count
end

-- Every photo of the catalog above mark (math.huge: none, only the largest id). Returns found, maxId, count, or nil
-- plus a message.
function AutoSend.scanAll(catalog, mark, shouldStop)
    local ok, photos = LrTasks.pcall(function()
        return catalog:getAllPhotos()
    end)
    if not ok or type(photos) ~= 'table' then
        return nil, 'catalog:getAllPhotos failed: ' .. tostring(photos)
    end
    return scanPhotos(photos, mark, shouldStop)
end

-- FALLBACK (see the header): the photos with an Edit Date in the last hours, above mark.
function AutoSend.findRecentlyEdited(catalog, mark, hours, shouldStop)
    local ok, photos = LrTasks.pcall(function()
        return catalog:findPhotos {
            searchDesc = { criteria = 'touchTime', operation = 'inLast', value = hours, value_units = 'hours' },
        }
    end)
    if not ok or type(photos) ~= 'table' then
        return nil, 'catalog:findPhotos failed: ' .. tostring(photos)
    end
    return scanPhotos(photos, mark, shouldStop)
end

-- The photos above the state's mark. Returns found, maxId, how ('scan' or 'fallback'), or nil plus a message.
function AutoSend.findNew(catalog, state, shouldStop, now)
    local found, maxId = AutoSend.scanAll(catalog, state.mark, shouldStop)
    if found then
        return found, maxId, 'scan'
    end
    if maxId == 'stopped' then
        return nil, 'stopped'
    end
    local scanProblem = maxId
    local hours = AutoSendPlan.windowHours(state, now)
    found, maxId = AutoSend.findRecentlyEdited(catalog, state.mark, hours, shouldStop)
    if found then
        return found, maxId, 'fallback'
    end
    return nil, scanProblem .. '; the fallback failed too: ' .. tostring(maxId)
end

local function add(counts, key, n)
    counts[key] = (counts[key] or 0) + (n or 1)
end

-- Stores the state, unless the option was switched off while the round ran (the Plug-in Manager then forgot the
-- state, and switching it on again must start afresh).
local function saveState(prefs, catalogPath, state)
    if Settings.read(prefs).autoSend then
        AutoSendPlan.save(prefs, catalogPath, state)
    end
end

-- Sends what the round picked; returns the text for the log. Holds the fetch lock (the caller took it).
local function sendPicked(settings, catalogPath, state, picked, isCanceled)
    local prefs = LrPrefs.prefsForPlugin()
    local info, infoProblem = ServerClient.fetchInfo(settings)
    if not info then
        return 'not done: ' .. infoProblem.message
    end
    local mappings = Settings.mappings(settings)
    local serverProblem = Selection.serverProblem(info, mappings)
    if serverProblem then
        return 'not done: ' .. serverProblem
    end
    local maxItems = info.capabilities.maxItemsPerJob
    picked = AutoSendPlan.limit(picked, maxItems)

    -- The photos, in ascending id order; virtual copies are not new files.
    local photos, ids = {}, {}
    for i, entry in ipairs(picked.photos) do
        photos[i], ids[i] = entry.photo, entry.id
    end
    local described = PhotoAccess.describeAll(photos)
    local leftOut, candidates = {}, {}
    for i, photo in ipairs(described) do
        photo.autoId = ids[i]
        if photo.isVirtualCopy then
            add(leftOut, 'virtualCopy')
        else
            candidates[#candidates + 1] = photo
        end
    end
    local sorted = Selection.classify(candidates, { extensions = info.capabilities.extensions, mappings = mappings,
        availableRoots = Selection.availableRoots(info) })
    for _, skipped in ipairs(sorted.skipped) do
        add(leftOut, skipped.reason)
    end

    -- The file UUIDs (sqlite3, read-only).
    local entries, transient = {}, {}
    if #sorted.eligible > 0 then
        local tool, toolProblem = SqliteRunner.locate(settings.sqlitePath, _PLUGIN and _PLUGIN.path)
        if not tool then
            return 'not done: ' .. toolProblem
        end
        local rows, problems = SqliteRunner.lookup(tool.tool, catalogPath, FileIds.ids(sorted.eligible), isCanceled)
        if not rows then
            return 'not done: reading the file ids from the catalog failed: ' .. tostring(problems)
        end
        local assigned = FileIds.assign(sorted.eligible, rows, catalogPath)
        for _, skipped in ipairs(assigned.skipped) do
            if AutoSendPlan.TRANSIENT[skipped.reason] then
                transient[skipped.photo.autoId] = true
            else
                add(leftOut, skipped.reason)
            end
        end
        entries = assigned.entries
    end

    local newState, cutoff, gaveUp = AutoSendPlan.settle(state, ids, transient, picked.seen, os.time())
    add(leftOut, 'gaveUp', #gaveUp)
    local send = {}
    for _, entry in ipairs(entries) do
        if cutoff == nil or entry.autoId < cutoff then
            send[#send + 1] = entry
        end
    end
    local later = 0
    for _, id in ipairs(ids) do
        if cutoff ~= nil and id >= cutoff then
            later = later + 1
        end
    end
    local outcome = { sent = 0, leftOut = leftOut, later = later, more = picked.more, waiting = picked.waiting,
        rejected = {} }

    if #send > 0 then
        local body, bodyError = Jobs.createBody(send, { clientId = Pipeline.clientId(catalogPath),
            label = AutoSend.LABEL })
        if not body then
            return 'not done: cannot build the job request: ' .. bodyError
        end
        local created, createProblem = ServerClient.createJob(settings, body)
        if not created then
            return 'not done: ' .. Jobs.createProblemText(createProblem, maxItems)
        end
        local refsOk, refsProblem = Jobs.checkRefs(created.items, send)
        if not refsOk then
            ServerClient.cancelJob(settings, created.job.id)
            return 'not done: the server\'s answer does not match the request (' .. refsProblem .. '); job '
                .. created.job.id .. ' was cancelled'
        end
        -- One log line per round (the loop writes it); the job's items can be looked up on the server by its id.
        outcome.sent, outcome.jobId, outcome.ready = #send, created.job.id, 0
        for _, item in ipairs(created.items) do
            if item.state == 'ready' then
                outcome.ready = outcome.ready + 1
            elseif item.state == 'rejected' then
                add(outcome.rejected, (item.error and item.error.code) or 'unknown')
            end
        end
    end
    saveState(prefs, catalogPath, newState)
    return AutoSendPlan.roundText(outcome)
end

-- One round of the automatic send. shouldStop() -> true when the loop must end. Returns a short text for the log, or
-- nil when there was nothing to do (the loop then logs nothing, and logs the same text only once in a row).
function AutoSend.sendOnce(shouldStop)
    local prefs = LrPrefs.prefsForPlugin()
    local settings = Settings.read(prefs)
    if settings.serverUrl == '' then
        return 'no server URL is set; nothing done'
    end
    local catalog = LrApplication.activeCatalog()
    local catalogPath = catalog:getPath()
    local state = AutoSendPlan.load(prefs, catalogPath)
    local now = os.time()
    if not state then
        local found, maxId, count = AutoSend.scanAll(catalog, math.huge, shouldStop)
        if not found then
            return 'not done: ' .. tostring(maxId)
        end
        saveState(prefs, catalogPath, AutoSendPlan.prime(maxId, now))
        return string.format('watching this catalog for new photos from now on (the %d photo(s) in it now are left '
            .. 'alone; largest catalog id %d)', count, maxId)
    end

    local found, problem, how = AutoSend.findNew(catalog, state, shouldStop, now)
    if not found then
        return 'not done: ' .. tostring(problem)
    end
    local picked = AutoSendPlan.pick(state, found, AutoSendPlan.LIMIT)
    if #picked.photos == 0 then
        if picked.seen ~= state.seen then
            state.seen, state.looked = picked.seen, now
            saveState(prefs, catalogPath, state)
            return AutoSendPlan.roundText({ waiting = picked.waiting })
        end
        return nil
    end
    local started, text = Pipeline.withLease(AutoSend.LEASE_LABEL, function(lease)
        return sendPicked(settings, catalogPath, state, picked, function()
            return shouldStop() or not lease.refresh()
        end)
    end)
    if not started then
        return 'skipped: another fetch holds the lock'
    end
    if how == 'fallback' then
        text = text .. ' (found with the fallback: catalog:getAllPhotos failed)'
    end
    return text
end

return AutoSend
