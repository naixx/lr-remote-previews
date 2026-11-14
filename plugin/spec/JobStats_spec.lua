-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local FastState = require 'FastState'
local JobStats = require 'JobStats'

describe('JobStats', function()
    it('writes the totals of a job with median and maximum of each step', function()
        local stats = JobStats.new()
        for _, seconds in ipairs({ 1.5, 2.5, 4 }) do
            JobStats.add(stats, 12, 'sent', seconds)
        end
        JobStats.add(stats, 12, 'sent', nil)
        JobStats.add(stats, 12, 'placed', 0.8)
        JobStats.add(stats, 12, 'placed', 1.2)
        JobStats.add(stats, 12, 'registered', 140)
        JobStats.fail(stats, 12)
        assert.are.equal(4, JobStats.count(stats, 12, 'sent'))
        assert.are.equal('job 12 «Lightroom import X»: 4 sent (first seen in the catalog -> sent: median 2.5 s, max '
            .. '4.0 s), 2 placed (ready -> placed: median 1.0 s, max 1.2 s), 1 registered (ready -> registered: median '
            .. '140 s, max 140 s), 1 failed', JobStats.summary(stats, 12, 'Lightroom import X'))
        assert.are.equal('job 13: 0 sent, 0 placed, 0 registered, 0 failed', JobStats.summary(stats, 13))
        JobStats.forget(stats, 12)
        assert.are.equal(0, JobStats.count(stats, 12, 'sent'))
        assert.is_nil(JobStats.spread({ false }))
        assert.are.equal('?', JobStats.seconds(nil))
        assert.are.equal('14 s', JobStats.seconds(13.6))
    end)
end)

describe('FastState', function()
    it('remembers what is needed to place a smart preview, per job and ref', function()
        FastState.remember(12, '108877', { fileUuid = 'U' })
        assert.are.same({ fileUuid = 'U' }, FastState.placementOf(12, '108877'))
        assert.is_nil(FastState.placementOf(12, '1'))
        FastState.setLabel(12, 'Lightroom import X')
        assert.are.equal('Lightroom import X', FastState.label(12))
        FastState.forgetJob(12)
        assert.is_nil(FastState.placementOf(12, '108877'))
    end)

    it('stores what the server can do', function()
        local store = {}
        assert.is_nil(FastState.capabilities(store))
        FastState.saveCapabilities(store, { capabilities = { maxWaitSeconds = 55, appendItems = true } }, 100)
        assert.are.same({ waits = 55, append = true, at = 100 }, FastState.capabilities(store))
        FastState.saveCapabilities(store, { capabilities = {} }, 200)
        assert.are.same({ append = false, at = 200 }, FastState.capabilities(store))
        assert.is_nil(FastState.capabilities({ [FastState.CAPABILITIES_KEY] = '{oops' }))
    end)
end)
