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

    it('arms once for each import record that appears after the first read', function()
        local state = WatchMode.new()
        assert.are.equal(0, WatchMode.imports(state, nil, 10)) -- a failed read: not the first read yet
        assert.are.equal(0, WatchMode.imports(state, {}, 20)) -- the first read
        assert.are.equal(1, WatchMode.imports(state, { { id = 106106 } }, 50)) -- no date needed: it appeared now
        assert.is_true(WatchMode.fast(state, 60))
        assert.are.same({ kind = 'firstPhoto', untilAt = 50 + WatchMode.FIRST_PHOTO_SECONDS },
            WatchMode.waiting(state, 60))
        assert.are.equal(0, WatchMode.imports(state, { { id = 106106 } }, 400))
        assert.is_false(WatchMode.fast(state, 400))
        assert.is_nil(WatchMode.waiting(state, 400))
        assert.are.equal(1, WatchMode.imports(state, { { id = 106106 }, { id = 200000 } }, 500))
        assert.is_true(WatchMode.fast(state, 500))
        assert.are.equal(0, WatchMode.imports(state, nil, 600))
        WatchMode.found(state, 7, 600)
        assert.are.same({ kind = 'photos', untilAt = 600 + WatchMode.QUIET_SECONDS }, WatchMode.waiting(state, 610))
    end)

    it('the session of 0.8.3: a record in the catalog before the start is not an import in progress', function()
        -- Lightroom started at 22:25 on a catalog whose last import began at 21:41:47 (+01:00); the mark of the
        -- automatic send was still below that record, so the first read returned it.
        local record = { id = 219546, date = '2026-11-14T21:41:47.693+01:00' }
        local now = WatchMode.importTime('2026-11-14T22:25:26+01:00')
        local state = WatchMode.new()
        assert.are.equal(0, WatchMode.imports(state, { record }, now))
        assert.is_false(WatchMode.fast(state, now))
        assert.is_nil(WatchMode.waiting(state, now))
        assert.are.equal(0, WatchMode.imports(state, { record }, now + 3)) -- read again: still nothing
        assert.is_false(WatchMode.fast(state, now + 3))
    end)

    it('a record of the first read arms only when its date is recent, a few minutes of clock error allowed', function()
        local began = WatchMode.importTime('2026-11-14T21:41:47.693+01:00')
        local function firstRead(date, now)
            local state = WatchMode.new()
            return WatchMode.imports(state, { { id = 1, date = date } }, now)
        end
        local date = '2026-11-14T21:41:47.693+01:00'
        assert.are.equal(1, firstRead(date, began + 60)) -- the import began a minute before the plug-in started
        assert.are.equal(1, firstRead(date, began - 100)) -- this computer's clock is 100 s behind
        assert.are.equal(1, firstRead(date, began + WatchMode.FIRST_PHOTO_SECONDS + 100)) -- or 100 s ahead
        -- a recent record whose photos are in the catalog already (Lightroom restarted just after an import)
        local withPhotos = WatchMode.new()
        assert.are.equal(0, WatchMode.imports(withPhotos, { { id = 1, date = date, photos = 1384 } }, began + 60))
        assert.are.equal(0, firstRead(date, began + WatchMode.FIRST_PHOTO_SECONDS + WatchMode.CLOCK_SLACK))
        assert.are.equal(0, firstRead(date, began - WatchMode.CLOCK_SLACK)) -- a date in the future: not trusted
        assert.are.equal(0, firstRead('', began))
        assert.are.equal(0, firstRead(nil, began))
        assert.are.equal(0, firstRead('yesterday', began))
    end)

    it('reads an import record\'s date as local time with its offset', function()
        assert.are.equal(1794688907, WatchMode.importTime('2026-11-14T21:41:47.693+01:00'))
        assert.are.equal(1794688907, WatchMode.importTime('2026-11-14T20:41:47Z'))
        assert.are.equal(1794688907, WatchMode.importTime('2026-11-14T15:41:47-0500'))
        assert.are.equal(951782400, WatchMode.importTime('2000-02-29T00:00:00+00:00'))
        assert.is_nil(WatchMode.importTime('2026-11-14 21:41:47'))
        assert.is_nil(WatchMode.importTime('2026-11-14T21:41:47+1'))
    end)
end)
