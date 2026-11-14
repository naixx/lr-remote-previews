-- Find the plug-in's modules (and the spec helpers) relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. here .. '?.lua;' .. package.path

local CompatCheck = require 'CompatCheck'
local DngCompare = require 'DngCompare'
local TestDng = require 'TestDng'

local OPTIONS = {
    extensions = { '.arw', '.cr2' },
    mappings = { { localPrefix = 'Z:\\', rootId = 'archive' }, { localPrefix = 'Y:\\', rootId = 'offline' } },
    availableRoots = { archive = true },
}

local function photo(values)
    local p = { fileName = 'IMG_0001.ARW', path = 'Z:\\2026\\IMG_0001.ARW', isVideo = false, isVirtualCopy = false,
        smartPreviewPath = 'C:\\Photos\\Main\\Main Smart Previews.lrdata\\6\\6282\\62823DFE.dng' }
    for key, value in pairs(values or {}) do
        p[key] = value
    end
    return p
end

local KEY = string.rep('ab', 32)

describe('CompatCheck.target', function()
    it('maps a raw photo with a smart preview to its root and path', function()
        assert.are.same({ rootId = 'archive', relativePath = '2026/IMG_0001.ARW' },
            CompatCheck.target(photo(), OPTIONS))
        assert.are.same({ rootId = 'archive', relativePath = '2026/IMG_0001.ARW' },
            CompatCheck.target(photo({ isVirtualCopy = true }), OPTIONS))
    end)

    it('refuses a photo without a smart preview and says how to get one', function()
        for _, missing in ipairs({ 'none', '' }) do
            local p = photo()
            p.smartPreviewPath = missing ~= 'none' and missing or nil
            local target, message = CompatCheck.target(p, OPTIONS)
            assert.is_nil(target)
            assert.matches('IMG_0001.ARW has no smart preview', message, 1, true)
            assert.matches('Library > Previews > Build Smart Previews', message, 1, true)
            assert.matches('never builds, changes or deletes a smart preview itself', message, 1, true)
        end
    end)

    it('refuses what the server cannot build, with the reason', function()
        local cases = {
            { { isVideo = true }, 'is a video' },
            { { path = '' }, 'no file path' },
            { { path = 'Z:\\2026\\IMG_0001.JPG', fileName = 'IMG_0001.JPG' }, 'does not take .jpg files (it takes '
                .. '.arw, .cr2)' },
            { { path = 'X:\\IMG_0001.ARW' }, 'is not under any local prefix' },
            { { path = 'Y:\\IMG_0001.ARW' }, 'in the server root "offline", which the server does not list' },
        }
        for _, case in ipairs(cases) do
            local target, message = CompatCheck.target(photo(case[1]), OPTIONS)
            assert.is_nil(target)
            assert.matches(case[2], message, 1, true)
        end
    end)

    it('does not change the photo it was given', function()
        local p = photo()
        CompatCheck.target(p, OPTIONS)
        assert.is_string(p.smartPreviewPath)
        assert.is_nil(p.rootId)
    end)
end)

describe('CompatCheck.afterLookup', function()
    it('downloads what the server has', function()
        local result = { key = KEY, size = 1000 }
        assert.are.same({ action = 'download', result = result },
            CompatCheck.afterLookup({ state = 'ready', result = result }, true))
        assert.is_nil(CompatCheck.afterLookup({ state = 'ready', result = { key = 'x', size = 1 } }, true))
        assert.is_nil(CompatCheck.afterLookup({ state = 'ready', result = { key = KEY } }, true))
    end)

    it('builds what the server does not have, when it can', function()
        assert.are.same({ action = 'build' }, CompatCheck.afterLookup({ state = 'absent' }, true))
        assert.are.same({ action = 'build' }, CompatCheck.afterLookup({ state = 'pending' }, true))
        local decision, message = CompatCheck.afterLookup({ state = 'absent' }, false)
        assert.is_nil(decision)
        assert.matches('Adobe DNG Converter is not installed', message)
    end)

    it('stops on a refusal or no answer', function()
        local decision, message = CompatCheck.afterLookup({ state = 'rejected',
            error = { code = 'not_found', message = 'no such file' } }, true)
        assert.is_nil(decision)
        assert.are.equal('The server refused the photo (not_found: no such file).', message)
        assert.is_nil(CompatCheck.afterLookup(nil, true))
    end)
end)

