-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local WaitPlan = require 'WaitPlan'

local function page(state, items, more)
    return { job = { state = state, seq = 900 }, items = items or {}, more = more == true }
end

describe('WaitPlan wait and timeout', function()
    it('asks a server that can wait for at most 25 s and gives LrHttp more time than that', function()
        assert.are.equal(25, WaitPlan.wait(55))
        assert.are.equal(10, WaitPlan.wait(10))
        assert.are.equal(55, WaitPlan.timeout(25))
        assert.are.equal(WaitPlan.PLAIN_TIMEOUT, WaitPlan.timeout(nil))
    end)

    it('does not wait against a server without maxWaitSeconds', function()
        assert.is_nil(WaitPlan.wait(nil))
        assert.is_nil(WaitPlan.wait(0))
    end)

    it('halves the wait after LrHttp ran out of time, down to five seconds', function()
        assert.are.equal(12, WaitPlan.wait(55, 1))
        assert.are.equal(6, WaitPlan.wait(55, 2))
        assert.are.equal(5, WaitPlan.wait(55, 3))
        assert.are.equal(5, WaitPlan.wait(55, 9))
        assert.are.equal(2, WaitPlan.wait(2, 3))
    end)
end)

describe('WaitPlan answers', function()
    it('takes the ready items and the largest seq', function()
        local answer = WaitPlan.answer(page('active', { { seq = 701, state = 'ready' }, { seq = 705, state = 'ready' },
            { seq = 703, state = 'failed' } }), 700)
        assert.are.equal(705, answer.since)
        assert.are.equal(2, #answer.ready)
        assert.is_true(answer.active)
        assert.is_true(answer.drained)
    end)

    it('treats an answer with no items after the wait as normal: ask again at once', function()
        local answer = WaitPlan.answer(page('active', {}), 705)
        assert.are.equal(705, answer.since)
        assert.are.equal(0, #answer.ready)
        assert.are.equal(0, WaitPlan.pause(answer, true, 60, 25.1))
        assert.is_false(WaitPlan.done(answer, 0))
    end)

    it('pauses a little after an empty answer that came at once (a server shutting down), never loops', function()
        local answer = WaitPlan.answer(page('active', {}), 705)
        assert.are.equal(WaitPlan.EARLY_PAUSE, WaitPlan.pause(answer, true, 60, 0.05))
        local some = WaitPlan.answer(page('active', { { seq = 706, state = 'ready' } }), 705)
        assert.are.equal(0, WaitPlan.pause(some, true, 60, 0.05))
    end)

    it('learns from job.state that a job finished without a ready item', function()
        local answer = WaitPlan.answer(page('done', {}), 705)
        assert.is_false(answer.active)
        assert.is_true(WaitPlan.done(answer, 0))
    end)

    it('asks at once while there is more, and at the interval when the server cannot wait', function()
        local more = WaitPlan.answer(page('active', { { seq = 1, state = 'ready' } }, true), 0)
        assert.is_false(more.drained)
        assert.are.equal(0, WaitPlan.pause(more, false, 60))
        local nothing = WaitPlan.answer(page('active', {}), 1)
        assert.are.equal(60, WaitPlan.pause(nothing, false, 60))
        local some = WaitPlan.answer(page('active', { { seq = 2, state = 'ready' } }), 1)
        assert.are.equal(0, WaitPlan.pause(some, false, 60))
    end)

    it('counts a job as done when it is not active, nothing more is to be read and nothing is open', function()
        local finished = WaitPlan.answer(page('done', {}), 900)
        assert.is_true(WaitPlan.done(finished, 0))
        assert.is_false(WaitPlan.done(finished, 2))
        assert.is_true(WaitPlan.done(WaitPlan.answer(page('cancelled', {}), 900), 0))
        assert.is_false(WaitPlan.done(WaitPlan.answer(page('done', {}, true), 900), 0))
        assert.is_false(WaitPlan.done(nil, 0))
    end)
end)

describe('WaitPlan failures', function()
    it('tells a job that is gone, a wait cut short on this side, and everything else', function()
        assert.are.equal('gone', WaitPlan.failure({ status = 404 }, 25))
        assert.are.equal('shorten', WaitPlan.failure({ kind = 'unreachable', timedOut = true }, 25))
        assert.are.equal('failed', WaitPlan.failure({ kind = 'unreachable', timedOut = true }, nil))
        assert.are.equal('failed', WaitPlan.failure({ kind = 'unreachable' }, 25))
        assert.are.equal('failed', WaitPlan.failure({ kind = 'unauthorized', status = 401 }, 25))
        assert.are.equal('failed', WaitPlan.failure({ kind = 'http', status = 500 }, 25))
        assert.are.equal('failed', WaitPlan.failure(nil, 25))
    end)
end)
