-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local Settings = require 'Settings'

describe('Settings', function()
    it('reads every key, trimmed, with missing values as empty strings', function()
        assert.are.same({ serverUrl = 'http://nas.local:8787', token = 'abc', localPrefix = '', rootId = '' },
            Settings.read({ serverUrl = ' http://nas.local:8787 ', token = 'abc\n', rootId = 42, other = 'x' }))
        assert.are.same({ serverUrl = '', token = '', localPrefix = '', rootId = '' }, Settings.read(nil))
    end)

    it('writes every key, trimmed', function()
        local store = { unrelated = 'kept' }
        Settings.write(store, { serverUrl = 'http://nas:8787 ', token = ' t ', localPrefix = 'Z:\\', rootId = 'a' })
        assert.are.same({ unrelated = 'kept', serverUrl = 'http://nas:8787', token = 't', localPrefix = 'Z:\\',
            rootId = 'a' }, store)
    end)

    it('gives one mapping when both halves are set', function()
        assert.are.same({ { localPrefix = 'Z:\\', rootId = 'archive' } },
            Settings.mappings({ localPrefix = 'Z:\\', rootId = 'archive' }))
        assert.are.same({}, Settings.mappings({ localPrefix = 'Z:\\', rootId = '' }))
        assert.are.same({}, Settings.mappings({ localPrefix = '', rootId = 'archive' }))
    end)
end)
