-- The loop of the automatic fetch: while Lightroom runs and the setting is on, fetch quietly every so often; end as
-- soon as asked to stop or the setting is switched off. Pure Lua 5.1: everything that touches Lightroom is passed
-- in (env), so it runs in unit tests.
--
--   local reason, rounds = AutoFetchLoop.run(env, options)   -- reason: 'stopped' or 'switched off'
--
-- env:
--   shouldStop() -> true when the loop must end (the plug-in is reloaded, disabled, or Lightroom shuts down)
--   settings()   -> enabled (boolean), interval (seconds); read again before every look, so a change in the
--                   Plug-in Manager applies without a restart
--   fetch()      -> a short text for the log; one quiet fetch (it must not raise; the glue protects it)
--   sleep(seconds), now() -> seconds, log(format, ...)
-- options: step (seconds between two looks at the flags, default 1), firstDelay (seconds from the start to the
-- first fetch, default 20).
-- The same text twice in a row is logged once, so a quiet catalog does not fill the log.
local AutoFetchLoop = {}

AutoFetchLoop.DEFAULTS = { step = 1, firstDelay = 20 }

function AutoFetchLoop.run(env, options)
    options = options or {}
    local step = options.step or AutoFetchLoop.DEFAULTS.step
    local nextRun = env.now() + (options.firstDelay or AutoFetchLoop.DEFAULTS.firstDelay)
    local rounds, lastText = 0, nil
    local reason
    env.log('automatic fetch: loop started')
    while true do
        if env.shouldStop() then
            reason = 'stopped'
            break
        end
        local enabled, interval = env.settings()
        if not enabled then
            reason = 'switched off'
            break
        end
        if env.now() >= nextRun then
            rounds = rounds + 1
            local text = tostring(env.fetch())
            if text ~= lastText then
                env.log('automatic fetch: %s', text)
                lastText = text
            end
            nextRun = env.now() + interval
        else
            env.sleep(step)
        end
    end
    env.log('automatic fetch: loop ended (%s) after %d fetch(es)', reason, rounds)
    return reason, rounds
end

return AutoFetchLoop
