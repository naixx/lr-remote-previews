-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local JobTracker = require 'JobTracker'

local function item(ref, state, seq, id)
    return { id = id or tonumber(ref), ref = ref, state = state, seq = seq }
end

local function refsOf(items)
    local refs = {}
    for i, entry in ipairs(items) do
        refs[i] = entry.ref
    end
    return refs
end

describe('JobTracker', function()
    it('returns items the first time they are final and keeps the largest seq', function()
        local tracker = JobTracker.new({ '1', '2', '3' })
        assert.are.same({ '2' }, refsOf(tracker:apply({ item('1', 'queued', 0), item('2', 'ready', 1),
            item('3', 'queued', 0) })))
        assert.are.equal(1, tracker.since)
        assert.are.same({ '1', '3' }, refsOf(tracker:apply({ item('1', 'building', 2), item('1', 'failed', 4),
            item('3', 'ready', 3) })))
        assert.are.equal(4, tracker.since)
        assert.is_true(tracker:isComplete())
        assert.are.same({ ready = 2, failed = 1 }, tracker:counts())
    end)

    it('ignores later copies of a final item and unknown refs', function()
        local tracker = JobTracker.new({ '1', '2' })
        assert.are.equal(1, #tracker:apply({ item('1', 'ready', 5) }))
        assert.are.same({}, tracker:apply({ item('1', 'ready', 5), item('1', 'failed', 6), item('9', 'ready', 7) }))
        assert.are.equal(1, tracker.unknown)
        assert.are.equal(7, tracker.since)
        assert.are.equal(1, tracker.final)
        assert.is_false(tracker:isComplete())
        assert.are.same({ '2' }, tracker:openRefs())
    end)

    it('counts every final state, cancelled included', function()
        local tracker = JobTracker.new({ '1', '2', '3', '4' })
        tracker:apply({ item('1', 'ready', 1), item('2', 'failed', 2), item('3', 'rejected', 3),
            item('4', 'cancelled', 4) })
        assert.is_true(tracker:isComplete())
    end)

    it('treats an empty job as complete and does not move since backwards', function()
        assert.is_true(JobTracker.new({}):isComplete())
        local tracker = JobTracker.new({ '1', '2' })
        tracker:apply({ item('1', 'building', 9) })
        tracker:apply({ item('2', 'queued', 3) })
        assert.are.equal(9, tracker.since)
        assert.are.same({ building = 1, queued = 1 }, tracker:counts())
    end)

    it('counts a ref given twice once', function()
        local tracker = JobTracker.new({ '1', '1' })
        assert.are.equal(1, tracker.total)
    end)
end)
