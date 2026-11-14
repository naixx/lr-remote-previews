-- The decisions of the automatic send (off by default): which photos are new, when they are sent, and what the
-- plug-in remembers so that no photo is sent twice. Pure Lua 5.1: the store (Lightroom's preferences for the plug-in)
-- and everything that comes from Lightroom are passed in.
--
-- New photos are told by their catalog id, photo.localIdentifier. The SDK documents it as "the local identifier of
-- the photo, unique within this catalog" (SDK 4.0). That it grows with every photo added is NOT documented; the
-- catalog's id counter (Adobe_entityIDCounter) suggests it, and it has to be confirmed in Lightroom. Should it not
-- hold, photos would be missed, never sent twice.
--
-- What is remembered per catalog (one JSON text in the store under AutoSendPlan.KEY, keyed by the catalog path the way
-- CatalogState does it):
--   mark    every photo with an id up to here has been dealt with: sent, left out, or in the catalog before
--   seen    the largest id seen so far. A photo is taken only in a round after the one that first saw it, so that an
--           import in progress has settled and the catalog database has its file record
--   blocked, tries   a photo whose file record could not be read yet, and in how many rounds in a row
--   looked  the time (os.time) the state last changed; the fallback finder looks back from there
-- The first round for a catalog only records the mark: what is in the catalog when the option is switched on is
-- never sent. Switching the option off forgets everything (AutoSendPlan.forget), so switching it on again starts
-- afresh.
--
-- Photos that «Import a folder without the dialog...» (version 0.6.0; 0.5.0's «Add a folder without previews...»
-- before it) sends itself are left out by the automatic send, so that no photo is sent twice when both are on. While
-- that command waits for Lightroom's import and sends, it holds the fetch lock, so no round of the automatic send can
-- send anything; right before it sends, it records the photos' catalog ids under AutoSendPlan.SENT_KEY
-- (AutoSendPlan.recordSent), and the rounds after it skip them. That record has one writer, the command; it drops the
-- ids the automatic send can no longer take (at or below its mark), and, when the catalog has no state (the automatic
-- send is off or has not had its first round, whose mark will cover every photo there is), the ids of earlier runs.
local Json = require 'Json'
local PathMap = require 'PathMap'

local AutoSendPlan = {}

AutoSendPlan.KEY = 'autoSendState'
AutoSendPlan.SENT_KEY = 'addedAndSent'
AutoSendPlan.MAX_SENT = 50000 -- catalog ids kept per catalog in that record, at most (the largest are kept)
AutoSendPlan.LIMIT = 500 -- photos looked at per round, at most (and at most the server's maxItemsPerJob)
AutoSendPlan.MAX_TRIES = 3 -- rounds a photo may wait for its file record before it is left out for good
AutoSendPlan.YIELD_EVERY = 500 -- photos between two yields while scanning the catalog
AutoSendPlan.MAX_WINDOW_HOURS = 24 * 31

-- Reasons from FileIds.assign that may go away by themselves (the catalog database had not written the photo yet).
AutoSendPlan.TRANSIENT = { noFileId = true, noLocalId = true }

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
    { 'gaveUp', 'no file record in the catalog database after ' .. AutoSendPlan.MAX_TRIES .. ' rounds' },
    { 'sentByCommand', 'imported and sent by «Import a folder without the dialog»' },
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

-- Forgets the states of all catalogs (the option was switched off), and the photos «Import a folder without the
-- dialog...» sent: when the option is switched on again, its first round's mark covers all of them.
function AutoSendPlan.forget(store)
    store[AutoSendPlan.KEY] = nil
    store[AutoSendPlan.SENT_KEY] = nil
end

local function loadSent(store)
    local text = store[AutoSendPlan.SENT_KEY]
    if type(text) ~= 'string' or text == '' then
        return {}
    end
    local ok, decoded = pcall(Json.decode, text)
    if not ok or type(decoded) ~= 'table' then
        return {}
    end
    return decoded
end

-- Records the catalog ids of photos that «Import a folder without the dialog...» is going to send, so that the
-- automatic send leaves them out. run: a text naming the command's run. Ids the automatic send can no longer take are
-- dropped (see the header). Must be called with no wait between reading and writing (Lightroom switches tasks only
-- where one waits). Returns the number of ids kept for the catalog, or false for a missing catalog path.
function AutoSendPlan.recordSent(store, catalogPath, ids, run)
    local key = PathMap.fileKey(catalogPath)
    if not key then
        return false
    end
    local all = loadSent(store)
    local entry = type(all[key]) == 'table' and all[key] or {}
    local state = AutoSendPlan.load(store, catalogPath)
    local keep, kept = {}, {}
    local function add(id)
        if isId(id) and id > 0 and not kept[id] and (not state or id > state.mark) then
            kept[id] = true
            keep[#keep + 1] = id
        end
    end
    if state or entry.run == run then
        for _, id in ipairs(type(entry.ids) == 'table' and entry.ids or {}) do
            add(id)
        end
    end
    for _, id in ipairs(ids) do
        add(id)
    end
    table.sort(keep)
    if #keep > AutoSendPlan.MAX_SENT then
        local largest = {}
        for i = #keep - AutoSendPlan.MAX_SENT + 1, #keep do
            largest[#largest + 1] = keep[i]
        end
        keep = largest
    end
    all[key] = #keep > 0 and { run = run, ids = keep } or nil
    store[AutoSendPlan.SENT_KEY] = Json.encode(all)
    return #keep
end

-- The catalog ids «Import a folder without the dialog...» recorded for this catalog: { [id] = true }.
function AutoSendPlan.sentByCommand(store, catalogPath)
    local key = PathMap.fileKey(catalogPath)
    local entry = key and loadSent(store)[key]
    local ids = {}
    if type(entry) == 'table' and type(entry.ids) == 'table' then
        for _, id in ipairs(entry.ids) do
            if isId(id) then
                ids[id] = true
            end
        end
    end
    return ids
end

-- The state of the first round: everything up to maxId is left alone.
function AutoSendPlan.prime(maxId, now)
    return { mark = maxId, seen = maxId, looked = now }
end

-- Goes through photos and keeps those with an id above mark. idOf(photo) -> the id (or nil when the photo has none);
-- it may raise, the caller protects the call. env (optional): yield() called every YIELD_EVERY photos, then
-- shouldStop() -> true to give up. Returns the photos found as { id, photo } in ascending id order, the largest id
-- (0 for none) and the number of photos looked at; or nil plus 'stopped'.
function AutoSendPlan.scan(photos, idOf, mark, env)
    env = env or {}
    local found, maxId = {}, 0
    for i, photo in ipairs(photos) do
        local id = idOf(photo)
        if isId(id) and id > 0 then
            if id > maxId then
                maxId = id
            end
            if mark == nil or id > mark then
                found[#found + 1] = { id = id, photo = photo }
            end
        end
        if i % AutoSendPlan.YIELD_EVERY == 0 then
            if env.yield then
                env.yield()
            end
            if env.shouldStop and env.shouldStop() then
                return nil, 'stopped'
            end
        end
    end
    table.sort(found, function(a, b)
        return a.id < b.id
    end)
    return found, maxId, #photos
end

-- Which of the photos found (above the mark, ascending) are taken this round: those already seen in an earlier
-- round, at most limit of them. Returns { photos = { { id, photo }, ... }, seen = the new largest id seen,
-- waiting = the number seen for the first time now, more = true when the limit left some for the next round }.
function AutoSendPlan.pick(state, found, limit)
    local picked = { photos = {}, seen = state.seen, waiting = 0, more = false }
    for _, entry in ipairs(found) do
        if entry.id > state.mark then
            if entry.id <= state.seen then
                if #picked.photos < limit then
                    picked.photos[#picked.photos + 1] = entry
                else
                    picked.more = true
                end
            else
                picked.waiting = picked.waiting + 1
            end
            if entry.id > picked.seen then
                picked.seen = entry.id
            end
        end
    end
    return picked
end

-- Keeps the first limit photos of a pick (the server takes fewer per job than AutoSendPlan.LIMIT).
function AutoSendPlan.limit(picked, limit)
    if not limit or #picked.photos <= limit then
        return picked
    end
    local photos = {}
    for i = 1, limit do
        photos[i] = picked.photos[i]
    end
    return { photos = photos, seen = picked.seen, waiting = picked.waiting, more = true }
end

-- The state after a round. ids: the ids taken this round, ascending; transient: { [id] = true } for photos whose
-- file record could not be read yet; seen: picked.seen. Photos up to the first transient one are dealt with; that one
-- and the ones after it wait for the next round, unless it has waited MAX_TRIES rounds, then it is left out.
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

-- Hours the fallback finder looks back: from the last change of the state, plus one, within 1 .. MAX_WINDOW_HOURS.
function AutoSendPlan.windowHours(state, now)
    if not state or not isId(state.looked) or not now then
        return 24
    end
    local hours = math.ceil((now - state.looked) / 3600) + 1
    return math.max(1, math.min(AutoSendPlan.MAX_WINDOW_HOURS, hours))
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

-- The one log line of a round that did something. outcome: { sent = n, jobId = n, ready = n (built already),
-- rejected = { [code] = n }, leftOut = { [reason] = n }, later = n (wait for the next round), more = bool,
-- waiting = n (seen for the first time) }.
function AutoSendPlan.roundText(outcome)
    local parts = {}
    local sent = outcome.sent or 0
    if sent > 0 then
        local text = string.format('sent %s as job %s', plural(sent, 'new photo', 'new photos'),
            tostring(outcome.jobId))
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
    if outcome.more then
        parts[#parts + 1] = 'more next round'
    end
    if (outcome.waiting or 0) > 0 then
        parts[#parts + 1] = plural(outcome.waiting, 'photo', 'photos') .. ' just added, taken next round'
    end
    return table.concat(parts, '; ')
end

return AutoSendPlan
