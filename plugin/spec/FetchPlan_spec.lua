-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local FetchPlan = require 'FetchPlan'

local ME = 'c1f0a6e2-7d0b-4c55-9d0e-3f6a1b2c4d5e'

local function job(id, state, seq, counts, clientId)
    local all = { total = 0, queued = 0, building = 0, ready = 0, failed = 0, rejected = 0, cancelled = 0 }
    for key, value in pairs(counts or {}) do
        all[key] = value
    end
    return { id = id, state = state, seq = seq, counts = all, clientId = clientId or ME }
end

local function ids(read)
    local list = {}
    for i, entry in ipairs(read) do
        list[i] = entry.job.id .. '@' .. entry.since
    end
    return list
end

describe('FetchPlan.plan', function()
    it('reads the jobs that may have something new, from where the last fetch stopped', function()
        local plan = FetchPlan.plan({
            job(9, 'active', 40, { ready = 5, queued = 10 }),
            job(8, 'done', 30, { ready = 3 }),
            job(7, 'done', 20, { ready = 4 }),
        }, { ['8'] = { since = 25 } }, ME)
        assert.are.same({ '9@0', '8@25', '7@0' }, ids(plan.read))
        assert.are.equal(0, plan.done)
        assert.are.same({ ['8'] = { since = 25 } }, plan.records)
    end)

    it('skips jobs dealt with earlier while their seq stays the same, and reads them again after a retry', function()
        local records = { ['5'] = { since = 18, doneSeq = 20 } }
        local plan = FetchPlan.plan({ job(5, 'done', 20, { ready = 4 }) }, records, ME)
        assert.are.same({}, plan.read)
        assert.are.equal(1, plan.done)
        assert.are.same(records, plan.records)
        plan = FetchPlan.plan({ job(5, 'active', 22, { ready = 4, queued = 2 }) }, records, ME)
        assert.are.same({ '5@18' }, ids(plan.read))
    end)

    it('forgets the jobs the server no longer lists', function()
        local plan = FetchPlan.plan({ job(9, 'done', 3, { ready = 1 }) },
            { ['9'] = { since = 0 }, ['4'] = { since = 7, doneSeq = 7 } }, ME)
        assert.are.same({ ['9'] = { since = 0 } }, plan.records)
    end)

    it('marks a finished job with nothing ready as done without reading it, and waits for active ones', function()
        local plan = FetchPlan.plan({
            job(3, 'done', 6, { failed = 2, rejected = 1 }),
            job(4, 'active', 2, { queued = 5 }),
            job(5, 'cancelled', 9, { cancelled = 3 }),
        }, {}, ME)
        assert.are.same({}, plan.read)
        assert.are.equal(2, plan.done)
        assert.are.equal(1, plan.waiting)
        assert.are.same({ ['3'] = { since = 0, doneSeq = 6 }, ['5'] = { since = 0, doneSeq = 9 } }, plan.records)
    end)

    it('ignores jobs of other clients', function()
        local plan = FetchPlan.plan({ job(1, 'done', 1, { ready = 1 }, 'someone-else'), job(2, 'done', 1,
            { ready = 1 }, nil) }, {}, ME)
        assert.are.same({ '2@0' }, ids(plan.read))
        assert.are.equal(1, plan.foreign)
    end)
end)

describe('FetchPlan.advance', function()
    local function outcomes(map)
        return function(item)
            return map[item.seq]
        end
    end
    local items = { { seq = 11 }, { seq = 12 }, { seq = 15 } }

    it('moves past every item when all have a final outcome, and marks a finished job as done', function()
        local final = outcomes({ [11] = 'delivered', [12] = 'hasSmartPreview', [15] = 'checkFailed' })
        assert.are.same({ since = 15, doneSeq = 20 }, FetchPlan.advance(job(1, 'done', 20), 10, items, final))
        assert.are.same({ since = 15 }, FetchPlan.advance(job(1, 'active', 20), 10, items, final))
        assert.are.same({ since = 10, doneSeq = 20 }, FetchPlan.advance(job(1, 'done', 20), 10, {}, final))
    end)

    it('stops before the first item that has to be tried again', function()
        local open = outcomes({ [11] = 'delivered', [12] = 'downloadFailed', [15] = 'notDelivered' })
        assert.are.same({ since = 11 }, FetchPlan.advance(job(1, 'done', 20), 10, items, open))
        local first = outcomes({ [11] = 'pending', [12] = 'delivered', [15] = 'delivered' })
        assert.are.same({ since = 10 }, FetchPlan.advance(job(1, 'done', 20), 10, items, first))
    end)

    it('never goes below where it started', function()
        local open = outcomes({ [11] = 'writeFailed' })
        assert.are.same({ since = 30 }, FetchPlan.advance(job(1, 'active', 40), 30, { { seq = 11 } }, open))
    end)

    it('knows which outcomes are final', function()
        for _, final in ipairs({ 'delivered', 'deliveredOther', 'destinationExists', 'checkFailed', 'absent',
            'rejected', 'hasSmartPreview', 'notInCatalog', 'badPath', 'noFileId', 'fileIdMismatch' }) do
            assert.is_true(FetchPlan.isFinal(final), final)
        end
        for _, open in ipairs({ 'downloadFailed', 'writeFailed', 'notInCache', 'pending', 'notDelivered', 'sameFile',
            'rootUnavailable', 'unknown' }) do
            assert.is_false(FetchPlan.isFinal(open), open)
        end
    end)
end)

describe('FetchPlan.interesting', function()
    it('lists active jobs, jobs not fully fetched and jobs with failed items, newest first', function()
        local list = FetchPlan.interesting({
            job(9, 'active', 4, { queued = 3 }),
            job(8, 'done', 10, { ready = 2 }),
            job(7, 'done', 8, { ready = 2 }),
            job(6, 'done', 5, { ready = 1, failed = 1 }),
            job(5, 'done', 3, { rejected = 1 }),
            job(4, 'active', 1, { queued = 1 }, 'someone-else'),
        }, { ['7'] = { since = 8, doneSeq = 8 }, ['6'] = { since = 5, doneSeq = 5 } }, ME)
        local listed = {}
        for i, j in ipairs(list) do
            listed[i] = j.id
        end
        assert.are.same({ 9, 8, 6 }, listed)
    end)
end)
