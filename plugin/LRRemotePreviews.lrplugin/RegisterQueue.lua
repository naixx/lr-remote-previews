-- The smart previews the automatic fetch has placed and Lightroom has not yet been asked to register. Pure Lua 5.1: the
-- store (Lightroom's preferences for the plug-in) is passed in.
--
-- Registering needs a call into the catalog with the photo objects. Seen with plug-in 0.8.0: Lightroom did not take a
-- placed file by itself in ten minutes while it ran; it wrote the smart preview's row when the plug-in called
-- photo:buildSmartPreview(). So registration is needed, but not while an import is in progress (calls into the catalog
-- are very slow then) and not one call per photo (each showed up as an operation of its own in Lightroom's progress
-- area, hundreds of them). Since 0.8.2 the placed photos are registered together with one
-- catalog:buildSmartPreviews(photos) call (SDK 5.0: one progress bar; returns the photos as created / existed / failed;
-- may stop at the first failure or when the user cancels):
--   * right after a fetch in one go (force), all photos placed in it;
--   * otherwise once nothing is on its way and no photo was placed for DELAY seconds, or when the oldest has waited
--     MAX_WAIT seconds (photos that come one by one are registered together).
-- What a call did not register comes back: a failed photo RETRY seconds later; the photos after a failure at once (in
-- a smaller call); the photos a call did not reach while it reported no failure (the user cancelled, or the call gave
-- up) at the next fetch in one go or the next start (held), so a cancelled progress bar does not come back by itself.
-- A photo that was in MAX_BATCH_TRIES calls without being registered gets a call of its own; one that failed GIVE_UP
-- times is given up (logged; its file stays where it was placed).
--
-- Kept per catalog under RegisterQueue.KEY (one JSON text, keyed by the catalog path as CatalogState does it), so that
-- the photos are still registered after a restart:
--   { { id = <catalog id>, job = <job id>, ready = t, placed = t (the clock, for the log), at = <os.time() placed>,
--       tries = n, notBefore = <os.time()>, single = true } }
-- held is not stored: after a restart those photos are due again.
local Json = require 'Json'
local PathMap = require 'PathMap'

local RegisterQueue = {}

RegisterQueue.KEY = 'registerQueue'
RegisterQueue.MAX_CALL = 2000 -- photos in one registration call, at most
RegisterQueue.SINGLES = 25 -- photos registered one by one in one step of the loop
RegisterQueue.DELAY = 30 -- seconds without a new placed photo before a call, outside a fetch in one go
RegisterQueue.MAX_WAIT = 300 -- seconds the oldest placed photo waits at most, outside a fetch in one go
RegisterQueue.RETRY = 60 -- seconds before a photo a call reported as failed is tried again
RegisterQueue.MAX_BATCH_TRIES = 3 -- calls for many photos before a photo gets a call of its own
RegisterQueue.GIVE_UP = 5 -- failed tries in all before a photo is given up (its file stays; logged)

local function isCount(value)
    return type(value) == 'number' and value >= 0 and value == math.floor(value)
end

local function number(value)
    return type(value) == 'number' and value or nil
end

local function loadAll(store)
    local text = store[RegisterQueue.KEY]
    if type(text) ~= 'string' or text == '' then
        return {}
    end
    local ok, decoded = pcall(Json.decode, text)
    if not ok or type(decoded) ~= 'table' then
        return {}
    end
    return decoded
end

-- The queue of this catalog, in the order the files were placed; malformed entries are dropped, and an id is kept
-- once.
function RegisterQueue.load(store, catalogPath)
    local key = PathMap.fileKey(catalogPath)
    local raw = key and loadAll(store)[key]
    local queue, seen = {}, {}
    for _, entry in ipairs(type(raw) == 'table' and raw or {}) do
        if type(entry) == 'table' and isCount(entry.id) and entry.id > 0 and not seen[entry.id] then
            seen[entry.id] = true
            queue[#queue + 1] = { id = entry.id, job = isCount(entry.job) and entry.job or nil,
                ready = number(entry.ready), placed = number(entry.placed), at = number(entry.at),
                tries = isCount(entry.tries) and entry.tries or nil, notBefore = number(entry.notBefore),
                single = entry.single == true or nil }
        end
    end
    return queue
end

-- Stores the queue of this catalog (without held); other catalogs' queues are kept.
function RegisterQueue.save(store, catalogPath, queue)
    local key = PathMap.fileKey(catalogPath)
    if not key then
        return false
    end
    local all = loadAll(store)
    local stored = {}
    for i, entry in ipairs(queue) do
        stored[i] = { id = entry.id, job = entry.job, ready = entry.ready, placed = entry.placed, at = entry.at,
            tries = entry.tries, notBefore = entry.notBefore, single = entry.single }
    end
    all[key] = #stored > 0 and stored or nil
    store[RegisterQueue.KEY] = Json.encode(all)
    return true
end

-- Adds a placed photo ({ id, job, ready, placed, at }) unless its id is in the queue already. Returns true when added.
function RegisterQueue.add(queue, entry)
    for _, existing in ipairs(queue) do
        if existing.id == entry.id then
            return false
        end
    end
    queue[#queue + 1] = entry
    return true
end

local function eligible(entry, now, force)
    return (entry.notBefore or 0) <= now and (force or not entry.held)
end

-- True when a call is due now. force: a fetch in one go has just ended (held photos count too); idle: nothing is on its
-- way (no download queued, nothing received and not yet placed, every followed job has answered); since (optional): the
-- time this session took the queue over: no photo counts as placed earlier (since 0.8.4: after a restart the photos
-- placed by an earlier session wait for the rest of their job, not MAX_WAIT from when they were placed).
function RegisterQueue.due(queue, now, force, idle, since)
    local newest, oldest
    for _, entry in ipairs(queue) do
        if eligible(entry, now, force) then
            if force then
                return true
            end
            local at = math.max(entry.at or 0, since or 0)
            newest = math.max(newest or at, at)
            oldest = math.min(oldest or at, at)
        end
    end
    if newest == nil then
        return false
    end
    return (idle and now - newest >= RegisterQueue.DELAY) or now - oldest >= RegisterQueue.MAX_WAIT
end

-- Takes out of the queue the photos to try now: { batch = { entry, ... } (at most MAX_CALL, for one call),
-- singles = { entry, ... } (at most SINGLES, a call each) }. force: held photos are taken too.
function RegisterQueue.takeDue(queue, now, force)
    local taken, keep = { batch = {}, singles = {} }, {}
    for _, entry in ipairs(queue) do
        local list = entry.single and taken.singles or taken.batch
        local limit = entry.single and RegisterQueue.SINGLES or RegisterQueue.MAX_CALL
        if eligible(entry, now, force) and #list < limit then
            entry.held = nil
            list[#list + 1] = entry
        else
            keep[#keep + 1] = entry
        end
    end
    for i = #queue, 1, -1 do
        queue[i] = nil
    end
    for i, entry in ipairs(keep) do
        queue[i] = entry
    end
    return taken
end

-- Sorts the entries of one call by what it returned. result: { created = { photo, ... }, existed = { ... },
-- failed = { ... } } (anything else counts as nothing returned); idOf(photo) -> the photo's catalog id. Returns
-- { existed = { entry, ... }, created = { ... }, failed = { ... }, untried = { ... } } (untried: in no list: the call
-- stopped before them, or the user cancelled).
function RegisterQueue.outcome(entries, result, idOf)
    local byId, sorted, taken = {}, { existed = {}, created = {}, failed = {}, untried = {} }, {}
    for _, entry in ipairs(entries) do
        byId[entry.id] = entry
    end
    result = type(result) == 'table' and result or {}
    for _, kind in ipairs({ 'existed', 'created', 'failed' }) do
        for _, photo in ipairs(type(result[kind]) == 'table' and result[kind] or {}) do
            local id = idOf(photo)
            local entry = id and byId[id]
            if entry and not taken[entry.id] then
                taken[entry.id] = true
                local list = sorted[kind]
                list[#list + 1] = entry
            end
        end
    end
    for _, entry in ipairs(entries) do
        if not taken[entry.id] then
            sorted.untried[#sorted.untried + 1] = entry
        end
    end
    return sorted
end

local function tried(entry)
    entry.tries = (entry.tries or 0) + 1
    entry.single = entry.tries >= RegisterQueue.MAX_BATCH_TRIES or nil
end

-- Puts back what a call did not register (sorted as RegisterQueue.outcome gives it). Returns a word for the log:
-- 'failed' (photos failed; those the call did not reach are tried again at once, in a smaller call), 'held' (photos
-- not reached and none failed: the user cancelled, or the call gave up; tried again at the next fetch in one go or the
-- next start; a call that registered none of them counts as a try, so one that never works ends in calls of their
-- own), or nil (all registered); and the entries given up (failed GIVE_UP times; not put back).
function RegisterQueue.putBack(queue, sorted, now)
    local givenUp = {}
    for _, entry in ipairs(sorted.failed) do
        tried(entry)
        entry.notBefore = now + RegisterQueue.RETRY
        if entry.tries >= RegisterQueue.GIVE_UP then
            givenUp[#givenUp + 1] = entry
        else
            RegisterQueue.add(queue, entry)
        end
    end
    local held = #sorted.failed == 0
    local registered = #sorted.existed + #sorted.created
    for _, entry in ipairs(sorted.untried) do
        if held then
            if registered == 0 then
                tried(entry)
            end
            entry.held = true
        end
        RegisterQueue.add(queue, entry)
    end
    if #sorted.failed > 0 then
        return 'failed', givenUp
    end
    return #sorted.untried > 0 and 'held' or nil, givenUp
end

-- The number of photos of one job (or of all, job nil) in the queue.
function RegisterQueue.count(queue, job)
    local n = 0
    for _, entry in ipairs(queue) do
        if job == nil or entry.job == job then
            n = n + 1
        end
    end
    return n
end

return RegisterQueue
