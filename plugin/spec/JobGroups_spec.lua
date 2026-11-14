-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local CatalogRead = require 'CatalogRead'
local JobGroups = require 'JobGroups'

local CATALOG = 'C:\\Photos\\Main\\Main.lrcat'
local DATE = '2026-11-14T15:15:56.060+01:00'

local function photos(importId, first, last, folder)
    local list = {}
    for id = first, last do
        list[#list + 1] = { id = id, importId = importId, folder = folder or 'Z:/2026/2026.06.20 - shoot/' }
    end
    return list
end

local function join(...)
    local list = {}
    for _, part in ipairs({ ... }) do
        for _, photo in ipairs(part) do
            list[#list + 1] = photo
        end
    end
    return list
end

local function summary(batches)
    local list = {}
    for i, batch in ipairs(batches) do
        list[i] = { key = batch.key, label = batch.label, part = batch.part, jobId = batch.jobId,
            count = #batch.photos }
    end
    return list
end

describe('JobGroups labels', function()
    it('names the import by its local time and folder, with a part number from the second job on', function()
        assert.are.equal('Lightroom import 2026-11-14 15:15, 2026.06.20 - shoot',
            JobGroups.label(DATE, '2026.06.20 - shoot', 1))
        assert.are.equal('Lightroom import 2026-11-14 15:15, shoot (part 3)', JobGroups.label(DATE, 'shoot', 3))
        assert.are.equal('Lightroom import, shoot', JobGroups.label('yesterday', 'shoot'))
        assert.are.equal('Lightroom import 2026-11-14 15:15', JobGroups.label(DATE, nil))
        local long = JobGroups.label(DATE, string.rep('é', 200), 2)
        assert.are.equal(JobGroups.MAX_LABEL, select(2, long:gsub('[^\128-\191]', '')))
        assert.matches(' %(part 2%)$', long)
        assert.are.equal('ab', JobGroups.cut('abé', 2))
        assert.are.equal('abé', JobGroups.cut('abé', 3))
    end)
end)

describe('JobGroups.plan', function()
    local options = { maxItems = 5000, append = true }

    it('puts the first photos of an import into a new job named after it', function()
        local batches = JobGroups.plan(photos(106106, 108877, 109001), {}, { [106106] = DATE }, CatalogRead.folderName,
            options)
        assert.are.same({ { key = '106106', label = 'Lightroom import 2026-11-14 15:15, 2026.06.20 - shoot', part = 1,
            count = 125 } }, summary(batches))
        assert.are.equal(106106, batches[1].importId)
    end)

    it('adds the later photos of an import to its job, and the overflow to a new part', function()
        local groups = { ['106106'] = { job = 12, count = 4990, label = 'Lightroom import X', part = 1, at = 0 } }
        local batches = JobGroups.plan(photos(106106, 1, 25), groups, {}, CatalogRead.folderName, options)
        assert.are.same({
            { key = '106106', label = 'Lightroom import X', part = 1, jobId = 12, count = 10 },
            { key = '106106', label = 'Lightroom import X (part 2)', part = 2, count = 15 },
        }, summary(batches))
        groups['106106'].count = 5000
        batches = JobGroups.plan(photos(106106, 1, 12001), groups, {}, CatalogRead.folderName, options)
        assert.are.same({
            { key = '106106', label = 'Lightroom import X (part 2)', part = 2, count = 5000 },
            { key = '106106', label = 'Lightroom import X (part 3)', part = 3, count = 5000 },
            { key = '106106', label = 'Lightroom import X (part 4)', part = 4, count = 2001 },
        }, summary(batches))
    end)

    it('sends the photos of no import per round, and keeps imports apart', function()
        local batches = JobGroups.plan(join(photos(0, 1, 3), photos(200, 4, 5, 'Z:/b/'), photos(0, 6, 6)), {},
            { [200] = DATE }, CatalogRead.folderName, options)
        assert.are.same({
            { label = 'Lightroom import (automatic)', part = 1, count = 4 },
            { key = '200', label = 'Lightroom import 2026-11-14 15:15, b', part = 1, count = 2 },
        }, summary(batches))
    end)

    it('names an import that spans folders after their common folder', function()
        local batches = JobGroups.plan(join(photos(7, 1, 2, 'Z:/2026/shoot/a/'), photos(7, 3, 4, 'Z:/2026/shoot/b/')),
            {}, { [7] = DATE }, CatalogRead.folderName, options)
        assert.are.equal('Lightroom import 2026-11-14 15:15, shoot', batches[1].label)
    end)

    it('creates new jobs every round when the server cannot add items, numbering the parts on', function()
        local groups = { ['106106'] = { job = 12, count = 125, label = 'Lightroom import X', part = 1, at = 0 } }
        local batches = JobGroups.plan(photos(106106, 1, 100), groups, {}, CatalogRead.folderName,
            { maxItems = 5000, append = false })
        assert.are.same({ { key = '106106', label = 'Lightroom import X (part 2)', part = 2, count = 100 } },
            summary(batches))
    end)
end)

describe('JobGroups records', function()
    it('remembers the job of each import per catalog, and forgets old entries', function()
        local store, groups = {}, {}
        JobGroups.created(groups, '106106', 12, 125, 'Lightroom import X', 1, 1000)
        JobGroups.added(groups, '106106', 100, 1100)
        JobGroups.created(groups, nil, 13, 4, 'Lightroom import (automatic)', 1, 1100) -- no import: not kept
        assert.is_true(JobGroups.save(store, CATALOG, groups))
        assert.are.same({ ['106106'] = { job = 12, count = 225, label = 'Lightroom import X', part = 1, at = 1100 } },
            JobGroups.load(store, 'c:/photos/main/MAIN.lrcat', 2000))
        assert.are.same({}, JobGroups.load(store, CATALOG, 1100 + JobGroups.MAX_AGE_DAYS * 86400 + 1))
        assert.are.same({}, JobGroups.load({ [JobGroups.KEY] = '{oops' }, CATALOG, 0))
        JobGroups.save(store, CATALOG, {})
        assert.are.same({}, JobGroups.load(store, CATALOG, 2000))
    end)

    it('starts a new job when a job cannot take more photos, and stops otherwise', function()
        for _, problem in ipairs({ { status = 413, code = 'too_many_items' }, { status = 409, code = 'job_cancelled' },
            { status = 404 }, { status = 422, code = 'duplicate_ref' } }) do
            assert.are.equal('newJob', JobGroups.afterAppendFailure(problem))
        end
        for _, problem in ipairs({ { kind = 'unreachable' }, { status = 500 }, { status = 401 },
            { status = 409, code = 'converter_not_installed' } }) do
            assert.are.equal('stop', JobGroups.afterAppendFailure(problem))
        end
        assert.are.equal('stop', JobGroups.afterAppendFailure(nil))
    end)
end)
