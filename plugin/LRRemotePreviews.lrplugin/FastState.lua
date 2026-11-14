-- What the automatic send, the send command and the automatic fetch share during a Lightroom session, and the server
-- capabilities they remember. Pure Lua 5.1: the store (Lightroom's preferences for the plug-in) is passed in.
--
-- placement: for every photo sent by this session, what is needed to place its smart preview without asking Lightroom
--   for the photo: [job id text][ref] = { id, fileUuid, fileName, width, height, path, seenAt, sentAt }. The ref of
--   every job sent since version 0.8.0 is the photo's catalog id, so after a restart (when this memory is empty) the
--   automatic fetch reads the same facts from the catalog again (CatalogRead.byIdSql).
-- firstSeen: [catalog id] = the clock when a read of the catalog first returned the photo (for the log).
-- stats: JobStats, the times and counts per job for the log.
-- Whether the scripts of the plug-in share this module is not verified; when they do not, the fetch reads the catalog
-- instead (the same facts), so nothing depends on it.
local JobStats = require 'JobStats'
local Json = require 'Json'

local FastState = {
    placement = {},
    firstSeen = {},
    labels = {},
    stats = JobStats.new(),
}

FastState.CAPABILITIES_KEY = 'serverCapabilities'

local function idText(id)
    return string.format('%d', id)
end

-- Remembers what is needed to place the smart preview of one photo of a job.
function FastState.remember(jobId, ref, data)
    local key = idText(jobId)
    FastState.placement[key] = FastState.placement[key] or {}
    FastState.placement[key][ref] = data
end

-- What was remembered for a ref of a job, or nil.
function FastState.placementOf(jobId, ref)
    local job = FastState.placement[idText(jobId)]
    return job and job[ref] or nil
end

-- The label a job was sent with (for the log), when this session sent it.
function FastState.setLabel(jobId, label)
    FastState.labels[idText(jobId)] = label
end

function FastState.label(jobId)
    return FastState.labels[idText(jobId)]
end

-- The file UUIDs of the photos this session sent and whose jobs are still followed (for PreviewWatch), each once.
function FastState.sentUuids()
    local uuids, seen = {}, {}
    for _, refs in pairs(FastState.placement) do
        for _, data in pairs(refs) do
            local uuid = type(data) == 'table' and data.fileUuid
            if type(uuid) == 'string' and not seen[uuid] then
                seen[uuid] = true
                uuids[#uuids + 1] = uuid
            end
        end
    end
    table.sort(uuids)
    return uuids
end

-- Forgets the placement data of a job (its fetch is done).
function FastState.forgetJob(jobId)
    FastState.placement[idText(jobId)] = nil
end

-- Records what the server said it can do (from GET /api/v1/info): { waits = maxWaitSeconds or 0, append = bool,
-- at = now }.
function FastState.saveCapabilities(store, info, now)
    local capabilities = info.capabilities or {}
    store[FastState.CAPABILITIES_KEY] = Json.encode({ waits = capabilities.maxWaitSeconds or 0,
        append = capabilities.appendItems == true, at = now })
end

-- What the server said it can do when last asked: { waits = n | nil, append = bool, at = t }, or nil when never asked
-- (or the record is unreadable).
function FastState.capabilities(store)
    local text = store[FastState.CAPABILITIES_KEY]
    if type(text) ~= 'string' or text == '' then
        return nil
    end
    local ok, decoded = pcall(Json.decode, text)
    if not ok or type(decoded) ~= 'table' or type(decoded.at) ~= 'number' then
        return nil
    end
    local waits = type(decoded.waits) == 'number' and decoded.waits > 0 and decoded.waits or nil
    return { waits = waits, append = decoded.append == true, at = decoded.at }
end

return FastState
