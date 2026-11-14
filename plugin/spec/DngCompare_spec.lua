-- Find the plug-in's modules (and the spec helpers) relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. here .. '?.lua;' .. package.path

local DngCompare = require 'DngCompare'
local TestDng = require 'TestDng'

local TILES = { string.rep('\17', 50), string.rep('\34', 61), string.rep('\51', 7), string.rep('\68', 20) }

-- Lightroom's file and the server's, as different as two programs make them where that is expected.
local function lightroom(options)
    options = options or {}
    options.order = options.order or 'II'
    options.tiles = options.tiles or TILES
    return TestDng.full(options)
end

local function server(options)
    options = options or {}
    options.order = options.order or 'MM'
    options.tiles = options.tiles or TILES
    options.software = options.software or 'Adobe DNG Converter 17.2 (Windows)'
    options.dateTime = options.dateTime or '2026:11:14 10:00:00'
    options.xmp = options.xmp or '<x:xmpmeta>  <rdf:Description xmp:CreatorTool="Adobe DNG Converter 17.2" '
        .. 'xmpMM:DocumentID="xmp.did:2222"\n crs:HasSettings="False"/></x:xmpmeta>'
    options.thumbnail = options.thumbnail or string.rep('U', 70)
    options.uniqueId = options.uniqueId or string.rep('\3', 16)
    options.digest = options.digest or string.rep('\4', 16)
    return TestDng.full(options)
end

local function expectedRow(report, name)
    for _, row in ipairs(report.expected) do
        if row.name == name then
            return row
        end
    end
    return nil
end

local function joined(list)
    return table.concat(list, ' | ')
end

