-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local RegisterQueue = require 'RegisterQueue'

local CATALOG = 'C:\\Photos\\Main\\Main.lrcat'

local function filled(n, at)
    local queue = {}
    for id = 1, n do
        RegisterQueue.add(queue, { id = id, job = id <= n / 2 and 12 or 13, ready = id, placed = id + 1, at = at })
    end
    return queue
end

local function ids(entries)
    local list = {}
    for i, entry in ipairs(entries) do
        list[i] = entry.id
    end
    return list
end

-- A photo object as catalog:buildSmartPreviews would return it.
local function photo(id)
    return { localIdentifier = id }
end

local function idOf(p)
    return p.localIdentifier
end

describe('RegisterQueue', function()
    it('keeps an id once and counts per job', function()
        local queue = filled(60, 1000)
        assert.is_false(RegisterQueue.add(queue, { id = 5, job = 12 }))
        assert.are.equal(60, RegisterQueue.count(queue))
        assert.are.equal(30, RegisterQueue.count(queue, 12))
        assert.are.equal(30, RegisterQueue.count(queue, 13))
    end)

    it('registers the photos of a fetch in one go with one call, all of them', function()
        local queue = filled(1384, 1000)
        assert.is_true(RegisterQueue.due(queue, 1001, true, false)) -- force: right after the fetch in one go
        local taken = RegisterQueue.takeDue(queue, 1001, true)
        assert.are.equal(1384, #taken.batch)
        assert.are.equal(0, #taken.singles)
        assert.are.equal(0, #queue)
        local big = filled(RegisterQueue.MAX_CALL + 10, 1000)
        assert.are.equal(RegisterQueue.MAX_CALL, #RegisterQueue.takeDue(big, 1001, true).batch)
        assert.are.equal(10, #big)
    end)

    it('outside a fetch in one go: waits until nothing comes for DELAY seconds, or MAX_WAIT at most', function()
        local queue = filled(3, 1000)
        RegisterQueue.add(queue, { id = 4, at = 1020 })
        assert.is_false(RegisterQueue.due(queue, 1030, false, true)) -- the newest is 10 s old
        assert.is_false(RegisterQueue.due(queue, 1060, false, false)) -- quiet long enough, but downloads on their way
        assert.is_true(RegisterQueue.due(queue, 1050, false, true))
        assert.is_true(RegisterQueue.due(queue, 1000 + RegisterQueue.MAX_WAIT, false, false))
        assert.is_false(RegisterQueue.due({}, 5000, true, true))
    end)

    it('sorts what the call returned; after a stop at a failure the rest goes at once in a smaller call', function()
        local queue = filled(10, 1000)
        local taken = RegisterQueue.takeDue(queue, 1100, true).batch
        local sorted = RegisterQueue.outcome(taken, { existed = { photo(1), photo(2), photo(3) }, created = {},
            failed = { photo(4) } }, idOf)
        assert.are.same({ 1, 2, 3 }, ids(sorted.existed))
        assert.are.same({ 4 }, ids(sorted.failed))
        assert.are.same({ 5, 6, 7, 8, 9, 10 }, ids(sorted.untried))
        assert.are.equal('failed', RegisterQueue.putBack(queue, sorted, 1100))
        assert.are.equal(7, #queue)
        local again = RegisterQueue.takeDue(queue, 1100, false)
        assert.are.same({ 5, 6, 7, 8, 9, 10 }, ids(again.batch)) -- the next call is smaller; the failed one waits
        assert.are.same({ 4 }, ids(queue))
        assert.is_false(RegisterQueue.due(queue, 1100 + RegisterQueue.RETRY - 1, true, true))
        assert.is_true(RegisterQueue.due(queue, 1100 + RegisterQueue.RETRY, true, true))
    end)

    it('a photo that keeps failing gets a call of its own, then is given up', function()
        local queue = { { id = 7, at = 0 } }
        local now = 1000
        for try = 1, RegisterQueue.MAX_BATCH_TRIES do
            local taken = RegisterQueue.takeDue(queue, now, true)
            assert.are.equal(1, #taken.batch)
            RegisterQueue.putBack(queue, RegisterQueue.outcome(taken.batch, { failed = { photo(7) } }, idOf), now)
            assert.are.equal(try, queue[1].tries)
            now = now + RegisterQueue.RETRY
        end
        assert.is_true(queue[1].single)
        local taken = RegisterQueue.takeDue(queue, now, false)
        assert.are.equal(0, #taken.batch)
        assert.are.same({ 7 }, ids(taken.singles))
        local word, givenUp
        for _ = RegisterQueue.MAX_BATCH_TRIES + 1, RegisterQueue.GIVE_UP do
            word, givenUp = RegisterQueue.putBack(queue, { failed = taken.singles, untried = {}, existed = {},
                created = {} }, now)
            taken = RegisterQueue.takeDue(queue, now + RegisterQueue.RETRY, false)
        end
        assert.are.equal('failed', word)
        assert.are.same({ 7 }, ids(givenUp))
        assert.are.same({}, queue)
    end)

    it('a cancelled call leaves the rest for the next fetch in one go or the next start, without retrying', function()
        local queue = filled(10, 1000)
        local taken = RegisterQueue.takeDue(queue, 1100, true).batch
        local sorted = RegisterQueue.outcome(taken, { existed = { photo(1), photo(2) } }, idOf)
        assert.are.equal('held', RegisterQueue.putBack(queue, sorted, 1100))
        assert.are.equal(8, #queue)
        assert.is_nil(queue[1].tries) -- the call registered some: not counted against the rest
        assert.is_false(RegisterQueue.due(queue, 9999, false, true)) -- not by itself
        assert.are.equal(0, #RegisterQueue.takeDue(queue, 9999, false).batch)
        assert.is_true(RegisterQueue.due(queue, 9999, true, false)) -- the next fetch in one go
        local store = {}
        RegisterQueue.save(store, CATALOG, queue)
        local restarted = RegisterQueue.load(store, CATALOG)
        assert.is_true(RegisterQueue.due(restarted, 9999, false, true)) -- the next start
        -- A call that registers nothing and reports nothing counts as a try, so one that never works ends in calls of
        -- their own.
        local none = RegisterQueue.outcome(RegisterQueue.takeDue(queue, 9999, true).batch, nil, idOf)
        assert.are.equal(8, #none.untried)
        assert.are.equal('held', RegisterQueue.putBack(queue, none, 9999))
        assert.are.equal(1, queue[1].tries)
    end)

    it('an answer naming unknown photos or a photo twice changes nothing', function()
        local entries = { { id = 1 }, { id = 2 } }
        local sorted = RegisterQueue.outcome(entries, { existed = { photo(1), photo(99), photo(1) },
            created = 'x', failed = { photo(1) } }, idOf)
        assert.are.same({ 1 }, ids(sorted.existed))
        assert.are.same({}, sorted.failed)
        assert.are.same({ 2 }, ids(sorted.untried))
        local created = RegisterQueue.outcome(entries, { created = { photo(2) }, existed = { photo(1) } }, idOf)
        assert.are.same({ 2 }, ids(created.created))
        assert.is_nil(RegisterQueue.putBack({}, created, 0))
    end)

    it('survives a restart, per catalog', function()
        local store = {}
        local queue = {}
        RegisterQueue.add(queue, { id = 110260, job = 12, ready = 10.5, placed = 11.25, at = 1731577800 })
        RegisterQueue.add(queue, { id = 110259, job = 12, tries = 2, notBefore = 1731577900, single = true,
            held = true })
        assert.is_true(RegisterQueue.save(store, CATALOG, queue))
        RegisterQueue.save(store, 'C:\\Photos\\Other\\Other.lrcat', { { id = 1 } })
        assert.are.same({ { id = 110260, job = 12, ready = 10.5, placed = 11.25, at = 1731577800 },
            { id = 110259, job = 12, tries = 2, notBefore = 1731577900, single = true } },
            RegisterQueue.load(store, 'c:/photos/main/MAIN.LRCAT'))
        RegisterQueue.save(store, CATALOG, {})
        assert.are.same({}, RegisterQueue.load(store, CATALOG))
        assert.are.equal(1, #RegisterQueue.load(store, 'C:\\Photos\\Other\\Other.lrcat'))
        assert.are.same({}, RegisterQueue.load({ [RegisterQueue.KEY] = '{oops' }, CATALOG))
        assert.are.same({ { id = 4 } }, RegisterQueue.load({ [RegisterQueue.KEY] =
            '{"c:/photos/main/main.lrcat": [{"id": 4}, {"id": 4}, {"id": -1}, "x"]}' }, CATALOG))
        assert.is_false(RegisterQueue.save({}, nil, {}))
        -- A queue stored by 0.8.1 (no at): due at once after the start.
        local old = RegisterQueue.load({ [RegisterQueue.KEY] = '{"c:/photos/main/main.lrcat": [{"id": 4, "job": 2}]}' },
            CATALOG)
        assert.is_true(RegisterQueue.due(old, 1731577800, false, true))
    end)
end)
