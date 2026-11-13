-- Find the plug-in's modules (and the spec helpers) relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. here .. '?.lua;' .. package.path

local Delivery = require 'Delivery'
local TestDng = require 'TestDng'

local DEST = 'C:\\Photos\\Main\\Main Smart Previews.lrdata\\6\\6282\\62823DFE-E7D3-40FF-938C-518FDECC6CF6.dng'
local FOLDER = 'C:\\Photos\\Main\\Main Smart Previews.lrdata\\6\\6282'

-- An in-memory file system with the operations Delivery uses. files: path -> content; folders: path -> true.
local function fakeFs(options)
    options = options or {}
    local fs = { files = {}, folders = {}, calls = {}, answer = options.answer or 'existed' }
    for path, content in pairs(options.files or {}) do
        fs.files[path] = content
    end
    for _, folder in ipairs(options.folders or {}) do
        fs.folders[folder] = true
    end
    local function log(name, path)
        fs.calls[#fs.calls + 1] = name .. ' ' .. path
    end
    function fs.exists(path)
        return fs.files[path] ~= nil or fs.folders[path] == true
    end
    function fs.makeFolder(path)
        log('makeFolder', path)
        if options.noFolder then
            return false, 'access denied'
        end
        fs.folders[path] = true
        return true
    end
    function fs.writeFile(path, data)
        log('writeFile', path)
        if options.writeFails then
            return false, 'disk full'
        end
        fs.files[path] = data
        if options.raceOnWrite then
            fs.files[DEST] = 'made by someone else'
        end
        return true
    end
    function fs.move(from, to)
        log('move', from .. ' -> ' .. to)
        if options.moveFails or fs.files[to] then
            return false, 'cannot move'
        end
        fs.files[to], fs.files[from] = fs.files[from], nil
        return true
    end
    function fs.delete(path)
        log('delete', path)
        fs.files[path] = nil
        return true
    end
    function fs.buildSmartPreview()
        log('buildSmartPreview', '')
        if fs.answer == 'raise' then
            return false, 'boom'
        end
        return true, fs.answer
    end
    return fs
end

local function dng(name, width, height, tail)
    return TestDng.make({ order = 'MM', name = name, width = width, height = height, tail = tail })
end

local target = { fileName = 'IMG_0001.ARW', width = 6000, height = 4000, dest = DEST }

describe('Delivery.verify', function()
    it('accepts the right file and says whether the size was checked', function()
        local body = dng('IMG_0001.ARW', 6000, 4000)
        local facts = Delivery.verify(body, { size = #body }, target)
        assert.are.same({ dngVersion = '1.7.0.0', originalName = 'IMG_0001.ARW', originalWidth = 6000,
            originalHeight = 4000, dimensionsChecked = true }, facts)
    end)

    it('compares names without regard to case and sizes in either orientation', function()
        local body = dng('img_0001.arw', 4000, 6000)
        assert.is_true(Delivery.verify(body, { size = #body }, target).dimensionsChecked)
    end)

    it('skips the size check when either side does not know it', function()
        local noTag = dng('IMG_0001.ARW')
        assert.is_false(Delivery.verify(noTag, { size = #noTag }, target).dimensionsChecked)
        local body = dng('IMG_0001.ARW', 1, 1)
        assert.is_false(Delivery.verify(body, { size = #body }, { fileName = 'IMG_0001.ARW' }).dimensionsChecked)
    end)

    it('rejects every mismatch with a reason', function()
        local right = dng('IMG_0001.ARW', 6000, 4000)
        local cases = {
            { right, { size = #right + 1 }, 'bytes' },
            { right, {}, 'no file size' },
            { right, false, 'no file size' }, -- false stands for "no result at all"
            { '<html>gateway</html>', { size = 20 }, 'not a readable DNG' },
            { dng('IMG_0002.ARW', 6000, 4000), nil, 'IMG_0002.ARW' },
            { dng('IMG_0001.ARW', 6000, 3376), nil, '6000x3376' },
            { dng(nil, 6000, 4000), nil, 'no original file name' },
            { TestDng.make({ name = 'IMG_0001.ARW', version = false }), nil, 'DNGVersion' },
            { TestDng.make({ name = '', width = 6000, height = 4000 }), nil, 'no original file name' },
        }
        for _, case in ipairs(cases) do
            local result = case[2]
            if result == nil then
                result = { size = #case[1] }
            elseif result == false then
                result = nil
            end
            local facts, reason = Delivery.verify(case[1], result, target)
            assert.is_nil(facts)
            assert.matches(case[3], reason, 1, true)
        end
        assert.matches('no file content', select(2, Delivery.verify(nil, { size = 1 }, target)))
    end)
end)

describe('Delivery.splitPath', function()
    it('splits on either slash', function()
        assert.are.same({ FOLDER, '62823DFE-E7D3-40FF-938C-518FDECC6CF6.dng', '\\' }, { Delivery.splitPath(DEST) })
        assert.are.same({ '/a/b', 'c.dng', '/' }, { Delivery.splitPath('/a/b/c.dng') })
        assert.is_nil(Delivery.splitPath('c.dng'))
    end)
end)

describe('Delivery.place', function()
    local body = 'DNG BYTES'
    local temp = DEST .. '.lrrp-1-7.tmp'

    it('creates the folder, writes a temporary file and renames it', function()
        local fs = fakeFs()
        assert.are.equal('placed', Delivery.place(DEST, body, fs, 'lrrp-1-7'))
        assert.are.equal(body, fs.files[DEST])
        assert.is_nil(fs.files[temp])
        assert.are.same({ 'makeFolder ' .. FOLDER, 'writeFile ' .. temp, 'move ' .. temp .. ' -> ' .. DEST }, fs.calls)
    end)

    it('never touches an existing file', function()
        local fs = fakeFs({ files = { [DEST] = 'original' }, folders = { FOLDER } })
        assert.are.equal('destinationExists', Delivery.place(DEST, body, fs, 'lrrp-1-7'))
        assert.are.equal('original', fs.files[DEST])
        assert.are.same({}, fs.calls)
    end)

    it('drops its temporary file when the destination appears meanwhile', function()
        local fs = fakeFs({ folders = { FOLDER }, raceOnWrite = true })
        assert.are.equal('destinationExists', Delivery.place(DEST, body, fs, 'lrrp-1-7'))
        assert.are.equal('made by someone else', fs.files[DEST])
        assert.is_nil(fs.files[temp])
    end)

    it('reports write, folder and rename failures and leaves nothing behind', function()
        for _, options in ipairs({ { writeFails = true }, { noFolder = true }, { moveFails = true } }) do
            local fs = fakeFs(options)
            local outcome, message = Delivery.place(DEST, body, fs, 'lrrp-1-7')
            assert.are.equal('writeFailed', outcome)
            assert.is_string(message)
            assert.is_nil(fs.files[DEST])
            assert.is_nil(fs.files[temp])
        end
    end)

    it('refuses to reuse an existing temporary name', function()
        local fs = fakeFs({ files = { [temp] = 'left over' }, folders = { FOLDER } })
        assert.are.equal('writeFailed', (Delivery.place(DEST, body, fs, 'lrrp-1-7')))
        assert.are.equal('left over', fs.files[temp])
    end)
end)

describe('Delivery.deliver', function()
    local body = dng('IMG_0001.ARW', 6000, 4000, string.rep('\0', 64))

    it('places the file and asks Lightroom to register it', function()
        local fs = fakeFs()
        local outcome, detail = Delivery.deliver(target, { size = #body }, body, fs, 't')
        assert.are.equal('delivered', outcome)
        assert.are.equal('DNG 1.7.0.0', detail)
        assert.are.equal(body, fs.files[DEST])
        assert.are.equal('buildSmartPreview ', fs.calls[#fs.calls])
    end)

    it('reports any other answer from Lightroom', function()
        local outcome, detail = Delivery.deliver(target, { size = #body }, body, fakeFs({ answer = 'created' }), 't')
        assert.are.equal('deliveredOther', outcome)
        assert.matches("answered 'created'", detail)
        local raised, why = Delivery.deliver(target, { size = #body }, body, fakeFs({ answer = 'raise' }), 't')
        assert.are.equal('deliveredOther', raised)
        assert.matches('boom', why)
    end)

    it('notes an unchecked size', function()
        local _, detail = Delivery.deliver({ fileName = 'IMG_0001.ARW', dest = DEST }, { size = #body }, body,
            fakeFs(), 't')
        assert.matches('original size not checked', detail)
    end)

    it('discards a file that fails the check without writing anything', function()
        local wrong = dng('IMG_0002.ARW', 6000, 4000)
        local fs = fakeFs()
        local outcome, detail = Delivery.deliver(target, { size = #wrong }, wrong, fs, 't')
        assert.are.equal('checkFailed', outcome)
        assert.matches('IMG_0002.ARW', detail)
        assert.are.same({}, fs.calls)
    end)

    it('does not call Lightroom when the destination exists', function()
        local fs = fakeFs({ files = { [DEST] = 'x' } })
        assert.are.equal('destinationExists', (Delivery.deliver(target, { size = #body }, body, fs, 't')))
        assert.are.same({}, fs.calls)
    end)
end)
