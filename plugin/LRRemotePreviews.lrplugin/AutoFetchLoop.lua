-- The loop of the automatic fetch and the automatic send: while Lightroom runs and at least one of the two settings
-- is on, do a round every so often (send new photos first, when that is on, then fetch quietly, when that is on);
-- end as soon as asked to stop or both settings are switched off. Pure Lua 5.1: everything that touches Lightroom is
-- passed in (env), so it runs in unit tests.
--
--   local reason, rounds = AutoFetchLoop.run(env, options)   -- reason: 'stopped' or 'switched off'
--
-- env:
--   shouldStop() -> true when the loop must end (the plug-in is reloaded, disabled, or Lightroom shuts down)
--   settings()   -> fetchEnabled (boolean), interval (seconds), sendEnabled (boolean); read again before every
--                   look, so a change in the Plug-in Manager applies without a restart
--   fetch()      -> a short text for the log; one quiet fetch (it must not raise; the glue protects it)
--   send()       -> a short text for the log, or nil when the round did nothing; one round of the automatic send
--                   (only called when sendEnabled)
--   sleep(seconds), now() -> seconds, log(format, ...)
-- options: step (seconds between two looks at the flags, default 1), firstDelay (seconds from the start to the
-- first round, default 20).
-- The same text twice in a row is logged once (for each duty), so a quiet catalog does not fill the log; a nil text
-- is not logged at all.
local AutoFetchLoop = {}

AutoFetchLoop.DEFAULTS = { step = 1, firstDelay = 20 }

function AutoFetchLoop.run(env, options)
    options = options or {}
    local step = options.step or AutoFetchLoop.DEFAULTS.step
    local nextRun = env.now() + (options.firstDelay or AutoFetchLoop.DEFAULTS.firstDelay)
    local rounds, lastText = 0, {}
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
        if env.now() >= nextRun then
            rounds = rounds + 1
            if sendEnabled then
                report('send', env.send())
            end
            if fetchEnabled and not (sendEnabled and env.shouldStop()) then
                report('fetch', env.fetch())
            end
            nextRun = env.now() + interval
        else
            env.sleep(step)
        end
    end
    env.log('automatic fetch: loop ended (%s) after %d round(s)', reason, rounds)
    return reason, rounds
end

return AutoFetchLoop
