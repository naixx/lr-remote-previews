-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local FolderListing = require 'FolderListing'

local RAW = { '.arw', '.cr2', '.dng' }

-- A file system in a table: folder path -> list of names; a name ending in '/' is a folder.
local function fakeEnv(tree, log)
    local function list(folder, withFolders)
        local names = tree[folder]
        if names == nil then
            return nil, 'no such folder: ' .. folder
        end
        local paths = {}
        for _, name in ipairs(names) do
            local isFolder = name:sub(-1) == '/'
            if withFolders or not isFolder then
                paths[#paths + 1] = folder .. '\\' .. (isFolder and name:sub(1, -2) or name)
            end
        end
        return paths
    end
    return {
        files = function(folder)
            if log then
                log[#log + 1] = 'files ' .. folder
            end
            return list(folder, false)
        end,
        entries = function(folder)
            if log then
                log[#log + 1] = 'entries ' .. folder
            end
            return list(folder, true)
        end,
    }
end

local function paths(list, field)
    local result = {}
    for i, item in ipairs(list) do
        result[i] = field and item[field] or item
    end
    return result
end

describe('FolderListing.split and extension', function()
    it('splits Windows and POSIX paths', function()
        assert.are.same({ 'Z:\\2026', 'IMG_0001.ARW' }, { FolderListing.split('Z:\\2026\\IMG_0001.ARW') })
        assert.are.same({ 'Z:/2026', 'a.arw' }, { FolderListing.split('Z:/2026/a.arw') })
        assert.are.same({ '\\\\nas.local\\photos', 'a.arw' }, { FolderListing.split('\\\\nas.local\\photos\\a.arw') })
        assert.are.same({ '/Volumes/Photos', 'a\\b.arw' }, { FolderListing.split('/Volumes/Photos/a\\b.arw') })
        assert.are.same({ '', 'a.arw' }, { FolderListing.split('a.arw') })
    end)

    it('gives the extension in lower case, none for dot files', function()
        assert.are.equal('.arw', FolderListing.extension('IMG_0001.ARW'))
        assert.are.equal('.jpeg', FolderListing.extension('a.b.JPEG'))
        assert.is_nil(FolderListing.extension('README'))
        assert.is_nil(FolderListing.extension('.hidden'))
        assert.are.equal('.arw', FolderListing.extension('._IMG_0001.ARW'))
    end)

    it('names the folders that are not looked into', function()
        assert.are.equal('hidden folder', FolderListing.folderSkip('.thumbnails'))
        assert.are.equal('Lightroom data folder', FolderListing.folderSkip('Main Smart Previews.lrdata'))
        assert.are.equal('Lightroom data folder', FolderListing.folderSkip('Main Previews.LRDATA'))
        assert.are.equal('NAS system folder', FolderListing.folderSkip('@eaDir'))
        assert.are.equal('NAS system folder', FolderListing.folderSkip('#recycle'))
        assert.are.equal('NAS system folder', FolderListing.folderSkip('@Recently-Snapshot'))
        assert.is_nil(FolderListing.folderSkip('2026.06.20 - shoot'))
        assert.is_nil(FolderListing.folderSkip('#1 shoot'))
        assert.is_nil(FolderListing.folderSkip('lrdata'))
    end)
end)

describe('FolderListing.walk', function()
    local tree = {
        ['Z:\\2026'] = { 'b.arw', 'A.ARW', 'shoot/', '.thumbs/', 'Main Smart Previews.lrdata/', '@eaDir/' },
        ['Z:\\2026\\shoot'] = { 'c.cr2', 'deeper/' },
        ['Z:\\2026\\shoot\\deeper'] = { 'd.dng' },
        ['Z:\\2026\\.thumbs'] = { 'x.arw' },
        ['Z:\\2026\\Main Smart Previews.lrdata'] = { 'X.dng' },
        ['Z:\\2026\\@eaDir'] = { 'SYNOPHOTO_THUMB_M.jpg' },
    }

    it('lists only the chosen folder without sub-folders, and never asks for its entries', function()
        local log = {}
        local listing = FolderListing.walk({ 'Z:\\2026' }, fakeEnv(tree, log), { recursive = false })
        assert.are.same({ 'Z:\\2026\\b.arw', 'Z:\\2026\\A.ARW' }, listing.files)
        assert.are.equal(1, listing.folders)
        assert.are.same({ 'files Z:\\2026' }, log)
        assert.are.same({}, listing.skippedFolders)
    end)

    it('goes into sub-folders, but not into hidden, Lightroom data and NAS system folders', function()
        local listing = FolderListing.walk({ 'Z:\\2026' }, fakeEnv(tree), { recursive = true })
        table.sort(listing.files)
        assert.are.same({ 'Z:\\2026\\A.ARW', 'Z:\\2026\\b.arw', 'Z:\\2026\\shoot\\c.cr2',
            'Z:\\2026\\shoot\\deeper\\d.dng' }, listing.files)
        assert.are.equal(3, listing.folders)
        assert.are.same({ { path = 'Z:\\2026\\.thumbs', reason = 'hidden folder' },
            { path = 'Z:\\2026\\@eaDir', reason = 'NAS system folder' },
            { path = 'Z:\\2026\\Main Smart Previews.lrdata', reason = 'Lightroom data folder' } },
            listing.skippedFolders)
        assert.is_false(listing.stopped)
    end)

    it('looks into a chosen folder whatever its name, and lists overlapping folders once', function()
        local listing = FolderListing.walk({ 'Z:\\2026\\.thumbs', 'Z:\\2026', 'z:/2026/SHOOT' }, fakeEnv(tree),
            { recursive = true })
        table.sort(listing.files)
        assert.are.same({ 'Z:\\2026\\.thumbs\\x.arw', 'Z:\\2026\\A.ARW', 'Z:\\2026\\b.arw', 'Z:\\2026\\shoot\\c.cr2',
            'Z:\\2026\\shoot\\deeper\\d.dng' }, listing.files)
        assert.are.equal(4, listing.folders)
    end)

    it('joins bare names to the folder', function()
        local env = {
            files = function(folder)
                return folder == 'Z:\\' and { 'a.arw' } or {}
            end,
            entries = function(folder)
                return folder == 'Z:\\' and { 'a.arw', 'sub' } or {}
            end,
        }
        local listing = FolderListing.walk({ 'Z:\\' }, env, { recursive = true })
        assert.are.same({ 'Z:\\a.arw' }, listing.files)
        assert.are.equal(2, listing.folders)
        local posix = FolderListing.walk({ '/Volumes/P' }, { files = function()
            return { 'a.arw' }
        end }, {})
        assert.are.same({ '/Volumes/P/a.arw' }, posix.files)
    end)

    it('reports folders it cannot read and goes on', function()
        local listing = FolderListing.walk({ 'Z:\\missing', 'Z:\\2026\\shoot' }, fakeEnv(tree), { recursive = true })
        assert.are.same({ 'Z:\\2026\\shoot\\c.cr2', 'Z:\\2026\\shoot\\deeper\\d.dng' }, listing.files)
        assert.are.equal(2, #listing.problems)
        assert.are.equal('Z:\\missing', listing.problems[1].path)
        assert.matches('no such folder', listing.problems[1].message)
    end)

    it('stops when asked to, before the next folder', function()
        local steps = 0
        local env = fakeEnv(tree)
        env.step = function()
            steps = steps + 1
            return steps == 2
        end
        local listing = FolderListing.walk({ 'Z:\\2026' }, env, { recursive = true })
        assert.is_true(listing.stopped)
        assert.are.equal(1, listing.folders)
    end)

    it('does not go deeper than MAX_DEPTH levels', function()
        local env = {
            files = function()
                return {}
            end,
            entries = function(folder)
                return { folder .. '\\loop' }
            end,
        }
        local listing = FolderListing.walk({ 'Z:\\a' }, env, { recursive = true })
        assert.are.equal(FolderListing.MAX_DEPTH + 1, listing.folders)
        assert.are.equal(1, #listing.skippedFolders)
        assert.matches('levels deep', listing.skippedFolders[1].reason)
    end)
end)

describe('FolderListing.classify', function()
    local files = {
        'Z:\\s\\IMG_0002.ARW', 'Z:\\s\\IMG_0001.arw', 'Z:\\s\\IMG_0001.JPG', 'Z:\\s\\img_0002.jpeg',
        'Z:\\s\\IMG_0003.JPG', 'Z:\\s\\IMG_0003.TIF', 'Z:\\s\\notes.txt', 'Z:\\s\\.IMG_0004.ARW',
        'Z:\\s\\._IMG_0001.ARW', 'Z:\\s\\README', 'Z:\\s\\sub\\IMG_0001.JPG', 'Z:\\s\\DSC_0005.NEF', 'Z:\\s\\pano.psd',
        'Z:\\s\\shot.HEIC', 'Z:\\s\\IMG_0006.ARW.JPG',
    }

    it('takes camera raw files only by default, sorted by folder and name', function()
        local sorted = FolderListing.classify(files, { rawExtensions = RAW })
        assert.are.same({ 'Z:\\s\\IMG_0001.arw', 'Z:\\s\\IMG_0002.ARW' }, paths(sorted.candidates, 'path'))
        assert.are.same({ 'raw', 'raw' }, paths(sorted.candidates, 'kind'))
        assert.are.equal('.arw', sorted.candidates[1].extension)
        assert.are.equal('IMG_0001.arw', sorted.candidates[1].name)
        assert.are.equal('Z:\\s', sorted.candidates[1].folder)
        assert.are.same({ hidden = 2, notPhoto = 11 }, sorted.counts)
    end)

    it('takes other photo formats when asked, and leaves out a JPEG next to a raw file of the same name', function()
        local sorted = FolderListing.classify(files, { rawExtensions = RAW,
            otherExtensions = FolderListing.OTHER_EXTENSIONS })
        assert.are.same({ 'Z:\\s\\IMG_0001.arw', 'Z:\\s\\IMG_0002.ARW', 'Z:\\s\\IMG_0003.JPG', 'Z:\\s\\IMG_0003.TIF',
            'Z:\\s\\IMG_0006.ARW.JPG', 'Z:\\s\\pano.psd', 'Z:\\s\\shot.HEIC', 'Z:\\s\\sub\\IMG_0001.JPG' },
            paths(sorted.candidates, 'path'))
        assert.are.same({ hidden = 2, notPhoto = 3, pairedJpeg = 2 }, sorted.counts)
        local paired = {}
        for _, skipped in ipairs(sorted.skipped) do
            if skipped.reason == 'pairedJpeg' then
                paired[skipped.path] = skipped.detail
            end
        end
        assert.are.same({ ['Z:\\s\\IMG_0001.JPG'] = 'IMG_0001.arw', ['Z:\\s\\img_0002.jpeg'] = 'IMG_0002.ARW' },
            paired)
    end)

    it('pairs with a raw type of the list in effect only, and names the extension of other files', function()
        local sorted = FolderListing.classify({ 'Z:\\s\\DSC_0005.NEF', 'Z:\\s\\DSC_0005.JPG', 'Z:\\s\\notes.txt',
            'Z:\\s\\README' }, { rawExtensions = { '.arw' }, otherExtensions = { '.jpg' } })
        assert.are.same({ 'Z:\\s\\DSC_0005.JPG' }, paths(sorted.candidates, 'path'))
        local details = {}
        for _, skipped in ipairs(sorted.skipped) do
            details[skipped.name] = skipped.reason .. ' ' .. skipped.detail
        end
        assert.are.same({ ['DSC_0005.NEF'] = 'notPhoto .nef', ['notes.txt'] = 'notPhoto .txt',
            README = 'notPhoto (no extension)' }, details)
        sorted = FolderListing.classify({ 'Z:\\s\\DSC_0005.NEF', 'Z:\\s\\DSC_0005.JPG' },
            { rawExtensions = FolderListing.RAW_EXTENSIONS, otherExtensions = { '.jpg' } })
        assert.are.same({ 'Z:\\s\\DSC_0005.NEF' }, paths(sorted.candidates, 'path'))
        assert.are.same({ pairedJpeg = 1 }, sorted.counts)
    end)

    it('keeps the built-in raw list equal to the types the server accepts', function()
        local file = assert(io.open(here .. '../../server/src/lrrp/converter.py', 'r'))
        local source = file:read('*a')
        file:close()
        local block = assert(source:match('\nRAW_EXTENSIONS = %((.-)%)'))
        local server = {}
        for extension in block:gmatch('"(%.[%w]+)"') do
            server[#server + 1] = extension
        end
        table.sort(server)
        local ours = {}
        for i, extension in ipairs(FolderListing.RAW_EXTENSIONS) do
            ours[i] = extension
        end
        table.sort(ours)
        assert.is_true(#server > 10)
        assert.are.same(server, ours)
        local raw = {}
        for _, extension in ipairs(ours) do
            raw[extension] = true
        end
        for _, extension in ipairs(FolderListing.OTHER_EXTENSIONS) do
            assert.is_nil(raw[extension])
        end
    end)
end)
