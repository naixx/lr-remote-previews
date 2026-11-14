-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local PendingJobs = require 'PendingJobs'

local CATALOG = 'C:\\Photos\\Main\\Main.lrcat'
local DAY = 86400

local function ids(store, now)
    local list = {}
    for id in pairs(PendingJobs.load(store, CATALOG, now).jobs) do
        list[#list + 1] = id
    end
    table.sort(list)
    return list
end

describe('PendingJobs', function()
    it('asks the server only while something is pending', function()
        local store = {}
        assert.are.equal('idle', PendingJobs.decide(store, CATALOG, 1000))
        PendingJobs.add(store, CATALOG, { 17, 18 }, 1000)
        assert.are.equal('contact', PendingJobs.decide(store, CATALOG, 1000))
        assert.are.same({ '17', '18' }, ids(store, 1000))
        assert.are.equal(2, PendingJobs.count(store, 'c:/photos/main/MAIN.LRCAT', 1000))
        assert.are.equal('idle', PendingJobs.decide(store, 'C:\\Photos\\Other\\Other.lrcat', 1000))
    end)

    it('keeps a job until a fetch finds it done or the server no longer lists it', function()
        local store = {}
        PendingJobs.add(store, CATALOG, { 17, 18, 19 }, 1000)
        assert.are.equal(1, PendingJobs.settle(store, CATALOG, { ['17'] = true, ['18'] = true, ['20'] = true },
            { ['17'] = true }, 1100))
        assert.are.same({ '18' }, ids(store, 1100))
        assert.are.equal(0, PendingJobs.settle(store, CATALOG, { ['18'] = true }, { ['18'] = true }, 1200))
        assert.are.equal('idle', PendingJobs.decide(store, CATALOG, 1200))
        assert.is_nil(next(require('Json').decode(store[PendingJobs.KEY])))
    end)

    it('forgets a job MAX_AGE_DAYS after it was sent, whatever its state', function()
        local store = {}
        PendingJobs.add(store, CATALOG, { 17 }, 1000)
        PendingJobs.add(store, CATALOG, { 18 }, 1000 + DAY)
        local limit = 1000 + PendingJobs.MAX_AGE_DAYS * DAY
        assert.are.same({ '17', '18' }, ids(store, limit))
        assert.are.same({ '18' }, ids(store, limit + 1))
        assert.are.equal('idle', PendingJobs.decide(store, CATALOG, limit + DAY + 1))
        -- a retry makes a job pending again from that moment
        PendingJobs.add(store, CATALOG, { 17 }, limit + 2 * DAY)
        assert.are.same({ '17' }, ids(store, limit + 2 * DAY))
    end)

    it('backs off after failed contacts and starts afresh after a success or a new job', function()
        local store = {}
        PendingJobs.add(store, CATALOG, { 17 }, 0)
        local t = 0
        for n = 1, #PendingJobs.BACKOFF + 2 do
            local retryAt = PendingJobs.contacted(store, CATALOG, false, t)
            local step = PendingJobs.BACKOFF[math.min(n, #PendingJobs.BACKOFF)]
            assert.are.equal(t + step, retryAt)
            local state, at = PendingJobs.decide(store, CATALOG, t + step - 1)
            assert.are.equal('wait', state)
            assert.are.equal(t + step, at)
            assert.are.equal('contact', PendingJobs.decide(store, CATALOG, t + step))
            t = t + step
        end
        assert.are.same({ 60, 120, 300, 600, 1800, 3600 }, PendingJobs.BACKOFF)
        assert.is_nil(PendingJobs.contacted(store, CATALOG, true, t))
        assert.are.equal('contact', PendingJobs.decide(store, CATALOG, t))
        assert.are.equal(t + 60, PendingJobs.contacted(store, CATALOG, false, t))
        PendingJobs.add(store, CATALOG, { 18 }, t + 1)
        assert.are.equal('contact', PendingJobs.decide(store, CATALOG, t + 1))
    end)

    it('survives a restart and ignores what it cannot read', function()
        local store = {}
        PendingJobs.add(store, CATALOG, { 17 }, 1000)
        local restarted = { [PendingJobs.KEY] = store[PendingJobs.KEY] }
        assert.are.same({ '17' }, ids(restarted, 1000))
        assert.are.equal('idle', PendingJobs.decide({ [PendingJobs.KEY] = '{oops' }, CATALOG, 1000))
        assert.are.equal('idle', PendingJobs.decide({ [PendingJobs.KEY] =
            '{"c:/photos/main/main.lrcat": {"jobs": {"x": {"sent": 1}, "5": {"sent": "y"}}}}' }, CATALOG, 1000))
        assert.is_false(PendingJobs.add({}, nil, { 1 }, 1000))
        PendingJobs.add(store, CATALOG, { 'x', 0, -1, 1.5 }, 2000)
        assert.are.same({ '17' }, ids(store, 2000))
    end)
end)
