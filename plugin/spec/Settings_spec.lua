-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local Settings = require 'Settings'

local EMPTY = { serverUrl = '', token = '', localPrefix1 = '', rootId1 = '', localPrefix2 = '', rootId2 = '',
    localPrefix3 = '', rootId3 = '', sqlitePath = '', downloadConcurrency = 4, autoFetch = false,
    autoFetchInterval = 60, autoSend = false }

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
    it('reads every key, trimmed, with missing values as empty strings or defaults', function()
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

    it('reads the options in their kind and bounds', function()
        local read = Settings.read({ downloadConcurrency = 2, autoFetch = true, autoFetchInterval = 300 })
        assert.are.equal(2, read.downloadConcurrency)
        assert.is_true(read.autoFetch)
        assert.are.equal(300, read.autoFetchInterval)
        read = Settings.read({ downloadConcurrency = '6', autoFetch = 'yes', autoFetchInterval = 5 })
        assert.are.equal(6, read.downloadConcurrency)
        assert.is_false(read.autoFetch)
        assert.are.equal(30, read.autoFetchInterval)
        read = Settings.read({ downloadConcurrency = 99, autoFetchInterval = 'often' })
        assert.are.equal(8, read.downloadConcurrency)
        assert.are.equal(60, read.autoFetchInterval)
        assert.is_false(read.autoSend)
        assert.is_true(Settings.read({ autoSend = true }).autoSend)
        assert.is_false(Settings.read({ autoSend = 'on' }).autoSend)
        assert.are.equal(1, Settings.option('downloadConcurrency', 0))
        assert.are.equal(3, Settings.option('downloadConcurrency', 3.7))
        assert.are.equal(4, Settings.option('downloadConcurrency', 0 / 0))
    end)

    it('offers choices that are within the bounds and include the defaults', function()
        local function within(choices, key)
            local option, hasDefault = Settings.OPTIONS[key], false
            for _, value in ipairs(choices) do
                assert.are.equal(value, Settings.option(key, value))
                hasDefault = hasDefault or value == option.default
            end
            assert.is_true(hasDefault)
        end
        within(Settings.CONCURRENCY_CHOICES, 'downloadConcurrency')
        within(Settings.INTERVAL_CHOICES, 'autoFetchInterval')
    end)

    it('bounds the interval to the choices offered: 30 seconds to 30 minutes', function()
        local option = Settings.OPTIONS.autoFetchInterval
        assert.are.equal(Settings.INTERVAL_CHOICES[1], option.min)
        assert.are.equal(Settings.INTERVAL_CHOICES[#Settings.INTERVAL_CHOICES], option.max)
        assert.are.equal(30, option.min)
        assert.are.equal(1800, option.max)
        assert.are.equal(1800, Settings.read({ autoFetchInterval = 3600 }).autoFetchInterval)
    end)

    it('writes every key, trimmed, and mapping 1 also under the 0.1.0 keys', function()
        local store = { unrelated = 'kept' }
        Settings.write(store, { serverUrl = 'http://nas:8787 ', token = ' t ', localPrefix1 = 'Z:\\', rootId1 = 'a',
            localPrefix3 = ' /Volumes/Photos ', rootId3 = 'b', downloadConcurrency = 2, autoFetch = true })
        assert.are.same({ unrelated = 'kept', serverUrl = 'http://nas:8787', token = 't', localPrefix1 = 'Z:\\',
            rootId1 = 'a', localPrefix2 = '', rootId2 = '', localPrefix3 = '/Volumes/Photos', rootId3 = 'b',
            sqlitePath = '', localPrefix = 'Z:\\', rootId = 'a', downloadConcurrency = 2, autoFetch = true,
            autoFetchInterval = 60, autoSend = false }, store)
        assert.are.same(Settings.read(store), Settings.read(store))
    end)

    it('lists every key once', function()
        local seen = {}
        for _, key in ipairs(Settings.KEYS) do
            assert.is_nil(seen[key])
            seen[key] = true
        end
        for key in pairs(EMPTY) do
            assert.is_true(seen[key])
        end
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
