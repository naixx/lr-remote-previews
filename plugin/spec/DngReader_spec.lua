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
end)
