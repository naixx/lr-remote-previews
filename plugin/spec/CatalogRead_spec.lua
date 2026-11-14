-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local CatalogRead = require 'CatalogRead'
local SqliteCommand = require 'SqliteCommand'

local function hex(text)
    return (text:gsub('.', function(char)
        return string.format('%02X', string.byte(char))
    end))
end

local UUID = '6b663cb5-5dbe-43b9-8034-307451e01cb3'

local function photoLine(fields)
    return table.concat({ 'p', fields.id or '108877', fields.uuid or UUID, hex(fields.root or 'Z:/2026/'),
        hex(fields.folder or '2026.06.20 - shoot/'), hex(fields.base or 'IMG_0001'), hex(fields.ext or 'ARW'),
        fields.import or '106106', fields.width or '6000', fields.height or '4000', fields.master or '0',
        hex(fields.format or 'RAW'), fields.proxies or '0' }, '|')
end

describe('CatalogRead SQL', function()
    it('reads the photos and import records above a mark in one SELECT that the read script accepts', function()
        local sql = CatalogRead.newSql(106000)
        assert.matches("^SELECT 'p', i%.id_local, ", sql)
        assert.matches('WHERE i%.id_local > 106000 UNION ALL SELECT \'i\', id_local', sql)
        assert.matches('FROM AgLibraryImport WHERE id_local > 106000;$', sql)
        assert.matches('LEFT JOIN AgLibraryImportImage ii ON ii%.image = i%.id_local', sql)
        assert.matches("AgDNGProxyInfo p WHERE p%.fileUUID = f%.id_global AND NOT p%.status = 'D'", sql)
        assert.is_string(SqliteCommand.readScript('C:\\a.lrcat', sql))
        assert.is_string(SqliteCommand.readScript('C:\\a.lrcat', CatalogRead.byIdSql({ 3, 4 })))
        assert.is_string(SqliteCommand.readScript('C:\\a.lrcat', CatalogRead.markSql()))
        assert.matches('WHERE i%.id_local IN %(3,4%);$', CatalogRead.byIdSql({ 3, 4 }))
        assert.is_nil(CatalogRead.newSql(-1))
        assert.is_nil(CatalogRead.newSql(1.5))
        assert.is_nil(CatalogRead.byIdSql({}))
        assert.is_nil(CatalogRead.byIdSql({ 0 }))
    end)
end)

describe('CatalogRead.parse', function()
    it('gives each photo its local path, file UUID, import, size and what Lightroom knows about it', function()
        local text = table.concat({
            photoLine({ id = '108878', proxies = '1' }),
            photoLine({}),
            photoLine({ id = '108879', master = '108877', import = '0', width = '0', height = '0' }),
            photoLine({ id = '108880', format = 'VIDEO', ext = 'MP4' }),
            'i|106106||' .. hex('2026-11-14T15:15:56.060+01:00') .. '||||0|0|0|0||0',
            'm|110260',
            'm|106106',
        }, '\n')
        local parsed, problems = CatalogRead.parse(text)
        assert.are.same({}, problems)
        assert.are.equal(4, #parsed.photos)
        local first = parsed.photos[1]
        assert.are.equal(108877, first.id)
        assert.are.equal(UUID:upper(), first.fileUuid)
        assert.are.equal('Z:/2026/2026.06.20 - shoot/', first.folder)
        assert.are.equal('IMG_0001.ARW', first.fileName)
        assert.are.equal('Z:\\2026\\2026.06.20 - shoot\\IMG_0001.ARW', first.path)
        assert.are.equal(106106, first.importId)
        assert.are.equal(6000, first.width)
        assert.are.equal(4000, first.height)
        assert.is_false(first.virtualCopy)
        assert.is_false(first.video)
        assert.is_false(first.hasSmartPreview)
        assert.is_nil(first.incomplete)
        assert.is_true(parsed.photos[2].hasSmartPreview)
        assert.is_true(parsed.photos[3].virtualCopy)
        assert.are.equal(0, parsed.photos[3].importId)
        assert.is_nil(parsed.photos[3].width)
        assert.is_true(parsed.photos[4].video)
        assert.are.same({ { id = 106106, date = '2026-11-14T15:15:56.060+01:00' } }, parsed.imports)
        assert.are.equal(110260, parsed.mark)
    end)

    it('reports photos whose rows are missing as incomplete, and a file id that is not a UUID', function()
        local parsed = CatalogRead.parse(photoLine({ uuid = '', root = '', folder = '', base = '', ext = '' }) .. '\n'
            .. photoLine({ id = '108990', uuid = 'not-a-uuid' }))
        assert.is_true(parsed.photos[1].incomplete)
        assert.is_nil(parsed.photos[1].path)
        assert.are.equal('not-a-uuid', parsed.photos[2].badUuid)
        assert.is_nil(parsed.photos[2].fileUuid)
    end)

    it('keeps a photo once, lists lines of another form, and copes with nothing', function()
        local parsed, problems = CatalogRead.parse(photoLine({}) .. '\n' .. photoLine({ import = '5' })
            .. '\nError: no such table\np|1|2')
        assert.are.equal(1, #parsed.photos)
        assert.are.equal(106106, parsed.photos[1].importId)
        assert.are.equal(2, #problems)
        local empty = CatalogRead.parse(nil)
        assert.are.same({ photos = {}, imports = {} }, { photos = empty.photos, imports = empty.imports })
        assert.is_nil(empty.mark)
    end)
end)

describe('CatalogRead paths', function()
    it('builds local paths for Windows drives, network shares and other systems', function()
        assert.are.equal('Z:\\a\\b.ARW', CatalogRead.localPath('Z:/a/', 'b.ARW'))
        assert.are.equal('\\\\nas\\photos\\x\\b.ARW', CatalogRead.localPath('//nas/photos/x/', 'b.ARW'))
        assert.are.equal('/Volumes/Photos/x/b.ARW', CatalogRead.localPath('/Volumes/Photos/x/', 'b.ARW'))
        assert.is_nil(CatalogRead.localPath('', 'b.ARW'))
        assert.are.equal('2026.06.20 - shoot', CatalogRead.folderName('Z:/2026/2026.06.20 - shoot/'))
        assert.are.equal('photos', CatalogRead.folderName('//nas/photos/'))
        assert.is_nil(CatalogRead.folderName('Z:/'))
        assert.is_nil(CatalogRead.folderName(nil))
    end)
end)
