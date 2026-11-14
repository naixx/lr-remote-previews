-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local FileIds = require 'FileIds'

local CATALOG = 'C:\\Photos\\Main\\Main.lrcat'
local U1 = '62823DFE-E7D3-40FF-938C-518FDECC6CF6'
local U2 = '11111111-2222-3333-4444-555555555555'

local function row(uuid, baseName, extension)
    return { fileUuid = uuid, baseName = baseName, extension = extension }
end

describe('FileIds', function()
    it('lists the catalog ids that are there', function()
        assert.are.same({ 3, 9 }, FileIds.ids({ { localId = 3 }, {}, { localId = 9 } }))
    end)

    it('gives every matching photo its smart preview path and a running ref', function()
        local photos = {
            { fileName = 'IMG_0001.ARW', localId = 1 },
            { fileName = 'img_0002.arw', localId = 2 },
        }
        local result = FileIds.assign(photos, { [1] = row(U1, 'IMG_0001', 'ARW'), [2] = row(U2, 'IMG_0002', 'ARW') },
            CATALOG)
        assert.are.equal(2, #result.entries)
        assert.are.same({}, result.skipped)
        assert.are.equal('C:\\Photos\\Main\\Main Smart Previews.lrdata\\6\\6282\\' .. U1 .. '.dng', photos[1].dest)
        assert.are.equal(U1, photos[1].fileUuid)
        assert.are.equal('1', photos[1].ref)
        assert.are.equal('2', photos[2].ref)
    end)

    it('leaves out photos without an id, without a row, with another file name or with the same file', function()
        local photos = {
            { fileName = 'IMG_0001.ARW' },
            { fileName = 'IMG_0002.ARW', localId = 2 },
            { fileName = 'IMG_0003.ARW', localId = 3 },
            { fileName = 'IMG_0004.ARW', localId = 4 },
            { fileName = 'IMG_0004.ARW', localId = 5 },
            { fileName = 'IMG_0006.ARW', localId = 6 },
        }
        local result = FileIds.assign(photos, {
            [3] = row(U1, 'IMG_0099', 'ARW'),
            [4] = row(U2, 'IMG_0004', 'ARW'),
            [5] = row(U2, 'IMG_0004', 'ARW'),
            [6] = row('not-a-uuid', 'IMG_0006', 'ARW'),
        }, CATALOG)
        local reasons = {}
        for i, skipped in ipairs(result.skipped) do
            reasons[i] = skipped.reason
        end
        assert.are.same({ 'noLocalId', 'noFileId', 'fileIdMismatch', 'sameFile', 'noFileId' }, reasons)
        assert.are.equal('catalog id 2', result.skipped[2].detail)
        assert.matches('names "IMG_0099.ARW" for catalog id 3', result.skipped[3].detail, 1, true)
        assert.are.equal('IMG_0004.ARW', result.skipped[4].detail)
        assert.are.equal(1, #result.entries)
        assert.are.equal('1', photos[4].ref)
    end)
end)
