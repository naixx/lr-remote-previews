-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

-- Json.lua is rxi/json.lua, vendored unmodified (see THIRD-PARTY.md). These tests pin the behaviour the
-- plug-in relies on.
local Json = require 'Json'

describe('Json', function()
    it('round-trips nested tables', function()
        local value = {
            name = 'LR Remote Previews',
            api = 1,
            ratio = 0.5,
            enabled = true,
            disabled = false,
            roots = { { id = 'archive', label = 'Archive', available = true }, { id = 'b' } },
            extensions = { '.arw', '.cr2' },
            path = 'C:\\Program Files\\Adobe\\Adobe DNG Converter\\Adobe DNG Converter.exe',
            text = 'quote " newline \n tab \t unicode \195\169',
        }
        assert.are.same(value, Json.decode(Json.encode(value)))
    end)

    it('decodes escaped backslashes in Windows paths', function()
        assert.are.equal('C:\\Program Files\\x.exe', Json.decode('"C:\\\\Program Files\\\\x.exe"'))
    end)

    it('decodes null as nil', function()
        local decoded = Json.decode('{"version": null, "name": "x"}')
        assert.is_nil(decoded.version)
        assert.are.equal('x', decoded.name)
    end)

    it('decodes unicode escapes to UTF-8', function()
        assert.are.equal('\195\169', Json.decode('"\\u00e9"'))
        assert.are.equal('\240\159\152\128', Json.decode('"\\ud83d\\ude00"'))
    end)

    it('decodes an empty array and an empty object to empty tables', function()
        assert.are.same({ a = {}, b = {} }, Json.decode('{"a": [], "b": {}}'))
    end)

    it('raises an error on malformed input', function()
        assert.has_error(function() Json.decode('{"a": 1') end)
        assert.has_error(function() Json.decode('{"a": 1} trailing') end)
        assert.has_error(function() Json.decode('"unterminated') end)
        assert.has_error(function() Json.decode('<html>') end)
        assert.has_error(function() Json.decode('') end)
        assert.has_error(function() Json.decode(nil) end)
    end)

    it('raises an error when encoding a sparse array', function()
        assert.has_error(function() Json.encode({ 1, nil, 3 }) end)
    end)
end)
