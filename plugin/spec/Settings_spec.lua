-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local Settings = require 'Settings'

local EMPTY = { serverUrl = '', token = '', localPrefix1 = '', rootId1 = '', localPrefix2 = '', rootId2 = '',
    localPrefix3 = '', rootId3 = '', sqlitePath = '' }

local function with(values)
    local settings = {}
    for key, value in pairs(EMPTY) do
        settings[key] = value
    end
    for key, value in pairs(values) do
        settings[key] = value
    end
    return settings
end

describe('Settings', function()
    it('reads every key, trimmed, with missing values as empty strings', function()
        assert.are.same(with({ serverUrl = 'http://nas.local:8787', token = 'abc', rootId2 = 'b',
            sqlitePath = 'C:\\Tools\\sqlite3.exe' }),
            Settings.read({ serverUrl = ' http://nas.local:8787 ', token = 'abc\n', rootId1 = 42, rootId2 = ' b ',
                sqlitePath = 'C:\\Tools\\sqlite3.exe', other = 'x' }))
        assert.are.same(EMPTY, Settings.read(nil))
        assert.are.same(EMPTY, Settings.read({}))
    end)

    it('takes the single mapping of version 0.1.0 as mapping 1', function()
        assert.are.same(with({ serverUrl = 'http://nas:8787', localPrefix1 = 'Z:\\', rootId1 = 'archive' }),
            Settings.read({ serverUrl = 'http://nas:8787', localPrefix = 'Z:\\ ', rootId = 'archive' }))
    end)

    it('prefers mapping 1 over the 0.1.0 keys once it was saved, even when emptied', function()
        assert.are.same(with({ localPrefix1 = 'Y:\\', rootId1 = 'new' }),
            Settings.read({ localPrefix = 'Z:\\', rootId = 'archive', localPrefix1 = 'Y:\\', rootId1 = 'new' }))
        assert.are.same(EMPTY, Settings.read({ localPrefix = 'Z:\\', rootId = 'archive', localPrefix1 = '',
            rootId1 = '' }))
    end)

    it('writes every key, trimmed, and mapping 1 also under the 0.1.0 keys', function()
        local store = { unrelated = 'kept' }
        Settings.write(store, { serverUrl = 'http://nas:8787 ', token = ' t ', localPrefix1 = 'Z:\\', rootId1 = 'a',
            localPrefix3 = ' /Volumes/Photos ', rootId3 = 'b' })
        assert.are.same({ unrelated = 'kept', serverUrl = 'http://nas:8787', token = 't', localPrefix1 = 'Z:\\',
            rootId1 = 'a', localPrefix2 = '', rootId2 = '', localPrefix3 = '/Volumes/Photos', rootId3 = 'b',
            sqlitePath = '', localPrefix = 'Z:\\', rootId = 'a' }, store)
        assert.are.same(Settings.read(store), Settings.read(store))
    end)

    it('gives the mappings whose both halves are set, in order', function()
        assert.are.same({ { localPrefix = 'Z:\\', rootId = 'archive' }, { localPrefix = '/Volumes/P', rootId = 'p' } },
            Settings.mappings(with({ localPrefix1 = 'Z:\\', rootId1 = 'archive', localPrefix2 = 'Y:\\',
                localPrefix3 = '/Volumes/P', rootId3 = 'p' })))
        assert.are.same({}, Settings.mappings(EMPTY))
    end)

    it('names the rows that are half filled in or invalid', function()
        assert.are.same({}, Settings.mappingProblems(with({ localPrefix1 = 'Z:\\', rootId1 = 'archive' })))
        local problems = Settings.mappingProblems(with({ localPrefix1 = 'Z:\\', rootId2 = 'x',
            localPrefix3 = 'relative', rootId3 = 'y' }))
        assert.are.equal(3, #problems)
        assert.matches('^Path mapping 1: the server root id is empty', problems[1])
        assert.matches('^Path mapping 2: the local prefix is empty', problems[2])
        assert.matches('^Path mapping 3: the local prefix must be an absolute path', problems[3])
    end)
end)
