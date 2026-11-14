-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local Json = require 'Json'
local Jobs = require 'Jobs'

local KEY = string.rep('5d41', 16)

-- The item example from docs/protocol.md.
local ITEM = [[
{"id": 4211, "ref": "17", "root": "archive", "path": "2026/2026.06.20 - shoot/IMG_0001.ARW", "state": "ready",
 "seq": 58, "error": null,
 "result": {"key": "]] .. KEY .. [[", "size": 359310, "sha256": "9f2c", "originalName": "IMG_0001.ARW",
            "originalWidth": 6000, "originalHeight": 4000}}
]]

local JOB = [[
{"id": 7, "label": "Lightroom selection", "client": "lr-plugin/0.3.0",
 "clientId": "c1f0a6e2-7d0b-4c55-9d0e-3f6a1b2c4d5e", "state": "active",
 "created": "2026-11-14T09:30:00Z", "finished": null, "seq": 58,
 "counts": {"total": 500, "queued": 300, "building": 8, "ready": 190, "failed": 2, "rejected": 0, "cancelled": 0}}
]]

describe('Jobs URLs', function()
    it('builds every endpoint', function()
        local base = 'http://nas.local:8787'
        assert.are.equal('http://nas.local:8787/api/v1/jobs', Jobs.jobsUrl(base))
        assert.are.equal('http://nas.local:8787/api/v1/jobs/7', Jobs.jobUrl(base, 7))
        assert.are.equal('http://nas.local:8787/api/v1/jobs/7/items?since=58&limit=500', Jobs.itemsUrl(base, 7, 58))
        assert.are.equal('http://nas.local:8787/api/v1/jobs/7/items?since=0&limit=10', Jobs.itemsUrl(base, 7, nil, 10))
        assert.are.equal('http://nas.local:8787/api/v1/items/4211/file', Jobs.fileUrl(base, 4211))
        assert.are.equal('http://nas.local:8787/api/v1/jobs/7/items?since=3&limit=1000&state=ready',
            Jobs.itemsUrl(base, 7, 3, 1000, 'ready'))
        assert.are.equal('http://nas.local:8787/api/v1/jobs/7/retry', Jobs.retryUrl(base, 7))
        assert.are.equal('http://nas.local:8787/api/v1/lookup', Jobs.lookupUrl(base))
        assert.are.equal('http://nas.local:8787/api/v1/files/' .. KEY, Jobs.fileByKeyUrl(base, KEY))
    end)

    it('lists the jobs of one clientId, encoding it', function()
        assert.are.equal('http://nas.local:8787/api/v1/jobs?clientId=c1f0a6e2-7d0b&limit=200',
            Jobs.listUrl('http://nas.local:8787', 'c1f0a6e2-7d0b'))
        assert.are.equal('http://x/api/v1/jobs?clientId=a%20b%26c%2Fd&limit=5', Jobs.listUrl('http://x', 'a b&c/d', 5))
    end)

    it('takes only cache keys of 64 lower-case hex characters', function()
        assert.is_true(Jobs.isCacheKey(KEY))
        for _, bad in ipairs({ KEY:upper(), KEY:sub(2), KEY .. '0', string.rep('g', 64), '../' .. KEY:sub(4), 5 }) do
            assert.is_false(Jobs.isCacheKey(bad))
            local url, message = Jobs.fileByKeyUrl('http://x', bad)
            assert.is_nil(url)
            assert.is_string(message)
        end
    end)
end)

describe('Jobs.createBody', function()
    it('builds the request of the contract', function()
        local body = Jobs.createBody({
            { ref = '1', rootId = 'archive', relativePath = '2026/2026.06.20 - shoot/IMG_0001.ARW', other = 'x' },
            { ref = '2', rootId = 'archive', relativePath = 'Caf\195\169/IMG_0002.ARW' },
        })
        assert.are.same({
            client = 'lr-plugin/0.3.0',
            label = 'Lightroom selection',
            items = {
                { ref = '1', root = 'archive', path = '2026/2026.06.20 - shoot/IMG_0001.ARW' },
                { ref = '2', root = 'archive', path = 'Caf\195\169/IMG_0002.ARW' },
            },
        }, Json.decode(body))
    end)

    it('adds the clientId and other options', function()
        local entries = { { ref = '1', rootId = 'archive', relativePath = 'a.arw' } }
        local decoded = Json.decode(Jobs.createBody(entries, { clientId = 'c1f0a6e2', label = 'part 1 of 2' }))
        assert.are.equal('c1f0a6e2', decoded.clientId)
        assert.are.equal('part 1 of 2', decoded.label)
        assert.are.equal('lr-plugin/0.3.0', decoded.client)
        assert.is_nil(Json.decode(Jobs.createBody(entries)).clientId)
        for _, bad in ipairs({ '', string.rep('a', 65), 12 }) do
            local body, message = Jobs.createBody(entries, { clientId = bad })
            assert.is_nil(body)
            assert.matches('client id', message)
        end
    end)

    it('refuses an empty list, missing or duplicate refs', function()
        local cases = {
            {},
            { { rootId = 'a', relativePath = 'x' } },
            { { ref = string.rep('1', 65), rootId = 'a', relativePath = 'x' } },
            { { ref = '1', rootId = 'a', relativePath = 'x' }, { ref = '1', rootId = 'a', relativePath = 'y' } },
            { { ref = '1', relativePath = 'x' } },
        }
        for _, entries in ipairs(cases) do
            local body, message = Jobs.createBody(entries)
            assert.is_nil(body)
            assert.is_string(message)
        end
    end)

    it('names the plug-in version of Info.lua as the client', function()
        local info = assert(loadfile(here .. '../LRRemotePreviews.lrplugin/Info.lua'))()
        local version = string.format('%d.%d.%d', info.VERSION.major, info.VERSION.minor, info.VERSION.revision)
        assert.are.equal('lr-plugin/' .. version, Jobs.CLIENT)
    end)
end)