describe('DngCompare.compare', function()
    for _, orders in ipairs({ { 'II', 'MM' }, { 'MM', 'II' }, { 'II', 'II' } }) do
        it('finds identical image data and reports the expected differences (' .. orders[1] .. '/' .. orders[2]
            .. ')', function()
            local report = DngCompare.compare(lightroom({ order = orders[1] }), server({ order = orders[2] }))
            assert.are.equal('identical', report.verdict)
            assert.are.same({}, report.reasons)
            assert.are.same({ kind = 'tiles', total = 4, same = 4, differing = {} }, report.parts)
            assert.are.same({}, report.unexpected)
            assert.are.equal('info', DngCompare.style(report))
            assert.are.equal('Adobe Photoshop Lightroom Classic 15.6 (Windows)', report.software.lightroom)
            assert.are.equal('Adobe DNG Converter 17.2 (Windows)', report.software.server)
            for _, name in ipairs({ 'Software', 'DateTime', 'XMP', 'RawDataUniqueID', 'NewRawImageDigest',
                'thumbnail' }) do
                assert.is_false(expectedRow(report, name).same, name)
            end
            assert.are.equal('only in ids, dates and software versions', expectedRow(report, 'XMP').detail)
            assert.are.equal('64 and 70 bytes', expectedRow(report, 'thumbnail').detail)
            assert.matches('^Identical image data: all 4 tiles of the raw image are byte%-identical%.$',
                DngCompare.verdictLine(report))
        end)
    end

    it('reports what is the same as the same', function()
        local report = DngCompare.compare(lightroom(), lightroom({ order = 'MM' }))
        assert.are.equal('identical', report.verdict)
        for _, row in ipairs(report.expected) do
            assert.is_true(row.same, row.name)
        end
        local lines = joined(DngCompare.detailLines(report))
        assert.matches('DNGVersion, original file name and original size: the same %(1%.7%.0%.0, IMG_0001%.ARW, '
            .. '6000x4000%)', lines)
        assert.matches('Raw image, the same in both: NewSubFileType 0, width 2560, height 1707, bits per sample '
            .. '16 16 16, compression 52546', lines)
        assert.matches('layout tiles 4', lines)
        assert.matches('No other tag differs', lines)
    end)

    it('counts identical tiles when some differ', function()
        local tiles = { TILES[1], string.rep('\35', 61), TILES[3], string.rep('\69', 21) }
        local report = DngCompare.compare(lightroom(), server({ tiles = tiles }))
        assert.are.equal('tilesDiffer', report.verdict)
        assert.are.equal(2, report.parts.same)
        assert.are.same({ 2, 4 }, report.parts.differing)
        assert.are.equal('warning', DngCompare.style(report))
        assert.are.equal('2 of 4 tiles identical: the raw image has the same structure, but 2 tiles (tiles 2, 4) '
            .. 'differ.', DngCompare.verdictLine(report))
        local one = DngCompare.compare(lightroom(), server({ tiles = { TILES[1], TILES[2], 'x', TILES[4] } }))
        assert.are.equal('3 of 4 tiles identical: the raw image has the same structure, but 1 tile (tile 3) differs.',
            DngCompare.verdictLine(one))
    end)

    it('calls another structure different', function()
        local cases = {
            { { tileWidth = 256 }, 'tile width is 368 in Lightroom\'s file and 256 in the server\'s' },
            { { compression = 7 }, 'compression is 52546 in Lightroom\'s file and 7 in the server\'s' },
            { { imageWidth = 2048 }, 'width is 2560' },
            { { bits = { 8, 8, 8 } }, 'bits per sample is 16 16 16 in Lightroom\'s file and 8 8 8' },
            { { tiles = { TILES[1], TILES[2], TILES[3] } }, 'stored as tiles 4 in Lightroom\'s file and as tiles 3' },
            { { layout = 'strips' }, 'stored as tiles 4 in Lightroom\'s file and as strips 4' },
        }
        for _, case in ipairs(cases) do
            local report = DngCompare.compare(lightroom(), server(case[1]))
            assert.are.equal('different', report.verdict)
            assert.matches(case[2], joined(report.reasons), 1, true)
            assert.are.equal('critical', DngCompare.style(report))
            assert.matches('^Different structure: ', DngCompare.verdictLine(report))
        end
    end)

    it('calls a different identity different', function()
        local cases = {
            { { name = 'IMG_0002.ARW' }, 'OriginalRawFileName is IMG_0001.ARW in Lightroom\'s file and IMG_0002.ARW' },
            { { width = 4000, height = 6000 }, 'OriginalDefaultFinalSize is 6000x4000' },
            { { version = { 1, 6, 0, 0 } }, 'DNGVersion is 1.7.0.0 in Lightroom\'s file and 1.6.0.0' },
        }
        for _, case in ipairs(cases) do
            local report = DngCompare.compare(lightroom(), server(case[1]))
            assert.are.equal('different', report.verdict)
            assert.matches(case[2], joined(report.reasons), 1, true)
        end
    end)

    it('calls a file without a raw image directory different', function()
        local report = DngCompare.compare(lightroom(), server({ noRaw = true }))
        assert.are.equal('different', report.verdict)
        assert.matches('the server\'s file: no raw image directory', joined(report.reasons), 1, true)
    end)

    it('does not compare a truncated file or one that is not a DNG', function()
        local data = server()
        local report = DngCompare.compare(lightroom(), data:sub(1, #data - 10))
        assert.are.equal('unreadable', report.verdict)
        assert.matches('the server\'s file: tile 4 of 4 lies outside the file', joined(report.reasons), 1, true)
        assert.are.equal('critical', DngCompare.style(report))
        assert.matches('^Not compared: ', DngCompare.verdictLine(report))
        report = DngCompare.compare('<html>not found</html>', server())
        assert.are.equal('unreadable', report.verdict)
        assert.matches('Lightroom\'s smart preview is not a readable DNG', joined(report.reasons), 1, true)
        report = DngCompare.compare(lightroom(), nil)
        assert.are.equal('unreadable', report.verdict)
        assert.are.equal(0, report.sizes.server)
    end)

    it('lists other tags that differ without changing the verdict', function()
        local report = DngCompare.compare(lightroom({ extraIfd0 = { TestDng.entry('II', 0xC621, 10, { 1, 2 }) },
            extraRaw = { TestDng.entry('II', 0xC61D, 4, { 65535 }) } }),
            server({ extraIfd0 = { TestDng.entry('MM', 0xC621, 10, { 1, 3 }) },
                extraRaw = { TestDng.entry('MM', 0xC61D, 4, { 4095 }) } }))
        assert.are.equal('identical', report.verdict)
        assert.are.same({ 'ColorMatrix1', 'WhiteLevel (raw image)' }, report.unexpected)
        assert.are.equal('warning', DngCompare.style(report))
        assert.matches('Other tags that differ %(not expected; worth a look%): ColorMatrix1, WhiteLevel %(raw image%)',
            joined(DngCompare.detailLines(report)))
        local only = DngCompare.compare(lightroom({ extraIfd0 = { TestDng.entry('II', 0xC634, 7, 'Adobe\0MakN') } }),
            server())
        assert.are.same({ 'DNGPrivateData' }, only.unexpected)
    end)

    it('takes rationals with other denominators as the same value', function()
        local report = DngCompare.compare(lightroom({ extraIfd0 = { TestDng.entry('II', 0xC62A, 10, { 35, 100 }) } }),
            server({ extraIfd0 = { TestDng.entry('MM', 0xC62A, 10, { 7, 20 }) } }))
        assert.are.same({}, report.unexpected)
    end)

    it('lists an XMP packet that differs in other properties as unexpected', function()
        local report = DngCompare.compare(lightroom(), server({ xmp = '<x:xmpmeta><rdf:Description '
            .. 'xmp:CreatorTool="Adobe DNG Converter 17.2" crs:HasSettings="True"/></x:xmpmeta>' }))
        assert.are.equal('identical', report.verdict)
        assert.are.equal('also in other properties', expectedRow(report, 'XMP').detail)
        assert.are.same({ 'XMP (other properties than ids, dates and versions)' }, report.unexpected)
    end)
end)

describe('DngCompare.normalizeXmp', function()
    it('drops the tool, the dates, the ids, the version and the history', function()
        local normalize = DngCompare.normalizeXmp
        local a = '<x:xmpmeta>\n <rdf:Description xmp:CreatorTool="Lightroom" xmp:ModifyDate="2026-11-14T09:30"\n'
            .. '   xmpMM:DocumentID="xmp.did:1" xmpMM:InstanceID="xmp.iid:1" crs:Version="18.0"'
            .. ' crs:HasSettings="False"><xmpMM:History><rdf:Seq><rdf:li stEvt:action="saved"/></rdf:Seq>'
            .. '</xmpMM:History><xmpMM:DerivedFrom stRef:documentID="x"/></rdf:Description></x:xmpmeta>\0\0'
        local b = '<x:xmpmeta> <rdf:Description crs:HasSettings="False"></rdf:Description></x:xmpmeta>'
        assert.are.equal(normalize(b), normalize(a))
        assert.are_not.equal(normalize(b), normalize((b:gsub('False', 'True'))))
        assert.are.equal(normalize('<a>\n  <b x="1"\n  /> </a>'), normalize('<a><b x="1"/></a>'))
        assert.are_not.equal(normalize('<a>x y</a>'), normalize('<a>xy</a>'))
    end)
end)
