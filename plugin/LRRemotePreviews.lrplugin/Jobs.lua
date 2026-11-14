-- Jobs, items and lookups of the server's API (docs/protocol.md, "Jobs and items" and "Asking for files without a
-- job"): URLs, the request bodies, and checking the job, item and lookup objects the server sends. Pure Lua 5.1:
-- no Lightroom imports.
local Json = require 'Json'

local Jobs = {}

Jobs.CLIENT = 'lr-plugin/0.4.0' -- kept equal to VERSION in Info.lua (a spec checks it)
Jobs.LABEL = 'Lightroom selection'
Jobs.PAGE_LIMIT = 500 -- items per page while polling one job
Jobs.READ_LIMIT = 1000 -- items per page when reading the ready items of a job (the protocol's maximum)
Jobs.LIST_LIMIT = 200 -- jobs per list (the protocol's maximum)
Jobs.MAX_REF_LENGTH = 64
Jobs.MAX_CLIENT_ID_LENGTH = 64

-- Every item state, and whether it is final.
Jobs.FINAL = { queued = false, building = false, ready = true, failed = true, rejected = true, cancelled = true }

-- The states of a lookup answer.
Jobs.LOOKUP_STATES = { ready = true, pending = true, absent = true, rejected = true }

local function integer(value)
    return string.format('%d', value)
end

-- Percent-encodes everything except the unreserved characters of RFC 3986.
function Jobs.urlEncode(text)
    return (tostring(text):gsub('[^%w%-%._~]', function(char)
        return string.format('%%%02X', string.byte(char))
    end))
end

function Jobs.jobsUrl(base)
    return base .. '/api/v1/jobs'
end

-- GET /api/v1/jobs for one clientId, newest first.
function Jobs.listUrl(base, clientId, limit)
    return Jobs.jobsUrl(base) .. '?clientId=' .. Jobs.urlEncode(clientId) .. '&limit='
        .. integer(limit or Jobs.LIST_LIMIT)
end

function Jobs.jobUrl(base, jobId)
    return base .. '/api/v1/jobs/' .. integer(jobId)
end

-- GET /api/v1/jobs/{id}/items; state (optional) asks for items in that one state only.
function Jobs.itemsUrl(base, jobId, since, limit, state)
    local url = Jobs.jobUrl(base, jobId) .. '/items?since=' .. integer(since or 0) .. '&limit='
        .. integer(limit or Jobs.PAGE_LIMIT)
    if state then
        url = url .. '&state=' .. Jobs.urlEncode(state)
    end
    return url
end

function Jobs.retryUrl(base, jobId)
    return Jobs.jobUrl(base, jobId) .. '/retry'
end

function Jobs.fileUrl(base, itemId)
    return base .. '/api/v1/items/' .. integer(itemId) .. '/file'
end

function Jobs.lookupUrl(base)
    return base .. '/api/v1/lookup'
end

-- True for a cache key as the protocol defines it: 64 lower-case hexadecimal characters.
function Jobs.isCacheKey(key)
    return type(key) == 'string' and #key == 64 and key:find('^[0-9a-f]+$') ~= nil
end

-- GET /api/v1/files/{key}; or nil plus a message for a key that is not one.
function Jobs.fileByKeyUrl(base, key)
    if not Jobs.isCacheKey(key) then
        return nil, 'not a cache key: ' .. tostring(key)
    end
    return base .. '/api/v1/files/' .. key
end

-- Checks a list of { ref, rootId, relativePath } and returns the items of a request, or nil plus a message.
local function requestItems(entries)
    if type(entries) ~= 'table' or #entries == 0 then
        return nil, 'a request needs at least one item'
    end
    local items, refs = {}, {}
    for i, entry in ipairs(entries) do
        local ref = entry.ref
        if type(ref) ~= 'string' or ref == '' or #ref > Jobs.MAX_REF_LENGTH then
            return nil, 'item ' .. i .. ' has no valid ref'
        end
        if refs[ref] then
            return nil, 'ref ' .. ref .. ' is used twice'
        end
        if type(entry.rootId) ~= 'string' or type(entry.relativePath) ~= 'string' then
            return nil, 'item ' .. i .. ' has no root or path'
        end
        refs[ref] = true
        items[i] = { ref = ref, root = entry.rootId, path = entry.relativePath }
    end
    return items
end

-- The JSON body of POST /api/v1/jobs. entries: { { ref, rootId, relativePath }, ... } with unique string refs.
-- options (optional): { client, label, clientId }; client and label default to Jobs.CLIENT and Jobs.LABEL,
-- clientId is left out when not given. Returns the body, or nil plus a message.
function Jobs.createBody(entries, options)
    options = options or {}
    local items, err = requestItems(entries)
    if not items then
        return nil, err
    end
    local clientId = options.clientId
    if clientId ~= nil and (type(clientId) ~= 'string' or clientId == '' or #clientId > Jobs.MAX_CLIENT_ID_LENGTH) then
        return nil, 'not a valid client id: ' .. tostring(clientId)
    end
    return Json.encode({ client = options.client or Jobs.CLIENT, label = options.label or Jobs.LABEL,
        clientId = clientId, items = items })
end

-- The JSON body of POST /api/v1/lookup; entries as for Jobs.createBody. Returns the body, or nil plus a message.
function Jobs.lookupBody(entries)
    local items, err = requestItems(entries)
    if not items then
        return nil, err
    end
    return Json.encode({ items = items })
end

-- Checking ---------------------------------------------------------------------------------------------------

local function isCount(value)
    return type(value) == 'number' and value >= 0 and value == math.floor(value)
end

local function optional(value, expected)
    if type(value) == expected then
        return value
    end
    return nil
end

local function normalizeError(raw)
    if type(raw) ~= 'table' then
        return nil
    end
    return { code = optional(raw.code, 'string'), message = optional(raw.message, 'string') }
end

local function normalizeResult(raw)
    if type(raw) ~= 'table' then
        return nil
    end
    return {
        key = optional(raw.key, 'string'),
        size = isCount(raw.size) and raw.size or nil,
        sha256 = optional(raw.sha256, 'string'),
        originalName = optional(raw.originalName, 'string'),
        originalWidth = optional(raw.originalWidth, 'number'),
        originalHeight = optional(raw.originalHeight, 'number'),
    }
end

-- Checks an item object. Returns
--   { id, ref, state, seq, root, path, error = { code, message } | nil,
--     result = { key, size, sha256, originalName, originalWidth, originalHeight } | nil }
-- (fields of error and result are nil when absent or of the wrong type), or nil plus a message.
function Jobs.normalizeItem(raw)
    if type(raw) ~= 'table' or raw[1] ~= nil then
        return nil, 'an item is not an object'
    end
    if not isCount(raw.id) or raw.id == 0 then
        return nil, 'an item has no valid "id"'
    end
    local name = 'item ' .. integer(raw.id)
    if type(raw.ref) ~= 'string' then
        return nil, name .. ' has no "ref"'
    end
    if type(raw.state) ~= 'string' or Jobs.FINAL[raw.state] == nil then
        return nil, name .. ' has an unknown state ' .. tostring(raw.state)
    end
    if not isCount(raw.seq) then
        return nil, name .. ' has no valid "seq"'
    end
    return {
        id = raw.id,
        ref = raw.ref,
        state = raw.state,
        seq = raw.seq,
        root = optional(raw.root, 'string'),
        path = optional(raw.path, 'string'),
        error = normalizeError(raw.error),
        result = normalizeResult(raw.result),
    }
end

-- The counts of a job object with every state present (0 when missing or not a count).
local function normalizeCounts(raw)
    local counts = {}
    raw = type(raw) == 'table' and raw or {}
    for _, key in ipairs({ 'total', 'queued', 'building', 'ready', 'failed', 'rejected', 'cancelled' }) do
        counts[key] = isCount(raw[key]) and raw[key] or 0
    end
    return counts
end

-- Checks a job object. Returns { id, state, seq, counts, label, client, clientId, created, finished } (the last
-- five nil when absent) or nil plus a message. counts has every state of the contract, 0 when missing.
function Jobs.normalizeJob(raw)
    if type(raw) ~= 'table' or raw[1] ~= nil then
        return nil, 'the job is not an object'
    end
    if not isCount(raw.id) or raw.id == 0 then
        return nil, 'the job has no valid "id"'
    end
    if type(raw.state) ~= 'string' then
        return nil, 'the job has no "state"'
    end
    return {
        id = raw.id,
        state = raw.state,
        seq = isCount(raw.seq) and raw.seq or nil,
        counts = normalizeCounts(raw.counts),
        label = optional(raw.label, 'string'),
        client = optional(raw.client, 'string'),
        clientId = optional(raw.clientId, 'string'),
        created = optional(raw.created, 'string'),
        finished = optional(raw.finished, 'string'),
    }
end

local function normalizeItems(list)
    if type(list) ~= 'table' then
        return nil, '"items" is not a list'
    end
    local items = {}
    for i, raw in ipairs(list) do
        local item, err = Jobs.normalizeItem(raw)
        if not item then
            return nil, err
        end
        items[i] = item
    end
    return items
end

-- The 201 answer of POST /api/v1/jobs: { job, items }, or nil plus a message.
function Jobs.parseCreated(decoded)
    local job, jobError = Jobs.normalizeJob(type(decoded) == 'table' and decoded.job)
    if not job then
        return nil, jobError
    end
    local items, itemsError = normalizeItems(decoded.items)
    if not items then
        return nil, itemsError
    end
    return { job = job, items = items }
end

-- The 200 answer of GET /api/v1/jobs/{id}/items: { job, items, more }, or nil plus a message.
function Jobs.parseItemsPage(decoded)
    local created, err = Jobs.parseCreated(decoded)
    if not created then
        return nil, err
    end
    created.more = decoded.more == true
    return created
end

-- The 200 answer of GET /api/v1/jobs/{id} or POST /api/v1/jobs/{id}/retry: the job, or nil plus a message.
function Jobs.parseJobAnswer(decoded)
    return Jobs.normalizeJob(type(decoded) == 'table' and decoded.job)
end

-- The 200 answer of GET /api/v1/jobs: a list of jobs (newest first, as the server sent them), or nil plus a
-- message.
function Jobs.parseJobList(decoded)
    if type(decoded) ~= 'table' or type(decoded.jobs) ~= 'table' then
        return nil, 'the answer has no "jobs" list'
    end
    local jobs = {}
    for i, raw in ipairs(decoded.jobs) do
        local job, err = Jobs.normalizeJob(raw)
        if not job then
            return nil, err
        end
        jobs[i] = job
    end
    return jobs
end

-- The 200 answer of POST /api/v1/lookup for the requested entries ({ ref, ... }). Returns a table keyed by ref:
-- { ref, state, error = { code, message } | nil, result = { key, size, ... } | nil }, or nil plus a message when
-- the answer does not have exactly one valid entry per requested ref.
function Jobs.parseLookup(decoded, entries)
    if type(decoded) ~= 'table' or type(decoded.items) ~= 'table' then
        return nil, 'the answer has no "items" list'
    end
    local wanted = {}
    for _, entry in ipairs(entries) do
        wanted[entry.ref] = true
    end
    local byRef, count = {}, 0
    for i, raw in ipairs(decoded.items) do
        if type(raw) ~= 'table' or type(raw.ref) ~= 'string' then
            return nil, 'lookup entry ' .. i .. ' has no "ref"'
        end
        if not wanted[raw.ref] then
            return nil, 'the server answered ref "' .. raw.ref .. '" that was not asked for'
        end
        if byRef[raw.ref] then
            return nil, 'the server answered ref "' .. raw.ref .. '" twice'
        end
        if type(raw.state) ~= 'string' or not Jobs.LOOKUP_STATES[raw.state] then
            return nil, 'lookup entry ' .. raw.ref .. ' has an unknown state ' .. tostring(raw.state)
        end
        byRef[raw.ref] = { ref = raw.ref, state = raw.state, error = normalizeError(raw.error),
            result = normalizeResult(raw.result) }
        count = count + 1
    end
    if count ~= #entries then
        return nil, string.format('the server answered %d entries for %d asked for', count, #entries)
    end
    return byRef
end

-- Checks that the server answered every requested ref exactly once. Returns true, or nil plus a message.
function Jobs.checkRefs(items, entries)
    local wanted, seen = {}, {}
    for _, entry in ipairs(entries) do
        wanted[entry.ref] = true
    end
    for _, item in ipairs(items) do
        if not wanted[item.ref] then
            return nil, 'the server answered an item with ref "' .. item.ref .. '" that was not requested'
        end
        if seen[item.ref] then
            return nil, 'the server answered ref "' .. item.ref .. '" twice'
        end
        seen[item.ref] = true
    end
    if #items ~= #entries then
        return nil, string.format('the server answered %d items for %d requested', #items, #entries)
    end
    return true
end

-- The message for a failed POST /api/v1/jobs. problem: from HttpJson ({ kind, message, status, code }).
function Jobs.createProblemText(problem, maxItems)
    if problem.code == 'converter_not_installed' then
        return 'The server cannot build smart previews: Adobe DNG Converter is not installed there. ' .. problem.message
    end
    if problem.status == 413 then
        return 'The server takes at most ' .. tostring(maxItems or '?') .. ' photos per job. Select fewer photos. '
            .. problem.message
    end
    return 'The server did not accept the job. ' .. problem.message
end

return Jobs
