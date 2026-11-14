-- How often the automatic send looks for new photos in the catalog: every FAST_SECONDS while an import is coming in,
-- otherwise at the slow interval of the settings. Pure Lua 5.1: the clock is passed in.
--
-- Seen with Lightroom Classic 15.6 (1384 raw files on a NAS): after the import starts, Lightroom prepares for 2 to 3
-- minutes with nothing in the catalog, then commits photos in bursts of about a hundred every 22 to 26 seconds. So:
--   * the import command's trigger, or an import record the plug-in has not seen before, arms the fast mode: look
--     every FAST_SECONDS for up to FIRST_PHOTO_SECONDS until the first photo comes. Since 0.8.4 the records the first
--     read of this run of the loop finds were in the catalog before (the mark of the automatic send moves only after
--     five quiet minutes, so the record of an import that ended just before Lightroom was closed still lies above it):
--     such a record arms only when no photo of that read is linked to it yet and its date (local time with offset)
--     is less than FIRST_PHOTO_SECONDS old, with CLOCK_SLACK seconds of tolerance either way; a record that appears in
--     a later read arms whatever its date says.
--     (Seen with 0.8.3: after a restart the old record armed the fast mode, and the fetch of the files left over waited
--     five minutes for an import that was not there.)
--   * every look that finds new photos keeps the fast mode on until no new photo has come for the quiet time
--     (WatchMode.quiet; since 0.8.5 QUIET_SECONDS = 45 s, or QUIET_FACTOR times the longest gap between two looks
--     with new photos in this import, at most QUIET_MAX; it was a fixed 120 s). Measured: bursts 22 to 26 s apart
--     (0.8.0's run), about 30 s apart on average (0.8.4's: 1384 photos sent from 23:39:36 to 23:46:11). The automatic
--     fetch also waits for Lightroom's previews, which keep coming while Lightroom works; an early end costs only some
--     sharing of the link, a late one looked like a hang;
--   * otherwise the slow interval.
-- While the fast mode is on, the plug-in counts an import as in progress (the automatic fetch then places files
-- without calling into the catalog, and Lightroom is asked to register them afterwards).
local WatchMode = {}

WatchMode.FAST_SECONDS = 3
WatchMode.QUIET_SECONDS = 45 -- the quiet time at least
WatchMode.QUIET_FACTOR = 1.5 -- the quiet time is at least this many times the longest gap between bursts
WatchMode.QUIET_MAX = 120
WatchMode.FIRST_PHOTO_SECONDS = 300
WatchMode.CLOCK_SLACK = 120 -- seconds an import record's date may be off from this computer's clock

-- A fresh state: { lastNewAt, armedAt, triggerSeen, imports = { [id] = true }, primed = the first read is done }.
function WatchMode.new()
    return { lastNewAt = nil, armedAt = nil, triggerSeen = nil, imports = {}, primed = false }
end

local function daysFromCivil(y, m, d)
    y = m <= 2 and y - 1 or y
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

-- The time (seconds since 1970, as os.time() gives it) of an import record's date, '2026-11-14T21:41:47.693+01:00'
-- (local time with its offset; 'Z' for UTC); nil when it is not such a date.
function WatchMode.importTime(date)
    local y, mo, d, h, mi, sec, zone = tostring(date or ''):match(
        '^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)[%.%d]*([Zz+%-]?[%d:]*)$')
    if not y then
        return nil
    end
    local offset = 0
    if zone ~= '' and zone ~= 'Z' and zone ~= 'z' then
        local sign, zh, zm = zone:match('^([+%-])(%d%d):?(%d%d)$')
        if not sign then
            return nil
        end
        offset = (tonumber(zh) * 3600 + tonumber(zm) * 60) * (sign == '-' and -1 or 1)
    end
    return daysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60
        + tonumber(sec) - offset
end

