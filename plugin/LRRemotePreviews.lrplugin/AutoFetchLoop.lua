-- The loop of the automatic send and the automatic fetch: while Lightroom runs and at least one of the two settings is
-- on, look for new photos every so often (WatchMode: every few seconds while an import comes in, otherwise at the
-- interval of the settings) and keep the fetch going (a short step every STEP seconds); end as soon as asked to stop
-- or both settings are switched off. Pure Lua 5.1: everything that touches Lightroom is passed in (env), so it runs in
-- unit tests.
--
--   local reason, looks = AutoFetchLoop.run(env, options)   -- reason: 'stopped' or 'switched off'
--
-- env:
--   shouldStop() -> true when the loop must end (the plug-in is reloaded, disabled, or Lightroom shuts down)
--   settings()   -> fetchEnabled (boolean), interval (seconds), sendEnabled (boolean); read again every step, so a
--                   change in the Plug-in Manager applies without a restart
--   triggered()  -> the time (os.time) «Import a folder without the dialog...» last started an import, or nil
--   send()       -> text (or nil: nothing to log), found (new photos found), imports (import records read above the
--                   mark: { { id, date } }); one look of the automatic send (only called when sendEnabled)
--   fetch(importing, sweepDue, waiting) -> text (or nil), nextStep; one step of the automatic fetch. importing: an
--                   import is taken to be in progress (WatchMode); waiting: what the fast mode waits for and until
--                   when (WatchMode.waiting); sweepDue: the slow interval has passed since the last sweep;
--                   nextStep: seconds to the next step when the fetch wants it sooner than step (files on their way,
--                   waiting requests open), or nil
--   sleep(seconds), now() -> seconds, log(format, ...)
-- options: step (seconds between two steps, default 1), firstDelay (seconds from the start to the first look and the
-- first sweep, default 20).
-- The same text twice in a row is logged once (for each duty); a nil text is not logged at all. A send line carries the
-- time since the previous look, and the end of a fast period says how often the looks really came: seen with plug-in
-- 0.8.0, while Lightroom imports plug-in tasks run only between its bursts, about every 20-26 s, not every 3 s.
local WatchMode = require 'WatchMode'

local AutoFetchLoop = {}

AutoFetchLoop.DEFAULTS = { step = 1, firstDelay = 20 }
AutoFetchLoop.STALL_SECONDS = 600 -- a loop that has not taken a step for this long is taken as hanging

-- True when the loop's last step (heartbeat, a time) is more than limit (default STALL_SECONDS) seconds before now: a
-- call that never returns (an LrTasks.execute of sqlite3 that Lightroom does not run, seen once while Lightroom was
-- busy removing 1384 photos) holds the loop for good, and a new loop has to be started.
function AutoFetchLoop.stalled(heartbeat, now, limit)
    return type(heartbeat) == 'number' and now - heartbeat > (limit or AutoFetchLoop.STALL_SECONDS)
end

-- 'every 21 s on average, the longest gap 26 s' for the gaps between looks, or '' for none.
function AutoFetchLoop.gapsText(gaps)
    if #gaps == 0 then
        return ''
    end
    local total, longest = 0, 0
    for _, gap in ipairs(gaps) do
        total = total + gap
        longest = math.max(longest, gap)
    end
    return string.format('every %.0f s on average, the longest gap %.0f s', total / #gaps, longest)
end

function AutoFetchLoop.run(env, options)
    options = options or {}
    local step = options.step or AutoFetchLoop.DEFAULTS.step
    local start = env.now()
    local nextLook = start + (options.firstDelay or AutoFetchLoop.DEFAULTS.firstDelay)
    local nextSweep = nextLook
    local watch = WatchMode.new()
    local looks, lastText, lastFast = 0, {}, false
    local lastLookAt, fastGaps = nil, {}
    local reason
    local function report(duty, text, suffix)
        if text == nil then
            return
        end
        text = tostring(text)
        if text ~= lastText[duty] then
            env.log('automatic %s: %s%s', duty, text, suffix or '')
            lastText[duty] = text
        end
    end
    env.log('automatic fetch: loop started')
    while true do
        if env.shouldStop() then
            reason = 'stopped'
            break
        end
        local fetchEnabled, interval, sendEnabled = env.settings()
        if not fetchEnabled and not sendEnabled then
            reason = 'switched off'
            break
        end
        local now = env.now()
        if sendEnabled then
            if env.triggered and WatchMode.triggered(watch, env.triggered(), now) then
                nextLook = now
            end
            if now >= nextLook then
                looks = looks + 1
                local gap = lastLookAt and (now - lastLookAt) or nil
                lastLookAt = now
                if lastFast and gap then
                    fastGaps[#fastGaps + 1] = gap
                end
                local text, found, imports = env.send()
                report('send', text, gap and string.format(' (%.0f s after the previous look)', gap) or nil)
                local after = env.now()
                WatchMode.found(watch, found or 0, after)
                WatchMode.imports(watch, imports, after)
                local fast = WatchMode.fast(watch, after)
                if fast and not lastFast then
                    env.log('automatic send: looking every %d s while photos come in', WatchMode.FAST_SECONDS)
                    fastGaps = {}
                elseif lastFast and not fast then
                    env.log('automatic send: no new photo for %d s; looking every %d s again (%d looks while photos '
                        .. 'came in, %s)', WatchMode.quiet(watch), interval, #fastGaps + 1,
                        AutoFetchLoop.gapsText(fastGaps))
                end
                lastFast = fast
                nextLook = WatchMode.nextLook(watch, after, interval)
            end
        end
        local nextStep
        if fetchEnabled and not env.shouldStop() then
            local now2 = env.now()
            local sweepDue = now2 >= nextSweep
            local text
            local importing = sendEnabled and WatchMode.fast(watch, now2)
            text, nextStep = env.fetch(importing, sweepDue, importing and WatchMode.waiting(watch, now2) or nil)
            report('fetch', text)
            if sweepDue then
                nextSweep = env.now() + interval
            end
        end
        env.sleep(type(nextStep) == 'number' and math.min(nextStep, step) or step)
    end
    env.log('automatic fetch: loop ended (%s) after %d look(s)', reason, looks)
    return reason, looks
end

return AutoFetchLoop