describe('Jobs.normalizeItem', function()
    it('accepts the contract example', function()
        assert.are.same({
            id = 4211, ref = '17', state = 'ready', seq = 58, root = 'archive',
            path = '2026/2026.06.20 - shoot/IMG_0001.ARW',
            result = { key = KEY, size = 359310, sha256 = '9f2c', originalName = 'IMG_0001.ARW', originalWidth = 6000,
                originalHeight = 4000 },
        }, Jobs.normalizeItem(Json.decode(ITEM)))
    end)

    it('keeps the error of a failed item and tolerates null result fields', function()
        local item = Jobs.normalizeItem(Json.decode('{"id": 1, "ref": "a", "state": "failed", "seq": 3, '
            .. '"error": {"code": "converter_failed", "message": "exit code 1"}, "result": null}'))
        assert.are.same({ code = 'converter_failed', message = 'exit code 1' }, item.error)
        assert.is_nil(item.result)
        local ready = Jobs.normalizeItem(Json.decode('{"id": 2, "ref": "b", "state": "ready", "seq": 4, '
            .. '"result": {"size": 10, "originalName": null, "originalWidth": null}}'))
        assert.are.same({ size = 10 }, ready.result)
    end)

    it('rejects malformed items', function()
        local cases = {
            '[1]',
            '{"ref": "a", "state": "ready", "seq": 1}',
            '{"id": 0, "ref": "a", "state": "ready", "seq": 1}',
            '{"id": 1.5, "ref": "a", "state": "ready", "seq": 1}',
            '{"id": 1, "state": "ready", "seq": 1}',
            '{"id": 1, "ref": "a", "state": "done", "seq": 1}',
            '{"id": 1, "ref": "a", "state": "ready"}',
            '{"id": 1, "ref": "a", "state": "ready", "seq": -1}',
        }
        for _, text in ipairs(cases) do
            local item, message = Jobs.normalizeItem(Json.decode(text))
            assert.is_nil(item)
            assert.is_string(message)
        end
        assert.is_nil(Jobs.normalizeItem(nil))
    end)
end)

