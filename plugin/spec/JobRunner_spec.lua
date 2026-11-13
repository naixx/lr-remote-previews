-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local JobRunner = require 'JobRunner'
local JobTracker = require 'JobTracker'

local function item(ref, state, seq)
    return { id = tonumber(ref), ref = ref, state = state, seq = seq }
end

local function page(items, jobState, more)
    return { job = { id = 7, state = jobState or 'active' }, items = items, more = more == true }
end

-- A scripted environment: pages[i] answers the i-th poll ({ problem = ... } for a failed poll).
-- cancel: a function(env) that says when the user has cancelled.
local function fakeEnv(pages, cancel)
    local env = { handled = {}, polls = {}, sleeps = {}, cancelCalls = 0, logs = {}, slept = 0 }
    function env.fetchItems(since)
        env.polls[#env.polls + 1] = since
        env.sleeps[#env.polls] = env.slept
        env.slept = 0
        local answer = assert(pages[#env.polls], 'no page scripted for poll ' .. #env.polls)
        if answer.problem then
            return nil, answer.problem
        end
        return answer
    end
    function env.handle(handled)
        env.handled[#env.handled + 1] = handled.ref .. ':' .. handled.state
    end
    function env.isCanceled()
        return cancel ~= nil and cancel(env)
    end
    function env.sleep(seconds)
        env.slept = env.slept + seconds
    end
    function env.cancelJob()
        env.cancelCalls = env.cancelCalls + 1
        return true
    end
    function env.progress() end
    function env.log(...)
        env.logs[#env.logs + 1] = string.format(...)
    end
    return env
end

describe('JobRunner.nextDelay', function()
    it('starts again at the minimum after a change and grows up to the maximum otherwise', function()
        assert.are.equal(1, JobRunner.nextDelay(4, true))
        assert.are.equal(1.5, JobRunner.nextDelay(1, false))
        assert.are.equal(1, JobRunner.nextDelay(0, false))
        assert.are.equal(5, JobRunner.nextDelay(4, false))
        assert.are.equal(5, JobRunner.nextDelay(5, false))
    end)
end)

describe('JobRunner.run', function()
    it('handles the items of the POST answer, then polls with the largest seq until all are final', function()
        local env = fakeEnv({
            page({ item('2', 'building', 4) }),
            page({ item('2', 'ready', 5), item('3', 'failed', 6) }, 'done'),
        })
        local tracker = JobTracker.new({ '1', '2', '3' })
        local result = JobRunner.run(env, tracker, { item('1', 'ready', 1), item('2', 'queued', 2),
            item('3', 'queued', 3) })
        assert.are.same({ completed = true }, result)
        assert.are.same({ '1:ready', '2:ready', '3:failed' }, env.handled)
        assert.are.same({ 3, 4 }, env.polls)
        assert.are.same({ 1, 1 }, env.sleeps)
        assert.are.equal(0, env.cancelCalls)
    end)

    it('does not poll when everything was final at once', function()
        local env = fakeEnv({})
        local result = JobRunner.run(env, JobTracker.new({ '1' }), { item('1', 'rejected', 1) })
        assert.is_true(result.completed)
        assert.are.same({}, env.polls)
    end)

    it('asks again at once when the server has more, and backs off when nothing changes', function()
        local env = fakeEnv({
            page({ item('1', 'ready', 1) }, 'active', true),
            page({}),
            page({}),
            page({}),
            page({}),
            page({}),
            page({ item('2', 'ready', 2) }, 'done'),
        })
        JobRunner.run(env, JobTracker.new({ '1', '2' }), {})
        assert.are.same({ 1, 0, 1, 1.5, 2.25, 3.5, 5 }, env.sleeps)
    end)

    it('cancels the job on the server when the user cancels while waiting', function()
        local env = fakeEnv({ page({ item('1', 'ready', 1) }), page({}) }, function(e)
            return #e.polls >= 2
        end)
        local result = JobRunner.run(env, JobTracker.new({ '1', '2' }), {})
        assert.is_true(result.cancelled)
        assert.is_nil(result.cancelProblem)
        assert.are.equal(1, env.cancelCalls)
        assert.are.same({ '1:ready' }, env.handled)
    end)

    it('stops handling items as soon as the user cancels', function()
        local env = fakeEnv({ page({ item('1', 'ready', 1), item('2', 'ready', 2) }) }, function(e)
            return #e.handled >= 1
        end)
        local result = JobRunner.run(env, JobTracker.new({ '1', '2' }), {})
        assert.is_true(result.cancelled)
        assert.are.same({ '1:ready' }, env.handled)
        assert.are.equal(1, env.cancelCalls)
    end)

    it('reports a failed cancel', function()
        local env = fakeEnv({}, function()
            return true
        end)
        env.cancelJob = function()
            return nil, { message = 'HTTP 500' }
        end
        local result = JobRunner.run(env, JobTracker.new({ '1' }), {})
        assert.are.equal('HTTP 500', result.cancelProblem.message)
    end)

    it('rides out failed polls and gives up after too many in a row', function()
        local failure = { problem = { message = 'Cannot reach the server.' } }
        local env = fakeEnv({ failure, page({ item('1', 'ready', 1) }, 'done') })
        assert.is_true(JobRunner.run(env, JobTracker.new({ '1' }), {}).completed)

        local always = fakeEnv({ failure, failure, failure })
        local result = JobRunner.run(always, JobTracker.new({ '1' }), {}, { maxFailures = 3 })
        assert.are.equal('Cannot reach the server.', result.aborted)
        assert.are.equal(3, #always.polls)
        assert.are.equal(0, always.cancelCalls)
    end)

    it('gives up at once on a fatal problem', function()
        local env = fakeEnv({ { problem = { message = 'token rejected', fatal = true } } })
        local result = JobRunner.run(env, JobTracker.new({ '1' }), {})
        assert.are.equal('token rejected', result.aborted)
        assert.are.equal(1, #env.polls)
    end)

    it('gives up when the job is finished but items never arrive', function()
        local env = fakeEnv({ page({}, 'done'), page({}, 'done'), page({}, 'done') })
        local result = JobRunner.run(env, JobTracker.new({ '1' }), {})
        assert.matches('never reached a final state', result.aborted)
        assert.are.equal(3, #env.polls)
    end)
end)
