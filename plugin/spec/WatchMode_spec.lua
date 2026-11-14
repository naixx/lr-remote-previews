-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local WatchMode = require 'WatchMode'

describe('WatchMode', function()
    it('looks at the slow interval while nothing happens', function()
        local state = WatchMode.new()
        assert.is_false(WatchMode.fast(state, 100))
        assert.are.equal(160, WatchMode.nextLook(state, 100, 60))
    end)

    it('looks fast after new photos until none came for two minutes', function()
        local state = WatchMode.new()
        WatchMode.found(state, 0, 10)
        assert.is_false(WatchMode.fast(state, 10))
        WatchMode.found(state, 125, 100)
        assert.is_true(WatchMode.fast(state, 100))
        assert.are.equal(103, WatchMode.nextLook(state, 100, 60))
        WatchMode.found(state, 0, 125)
        assert.is_true(WatchMode.fast(state, 219))
        assert.is_false(WatchMode.fast(state, 220))
        assert.are.equal(280, WatchMode.nextLook(state, 220, 60))
    end)

    it('waits fast for the first photo after the trigger, for five minutes at most', function()
        local state = WatchMode.new()
        assert.is_true(WatchMode.triggered(state, 1000, 1001))
        assert.is_true(WatchMode.fast(state, 1001 + 299))
        assert.is_false(WatchMode.fast(state, 1001 + 300))
        assert.is_false(WatchMode.triggered(state, 1000, 1010)) -- the same trigger once
        -- the first photos end the wait; then the two-minute rule
        assert.is_true(WatchMode.triggered(state, 2000, 2000))
        WatchMode.found(state, 50, 2150)
        assert.is_true(WatchMode.fast(state, 2269))
        assert.is_false(WatchMode.fast(state, 2270))
    end)

    it('does not arm for a trigger left from an earlier session', function()
        local state = WatchMode.new()
        assert.is_false(WatchMode.triggered(state, 1000, 1000 + WatchMode.FIRST_PHOTO_SECONDS))
        assert.is_false(WatchMode.fast(state, 1000 + WatchMode.FIRST_PHOTO_SECONDS))
        assert.is_false(WatchMode.triggered(state, nil, 5))
    end)

    it('arms once for each import record not seen before', function()
        local state = WatchMode.new()
        assert.are.equal(1, WatchMode.imports(state, { { id = 106106 } }, 50))
        assert.is_true(WatchMode.fast(state, 60))
        assert.are.equal(0, WatchMode.imports(state, { { id = 106106 } }, 400))
        assert.is_false(WatchMode.fast(state, 400))
        assert.are.equal(1, WatchMode.imports(state, { { id = 106106 }, { id = 200000 } }, 500))
        assert.is_true(WatchMode.fast(state, 500))
        assert.are.equal(0, WatchMode.imports(state, nil, 600))
    end)
end)
