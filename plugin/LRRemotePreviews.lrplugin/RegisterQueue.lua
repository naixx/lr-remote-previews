-- The smart previews the automatic fetch has placed and Lightroom has not yet been asked to register
-- (photo:buildSmartPreview()). Pure Lua 5.1: the store (Lightroom's preferences for the plug-in) is passed in.
--
-- While an import is in progress (WatchMode), plug-in calls into the catalog are very slow, and the registration needs
-- the photo object; so the automatic fetch only places the file (temporary name, rename, never over an existing file)
-- and puts the photo here. When no import is in progress, the photos are taken out in batches and registered. A
-- placed file that is never registered is harmless: Lightroom takes such a file by itself (seen: listed 94 seconds
-- later while it ran, and at the latest when the catalog is opened again).
--
-- Kept per catalog under RegisterQueue.KEY (one JSON text, keyed by the catalog path as CatalogState does it), so that
-- the photos are still registered after a restart: { { id = <catalog id>, job = <job id>, ready = t, placed = t } }
-- (times as the clock gives them; only used for the log).
local Json = require 'Json'
local PathMap = require 'PathMap'

local RegisterQueue = {}

RegisterQueue.KEY = 'registerQueue'
RegisterQueue.BATCH = 25 -- photos registered in one step of the loop

local function isCount(value)
    return type(value) == 'number' and value >= 0 and value == math.floor(value)
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
                ready = type(entry.ready) == 'number' and entry.ready or nil,
                placed = type(entry.placed) == 'number' and entry.placed or nil }
        end
    end
    return queue
end

-- Stores the queue of this catalog; other catalogs' queues are kept.
function RegisterQueue.save(store, catalogPath, queue)
    local key = PathMap.fileKey(catalogPath)
    if not key then
        return false
    end
    local all = loadAll(store)
    all[key] = #queue > 0 and queue or nil
    store[RegisterQueue.KEY] = Json.encode(all)
    return true
end

-- Adds a placed photo ({ id, job, ready, placed }) unless its id is in the queue already. Returns true when added.
function RegisterQueue.add(queue, entry)
    for _, existing in ipairs(queue) do
        if existing.id == entry.id then
            return false
        end
    end
    queue[#queue + 1] = entry
    return true
end

-- The photos to register now: none while an import is in progress (deferring), else the first max (default BATCH),
-- taken out of the queue.
function RegisterQueue.take(queue, deferring, max)
    local batch = {}
    if deferring then
        return batch
    end
    max = max or RegisterQueue.BATCH
    while #batch < max and #queue > 0 do
        batch[#batch + 1] = table.remove(queue, 1)
    end
    return batch
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
