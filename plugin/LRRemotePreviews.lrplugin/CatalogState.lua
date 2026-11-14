-- What the plug-in remembers per catalog, in a key-value store (Lightroom's preferences for the plug-in): the
-- catalog's clientId, and for each job of that catalog on the server how far fetching got. Both are kept as JSON
-- text, one key each (text values are what versions 0.1.0 and 0.2.0 already stored there successfully), keyed by
-- the catalog's path as PathMap.fileKey spells it (the two slash kinds and the letter case of a Windows path give
-- the same key). Pure Lua 5.1: the store is passed in.
--
-- A job record is { since = <seq>, doneSeq = <seq> | nil } (see FetchPlan): every ready item of the job with a seq
-- up to since has been dealt with; doneSeq is the job's seq at the time nothing was left to fetch from it.
local Json = require 'Json'
local PathMap = require 'PathMap'

local CatalogState = {}

CatalogState.CLIENT_IDS_KEY = 'clientIds'
CatalogState.JOBS_KEY = 'fetchProgress'

-- The key of a catalog, or nil for a missing path.
function CatalogState.catalogKey(catalogPath)
    return PathMap.fileKey(catalogPath)
end

-- The decoded table under a key; an empty table when the key is empty or does not hold a JSON object.
local function load(store, key)
    local text = store[key]
    if type(text) ~= 'string' or text == '' then
        return {}
    end
    local ok, decoded = pcall(Json.decode, text)
    if not ok or type(decoded) ~= 'table' then
        return {}
    end
    return decoded
end

local function save(store, key, value)
    store[key] = Json.encode(value)
end

-- The clientId of this catalog, or nil when it has none yet.
function CatalogState.clientId(store, catalogPath)
    local key = CatalogState.catalogKey(catalogPath)
    local id = key and load(store, CatalogState.CLIENT_IDS_KEY)[key]
    if type(id) == 'string' and id ~= '' then
        return id
    end
    return nil
end

-- The clientId of this catalog; makes one up with generate() and stores it when there is none. Returns the id
-- and whether it is new, or nil plus a message for a missing catalog path.
function CatalogState.ensureClientId(store, catalogPath, generate)
    local key = CatalogState.catalogKey(catalogPath)
    if not key then
        return nil, 'the catalog has no path'
    end
    local ids = load(store, CatalogState.CLIENT_IDS_KEY)
    if type(ids[key]) == 'string' and ids[key] ~= '' then
        return ids[key], false
    end
    ids[key] = generate()
    save(store, CatalogState.CLIENT_IDS_KEY, ids)
    return ids[key], true
end

local function isCount(value)
    return type(value) == 'number' and value >= 0 and value == math.floor(value)
end

-- The job records of this catalog: { [job id as text] = { since, doneSeq } }. Malformed records are dropped.
function CatalogState.jobs(store, catalogPath)
    local key = CatalogState.catalogKey(catalogPath)
    local all = key and load(store, CatalogState.JOBS_KEY)[key]
    local jobs = {}
    if type(all) ~= 'table' then
        return jobs
    end
    for id, record in pairs(all) do
        if type(id) == 'string' and id:match('^%d+$') and type(record) == 'table' and isCount(record.since) then
            jobs[id] = { since = record.since, doneSeq = isCount(record.doneSeq) and record.doneSeq or nil }
        end
    end
    return jobs
end

local function sameRecords(a, b)
    for id, record in pairs(a) do
        local other = b[id]
        if not other or other.since ~= record.since or other.doneSeq ~= record.doneSeq then
            return false
        end
    end
    for id in pairs(b) do
        if not a[id] then
            return false
        end
    end
    return true
end

-- Replaces the job records of this catalog (records as CatalogState.jobs returns them). Other catalogs' records
-- are kept. Nothing is written when the records did not change. Returns true when it wrote.
function CatalogState.saveJobs(store, catalogPath, jobs)
    local key = CatalogState.catalogKey(catalogPath)
    if not key or sameRecords(jobs, CatalogState.jobs(store, catalogPath)) then
        return false
    end
    local all = load(store, CatalogState.JOBS_KEY)
    local copy, count = {}, 0
    for id, record in pairs(jobs) do
        copy[id] = { since = record.since, doneSeq = record.doneSeq }
        count = count + 1
    end
    all[key] = count > 0 and copy or nil
    save(store, CatalogState.JOBS_KEY, all)
    return true
end

return CatalogState
