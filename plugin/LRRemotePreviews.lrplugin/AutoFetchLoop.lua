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
--   fetch(importing, sweepDue) -> text (or nil), nextStep; one step of the automatic fetch. importing: an import is
--                   taken to be in progress (WatchMode); sweepDue: the slow interval has passed since the last sweep;
--                   nextStep: seconds to the next step when the fetch wants it sooner than step (files on their way,
--                   waiting requests open), or nil
--   sleep(seconds), now() -> seconds, log(format, ...)
-- options: step (seconds between two steps, default 1), firstDelay (seconds from the start to the first look and the
-- first sweep, default 20).
-- The same text twice in a row is logged once (for each duty); a nil text is not logged at all.
local WatchMode = require 'WatchMode'

local AutoFetchLoop = {}

AutoFetchLoop.DEFAULTS = { step = 1, firstDelay = 20 }

function AutoFetchLoop.run(env, options)
    options = options or {}
    local step = options.step or AutoFetchLoop.DEFAULTS.step
    local start = env.now()
    local nextLook = start + (options.firstDelay or AutoFetchLoop.DEFAULTS.firstDelay)
    local nextSweep = nextLook
    local watch = WatchMode.new()
    local looks, lastText, lastFast = 0, {}, false
    local reason
    local function report(duty, text)
        if text == nil then
            return
        end
        text = tostring(text)
        if text ~= lastText[duty] then
            env.log('automatic %s: %s', duty, text)
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
                local text, found, imports = env.send()
                report('send', text)
                local after = env.now()
                WatchMode.found(watch, found or 0, after)
                WatchMode.imports(watch, imports, after)
                local fast = WatchMode.fast(watch, after)
                if fast and not lastFast then
                    env.log('automatic send: looking every %d s while photos come in', WatchMode.FAST_SECONDS)
                elseif lastFast and not fast then
                    env.log('automatic send: no new photo for %d s; looking every %d s again', WatchMode.QUIET_SECONDS,
                        interval)
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
            text, nextStep = env.fetch(sendEnabled and WatchMode.fast(watch, now2), sweepDue)
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
