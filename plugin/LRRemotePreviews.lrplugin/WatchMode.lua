-- How often the automatic send looks for new photos in the catalog: every FAST_SECONDS while an import is coming in,
-- otherwise at the slow interval of the settings. Pure Lua 5.1: the clock is passed in.
--
-- Seen with Lightroom Classic 15.6 (1384 raw files on a NAS): after the import starts, Lightroom prepares for 2 to 3
-- minutes with nothing in the catalog, then commits photos in bursts of about a hundred every 22 to 26 seconds. So:
--   * the import command's trigger, or an import record the plug-in has not seen before, arms the fast mode: look
--     every FAST_SECONDS for up to FIRST_PHOTO_SECONDS until the first photo comes;
--   * every look that finds new photos keeps the fast mode on until no new photo has come for QUIET_SECONDS;
--   * otherwise the slow interval.
-- While the fast mode is on, the plug-in counts an import as in progress (the automatic fetch then places files
-- without calling into the catalog, and Lightroom is asked to register them afterwards).
local WatchMode = {}

WatchMode.FAST_SECONDS = 3
WatchMode.QUIET_SECONDS = 120
WatchMode.FIRST_PHOTO_SECONDS = 300

-- A fresh state: { lastNewAt, armedAt, triggerSeen, imports = { [id] = true } }.
function WatchMode.new()
    return { lastNewAt = nil, armedAt = nil, triggerSeen = nil, imports = {} }
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

-- Import records seen above the mark ({ { id, date }, ... }); arms the fast mode for each one not seen before.
-- Returns the number of new ones.
function WatchMode.imports(state, imports, now)
    local new = 0
    for _, import in ipairs(imports or {}) do
        if type(import.id) == 'number' and not state.imports[import.id] then
            state.imports[import.id] = true
            new = new + 1
        end
    end
    if new > 0 then
        WatchMode.arm(state, now)
    end
    return new
end

-- A look found count new photos.
function WatchMode.found(state, count, now)
    if (count or 0) > 0 then
        state.lastNewAt = now
        state.armedAt = nil
    end
end

-- True while the fast mode is on (an import is taken to be in progress).
function WatchMode.fast(state, now)
    if state.lastNewAt ~= nil and now - state.lastNewAt < WatchMode.QUIET_SECONDS then
        return true
    end
    return state.armedAt ~= nil and now - state.armedAt < WatchMode.FIRST_PHOTO_SECONDS
end

-- The time of the next look: FAST_SECONDS from now in the fast mode, slowInterval otherwise.
function WatchMode.nextLook(state, now, slowInterval)
    if WatchMode.fast(state, now) then
        return now + WatchMode.FAST_SECONDS
    end
    return now + slowInterval
end

return WatchMode
