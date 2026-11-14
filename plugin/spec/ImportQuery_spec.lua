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

describe('ImportQuery.newSinceSql', function()
    it('asks for photos and imports above the mark, in a SELECT the read-only script takes', function()
        local sql = ImportQuery.newSinceSql(50540)
        assert.is_string(SqliteCommand.readScript('/a.lrcat', sql))
        assert.is_truthy(sql:find('WHERE i.id_local > 50540 UNION ALL', 1, true))
        assert.is_truthy(sql:find('FROM AgLibraryImport WHERE id_local > 50540;', 1, true))
        assert.is_truthy(sql:find('JOIN AgLibraryRootFolder r ON r.id_local = fo.rootFolder', 1, true))
    end)

    it('refuses a mark that is not a count', function()
        for _, bad in ipairs({ -1, 1.5, '7', nil, 2 ^ 60 }) do
            assert.is_nil(ImportQuery.newSinceSql(bad))
        end
        assert.is_string(ImportQuery.newSinceSql(0))
    end)
end)

describe('ImportQuery.parseNewSince', function()
    it('reads photos in id order with their folder, name and sidecars, and the imports', function()
        local function photo(id, root, folder, base, extension, sidecars)
            return table.concat({ 'p', id, '8E7F0000-1111-2222-3333-444455556666', hex(root), hex(folder), hex(base),
                hex(extension), hex(sidecars) }, '|')
        end
        local text = table.concat({
            photo(50479, 'Z:/', '2026/2026.06.20 - shoot/', 'IMG_0002', 'ARW', ''),
            photo(50478, 'Z:/', '2026/2026.06.20 - shoot/', 'IMG_0001', 'ARW', 'JPG'),
            photo(50478, 'Z:/', '2026/2026.06.20 - shoot/', 'IMG_0001', 'ARW', 'JPG'),
            photo(50480, '//nas.local/photos/', '', 'README', '', ''),
            'i|50476||' .. hex('2026-11-14T04:44:59.031+03:00') .. '||||',
            'p|x|y',
        }, '\n')
        local result, problems = ImportQuery.parseNewSince(text)
        assert.are.equal(3, #result.photos)
        assert.are.same({ id = 50478, uuid = '8E7F0000-1111-2222-3333-444455556666',
            folder = 'Z:/2026/2026.06.20 - shoot/', name = 'IMG_0001.ARW', sidecars = 'JPG' }, result.photos[1])
        assert.are.equal(50479, result.photos[2].id)
        assert.are.equal('', result.photos[2].sidecars)
        assert.are.equal('//nas.local/photos/', result.photos[3].folder)
        assert.are.equal('README', result.photos[3].name)
        assert.are.same({ { id = 50476, date = '2026-11-14T04:44:59.031+03:00' } }, result.imports)
        assert.are.same({ 'unexpected line: p|x|y' }, problems)
    end)
end)
