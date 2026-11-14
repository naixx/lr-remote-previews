-- The decisions of the automatic send (off by default): which photos are new, and what the plug-in remembers so that
-- no photo is sent twice. Pure Lua 5.1: the store (Lightroom's preferences for the plug-in) and everything that comes
-- from the catalog are passed in.
--
-- New photos are told by their catalog id (Adobe_images.id_local, the SDK's photo.localIdentifier), read with sqlite3
-- (CatalogRead). That ids grow with every photo added is NOT documented; the catalog's id counter
-- (Adobe_entityIDCounter) suggests it, and it held in every import seen (Lightroom Classic 15.6). Should it not
-- hold, photos would be missed, never sent twice.
--
-- What is remembered per catalog (one JSON text in the store under AutoSendPlan.KEY, keyed by the catalog path the way
-- CatalogState does it):
--   mark    every photo with an id up to here has been dealt with: sent, left out, or in the catalog before
--   seen    the largest id seen so far
--   blocked, tries   a photo whose rows were not all in the catalog database yet, and in how many rounds in a row
--   looked  the time (os.time) the state last changed
-- The first round for a catalog only records the mark: what is in the catalog when the option is switched on is
-- never sent. Switching the option off forgets everything (AutoSendPlan.forget), so switching it on again starts
-- afresh. «Import a folder without the dialog...» (since version 0.7.0), when its checkbox switches the option on,
-- records the mark itself before it starts Lightroom's import (AutoSendPlan.prime with the catalog's largest id), so
-- that the photos of that import are sent however late the first round runs.
--
-- Since version 0.8.0 a photo is sent in the round that finds it (no waiting for a second round, no limit per round
-- but the server's maxItemsPerJob per job), so an import that arrives in bursts (seen: about a hundred photos every
-- 22-26 seconds) is sent burst by burst.
local Json = require 'Json'
local PathMap = require 'PathMap'

local AutoSendPlan = {}

AutoSendPlan.KEY = 'autoSendState'
AutoSendPlan.EXTENSIONS_KEY = 'serverExtensions' -- the file types the server took when it was last asked (JSON)
AutoSendPlan.MAX_TRIES = 3 -- rounds a photo may wait for its rows before it is left out for good

-- Short names of the reasons a photo is left out, for the one log line of a round, in the order listed.
AutoSendPlan.LEFT_OUT = {
    { 'hasSmartPreview', 'already have a smart preview' },
    { 'video', 'videos' },
    { 'virtualCopy', 'virtual copies' },
    { 'unsupportedFormat', 'file type not taken by the server' },
    { 'noMapping', 'not under a path mapping' },
    { 'rootUnavailable', 'server root not available' },
    { 'noPath', 'no file path' },
    { 'sameFile', 'same file as another photo' },
    { 'fileIdMismatch', 'the catalog database names another file' },
    { 'noFileId', 'no valid file id in the catalog database' },
    { 'gaveUp', 'no file record in the catalog database after ' .. AutoSendPlan.MAX_TRIES .. ' rounds' },
}

local function isId(value)
    return type(value) == 'number' and value >= 0 and value == math.floor(value)
end

local function loadAll(store)
    local text = store[AutoSendPlan.KEY]
    if type(text) ~= 'string' or text == '' then
        return {}
    end
    local ok, decoded = pcall(Json.decode, text)
    if not ok or type(decoded) ~= 'table' then
        return {}
    end
    return decoded
end

-- The state of this catalog, or nil when there is none (or it is unreadable).
function AutoSendPlan.load(store, catalogPath)
    local key = PathMap.fileKey(catalogPath)
    local raw = key and loadAll(store)[key]
    if type(raw) ~= 'table' or not isId(raw.mark) then
        return nil
    end
    return {
        mark = raw.mark,
        seen = isId(raw.seen) and math.max(raw.seen, raw.mark) or raw.mark,
        blocked = isId(raw.blocked) and raw.blocked or nil,
        tries = isId(raw.tries) and raw.tries or nil,
        looked = isId(raw.looked) and raw.looked or nil,
    }
end

-- Stores the state of this catalog; other catalogs' states are kept.
function AutoSendPlan.save(store, catalogPath, state)
    local key = PathMap.fileKey(catalogPath)
    if not key then
        return false
    end
    local all = loadAll(store)
    all[key] = { mark = state.mark, seen = state.seen, blocked = state.blocked, tries = state.tries,
        looked = state.looked }
    store[AutoSendPlan.KEY] = Json.encode(all)
    return true
end

-- Forgets the states of all catalogs (the option was switched off).
function AutoSendPlan.forget(store)
    store[AutoSendPlan.KEY] = nil
end

-- The file types the server took when it was last asked ({ '.arw', ... }), or nil when it never was (or the record
-- is unreadable). Lets a round leave out a JPEG-only import without asking the server.
function AutoSendPlan.knownExtensions(store)
    local text = store[AutoSendPlan.EXTENSIONS_KEY]
    if type(text) ~= 'string' or text == '' then
        return nil
    end
    local ok, decoded = pcall(Json.decode, text)
    if not ok or type(decoded) ~= 'table' or #decoded == 0 then
        return nil
    end
    for _, extension in ipairs(decoded) do
        if type(extension) ~= 'string' then
            return nil
        end
    end
    return decoded
end

-- Remembers the file types the server takes (from its info).
function AutoSendPlan.rememberExtensions(store, extensions)
    if type(extensions) == 'table' and #extensions > 0 then
        store[AutoSendPlan.EXTENSIONS_KEY] = Json.encode(extensions)
    end
end

-- The state of the first round: everything up to maxId is left alone.
function AutoSendPlan.prime(maxId, now)
    return { mark = maxId, seen = maxId, looked = now }
end

-- The state after a round. ids: the ids found this round, ascending; transient: { [id] = true } for photos whose
-- rows were not all in the catalog database yet; seen: the largest id seen. Photos up to the first transient one are
-- dealt with; that one and the ones after it wait for the next round, unless it has waited MAX_TRIES rounds, then it
-- is left out.
-- Returns the new state, the cut-off (ids from here on must not be sent this round; nil = send all) and the list of
-- ids left out for good.
function AutoSendPlan.settle(state, ids, transient, seen, now)
    local new = { mark = state.mark, seen = math.max(seen or state.seen, state.seen), looked = now }
    local cutoff, gaveUp = nil, {}
    for _, id in ipairs(ids) do
        if transient[id] then
            local tries = ((state.blocked == id and state.tries) or 0) + 1
            if tries >= AutoSendPlan.MAX_TRIES then
                gaveUp[#gaveUp + 1] = id
            else
                cutoff = id
                new.blocked, new.tries = id, tries
                break
            end
        end
        if id > new.mark then
            new.mark = id
        end
    end
    return new, cutoff, gaveUp
end

local function plural(n, one, many)
    return n .. ' ' .. (n == 1 and one or many)
end

local function countsText(counts, order)
    local parts = {}
    for _, pair in ipairs(order) do
        local n = counts[pair[1]]
        if n and n > 0 then
            parts[#parts + 1] = pair[2] .. ': ' .. n
        end
    end
    local known = {}
    for _, pair in ipairs(order) do
        known[pair[1]] = true
    end
    local others = {}
    for key, n in pairs(counts) do
        if not known[key] and n > 0 then
            others[#others + 1] = key .. ': ' .. n
        end
    end
    table.sort(others)
    for _, part in ipairs(others) do
        parts[#parts + 1] = part
    end
    return table.concat(parts, ', ')
end

-- The jobs of a round: 'job 12 (added 100), job 13 (new, 25)'. jobs: { { id, count, added = bool }, ... }.
local function jobsText(jobs)
    local parts = {}
    for _, job in ipairs(jobs or {}) do
        parts[#parts + 1] = string.format('job %d (%s %d)', job.id, job.added and 'added' or 'new,', job.count)
    end
    return table.concat(parts, ', ')
end

-- The one log line of a round that did something. outcome: { sent = n, jobs = { { id, count, added } },
-- ready = n (built already), rejected = { [code] = n }, leftOut = { [reason] = n }, later = n (wait for their rows),
-- unsent = n (not sent this round: the server could not be reached or refused; a later round sends them) }.
function AutoSendPlan.roundText(outcome)
    local parts = {}
    local sent = outcome.sent or 0
    if sent > 0 then
        local text = string.format('sent %s: %s', plural(sent, 'new photo', 'new photos'), jobsText(outcome.jobs))
        local details = {}
        if (outcome.ready or 0) > 0 then
            details[#details + 1] = outcome.ready .. ' built already'
        end
        local rejected = 0
        for _, n in pairs(outcome.rejected or {}) do
            rejected = rejected + n
        end
        if rejected > 0 then
            local codes = {}
            for code in pairs(outcome.rejected) do
                codes[#codes + 1] = code
            end
            table.sort(codes)
            for i, code in ipairs(codes) do
                codes[i] = code .. ': ' .. outcome.rejected[code]
            end
            details[#details + 1] = rejected .. ' refused (' .. table.concat(codes, ', ') .. ')'
        end
        if #details > 0 then
            text = text .. ' (' .. table.concat(details, ', ') .. ')'
        end
        parts[#parts + 1] = text
    else
        parts[#parts + 1] = 'sent nothing'
    end
    local leftOut = 0
    for _, n in pairs(outcome.leftOut or {}) do
        leftOut = leftOut + n
    end
    if leftOut > 0 then
        parts[#parts + 1] = string.format('%d left out (%s)', leftOut, countsText(outcome.leftOut,
            AutoSendPlan.LEFT_OUT))
    end
    if (outcome.later or 0) > 0 then
        parts[#parts + 1] = string.format('%d %s for a file record in the catalog database', outcome.later,
            outcome.later == 1 and 'photo waits' or 'photos wait')
    end
    if (outcome.unsent or 0) > 0 then
        parts[#parts + 1] = string.format('%d not sent yet: %s', outcome.unsent, tostring(outcome.problem))
    end
    return table.concat(parts, '; ')
end

return AutoSendPlan
