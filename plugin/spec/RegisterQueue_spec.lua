-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local RegisterQueue = require 'RegisterQueue'

local CATALOG = 'C:\\Photos\\Main\\Main.lrcat'

describe('RegisterQueue', function()
    it('defers registration while an import is in progress and gives batches afterwards', function()
        local queue = {}
        for id = 1, 60 do
            local job = id <= 30 and 12 or 13
            assert.is_true(RegisterQueue.add(queue, { id = id, job = job, ready = id, placed = id + 1 }))
        end
        assert.is_false(RegisterQueue.add(queue, { id = 5, job = 12 }))
        assert.are.same({}, RegisterQueue.take(queue, true))
        assert.are.equal(60, RegisterQueue.count(queue))
        local batch = RegisterQueue.take(queue, false)
        assert.are.equal(RegisterQueue.BATCH, #batch)
        assert.are.equal(1, batch[1].id)
        assert.are.equal(35, RegisterQueue.count(queue))
        assert.are.equal(5, RegisterQueue.count(queue, 12))
        assert.are.equal(30, RegisterQueue.count(queue, 13))
        assert.are.equal(10, #RegisterQueue.take(queue, false, 10))
    end)

    it('survives a restart, per catalog', function()
        local store = {}
        local queue = {}
        RegisterQueue.add(queue, { id = 110260, job = 12, ready = 10.5, placed = 11.25 })
        RegisterQueue.add(queue, { id = 110259, job = 12 })
        assert.is_true(RegisterQueue.save(store, CATALOG, queue))
        RegisterQueue.save(store, 'C:\\Photos\\Other\\Other.lrcat', { { id = 1 } })
        assert.are.same({ { id = 110260, job = 12, ready = 10.5, placed = 11.25 }, { id = 110259, job = 12 } },
            RegisterQueue.load(store, 'c:/photos/main/MAIN.LRCAT'))
        RegisterQueue.save(store, CATALOG, {})
        assert.are.same({}, RegisterQueue.load(store, CATALOG))
        assert.are.equal(1, #RegisterQueue.load(store, 'C:\\Photos\\Other\\Other.lrcat'))
        assert.are.same({}, RegisterQueue.load({ [RegisterQueue.KEY] = '{oops' }, CATALOG))
        assert.are.same({ { id = 4 } }, RegisterQueue.load({ [RegisterQueue.KEY] =
            '{"c:/photos/main/main.lrcat": [{"id": 4}, {"id": 4}, {"id": -1}, "x"]}' }, CATALOG))
        assert.is_false(RegisterQueue.save({}, nil, {}))
    end)
end)
