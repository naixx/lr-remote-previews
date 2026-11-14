-- Find the plug-in's modules (and the spec helpers) relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. here .. '?.lua;' .. package.path

local DngReader = require 'DngReader'
local TestDng = require 'TestDng'

describe('DngReader.read', function()
    for _, order in ipairs({ 'II', 'MM' }) do
        describe('byte order ' .. order, function()
            it('reads the version, the original name and the original size (LONG)', function()
                local data = TestDng.make({ order = order, name = 'IMG_0001.ARW', width = 6000, height = 4000 })
                assert.are.same({
                    byteOrder = order,
                    dngVersion = '1.7.0.0',
                    originalRawFileName = 'IMG_0001.ARW',
                    originalWidth = 6000,
                    originalHeight = 4000,
                }, DngReader.read(data))
            end)

            it('reads the size as SHORTs (inline) and a name of type ASCII', function()
                local data = TestDng.make({ order = order, name = 'DSC01234.ARW', nameType = 2, width = 4000,
                    height = 6000, sizeType = 3 })
                local info = DngReader.read(data)
                assert.are.equal('DSC01234.ARW', info.originalRawFileName)
                assert.are.equal(4000, info.originalWidth)
                assert.are.equal(6000, info.originalHeight)
            end)

            it('reads a short name stored inside the entry', function()
                local info = DngReader.read(TestDng.make({ order = order, name = 'a.b' }))
                assert.are.equal('a.b', info.originalRawFileName)
            end)

            it('reads large values and keeps non-ASCII names as bytes', function()
                local name = 'Caf\195\169 100.CR3'
                local info = DngReader.read(TestDng.make({ order = order, name = name, width = 70000, height = 65536,
                    tail = string.rep('\0', 1000) }))
                assert.are.equal(name, info.originalRawFileName)
                assert.are.equal(70000, info.originalWidth)
                assert.are.equal(65536, info.originalHeight)
            end)

            it('leaves out what the file does not have', function()
                local info = DngReader.read(TestDng.make({ order = order, version = false }))
                assert.are.same({ byteOrder = order }, info)
            end)
        end)
    end

    it('stops the name at the first NUL', function()
        local text = 'IMG_0002.ARW\0junk\0'
        local data = TestDng.tiff('II', { { tag = 0xC68B, type = 1, count = #text, data = text } })
        assert.are.equal('IMG_0002.ARW', DngReader.read(data).originalRawFileName)
    end)

    it('rejects what is not a TIFF', function()
        assert.is_nil(DngReader.read(nil))
        local cases = {
            '',
            'II*',
            'XX*\0\8\0\0\0\0\0',
            'II\43\0\8\0\0\0\0\0', -- magic 43
            'II*\0\200\0\0\0\0\0', -- IFD offset beyond the end
            'II*\0\8\0\0\0\0\0', -- no entries
            'II*\0\8\0\0\0\5\0\0\0', -- 5 entries announced, none there
            '<html>not found</html>',
        }
        for _, case in ipairs(cases) do
            local info, message = DngReader.read(case)
            assert.is_nil(info)
            assert.is_string(message)
        end
    end)

    it('rejects a tag that points outside the file', function()
        local entry = { tag = 0xC68B, type = 2, count = 100, data = string.rep('x', 100) }
        local data = TestDng.tiff('II', { entry })
        local info, message = DngReader.read(data:sub(1, #data - 50))
        assert.is_nil(info)
        assert.matches('outside', message)
    end)

    it('rejects tags with a type or count the DNG specification does not allow', function()
        local u16, u32 = TestDng.u16, TestDng.u32
        local cases = {
            { tag = 0xC612, type = 3, count = 2, data = u16('II', 1) .. u16('II', 7) }, -- DNGVersion as SHORTs
            { tag = 0xC612, type = 1, count = 3, data = '\1\7\0' },
            { tag = 0xC68B, type = 3, count = 2, data = u16('II', 65) .. u16('II', 0) }, -- name as SHORTs
            { tag = 0xC791, type = 4, count = 1, data = u32('II', 6000) }, -- one value
            { tag = 0xC791, type = 5, count = 2, data = string.rep('\1', 16) }, -- RATIONAL
            { tag = 0xC791, type = 99, count = 2, data = '\0\0\0\0' }, -- unknown type
        }
        for _, entry in ipairs(cases) do
            local info, message = DngReader.read(TestDng.tiff('II', { entry }))
            assert.is_nil(info)
            assert.is_string(message)
        end
    end)

    it('still reads the identity of a full DNG', function()
        local info = DngReader.read(TestDng.full({ order = 'MM', tiles = { 'ab', 'cd' }, name = 'DSC0001.ARW' }))
        assert.are.equal('DSC0001.ARW', info.originalRawFileName)
        assert.are.equal(6000, info.originalWidth)
    end)
end)

describe('DngReader.parse', function()
    local tiles = { string.rep('a', 37), string.rep('b', 40), string.rep('c', 3) }

    for _, order in ipairs({ 'II', 'MM' }) do
        it('finds IFD0, the raw image directory and its tiles (' .. order .. ')', function()
            local parsed = assert(DngReader.parse(TestDng.full({ order = order, tiles = tiles })))
            assert.are.equal(order, parsed.byteOrder)
            assert.is_nil(parsed.rawProblem)
            assert.are.equal('Adobe Photoshop Lightroom Classic 15.6 (Windows)',
                DngReader.text(parsed, parsed.ifd0.byTag[0x0131]))
            assert.are.same({ 16, 16, 16 }, DngReader.numbers(parsed, parsed.raw.byTag[0x0102]))
            assert.are.same({ 52546 }, DngReader.numbers(parsed, parsed.raw.byTag[0x0103]))
            local parts = assert(DngReader.imageParts(parsed, parsed.raw))
            assert.are.equal('tiles', parts.kind)
            assert.are.equal(3, #parts.offsets)
            for i, tile in ipairs(tiles) do
                assert.are.equal(tile, DngReader.partBytes(parsed, parts, i))
            end
            local thumbnail = assert(DngReader.imageParts(parsed, parsed.ifd0))
            assert.are.equal('strips', thumbnail.kind)
            assert.are.equal(string.rep('T', 64), DngReader.partBytes(parsed, thumbnail, 1))
        end)
    end

    it('reads strips as the raw image data too', function()
        local parsed = DngReader.parse(TestDng.full({ tiles = tiles, layout = 'strips' }))
        local parts = assert(DngReader.imageParts(parsed, parsed.raw))
        assert.are.equal('strips', parts.kind)
        assert.are.equal(tiles[2], DngReader.partBytes(parsed, parts, 2))
    end)

    it('compares values across byte orders, and rationals by their value', function()
        local function file(order, num, den)
            return assert(DngReader.parse(TestDng.full({ order = order, tiles = tiles, extraIfd0 = {
                TestDng.entry(order, 0xC62A, 10, { num, den }),
                TestDng.entry(order, 0xC621, 10, { -3, 10, 7, 10, 1, 1 }),
            } })))
        end
        local a, b, c = file('II', 35, 100), file('MM', 7, 20), file('MM', 36, 100)
        local function same(x, y, tag)
            return DngReader.sameValue(x, x.ifd0.byTag[tag], y, y.ifd0.byTag[tag])
        end
        assert.is_true(same(a, b, 0xC62A))
        assert.is_false(same(a, c, 0xC62A))
        assert.is_true(same(a, b, 0xC621))
        assert.is_true(same(a, b, 0xC791)) -- LONGs in two byte orders
        assert.is_true(same(a, b, 0x0131)) -- text
        local short = assert(DngReader.parse(TestDng.tiff('II', { TestDng.entry('II', 0x0100, 3, { 2560 }) })))
        local long = assert(DngReader.parse(TestDng.tiff('MM', { TestDng.entry('MM', 0x0100, 4, { 2560 }) })))
        assert.is_true(DngReader.sameValue(short, short.ifd0.byTag[0x0100], long, long.ifd0.byTag[0x0100]))
    end)

    it('reports a missing raw image directory instead of failing', function()
        local parsed = assert(DngReader.parse(TestDng.full({ tiles = tiles, noRaw = true })))
        assert.is_nil(parsed.raw)
        assert.matches('no raw image directory', parsed.rawProblem)
    end)

    it('finds tiles that lie outside a truncated file', function()
        local data = TestDng.full({ tiles = tiles })
        local parsed = assert(DngReader.parse(data:sub(1, #data - 2)))
        local parts, message = DngReader.imageParts(parsed, parsed.raw)
        assert.is_nil(parts)
        assert.matches('tile 3 of 3 lies outside the file', message)
    end)

    it('rejects what has no readable IFD0', function()
        for _, case in ipairs({ '', 'II*\0\200\0\0\0\0\0', '<html>not found</html>' }) do
            local parsed, message = DngReader.parse(case)
            assert.is_nil(parsed)
            assert.is_string(message)
        end
        local entry = { tag = 0x02BC, type = 7, count = 100, data = string.rep('x', 100) }
        local data = TestDng.tiff('II', { entry })
        local parsed, message = DngReader.parse(data:sub(1, #data - 50))
        assert.is_nil(parsed)
        assert.matches('points outside the file', message)
    end)
end)
