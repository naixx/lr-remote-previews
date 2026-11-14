-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local AutoFetchLoop = require 'AutoFetchLoop'

-- A scripted environment with a clock that only sleep() and fetch() move.
local function fakeEnv(options)
    local env = { clock = 0, fetches = {}, logs = {}, settingsCalls = 0, sleeps = 0 }
    env.enabled = options.enabled ~= false
    env.interval = options.interval or 60
    function env.now()
        return env.clock
    end
    function env.sleep(seconds)
        env.sleeps = env.sleeps + 1
        env.clock = env.clock + seconds
    end
    function env.shouldStop()
        return options.stopAt ~= nil and env.clock >= options.stopAt
    end
    function env.settings()
        env.settingsCalls = env.settingsCalls + 1
        if options.settings then
            return options.settings(env)
        end
        return env.enabled, env.interval
    end
    function env.fetch()
        env.fetches[#env.fetches + 1] = env.clock
        env.clock = env.clock + (options.fetchTakes or 0)
        return options.text and options.text(#env.fetches) or 'nothing new to fetch'
    end
    function env.log(...)
        env.logs[#env.logs + 1] = string.format(...)
    end
    return env
end

local function count(list, pattern)
    local n = 0
    for _, line in ipairs(list) do
        if line:find(pattern, 1, true) then
            n = n + 1
        end
    end
    return n
end

describe('AutoFetchLoop', function()
    it('waits, then fetches every interval until asked to stop', function()
        local env = fakeEnv({ stopAt = 200 })
        local reason, rounds = AutoFetchLoop.run(env, { step = 1, firstDelay = 20 })
        assert.are.equal('stopped', reason)
        assert.are.equal(3, rounds)
        assert.are.same({ 20, 80, 140 }, env.fetches)
        assert.are.equal(200, env.clock)
    end)

    it('logs the same text once, and a new text again', function()
        local texts = { 'nothing new to fetch', 'nothing new to fetch', '3 placed', 'nothing new to fetch' }
        local env = fakeEnv({ stopAt = 300, text = function(n)
            return texts[n] or 'nothing new to fetch'
        end })
        AutoFetchLoop.run(env, { firstDelay = 0 })
        assert.are.equal(2, count(env.logs, 'automatic fetch: nothing new to fetch'))
        assert.are.equal(1, count(env.logs, 'automatic fetch: 3 placed'))
        assert.matches('loop ended %(stopped%) after 5 fetch', env.logs[#env.logs])
    end)

    it('ends at once when the setting is off, without fetching', function()
        local env = fakeEnv({ enabled = false, stopAt = 1000 })
        local reason, rounds = AutoFetchLoop.run(env)
        assert.are.equal('switched off', reason)
        assert.are.equal(0, rounds)
        assert.are.same({}, env.fetches)
        assert.are.equal(0, env.sleeps)
    end)

    it('ends when the setting is switched off later, and follows a new interval', function()
        local env = fakeEnv({ settings = function(e)
            if e.clock >= 250 then
                return false, 60
            end
            return true, e.clock >= 100 and 30 or 60
        end })
        local reason = AutoFetchLoop.run(env, { firstDelay = 10 })
        assert.are.equal('switched off', reason)
        assert.are.same({ 10, 70, 130, 160, 190, 220 }, env.fetches)
    end)

    it('does not start the next fetch before the interval after the last one ended', function()
        local env = fakeEnv({ stopAt = 400, fetchTakes = 50 })
        AutoFetchLoop.run(env, { firstDelay = 0 })
        assert.are.same({ 0, 110, 220, 330 }, env.fetches)
    end)

    it('stops before the first fetch when asked during the wait', function()
        local env = fakeEnv({ stopAt = 5 })
        local reason, rounds = AutoFetchLoop.run(env, { firstDelay = 20 })
        assert.are.equal('stopped', reason)
        assert.are.equal(0, rounds)
        assert.are.equal(5, env.clock)
    end)
end)
