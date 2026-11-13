-- Jobs and items of the server's API (docs/protocol.md, "Jobs and items"): URLs, the request that creates a
-- job, and checking the job and item objects the server sends. Pure Lua 5.1: no Lightroom imports.
local Json = require 'Json'

local Jobs = {}

Jobs.CLIENT = 'lr-plugin/0.2.0' -- kept equal to VERSION in Info.lua (a spec checks it)
Jobs.LABEL = 'Lightroom selection'
Jobs.PAGE_LIMIT = 500
Jobs.MAX_REF_LENGTH = 64

-- Every item state, and whether it is final.
Jobs.FINAL = { queued = false, building = false, ready = true, failed = true, rejected = true, cancelled = true }

local function integer(value)
    return string.format('%d', value)
end

function Jobs.jobsUrl(base)
    return base .. '/api/v1/jobs'
end

function Jobs.jobUrl(base, jobId)
    return base .. '/api/v1/jobs/' .. integer(jobId)
end

function Jobs.itemsUrl(base, jobId, since, limit)
    return Jobs.jobUrl(base, jobId) .. '/items?since=' .. integer(since or 0) .. '&limit='
        .. integer(limit or Jobs.PAGE_LIMIT)
end

function Jobs.fileUrl(base, itemId)
    return base .. '/api/v1/items/' .. integer(itemId) .. '/file'
end

-- The JSON body of POST /api/v1/jobs. entries: { { ref, rootId, relativePath }, ... } with unique string refs.
-- Returns the body, or nil plus a message.
function Jobs.createBody(entries, client, label)
    if type(entries) ~= 'table' or #entries == 0 then
        return nil, 'a job needs at least one item'
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
    return Json.encode({ client = client or Jobs.CLIENT, label = label or Jobs.LABEL, items = items })
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

-- Checks an item object. Returns
--   { id, ref, state, seq, root, path, error = { code, message } | nil,
--     result = { size, sha256, originalName, originalWidth, originalHeight } | nil }
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
    local item = {
        id = raw.id,
        ref = raw.ref,
        state = raw.state,
        seq = raw.seq,
        root = optional(raw.root, 'string'),
        path = optional(raw.path, 'string'),
    }
    if type(raw.error) == 'table' then
        item.error = { code = optional(raw.error.code, 'string'), message = optional(raw.error.message, 'string') }
    end
    if type(raw.result) == 'table' then
        local result = raw.result
        item.result = {
            size = isCount(result.size) and result.size or nil,
            sha256 = optional(result.sha256, 'string'),
            originalName = optional(result.originalName, 'string'),
            originalWidth = optional(result.originalWidth, 'number'),
            originalHeight = optional(result.originalHeight, 'number'),
        }
    end
    return item
end

-- Checks a job object. Returns { id, state, seq, counts } or nil plus a message.
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
        counts = optional(raw.counts, 'table') or {},
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