-- True when an import record's date says that the import began less than FIRST_PHOTO_SECONDS ago (CLOCK_SLACK either
-- way); false for an older date, a date in the future and anything that is not a date.
function WatchMode.recent(date, now)
    local t = WatchMode.importTime(date)
    return t ~= nil and now - t < WatchMode.FIRST_PHOTO_SECONDS + WatchMode.CLOCK_SLACK
        and t - now < WatchMode.CLOCK_SLACK
end

-- Arms the fast mode: an import has started and its first photos are still to come.
function WatchMode.arm(state, now)
    state.armedAt = now
end

-- The import command's trigger, stored as a time (at); arms the fast mode once per trigger, and only when the trigger
-- is recent (a time left from an earlier session does not). Returns true when it armed.
function WatchMode.triggered(state, at, now)
    if type(at) ~= 'number' or (state.triggerSeen ~= nil and at <= state.triggerSeen) then
        return false
    end
    state.triggerSeen = at
    if now - at >= WatchMode.FIRST_PHOTO_SECONDS then
        return false
    end
    WatchMode.arm(state, now)
    return true
end

-- Import records a read found above the mark ({ { id, date, photos = photos of the read linked to it }, ... }; nil: the
-- read failed); arms the fast mode for each one not seen before, but for the records of the first read of this run
-- only when no photo is linked to them yet and their date is recent. Returns the number of records that armed.
function WatchMode.imports(state, imports, now)
    if imports == nil then
        return 0
    end
    local first, new = not state.primed, 0
    state.primed = true
    for _, import in ipairs(imports) do
        if type(import.id) == 'number' and not state.imports[import.id] then
            state.imports[import.id] = true
            if not first or ((import.photos or 0) == 0 and WatchMode.recent(import.date, now)) then
                new = new + 1
            end
        end
    end
    if new > 0 then
        WatchMode.arm(state, now)
    end
    return new
end

-- A look found count new photos.
-- The quiet time: no new photo for this long ends the fast mode (QUIET_SECONDS, or QUIET_FACTOR times the longest gap
-- between new photos of this import, at most QUIET_MAX).
function WatchMode.quiet(state)
    local adapted = math.ceil(WatchMode.QUIET_FACTOR * (state.longestGap or 0))
    return math.min(WatchMode.QUIET_MAX, math.max(WatchMode.QUIET_SECONDS, adapted))
end

function WatchMode.found(state, count, now)
    if (count or 0) > 0 then
        if state.lastNewAt ~= nil and now - state.lastNewAt < WatchMode.quiet(state) then
            state.longestGap = math.max(state.longestGap or 0, now - state.lastNewAt)
        else
            state.longestGap = nil -- the first photos of an import
        end
        state.lastNewAt = now
        state.armedAt = nil
    end
end

-- True while the fast mode is on (an import is taken to be in progress).
function WatchMode.fast(state, now)
    if state.lastNewAt ~= nil and now - state.lastNewAt < WatchMode.quiet(state) then
        return true
    end
    return state.armedAt ~= nil and now - state.armedAt < WatchMode.FIRST_PHOTO_SECONDS
end

-- What the fast mode waits for, and until when (nil when it is off): { kind = 'photos', untilAt = when it ends if no
-- new photo comes } or { kind = 'firstPhoto', untilAt = when it ends if the first photo does not come }.
function WatchMode.waiting(state, now)
    if state.lastNewAt ~= nil and now - state.lastNewAt < WatchMode.quiet(state) then
        return { kind = 'photos', untilAt = state.lastNewAt + WatchMode.quiet(state) }
    end
    if state.armedAt ~= nil and now - state.armedAt < WatchMode.FIRST_PHOTO_SECONDS then
        return { kind = 'firstPhoto', untilAt = state.armedAt + WatchMode.FIRST_PHOTO_SECONDS }
    end
    return nil
end

-- The time of the next look: FAST_SECONDS from now in the fast mode, slowInterval otherwise.
function WatchMode.nextLook(state, now, slowInterval)
    if WatchMode.fast(state, now) then
        return now + WatchMode.FAST_SECONDS
    end
    return now + slowInterval
end

return WatchMode
