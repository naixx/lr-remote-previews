-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local AutoFetchLoop = require 'AutoFetchLoop'
local WatchMode = require 'WatchMode'

-- A scripted environment with a clock that only sleep(), send() and fetch() move.
local function fakeEnv(options)
    local env = { clock = 0, fetches = {}, sends = {}, logs = {}, sleeps = 0, importing = {}, sweeps = {} }
    env.fetchOn = options.fetch ~= false
    env.sendOn = options.send == true
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
        if options.settings then
            return options.settings(env)
        end
        return env.fetchOn, env.interval, env.sendOn
    end
    function env.triggered()
        return options.triggerAt and env.clock >= options.triggerAt and options.triggerAt or nil
    end
    function env.fetch(importing, sweepDue)
        env.fetches[#env.fetches + 1] = env.clock
        env.importing[#env.importing + 1] = importing
        if sweepDue then
            env.sweeps[#env.sweeps + 1] = env.clock
        end
        if options.fetchText then
            return options.fetchText(env)
        end
        return 'nothing pending for this catalog; the server is not asked'
    end
    function env.send()
        env.sends[#env.sends + 1] = env.clock
        local found = options.found and options.found(env.clock) or 0
        local imports = options.imports and options.imports(env.clock) or {}
        return options.sendText and options.sendText(#env.sends) or nil, found, imports
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
    it('takes a fetch step every second, a sweep every interval, until asked to stop', function()
        local env = fakeEnv({ stopAt = 200 })
        local reason, looks = AutoFetchLoop.run(env, { step = 1, firstDelay = 20 })
        assert.are.equal('stopped', reason)
        assert.are.equal(0, looks)
        assert.are.equal(200, #env.fetches)
        assert.are.same({ 20, 80, 140 }, env.sweeps)
        assert.are.equal(1, count(env.logs, 'automatic fetch: nothing pending for this catalog'))
        assert.matches('loop ended %(stopped%) after 0 look', env.logs[#env.logs])
    end)

    it('ends at once when both settings are off, and when they are switched off later', function()
        local env = fakeEnv({ fetch = false, stopAt = 1000 })
        local reason, looks = AutoFetchLoop.run(env)
        assert.are.equal('switched off', reason)
        assert.are.equal(0, looks)
        assert.are.equal(0, env.sleeps)
        env = fakeEnv({ settings = function(e)
            return e.clock < 50, 60, false
        end })
        assert.are.equal('switched off', AutoFetchLoop.run(env, { firstDelay = 0 }))
        assert.are.equal(50, #env.fetches)
    end)

    it('looks at the slow interval while nothing new comes, and never fetches while the fetch is off', function()
        local env = fakeEnv({ fetch = false, send = true, stopAt = 200 })
        local reason, looks = AutoFetchLoop.run(env, { firstDelay = 10 })
        assert.are.equal('stopped', reason)
        assert.are.same({ 10, 70, 130, 190 }, env.sends)
        assert.are.equal(4, looks)
        assert.are.same({}, env.fetches)
    end)

    it('looks every few seconds after new photos and back at the interval after two quiet minutes', function()
        local env = fakeEnv({ send = true, stopAt = 400, found = function(clock)
            return (clock == 10 or clock == 31) and 100 or 0
        end })
        AutoFetchLoop.run(env, { firstDelay = 10 })
        -- 10: found -> every 3 s; 31 (by 3-second steps from 10, the 8th look) found again; quiet until 151, then 60 s
        assert.are.equal(10, env.sends[1])
        assert.are.equal(13, env.sends[2])
        assert.are.equal(3, env.sends[3] - env.sends[2])
        local last = env.sends[#env.sends]
        local fastEnd
        for i = 2, #env.sends do
            if env.sends[i] - env.sends[i - 1] > WatchMode.FAST_SECONDS then
                fastEnd = env.sends[i - 1]
                break
            end
        end
        assert.is_true(fastEnd >= 31 + WatchMode.QUIET_SECONDS)
        assert.is_true(fastEnd < 31 + WatchMode.QUIET_SECONDS + 2 * WatchMode.FAST_SECONDS)
        assert.is_true(last > fastEnd)
        assert.are.equal(1, count(env.logs, 'automatic send: looking every 3 s while photos come in'))
        assert.are.equal(1, count(env.logs, 'automatic send: no new photo for 120 s; looking every 60 s again'))
    end)

    it('tells the fetch that an import is in progress while it looks fast', function()
        local env = fakeEnv({ send = true, stopAt = 300, found = function(clock)
            return clock == 0 and 5 or 0
        end })
        AutoFetchLoop.run(env, { firstDelay = 0 })
        assert.is_true(env.importing[1])
        assert.is_true(env.importing[100])
        assert.is_false(env.importing[#env.importing])
    end)

    it('looks at once after the trigger of the import command and keeps looking fast until the first photo', function()
        local env = fakeEnv({ send = true, stopAt = 400, triggerAt = 30, found = function(clock)
            return clock >= 180 and clock < 182 and 100 or 0
        end })
        AutoFetchLoop.run(env, { firstDelay = 20 })
        assert.are.equal(20, env.sends[1])
        assert.are.equal(30, env.sends[2])
        -- every 3 s from 30 up to the photos at 180, and on for two quiet minutes after them
        for i = 3, 52 do
            assert.are.equal(3, env.sends[i] - env.sends[i - 1])
        end
        assert.is_true(env.importing[160])
    end)

    it('arms the fast mode for an import record not seen before, once', function()
        local env = fakeEnv({ send = true, stopAt = 1000, imports = function()
            return { { id = 106106, date = '2026-11-14T15:15:56.060+01:00' } }
        end })
        AutoFetchLoop.run(env, { firstDelay = 0 })
        -- fast for FIRST_PHOTO_SECONDS from the first look, then the slow interval although the record is still read
        assert.are.equal(3, env.sends[2] - env.sends[1])
        local slow = 0
        for i = 2, #env.sends do
            if env.sends[i] - env.sends[i - 1] == 60 then
                slow = slow + 1
            end
        end
        assert.is_true(slow >= 10)
        assert.is_true(env.sends[#env.sends] - env.sends[#env.sends - 1] == 60)
    end)

    it('logs the same text once, and a new text again; a nil text not at all', function()
        local texts = { 'watching', nil, 'not done: no server', 'not done: no server', nil, 'not done: no server',
            'sent 3 new photos: job 7 (new, 3)' }
        local env = fakeEnv({ fetch = false, send = true, stopAt = 420, sendText = function(n)
            return texts[n]
        end })
        AutoFetchLoop.run(env, { firstDelay = 0 })
        assert.are.equal(1, count(env.logs, 'automatic send: watching'))
        assert.are.equal(1, count(env.logs, 'automatic send: not done: no server'))
        assert.are.equal(1, count(env.logs, 'automatic send: sent 3 new photos'))
    end)

    it('takes the next fetch step sooner when the fetch asks for it', function()
        local env = fakeEnv({ stopAt = 10 })
        env.fetch = function()
            env.fetches[#env.fetches + 1] = env.clock
            return nil, env.clock < 2 and 0.25 or (env.clock >= 3 and 5 or nil)
        end
        AutoFetchLoop.run(env, { firstDelay = 0 })
        assert.are.same({ 0, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3 }, { unpack(env.fetches, 1, 10) })
    end)

    it('skips the fetch step when asked to stop during a look', function()
        local stopped = false
        local env = fakeEnv({ send = true, found = function()
            stopped = true
            return 0
        end })
        local oldStop = env.shouldStop
        env.shouldStop = function()
            return stopped or oldStop()
        end
        local reason, looks = AutoFetchLoop.run(env, { firstDelay = 0 })
        assert.are.equal('stopped', reason)
        assert.are.equal(1, looks)
        assert.are.same({}, env.fetches)
    end)
end)
