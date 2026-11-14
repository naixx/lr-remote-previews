-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local CatalogState = require 'CatalogState'

local MAIN = 'C:\\Photos\\Main\\Main.lrcat'
local OTHER = 'C:\\Photos\\Other\\Other.lrcat'

local function counter()
    local n = 0
    return function()
        n = n + 1
        return 'id-' .. n
    end
end

describe('CatalogState client ids', function()
    it('makes an id once per catalog and keeps it', function()
        local store, generate = {}, counter()
        assert.is_nil(CatalogState.clientId(store, MAIN))
        local id, created = CatalogState.ensureClientId(store, MAIN, generate)
        assert.are.equal('id-1', id)
        assert.is_true(created)
        id, created = CatalogState.ensureClientId(store, MAIN, generate)
        assert.are.equal('id-1', id)
        assert.is_false(created)
        assert.are.equal('id-1', CatalogState.clientId(store, MAIN))
        assert.are.equal('id-2', (CatalogState.ensureClientId(store, OTHER, generate)))
        assert.are.equal('id-1', CatalogState.clientId(store, MAIN))
        assert.is_string(store[CatalogState.CLIENT_IDS_KEY])
    end)

    it('takes two spellings of the same Windows path as one catalog', function()
        local store = {}
        CatalogState.ensureClientId(store, MAIN, counter())
        assert.are.equal('id-1', CatalogState.clientId(store, 'c:/photos/main/MAIN.LRCAT'))
    end)

    it('starts afresh from a value that is not JSON, and refuses a catalog without a path', function()
        local store = { [CatalogState.CLIENT_IDS_KEY] = '{not json' }
        assert.is_nil(CatalogState.clientId(store, MAIN))
        assert.are.equal('id-1', (CatalogState.ensureClientId(store, MAIN, counter())))
        local id, message = CatalogState.ensureClientId(store, nil, counter())
        assert.is_nil(id)
        assert.is_string(message)
    end)
end)

describe('CatalogState job records', function()
    it('stores and reads the records of one catalog, leaving the others alone', function()
        local store = {}
        assert.is_true(CatalogState.saveJobs(store, MAIN, { ['7'] = { since = 12, doneSeq = 15 },
            ['8'] = { since = 0 } }))
        CatalogState.saveJobs(store, OTHER, { ['3'] = { since = 4 } })
        assert.are.same({ ['7'] = { since = 12, doneSeq = 15 }, ['8'] = { since = 0 } },
            CatalogState.jobs(store, MAIN))
        assert.are.same({ ['3'] = { since = 4 } }, CatalogState.jobs(store, OTHER))
        CatalogState.saveJobs(store, MAIN, {})
        assert.are.same({}, CatalogState.jobs(store, MAIN))
        assert.are.same({ ['3'] = { since = 4 } }, CatalogState.jobs(store, OTHER))
    end)

    it('does not write records that did not change', function()
        local store = {}
        CatalogState.saveJobs(store, MAIN, { ['7'] = { since = 12 } })
        local before = store[CatalogState.JOBS_KEY]
        store[CatalogState.JOBS_KEY] = before .. ' '
        assert.is_false(CatalogState.saveJobs(store, MAIN, { ['7'] = { since = 12 } }))
        assert.are.equal(before .. ' ', store[CatalogState.JOBS_KEY])
        assert.is_true(CatalogState.saveJobs(store, MAIN, { ['7'] = { since = 13 } }))
        assert.is_true(CatalogState.saveJobs(store, MAIN, { ['7'] = { since = 13, doneSeq = 13 } }))
        assert.is_false(CatalogState.saveJobs(store, MAIN, { ['7'] = { since = 13, doneSeq = 13 } }))
        assert.is_false(CatalogState.saveJobs({}, MAIN, {}))
    end)

    it('drops malformed records', function()
        local store = { [CatalogState.JOBS_KEY] = '{"c:/photos/main/main.lrcat": {"7": {"since": 3, "doneSeq": -1}, '
            .. '"x": {"since": 1}, "9": {"since": "a"}, "10": 5}}' }
        assert.are.same({ ['7'] = { since = 3 } }, CatalogState.jobs(store, MAIN))
        assert.are.same({}, CatalogState.jobs({ [CatalogState.JOBS_KEY] = '[]' }, MAIN))
    end)
end)