describe('Jobs answers', function()
    it('parses the answer to POST /api/v1/jobs', function()
        local created = Jobs.parseCreated(Json.decode('{"job": ' .. JOB .. ', "items": [' .. ITEM .. ']}'))
        assert.are.equal(7, created.job.id)
        assert.are.equal('active', created.job.state)
        assert.are.equal(58, created.job.seq)
        assert.are.equal(500, created.job.counts.total)
        assert.are.equal(4211, created.items[1].id)
        assert.are.equal('c1f0a6e2-7d0b-4c55-9d0e-3f6a1b2c4d5e', created.job.clientId)
        assert.are.equal('Lightroom selection', created.job.label)
        assert.are.equal('2026-11-14T09:30:00Z', created.job.created)
        assert.is_nil(created.job.finished)
    end)

    it('fills in missing counts with 0', function()
        local job = Jobs.normalizeJob(Json.decode('{"id": 3, "state": "done", "counts": {"ready": 2, "failed": "x"}}'))
        assert.are.same({ total = 0, queued = 0, building = 0, ready = 2, failed = 0, rejected = 0, cancelled = 0 },
            job.counts)
        assert.is_nil(job.clientId)
    end)

    it('parses a page of items', function()
        local page = Jobs.parseItemsPage(Json.decode('{"job": ' .. JOB .. ', "items": [], "more": true}'))
        assert.are.same({}, page.items)
        assert.is_true(page.more)
        assert.is_false(Jobs.parseItemsPage(Json.decode('{"job": ' .. JOB .. ', "items": []}')).more)
    end)

    it('parses the list of jobs and the answer to a retry', function()
        local jobs = Jobs.parseJobList(Json.decode('{"jobs": [' .. JOB .. ', {"id": 6, "state": "done"}]}'))
        assert.are.equal(2, #jobs)
        assert.are.equal(7, jobs[1].id)
        assert.are.equal(6, jobs[2].id)
        assert.are.same({}, Jobs.parseJobList(Json.decode('{"jobs": []}')))
        assert.is_nil(Jobs.parseJobList(Json.decode('{"items": []}')))
        assert.is_nil(Jobs.parseJobList(Json.decode('{"jobs": [{"id": 0, "state": "done"}]}')))
        assert.are.equal(7, Jobs.parseJobAnswer(Json.decode('{"job": ' .. JOB .. '}')).id)
        assert.is_nil(Jobs.parseJobAnswer(Json.decode('{"detail": "x"}')))
    end)

    it('rejects answers without a job or with a bad item', function()
        assert.is_nil(Jobs.parseCreated(Json.decode('{"items": []}')))
        assert.is_nil(Jobs.parseCreated(Json.decode('{"job": {"id": 7}, "items": []}')))
        assert.is_nil(Jobs.parseCreated(Json.decode('{"job": ' .. JOB .. '}')))
        local page, message = Jobs.parseItemsPage(Json.decode('{"job": ' .. JOB .. ', "items": [{"id": 1}]}'))
        assert.is_nil(page)
        assert.matches('ref', message)
        assert.is_nil(Jobs.parseCreated(nil))
    end)
end)

describe('Jobs lookups', function()
    local entries = {
        { ref = '1', rootId = 'archive', relativePath = 'a/IMG_0001.ARW' },
        { ref = '2', rootId = 'archive', relativePath = 'a/IMG_0002.ARW' },
        { ref = '3', rootId = 'archive', relativePath = 'a/IMG_0003.ARW' },
        { ref = '4', rootId = 'gone', relativePath = 'b/IMG_0004.ARW' },
    }

    it('builds the request of the contract', function()
        assert.are.same({ items = {
            { ref = '1', root = 'archive', path = 'a/IMG_0001.ARW' },
            { ref = '2', root = 'archive', path = 'a/IMG_0002.ARW' },
            { ref = '3', root = 'archive', path = 'a/IMG_0003.ARW' },
            { ref = '4', root = 'gone', path = 'b/IMG_0004.ARW' },
        } }, Json.decode(Jobs.lookupBody(entries)))
        assert.is_nil(Jobs.lookupBody({}))
        assert.is_nil(Jobs.lookupBody({ entries[1], entries[1] }))
    end)

    it('parses every state of the answer, keyed by ref', function()
        local answer = Json.decode([[{"items": [
            {"ref": "1", "state": "ready", "error": null, "result": {"key": "]] .. KEY .. [[", "size": 10,
             "sha256": "ab", "originalName": "IMG_0001.ARW", "originalWidth": 6000, "originalHeight": 4000}},
            {"ref": "2", "state": "pending", "error": null, "result": null},
            {"ref": "3", "state": "absent", "error": null, "result": null},
            {"ref": "4", "state": "rejected", "error": {"code": "unknown_root", "message": "no such root"},
             "result": null}]}]])
        local byRef = assert(Jobs.parseLookup(answer, entries))
        assert.are.equal('ready', byRef['1'].state)
        assert.are.equal(KEY, byRef['1'].result.key)
        assert.are.equal(10, byRef['1'].result.size)
        assert.are.equal('pending', byRef['2'].state)
        assert.is_nil(byRef['2'].result)
        assert.are.equal('absent', byRef['3'].state)
        assert.are.same({ code = 'unknown_root', message = 'no such root' }, byRef['4'].error)
    end)

    it('rejects answers that do not match the request', function()
        local function answer(items)
            return Json.decode('{"items": [' .. table.concat(items, ',') .. ']}')
        end
        local one = { entries[1] }
        local cases = {
            Json.decode('{"jobs": []}'),
            answer({}),
            answer({ '{"ref": "9", "state": "ready"}' }),
            answer({ '{"ref": "1", "state": "ready"}', '{"ref": "1", "state": "ready"}' }),
            answer({ '{"ref": "1", "state": "done"}' }),
            answer({ '{"state": "ready"}' }),
        }
        for _, case in ipairs(cases) do
            local byRef, message = Jobs.parseLookup(case, one)
            assert.is_nil(byRef)
            assert.is_string(message)
        end
    end)
end)

describe('Jobs.checkRefs', function()
    local entries = { { ref = '1' }, { ref = '2' } }

    it('accepts one item per requested ref', function()
        assert.is_true(Jobs.checkRefs({ { ref = '2' }, { ref = '1' } }, entries))
    end)

    it('finds missing, extra and repeated refs', function()
        assert.is_nil(Jobs.checkRefs({ { ref = '1' } }, entries))
        assert.is_nil(Jobs.checkRefs({ { ref = '1' }, { ref = '3' } }, entries))
        assert.is_nil(Jobs.checkRefs({ { ref = '1' }, { ref = '1' } }, entries))
    end)
end)

describe('Jobs.createProblemText', function()
    it('explains the cases the contract names', function()
        assert.matches('not installed', Jobs.createProblemText({ code = 'converter_not_installed', status = 409,
            message = 'HTTP 409.' }))
        assert.matches('at most 5000', Jobs.createProblemText({ status = 413, message = 'HTTP 413.' }, 5000))
        assert.matches('did not accept the job', Jobs.createProblemText({ status = 422, message = 'HTTP 422.' }))
    end)
end)
