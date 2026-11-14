-- When the automatic fetch downloads (since plug-in 0.8.2). Pure Lua 5.1.
--
-- While an import is in progress (WatchMode's fast period: new photos still coming, or an import seen whose first
-- photos are still to come) Lightroom itself reads from the NAS over the same link (the embedded previews: about 2 GB
-- for 1384 photos), so the plug-in only sends (small requests, so that the server builds meanwhile) and downloads
-- nothing. The waiting requests go on: they cost nothing on the link and tell which smart previews are ready. When the
-- import is over, everything ready is fetched in one go (the configured number of downloads at once), then the photos
-- placed in that go are registered with one call; what becomes ready later is fetched as it comes, as before. Jobs
-- while no import is in progress (the send command on a selection) are fetched as they finish.
--
--   local event = FetchGo.step(state, importing, idle, now, ready)
--     'begin'   an import has just been seen: download nothing from now on (downloads already queued are taken back)
--     'hold'    the import is still in progress: download nothing
--     'start'   the import has just been judged over: the fetch in one go begins (state.go; ready: what is ready now)
--     'finish'  the fetch in one go is done (idle: nothing left to download or place); state.last has its totals
--     nil       otherwise (fetch as things become ready)
local FetchGo = {}

function FetchGo.new()
    return { holding = false, go = nil, last = nil }
end

function FetchGo.step(state, importing, idle, now, ready)
    if importing then
        local first = not state.holding
        state.holding = true
        return first and 'begin' or 'hold'
    end
    if state.holding then
        state.holding = false
        state.go = { started = now, ready = ready or 0, placed = 0, left = 0, again = 0, bytes = 0 }
        return 'start'
    end
    if state.go and idle then
        state.last, state.go = state.go, nil
        state.last.finished = now
        return 'finish'
    end
    return nil
end

-- Counts one download of the fetch in one go (when one is running). kind: 'placed', 'left' (given up or not needed),
-- 'again' (to be tried again later); bytes: what was downloaded.
function FetchGo.count(state, kind, bytes)
    local go = state.go
    if not go then
        return
    end
    go[kind] = (go[kind] or 0) + 1
    go.bytes = go.bytes + (bytes or 0)
end

-- '1384 placed, 0 left out, 0 to be tried again later; 482.3 MB in 95.2 s (5.07 MB/s)'.
function FetchGo.totals(go)
    local seconds = (go.finished or go.started) - go.started
    local mb = go.bytes / 1048576
    return string.format('%d placed, %d left out, %d to be tried again later; %.1f MB in %.1f s (%.2f MB/s)',
        go.placed, go.left, go.again, mb, seconds, seconds > 0 and mb / seconds or 0)
end

return FetchGo
