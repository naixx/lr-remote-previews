-- What this catalog still waits for from the server, and when the background fetch may ask for it. Pure Lua 5.1: the
-- store (Lightroom's preferences for the plug-in) and the clock are passed in.
--
-- The background fetch (AutoFetch) talks to the server only while this catalog has a pending job: a job it sent
-- («Build smart previews on the server», the automatic send, a retry from «Server status...») whose smart previews
-- have not all been delivered or finally refused. With nothing pending it makes no request at all, so an idle
-- Lightroom never wakes a sleeping NAS or keeps it awake.
--
-- Kept per catalog under PendingJobs.KEY (one JSON text, keyed by the catalog path as CatalogState does it), so it
-- survives a restart of Lightroom:
--   jobs      { ["17"] = { sent = <os.time() when it was sent or retried>, byId = true | nil } }
--             byId: the job's refs are the photos' catalog ids (jobs sent by version 0.8.0 or newer), so the
--             automatic fetch can place its files without asking Lightroom for the photos (FastFetch); other jobs are
--             fetched the way version 0.7.0 did (Fetcher.everything)
--   failures  contacts in a row that failed (the server did not answer, or answered with an error)
--   retryAt   no contact before this time (os.time) after a failure
-- A job stops being pending when a fetch found it done (no longer active and every ready item dealt with: FetchPlan),
-- when the server no longer lists it (it deletes jobs some days after they finished), or MAX_AGE_DAYS after it was
-- sent, whatever its state (then «Fetch ready smart previews» or «Fetch now» still bring its files).
-- After a failed contact the next one waits BACKOFF[n] seconds, n = failures in a row (the last step repeats).
local Json = require 'Json'
local PathMap = require 'PathMap'

local PendingJobs = {}

PendingJobs.KEY = 'pendingJobs'
PendingJobs.MAX_AGE_DAYS = 7
PendingJobs.BACKOFF = { 60, 120, 300, 600, 1800, 3600 }

local function isTime(value)
    return type(value) == 'number' and value >= 0 and value == math.floor(value)
end

local function loadAll(store)
    local text = store[PendingJobs.KEY]
    if type(text) ~= 'string' or text == '' then
        return {}
    end
    local ok, decoded = pcall(Json.decode, text)
    if not ok or type(decoded) ~= 'table' then
        return {}
    end
    return decoded
end

-- The entry of this catalog: { jobs = { [id] = { sent } }, failures = n, retryAt = t | nil }. Malformed parts are
-- dropped; jobs older than MAX_AGE_DAYS are dropped when now is given.
function PendingJobs.load(store, catalogPath, now)
    local key = PathMap.fileKey(catalogPath)
    local raw = key and loadAll(store)[key]
    local entry = { jobs = {}, failures = 0, retryAt = nil }
    if type(raw) ~= 'table' then
        return entry
    end
    local oldest = now and (now - PendingJobs.MAX_AGE_DAYS * 86400) or nil
    for id, job in pairs(type(raw.jobs) == 'table' and raw.jobs or {}) do
        if type(id) == 'string' and id:match('^%d+$') and type(job) == 'table' and isTime(job.sent)
            and (oldest == nil or job.sent >= oldest) then
            entry.jobs[id] = { sent = job.sent, byId = job.byId == true or nil }
        end
    end
    entry.failures = isTime(raw.failures) and raw.failures or 0
    entry.retryAt = isTime(raw.retryAt) and raw.retryAt or nil
    return entry
end

local function save(store, catalogPath, entry)
    local key = PathMap.fileKey(catalogPath)
    if not key then
        return false
    end
    local all = loadAll(store)
    if next(entry.jobs) == nil then
        all[key] = nil
    else
        all[key] = { jobs = entry.jobs, failures = entry.failures > 0 and entry.failures or nil,
            retryAt = entry.retryAt }
    end
    store[PendingJobs.KEY] = Json.encode(all)
    return true
end

-- The number of pending jobs of this catalog (expired ones not counted).
function PendingJobs.count(store, catalogPath, now)
    local n = 0
    for _ in pairs(PendingJobs.load(store, catalogPath, now).jobs) do
        n = n + 1
    end
    return n
end

-- Marks jobs as pending (just sent, items added, or retried). jobIds: job ids (numbers). options.byId: their refs are
-- catalog ids (a job already known as such stays so). A new job also ends a wait after failures: the server was just
-- reached. Returns false for a missing catalog path.
function PendingJobs.add(store, catalogPath, jobIds, now, options)
    local entry = PendingJobs.load(store, catalogPath, now)
    local added = false
    for _, id in ipairs(jobIds) do
        if isTime(id) and id > 0 then
            local key = string.format('%d', id)
            local known = entry.jobs[key]
            entry.jobs[key] = { sent = now,
                byId = (options and options.byId) == true or (known ~= nil and known.byId) or nil }
            added = true
        end
    end
    if added then
        entry.failures, entry.retryAt = 0, nil
    end
    return save(store, catalogPath, entry)
end

-- What the background fetch may do now: 'idle' (nothing pending: no request at all), 'wait' (backing off after a
-- failure; the second value is the time of the next try) or 'contact'.
function PendingJobs.decide(store, catalogPath, now)
    local entry = PendingJobs.load(store, catalogPath, now)
    if next(entry.jobs) == nil then
        return 'idle'
    end
    if entry.retryAt and now < entry.retryAt then
        return 'wait', entry.retryAt
    end
    return 'contact'
end

-- The seconds to wait after the n-th failed contact in a row.
function PendingJobs.backoff(failures)
    local steps = PendingJobs.BACKOFF
    return steps[math.max(1, math.min(failures, #steps))]
end

-- Records the result of a contact. ok: the server answered and the fetch ran. Returns the time of the next try after
-- a failure (nil after a success).
function PendingJobs.contacted(store, catalogPath, ok, now)
    local entry = PendingJobs.load(store, catalogPath, now)
    if ok then
        entry.failures, entry.retryAt = 0, nil
    else
        entry.failures = entry.failures + 1
        entry.retryAt = now + PendingJobs.backoff(entry.failures)
    end
    save(store, catalogPath, entry)
    return entry.retryAt
end

-- The pending jobs of this catalog, oldest first: { { id = n, byId = bool, sent = t }, ... }.
function PendingJobs.list(store, catalogPath, now)
    local list = {}
    for id, job in pairs(PendingJobs.load(store, catalogPath, now).jobs) do
        list[#list + 1] = { id = tonumber(id), byId = job.byId == true, sent = job.sent }
    end
    table.sort(list, function(a, b)
        return a.id < b.id
    end)
    return list
end

-- True while the job is pending.
function PendingJobs.has(store, catalogPath, jobId, now)
    return PendingJobs.load(store, catalogPath, now).jobs[string.format('%d', jobId)] ~= nil
end

-- Takes jobs off the list (done, or gone from the server). Returns the number still pending.
function PendingJobs.finish(store, catalogPath, jobIds, now)
    local entry = PendingJobs.load(store, catalogPath, now)
    for _, id in ipairs(jobIds) do
        entry.jobs[string.format('%d', id)] = nil
    end
    save(store, catalogPath, entry)
    local left = 0
    for _ in pairs(entry.jobs) do
        left = left + 1
    end
    return left
end

-- Takes the jobs a fetch found finished off the list. listed: { [id text] = true } for every job of this catalog the
-- server listed; done: { [id text] = true } for the ones that need nothing more. A pending job that is done, or that
-- the server no longer lists, stops being pending. Returns the number still pending.
function PendingJobs.settle(store, catalogPath, listed, done, now)
    local entry = PendingJobs.load(store, catalogPath, now)
    local left = 0
    for id in pairs(entry.jobs) do
        if done[id] or not listed[id] then
            entry.jobs[id] = nil
        else
            left = left + 1
        end
    end
    save(store, catalogPath, entry)
    return left
end

return PendingJobs
