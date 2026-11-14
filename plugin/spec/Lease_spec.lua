-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local Lease = require 'Lease'

describe('Lease', function()
    it('lets one owner at a time hold the lock', function()
        local store = {}
        assert.is_true(Lease.acquire(store, 'run-a', 'a manual fetch', 1000))
        local ok, holder = Lease.acquire(store, 'run-b', 'the automatic fetch', 1010)
        assert.is_false(ok)
        assert.are.equal('run-a', holder.owner)
        assert.are.equal('a manual fetch', holder.label)
        assert.are.equal(1000 + Lease.TTL, holder.expires)
        assert.is_true(Lease.acquire(store, 'run-a', 'a manual fetch', 1020)) -- the holder may take it again
        Lease.release(store, 'run-a')
        assert.is_nil(store[Lease.KEY])
        assert.is_true(Lease.acquire(store, 'run-b', 'the automatic fetch', 1030))
    end)

    it('frees a lock that was not refreshed in time', function()
        local store = {}
        Lease.acquire(store, 'run-a', 'a manual fetch', 1000)
        assert.is_false((Lease.acquire(store, 'run-b', 'x', 1000 + Lease.TTL - 1)))
        assert.is_true(Lease.acquire(store, 'run-b', 'x', 1000 + Lease.TTL))
        assert.is_false(Lease.refresh(store, 'run-a', 1000 + Lease.TTL + 1)) -- run-a learns it lost the lock
        Lease.release(store, 'run-a') -- and releasing does not take it from run-b
        assert.are.equal('run-b', Lease.read(store).owner)
    end)

    it('refreshes, writing the store only once the lock has aged', function()
        local store = {}
        Lease.acquire(store, 'run-a', 'label', 1000)
        local first = store[Lease.KEY]
        assert.is_true(Lease.refresh(store, 'run-a', 1000 + Lease.REFRESH_AFTER - 1))
        assert.are.equal(first, store[Lease.KEY])
        assert.is_true(Lease.refresh(store, 'run-a', 1000 + Lease.REFRESH_AFTER))
        assert.are.equal(1000 + Lease.REFRESH_AFTER + Lease.TTL, Lease.read(store).expires)
        assert.are.equal('label', Lease.read(store).label)
        assert.is_true(Lease.refresh(store, 'run-a', 1000 + Lease.TTL + 10)) -- kept alive past the first expiry
        assert.is_false((Lease.acquire(store, 'run-b', 'x', 1000 + Lease.TTL + 11)))
    end)

    it('takes a lock that claims to last longer than a lock can as stale (the clock was set back)', function()
        local store = {}
        Lease.acquire(store, 'run-a', 'label', 5000)
        assert.is_false((Lease.acquire(store, 'run-b', 'x', 5000)))
        assert.is_true(Lease.acquire(store, 'run-b', 'x', 5000 - 3600)) -- one hour back
        store[Lease.KEY] = 'run-c|9999999999|damaged'
        assert.is_true(Lease.acquire(store, 'run-b', 'x', 5000))
    end)

    it('treats an unreadable value as free and reports nothing to refresh', function()
        local store = { [Lease.KEY] = 'garbage' }
        assert.is_nil(Lease.read(store))
        assert.is_false(Lease.refresh(store, 'run-a', 1))
        assert.is_true(Lease.acquire(store, 'run-a', 'a|label|with bars', 1))
        assert.are.equal('a|label|with bars', Lease.read(store).label)
    end)

    it('words the message for a command that found the lock taken', function()
        local text = Lease.busyText({ owner = 'x', expires = 1000 + 150, label = 'the automatic fetch' }, 1000)
        assert.matches('already being fetched by the automatic fetch', text, 1, true)
        assert.matches('within 3 minutes', text, 1, true)
        assert.matches('within 1 minute%.', Lease.busyText({ expires = 1010, label = '' }, 1000))
        assert.matches('another task of this plug-in', Lease.busyText({ expires = 1010, label = '' }, 1000), 1, true)
    end)
end)
