-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local SmartPreviewPath = require 'SmartPreviewPath'

local UUID = '62823DFE-E7D3-40FF-938C-518FDECC6CF6'

describe('SmartPreviewPath', function()
    describe('on Windows', function()
        it('builds the documented example', function()
            assert.are.equal(
                'C:\\Photos\\Main\\Main Smart Previews.lrdata\\6\\6282\\62823DFE-E7D3-40FF-938C-518FDECC6CF6.dng',
                SmartPreviewPath.dngPath('C:\\Photos\\Main\\Main.lrcat', UUID))
        end)

        it('builds the store folder', function()
            assert.are.equal('C:\\Photos\\Main\\Main Smart Previews.lrdata',
                SmartPreviewPath.storeFolder('C:\\Photos\\Main\\Main.lrcat'))
            assert.are.equal('\\', SmartPreviewPath.separator('C:\\Photos\\Main\\Main.lrcat'))
        end)

        it('handles a catalog in a drive root', function()
            assert.are.equal('C:\\Main Smart Previews.lrdata\\6\\6282\\' .. UUID .. '.dng',
                SmartPreviewPath.dngPath('C:\\Main.lrcat', UUID))
        end)

        it('turns forward slashes into backslashes', function()
            assert.are.equal('C:\\Photos\\Main\\Main Smart Previews.lrdata\\6\\6282\\' .. UUID .. '.dng',
                SmartPreviewPath.dngPath('C:/Photos/Main/Main.lrcat', UUID))
        end)

        it('handles a UNC catalog path', function()
            assert.are.equal('\\\\nas\\lr\\Main Smart Previews.lrdata\\6\\6282\\' .. UUID .. '.dng',
                SmartPreviewPath.dngPath('\\\\nas\\lr\\Main.lrcat', UUID))
        end)

        it('keeps spaces and dots in the base name and accepts an upper-case extension', function()
            assert.are.equal('D:\\LR\\My Catalog v13.2 Smart Previews.lrdata',
                SmartPreviewPath.storeFolder('D:\\LR\\My Catalog v13.2.LRCAT'))
        end)
    end)

    describe('on POSIX systems', function()
        it('uses forward slashes', function()
            assert.are.equal('/Volumes/Photos/Main/Main Smart Previews.lrdata/6/6282/' .. UUID .. '.dng',
                SmartPreviewPath.dngPath('/Volumes/Photos/Main/Main.lrcat', UUID))
            assert.are.equal('/', SmartPreviewPath.separator('/Volumes/Photos/Main/Main.lrcat'))
        end)

        it('handles a catalog in the file system root', function()
            assert.are.equal('/Main Smart Previews.lrdata', SmartPreviewPath.storeFolder('/Main.lrcat'))
        end)
    end)

    describe('UUIDs', function()
        it('upper-cases a lower-case UUID', function()
            assert.are.equal('/c/Main Smart Previews.lrdata/6/6282/' .. UUID .. '.dng',
                SmartPreviewPath.dngPath('/c/Main.lrcat', UUID:lower()))
            assert.are.equal(UUID, SmartPreviewPath.normalizeUuid(UUID:lower()))
        end)

        it('validates the format', function()
            assert.is_true(SmartPreviewPath.isValidUuid(UUID))
            assert.is_true(SmartPreviewPath.isValidUuid(UUID:lower()))
            local bad = {
                nil, 42, '', '62823DFE',
                '62823DFEE7D340FF938C518FDECC6CF6',
                '{62823DFE-E7D3-40FF-938C-518FDECC6CF6}',
                ' 62823DFE-E7D3-40FF-938C-518FDECC6CF6',
                '62823DFE-E7D3-40FF-938C-518FDECC6CF6 ',
                '62823DFG-E7D3-40FF-938C-518FDECC6CF6',
                '62823DF-EE7D3-40FF-938C-518FDECC6CF6',
                '62823DFE-E7D3-40FF-938C-518FDECC6CF6.dng',
            }
            for i = 1, 11 do
                assert.is_false(SmartPreviewPath.isValidUuid(bad[i]))
            end
        end)

        it('returns nil and a message for an invalid UUID', function()
            local path, message = SmartPreviewPath.dngPath('C:\\Photos\\Main.lrcat', 'not-a-uuid')
            assert.is_nil(path)
            assert.matches('UUID', message)
        end)
    end)

    describe('bad catalog paths', function()
        it('returns nil and a message', function()
            local cases = { nil, '', 'Main.lrcat', 'C:\\Photos\\Main.lrdata', 'C:\\Photos\\', '/a/.lrcat', 42 }
            for i = 1, 7 do
                local folder, message = SmartPreviewPath.storeFolder(cases[i])
                assert.is_nil(folder)
                assert.is_string(message)
                assert.is_nil(SmartPreviewPath.dngPath(cases[i], UUID))
            end
        end)
    end)
end)
