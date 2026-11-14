-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local ImportQuery = require 'ImportQuery'
local SqliteCommand = require 'SqliteCommand'

local function hex(text)
    return (text:gsub('.', function(char)
        return string.format('%02X', char:byte())
    end))
end

describe('ImportQuery.stateSql', function()
    it('is one plain SELECT that the read-only script takes, naming every setting', function()
        local sql = ImportQuery.stateSql()
        assert.is_string(SqliteCommand.readScript('C:\\Photos\\Main\\Main.lrcat', sql))
        assert.matches("^SELECT 'v', hex%(name%), hex%(value%) FROM Adobe_variablesTable WHERE name IN %(", sql)
        for _, name in ipairs(ImportQuery.VARIABLES) do
            assert.is_truthy(sql:find("'" .. name .. "'", 1, true))
        end
        assert.is_truthy(sql:find("SELECT 'm', ifnull(max(id_local), 0), '' FROM Adobe_images", 1, true))
        assert.is_truthy(sql:find("SELECT 'm', ifnull(max(id_local), 0), '' FROM AgLibraryImport;", 1, true))
    end)
end)

describe('ImportQuery.parseState', function()
    it('reads the settings and the largest id', function()
        local text = table.concat({
            'v|' .. hex('AgImportDialog_importBehavior') .. '|' .. hex('refInPlace'),
            'v|' .. hex('AgImportDialog_previewBuildQuality') .. '|' .. hex('bthm'),
            'v|' .. hex('AgImportDialog_metadataPresetID') .. '|' .. hex('<none>'),
            'm|50540|',
            'm|50476|',
        }, '\r\n')
        local state, problems = ImportQuery.parseState(text)
        assert.are.same({ AgImportDialog_importBehavior = 'refInPlace', AgImportDialog_previewBuildQuality = 'bthm',
            AgImportDialog_metadataPresetID = '<none>' }, state.variables)
        assert.are.equal(50540, state.mark)
        assert.are.same({}, state.duplicates)
        assert.are.same({}, problems)
    end)

    it('leaves out a setting with two different values, and names odd lines', function()
        local text = table.concat({
            'v|' .. hex('A') .. '|' .. hex('1'),
            'v|' .. hex('A') .. '|' .. hex('2'),
            'v|' .. hex('B') .. '|' .. hex('x'),
            'v|' .. hex('B') .. '|' .. hex('x'),
            'v|ABC|00',
            'Error: database is locked',
        }, '\n')
        local state, problems = ImportQuery.parseState(text)
        assert.are.same({ B = 'x' }, state.variables)
        assert.are.same({ 'A' }, state.duplicates)
        assert.is_nil(state.mark)
        assert.are.equal(2, #problems)
        assert.matches('^unexpected line: Error', problems[2])
        assert.are.same({}, ImportQuery.parseState(nil).variables)
    end)
end)
