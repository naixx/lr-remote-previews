-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local ClientId = require 'ClientId'

describe('ClientId', function()
    it('makes a random-UUID-shaped id with the version and variant bits', function()
        local id = ClientId.generate(ClientId.newRandom(1794648600, 123456, 1, 'C:\\Photos\\Main\\Main.lrcat'))
        assert.matches('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$', id)
        assert.are.equal(id:lower(), id)
        assert.are.equal(36, #id)
        assert.is_true(ClientId.isValid(id))
        assert.is_true(#id <= 64) -- the protocol's limit
    end)

    it('gives the same id for the same seed and different ids for different seeds', function()
        local function make(...)
            return ClientId.generate(ClientId.newRandom(...))
        end
        assert.are.equal(make(1, 2, 'a'), make(1, 2, 'a'))
        local seen = {}
        for counter = 1, 500 do
            local id = make(1794648600, 0, counter, 'C:\\Photos\\Main\\Main.lrcat')
            assert.is_nil(seen[id], 'repeated id for counter ' .. counter)
            seen[id] = true
        end
        assert.are_not.equal(make(1794648600, 0, 1, 'C:\\Photos\\Main\\Main.lrcat'),
            make(1794648600, 0, 1, 'C:\\Photos\\Other\\Other.lrcat'))
        assert.are_not.equal(make(1794648600, 0, 1), make(1794648601, 0, 1))
    end)

    it('draws numbers in [0, 1) and survives a zero seed', function()
        local random = ClientId.newRandom(0)
        for _ = 1, 1000 do
            local value = random()
            assert.is_true(value >= 0 and value < 1)
        end
    end)

    it('tells ids from other text', function()
        assert.is_true(ClientId.isValid('c1f0a6e2-7d0b-4c55-9d0e-3f6a1b2c4d5e'))
        for _, bad in ipairs({ 'c1f0a6e2', '', 42, 'c1f0a6e2-7d0b-4c55-9d0e-3f6a1b2c4d5e-x' }) do
            assert.is_false(ClientId.isValid(bad))
        end
    end)

    it('hashes text to a stable number', function()
        assert.are.equal(ClientId.hash('abc'), ClientId.hash('abc'))
        assert.are_not.equal(ClientId.hash('abc'), ClientId.hash('abd'))
        assert.are.equal(0, ClientId.hash(''))
    end)
end)
