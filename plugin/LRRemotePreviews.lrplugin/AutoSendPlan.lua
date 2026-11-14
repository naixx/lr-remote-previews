-- The decisions of the automatic send (off by default): which photos are new, and what the plug-in remembers so that
-- no photo is missed and none is sent twice. Pure Lua 5.1: the store (Lightroom's preferences for the plug-in) and
-- everything that comes from the catalog are passed in.
--
-- New photos are told by their catalog id (Adobe_images.id_local, the SDK's photo.localIdentifier), read with sqlite3
-- (CatalogRead). Seen with plug-in 0.8.0 in Lightroom Classic 15.6: an import gets the ids of all its photos at once
-- (one contiguous block), but the rows become visible in the catalog in an order that is NOT ascending by id (several
-- places of the block advance at the same time, burst by burst). 0.8.0 moved its mark to the largest id it had seen and
-- so skipped every photo that became visible later below it: 737 of 1384 photos were never sent. So since 0.8.1:
--   mark     a low-water mark: every photo with an id up to here has been dealt with (or was in the catalog before)
--   handled  the photos above the mark that have been dealt with: sent, or left out for good
--   waiting  photos above the mark that wait, with the number of looks and the time since they first waited: for
--            rows that are not all in the catalog database yet (MAX_TRIES looks and ROWS_SECONDS, then left out), or,
--            while an import record above the mark exists, for their link to the import (seen: it comes a moment after
--            the photo's row; LINK_SECONDS, then sent as photos of no import), so that the photos of one import go into
--            its one job. Time, not only looks, because how often the looks come depends on Lightroom (every 3 s when
--            it lets the plug-in run, every 20-26 s while it imports)
--   newAt    the time (os.time) a look last found a photo it had not seen before (which photos a look has seen is
--            kept in memory only, as known)
-- Every look reads every photo above the mark (1384 rows took 5 ms) and tells new from dealt with by the handled set.
-- The mark moves only when no new photo has come for MARK_QUIET seconds and nothing waits, and never past a photo it
-- can see that has not been dealt with. Kept per catalog (one JSON text in the store under AutoSendPlan.KEY, keyed by
-- the catalog path as CatalogState does it; handled as id ranges), so it survives a restart.
--
-- The first look for a catalog only records the mark: what is in the catalog when the option is switched on is never
-- sent. Switching the option off forgets everything (AutoSendPlan.forget). «Import a folder without the dialog...»,
-- when its checkbox switches the option on, records the mark itself before it starts Lightroom's import
-- (AutoSendPlan.prime with the catalog's largest id), so that the photos of that import are sent however late the
-- first look runs.
local Json = require 'Json'
local PathMap = require 'PathMap'

local AutoSendPlan = {}

AutoSendPlan.KEY = 'autoSendState'
AutoSendPlan.EXTENSIONS_KEY = 'serverExtensions' -- the file types the server took when it was last asked (JSON)
AutoSendPlan.MAX_TRIES = 3 -- looks a photo may wait for its rows (and ROWS_SECONDS) before it is left out for good
AutoSendPlan.ROWS_SECONDS = 60
AutoSendPlan.LINK_SECONDS = 90 -- seconds a photo may wait for its import link while an import is in progress
AutoSendPlan.MARK_QUIET = 300 -- seconds without a new photo before the mark moves

-- Short names of the reasons a photo is left out, for the one log line of a look, in the order listed.
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
    { 'gaveUp', 'no file record in the catalog database after ' .. AutoSendPlan.MAX_TRIES .. ' looks' },
}

local function isId(value)
    return type(value) == 'number' and value >= 0 and value == math.floor(value) and value < 2 ^ 53
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

-- Ids as ranges: { 3, 4, 5, 9 } gives { { 3, 5 }, { 9, 9 } }.
function AutoSendPlan.toRanges(set)
    local ids = {}
    for id in pairs(set) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    local ranges = {}
    for _, id in ipairs(ids) do
        local last = ranges[#ranges]
        if last and id == last[2] + 1 then
            last[2] = id
        else
            ranges[#ranges + 1] = { id, id }
        end
    end
    return ranges
end

-- The set of ids above mark from ranges (malformed ranges are dropped).
function AutoSendPlan.fromRanges(ranges, mark)
    local set = {}
    for _, range in ipairs(type(ranges) == 'table' and ranges or {}) do
        local first, last = type(range) == 'table' and range[1], type(range) == 'table' and range[2]
        if isId(first) and isId(last) and first <= last and last - first < 1000000 then
            for id = math.max(first, mark + 1), last do
                set[id] = true
            end
        end
    end
    return set
end

-- The state of this catalog, or nil when there is none (or it is unreadable). A state of 0.8.0 (no handled set) is
-- taken as it is: its mark stays where 0.8.0 left it.
function AutoSendPlan.load(store, catalogPath)
    local key = PathMap.fileKey(catalogPath)
    local raw = key and loadAll(store)[key]
    if type(raw) ~= 'table' or not isId(raw.mark) then
        return nil
    end
    local waiting = {}
    for id, entry in pairs(type(raw.waiting) == 'table' and raw.waiting or {}) do
        local number = tonumber(id)
        if isId(number) and number > raw.mark and type(entry) == 'table' and isId(entry[1]) and isId(entry[2]) then
            waiting[number] = { tries = entry[1], since = entry[2] }
        end
    end
    return {
        mark = raw.mark,
        seen = isId(raw.seen) and math.max(raw.seen, raw.mark) or raw.mark,
        handled = AutoSendPlan.fromRanges(raw.handled, raw.mark),
        waiting = waiting,
        newAt = isId(raw.newAt) and raw.newAt or nil,
        looked = isId(raw.looked) and raw.looked or nil,
        known = {},
    }
end

-- Stores the state of this catalog; other catalogs' states are kept.
function AutoSendPlan.save(store, catalogPath, state)
    local key = PathMap.fileKey(catalogPath)
    if not key then
        return false
    end
    local all = loadAll(store)
    local waiting
    for id, entry in pairs(state.waiting or {}) do
        waiting = waiting or {}
        waiting[string.format('%d', id)] = { entry.tries, entry.since }
    end
    local handled = AutoSendPlan.toRanges(state.handled or {})
    all[key] = { mark = state.mark, seen = state.seen, handled = #handled > 0 and handled or nil, waiting = waiting,
        newAt = state.newAt, looked = state.looked }
    store[AutoSendPlan.KEY] = Json.encode(all)
    return true
end

-- Forgets the states of all catalogs (the option was switched off).
function AutoSendPlan.forget(store)
    store[AutoSendPlan.KEY] = nil
end

-- The file types the server took when it was last asked ({ '.arw', ... }), or nil when it never was (or the record
-- is unreadable). Lets a look leave out a JPEG-only import without asking the server.
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

-- The state of the first look: everything up to maxId is left alone.
function AutoSendPlan.prime(maxId, now)
    return { mark = maxId, seen = maxId, handled = {}, waiting = {}, looked = now, known = {} }
end

-- What a look does with the photos it read above the mark ({ id, incomplete, importId }, any order). importRunning: an
-- import record above the mark was read. Changes the state's waiting counts and seen, and returns
--   { take = { photo, ... }  (to deal with now, ascending id; a photo whose import link did not come is taken with
--                             importId 0),
--     new = n                (photos not seen by an earlier look of this session),
--     waiting = n            (photos that wait),
--     gaveUp = { id, ... }   (waited too long for their rows: left out for good; call handle() for them) }
function AutoSendPlan.sort(state, photos, importRunning, now)
    local result = { take = {}, new = 0, waiting = 0, gaveUp = {} }
    local sorted = {}
    for _, photo in ipairs(photos) do
        sorted[#sorted + 1] = photo
    end
    table.sort(sorted, function(a, b)
        return a.id < b.id
    end)
    for _, photo in ipairs(sorted) do
        local id = photo.id
        if id > state.mark and not state.handled[id] then
            local entry = state.waiting[id] or { tries = 0, since = now }
            local tries, waited = entry.tries, now - entry.since
            state.known = state.known or {}
            if not state.known[id] then
                state.known[id] = true
                result.new = result.new + 1
            end
            if id > state.seen then
                state.seen = id
            end
            if photo.incomplete then
                if tries + 1 >= AutoSendPlan.MAX_TRIES and waited >= AutoSendPlan.ROWS_SECONDS then
                    result.gaveUp[#result.gaveUp + 1] = id
                    state.waiting[id] = nil
                else
                    state.waiting[id] = { tries = tries + 1, since = entry.since }
                    result.waiting = result.waiting + 1
                end
            elseif (photo.importId or 0) == 0 and importRunning and not photo.virtualCopy
                and waited < AutoSendPlan.LINK_SECONDS then
                state.waiting[id] = { tries = tries + 1, since = entry.since }
                result.waiting = result.waiting + 1
            else
                state.waiting[id] = nil
                result.take[#result.take + 1] = photo
            end
        end
    end
    if result.new > 0 then
        state.newAt = now
    end
    return result
end

-- Marks photos as dealt with (sent, or left out for good).
function AutoSendPlan.handle(state, ids)
    for _, id in ipairs(ids) do
        if id > state.mark then
            state.handled[id] = true
            state.waiting[id] = nil
        end
    end
end

-- Moves the mark when no new photo has come for MARK_QUIET seconds and nothing waits: up to the largest id seen, but
-- never past a photo of this look (visible: { id, ... }) that has not been dealt with. Ids up to the new mark leave the
-- handled set. Returns true when the mark moved.
function AutoSendPlan.advance(state, visible, now)
    if next(state.waiting) ~= nil or (state.newAt ~= nil and now - state.newAt < AutoSendPlan.MARK_QUIET) then
        return false
    end
    local target = state.seen
    for _, id in ipairs(visible) do
        if id > state.mark and not state.handled[id] and id - 1 < target then
            target = id - 1
        end
    end
    if target <= state.mark then
        return false
    end
    state.mark = target
    for id in pairs(state.handled) do
        if id <= target then
            state.handled[id] = nil
        end
    end
    for id in pairs(state.known or {}) do
        if id <= target then
            state.known[id] = nil
        end
    end
    return true
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

-- The jobs of a look: 'job 12 (added 100), job 13 (new, 25)'. jobs: { { id, count, added = bool }, ... }.
local function jobsText(jobs)
    local parts = {}
    for _, job in ipairs(jobs or {}) do
        parts[#parts + 1] = string.format('job %d (%s %d)', job.id, job.added and 'added' or 'new,', job.count)
    end
    return table.concat(parts, ', ')
end

-- The one log line of a look that did something. outcome: { sent = n, jobs = { { id, count, added } },
-- ready = n (built already), rejected = { [code] = n }, leftOut = { [reason] = n }, later = n (wait for their rows),
-- unsent = n (not sent by this look: the server could not be reached or refused; a later look sends them) }.
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
        parts[#parts + 1] = string.format('%d %s file record or import link in the catalog database', outcome.later,
            outcome.later == 1 and 'photo waits for its' or 'photos wait for their')
    end
    if (outcome.unsent or 0) > 0 then
        parts[#parts + 1] = string.format('%d not sent yet: %s', outcome.unsent, tostring(outcome.problem))
    end
    return table.concat(parts, '; ')
end

return AutoSendPlan
