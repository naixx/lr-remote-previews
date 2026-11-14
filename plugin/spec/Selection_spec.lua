-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local Selection = require 'Selection'
local ServerInfo = require 'ServerInfo'

local function info(overrides)
    local raw = {
        name = 'LR Remote Previews', version = '0.2.0', api = 1,
        converter = { installed = true },
        roots = { { id = 'archive', available = true }, { id = 'offline', available = false } },
        capabilities = { extensions = { '.arw', '.cr2' }, maxItemsPerJob = 5000 },
    }
    for key, value in pairs(overrides or {}) do
        raw[key] = value
    end
    return assert(ServerInfo.normalize(raw))
end

local MAPPINGS = {
    { localPrefix = 'Z:\\', rootId = 'archive' },
    { localPrefix = 'Y:\\Offline', rootId = 'offline' },
}

local function photo(fileName, path, extra)
    local p = { fileName = fileName, path = path }
    for key, value in pairs(extra or {}) do
        p[key] = value
    end
    return p
end

local function namesOf(list)
    local names = {}
    for i, p in ipairs(list) do
        names[i] = p.fileName or p.photo.fileName
    end
    return names
end

describe('Selection.serverProblem', function()
    it('accepts a usable server', function()
        assert.is_nil(Selection.serverProblem(info(), MAPPINGS))
    end)

    it('explains why a server cannot be used', function()
        local cases = {
            { info({ api = 2 }), MAPPINGS, 'API 2' },
            { info({ converter = { installed = false } }), MAPPINGS, 'not installed' },
            { info({ capabilities = { extensions = {} } }), MAPPINGS, 'no file types' },
            { info(), {}, 'No path mapping' },
            { info(), { { localPrefix = 'Y:\\Offline', rootId = 'offline' },
                { localPrefix = 'X:\\', rootId = 'gone' } }, 'offline (not available), gone (not on this server)' },
        }
        for _, case in ipairs(cases) do
            assert.matches(case[3], Selection.serverProblem(case[1], case[2]), 1, true)
        end
    end)

    it('does not need the converter for fetching only', function()
        local noConverter = info({ converter = { installed = false } })
        assert.is_nil(Selection.serverProblem(noConverter, MAPPINGS, { fetchOnly = true }))
        assert.matches('API 2', Selection.serverProblem(info({ api = 2 }), MAPPINGS, { fetchOnly = true }), 1, true)
        assert.matches('No path mapping', Selection.serverProblem(noConverter, {}, { fetchOnly = true }), 1, true)
    end)
end)

describe('Selection helpers', function()
    it('finds the extension of the last path segment', function()
        assert.are.equal('.arw', Selection.extension('Z:\\2026\\IMG_0001.ARW'))
        assert.are.equal('.cr2', Selection.extension('/Volumes/Photos/a.b/IMG.cr2'))
        assert.is_nil(Selection.extension('Z:\\folder.d\\README'))
    end)

    it('reads dimensions in the forms Lightroom may give them', function()
        assert.are.same({ 6000, 4000 }, { Selection.dimensions({ width = 6000, height = 4000 }) })
        assert.are.same({ 6000, 4000 }, { Selection.dimensions('6000 x 4000') })
        assert.are.same({ 6000, 4000 }, { Selection.dimensions('6000 \195\151 4000') })
        assert.is_nil(Selection.dimensions(nil))
        assert.is_nil(Selection.dimensions({ width = 0, height = 4000 }))
        assert.is_nil(Selection.dimensions('unknown'))
    end)

    it('lists the available roots', function()
        assert.are.same({ archive = true }, Selection.availableRoots(info()))
    end)
end)

describe('Selection.classify', function()
    local options = { extensions = { '.arw', '.cr2' }, mappings = MAPPINGS, availableRoots = { archive = true } }

    it('keeps the photos the server can build and counts every reason for the others', function()
        local photos = {
            photo('IMG_0001.ARW', 'Z:\\2026\\IMG_0001.ARW'),
            photo('MOV_0002.MP4', 'Z:\\2026\\MOV_0002.MP4', { isVideo = true }),
            photo('IMG_0003.ARW', nil),
            photo('IMG_0004.ARW', 'Z:\\2026\\IMG_0004.ARW', { smartPreviewPath = 'C:\\x.dng' }),
            photo('IMG_0005.JPG', 'Z:\\2026\\IMG_0005.JPG'),
            photo('IMG_0006.ARW', 'C:\\Elsewhere\\IMG_0006.ARW'),
            photo('IMG_0007.CR2', 'Y:\\Offline\\IMG_0007.CR2'),
            photo('IMG_0008', 'Z:\\2026\\IMG_0008'),
            photo('IMG_0009.cr2', 'z:/2026/IMG_0009.cr2'),
        }
        local result = Selection.classify(photos, options)
        assert.are.same({ 'IMG_0001.ARW', 'IMG_0009.cr2' }, namesOf(result.eligible))
        assert.are.same({ video = 1, noPath = 1, hasSmartPreview = 1, unsupportedFormat = 2, noMapping = 1,
            rootUnavailable = 1 }, result.counts)
        assert.are.equal('archive', result.eligible[1].rootId)
        assert.are.equal('2026/IMG_0001.ARW', result.eligible[1].relativePath)
        assert.are.equal('2026/IMG_0009.cr2', result.eligible[2].relativePath)
        assert.are.equal(7, #result.skipped)
        assert.are.equal('.jpg', result.skipped[4].detail)
    end)

    it('sends a file once, preferring the photo over its virtual copies', function()
        local photos = {
            photo('IMG_0001.ARW', 'Z:\\a\\IMG_0001.ARW', { isVirtualCopy = true, tag = 'copy 1' }),
            photo('IMG_0001.ARW', 'z:/A/img_0001.arw', { tag = 'master' }),
            photo('IMG_0001.ARW', 'Z:\\a\\IMG_0001.ARW', { isVirtualCopy = true, tag = 'copy 2' }),
            photo('IMG_0002.ARW', 'Z:\\a\\IMG_0002.ARW', { isVirtualCopy = true, tag = 'only copy' }),
        }
        local result = Selection.classify(photos, options)
        assert.are.equal(2, #result.eligible)
        assert.are.equal('master', result.eligible[1].tag)
        assert.are.equal('only copy', result.eligible[2].tag)
        assert.are.same({ sameFile = 2 }, result.counts)
    end)

    it('copes with an empty selection', function()
        assert.are.same({ eligible = {}, skipped = {}, counts = {} }, Selection.classify({}, options))
    end)
end)