describe('CompatCheck.afterJob', function()
    it('downloads a ready item and explains the others', function()
        local result = { key = KEY, size = 10 }
        assert.are.same({ action = 'download', result = result, itemId = 7 },
            CompatCheck.afterJob({ id = 7, state = 'ready', result = result }))
        local cases = {
            { { state = 'failed', error = { code = 'converter_failed' } },
                'could not build the photo (converter_failed)' },
            { { state = 'rejected', error = { code = 'not_found' } }, 'refused the photo (not_found)' },
            { { state = 'cancelled' }, 'cancelled' },
            { { state = 'ready', result = {} }, 'no file size' },
        }
        for _, case in ipairs(cases) do
            local decision, message = CompatCheck.afterJob(case[1])
            assert.is_nil(decision)
            assert.matches(case[2], message, 1, true)
        end
        assert.is_nil(CompatCheck.afterJob(nil))
    end)
end)

describe('CompatCheck.text', function()
    local tiles = { 'aaaa', 'bbbb', 'cccc' }
    local context = { fileName = 'IMG_0001.ARW', lightroomVersion = '15.6', serverName = 'LR Remote Previews',
        serverVersion = '0.4.0', converterVersion = '17.2', built = true }

    it('gives the verdict first, then the versions and the details', function()
        local report = DngCompare.compare(TestDng.full({ tiles = tiles }), TestDng.full({ tiles = tiles,
            software = 'Adobe DNG Converter 17.2 (Windows)' }))
        local text = CompatCheck.text(report, context)
        assert.matches('^Identical image data: all 3 tiles', text)
        assert.matches('Lightroom: version 15.6; its smart preview names "Adobe Photoshop Lightroom Classic 15.6 '
            .. '(Windows)" as its software.', text, 1, true)
        assert.matches('Server: LR Remote Previews 0.4.0 with Adobe DNG Converter 17.2; its file names "Adobe DNG '
            .. 'Converter 17.2 (Windows)" as its software (built for this check).', text, 1, true)
        assert.matches('Software: differs', text, 1, true)
        assert.are.equal('info', CompatCheck.style(report))
    end)

    it('says when differing tiles were seen before and when the structure differs', function()
        local tilesDiffer = DngCompare.compare(TestDng.full({ tiles = tiles }),
            TestDng.full({ tiles = { 'aaaa', 'bbbx', 'cccc' } }))
        assert.matches('2 of 3 tiles identical', CompatCheck.text(tilesDiffer, context), 1, true)
        assert.matches('6 were fully identical and one had 27 of 28', CompatCheck.text(tilesDiffer, context), 1, true)
        local different = DngCompare.compare(TestDng.full({ tiles = tiles }),
            TestDng.full({ tiles = tiles, compression = 7 }))
        assert.matches('Do not rely on its smart previews', CompatCheck.text(different, context), 1, true)
        assert.are.equal('critical', CompatCheck.style(different))
        local unknown = CompatCheck.text(tilesDiffer, { fileName = 'x', built = false })
        assert.matches('version unknown', unknown, 1, true)
        assert.matches('(version unknown)', unknown, 1, true)
        assert.matches('it was in the server\'s cache', unknown, 1, true)
    end)

    it('warns when the catalog\'s smart preview was written by the converter', function()
        local converter = 'Adobe DNG Converter 17.2 (Windows)'
        local report = DngCompare.compare(TestDng.full({ tiles = tiles, software = converter }),
            TestDng.full({ tiles = tiles, software = converter }))
        assert.are.equal('identical', report.verdict)
        assert.is_true(CompatCheck.madeByConverter(converter))
        assert.is_false(CompatCheck.madeByConverter('Adobe Photoshop Lightroom Classic 15.6 (Windows)'))
        assert.is_false(CompatCheck.madeByConverter(nil))
        assert.matches('probably delivered from the server rather than built by Lightroom',
            CompatCheck.text(report, context), 1, true)
        assert.are.equal('warning', CompatCheck.style(report))
    end)
end)
