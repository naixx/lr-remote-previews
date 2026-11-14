-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local PathMap = require 'PathMap'

local function mapping(localPrefix, rootId)
    return { localPrefix = localPrefix, rootId = rootId }
end

describe('PathMap.map', function()
    describe('Windows drive paths', function()
        local mappings = { mapping('Z:\\', 'archive') }

        it('maps a file under a drive root', function()
            assert.are.same({ rootId = 'archive', relativePath = '2024/05/IMG_0001.ARW' },
                PathMap.map('Z:\\2024\\05\\IMG_0001.ARW', mappings))
        end)

        it('accepts a prefix without a trailing separator', function()
            assert.are.same({ rootId = 'photos', relativePath = 'a.arw' },
                PathMap.map('Z:\\Photos\\a.arw', { mapping('Z:\\Photos', 'photos') }))
            assert.are.same({ rootId = 'archive', relativePath = 'a.arw' },
                PathMap.map('Z:\\a.arw', { mapping('Z:', 'archive') }))
        end)

        it('matches whole folder names only', function()
            local result, message = PathMap.map('Z:\\Photos2\\a.arw', { mapping('Z:\\Photos', 'photos') })
            assert.is_nil(result)
            assert.is_string(message)
        end)

        it('compares case-insensitively and keeps the original case in the result', function()
            assert.are.same({ rootId = 'photos', relativePath = 'Sub/A.ARW' },
                PathMap.map('Z:\\PHOTOS\\Sub\\A.ARW', { mapping('z:\\photos\\', 'photos') }))
        end)

        it('accepts both slash kinds in the prefix and in the path', function()
            assert.are.same({ rootId = 'photos', relativePath = 'x/y.arw' },
                PathMap.map('Z:\\Photos\\x\\y.arw', { mapping('Z:/Photos/', 'photos') }))
            assert.are.same({ rootId = 'photos', relativePath = 'x/y.arw' },
                PathMap.map('Z:/Photos/x/y.arw', { mapping('Z:\\Photos\\', 'photos') }))
            assert.are.same({ rootId = 'photos', relativePath = 'x/y.arw' },
                PathMap.map('Z:\\Photos/x\\y.arw', { mapping('Z:\\Photos', 'photos') }))
        end)

        it('ignores repeated separators', function()
            assert.are.same({ rootId = 'photos', relativePath = '2024/a.arw' },
                PathMap.map('Z:\\\\Photos\\\\2024\\\\a.arw', { mapping('Z:\\Photos\\\\', 'photos') }))
        end)

        it('does not match another drive', function()
            assert.is_nil(PathMap.map('Y:\\a.arw', mappings))
        end)

        it('returns nil for the mapped folder itself', function()
            assert.is_nil(PathMap.map('Z:\\Photos\\', { mapping('Z:\\Photos', 'photos') }))
            assert.is_nil(PathMap.map('Z:\\Photos', { mapping('Z:\\Photos', 'photos') }))
        end)
    end)

    describe('longest prefix', function()
        it('wins regardless of order', function()
            local a = { mapping('Z:\\', 'archive'), mapping('Z:\\Photos\\Raw', 'raw') }
            local b = { mapping('Z:\\Photos\\Raw', 'raw'), mapping('Z:\\', 'archive') }
            for _, mappings in ipairs({ a, b }) do
                assert.are.same({ rootId = 'raw', relativePath = 'a.arw' },
                    PathMap.map('Z:\\Photos\\Raw\\a.arw', mappings))
                assert.are.same({ rootId = 'archive', relativePath = 'Photos/b.arw' },
                    PathMap.map('Z:\\Photos\\b.arw', mappings))
                assert.are.same({ rootId = 'archive', relativePath = 'Photos/Raw2/c.arw' },
                    PathMap.map('Z:\\Photos\\Raw2\\c.arw', mappings))
            end
        end)

        it('picks the first of two equal prefixes', function()
            local mappings = { mapping('Z:\\Photos', 'first'), mapping('z:/photos/', 'second') }
            assert.are.equal('first', PathMap.map('Z:\\Photos\\a.arw', mappings).rootId)
        end)
    end)

    describe('UNC paths', function()
        local mappings = { mapping('\\\\nas\\photos\\', 'archive') }

        it('maps a file under a share', function()
            assert.are.same({ rootId = 'archive', relativePath = '2024/a.arw' },
                PathMap.map('\\\\nas\\photos\\2024\\a.arw', mappings))
        end)

        it('compares case-insensitively', function()
            assert.are.same({ rootId = 'archive', relativePath = 'A.arw' },
                PathMap.map('\\\\NAS\\Photos\\A.arw', mappings))
        end)

        it('accepts forward slashes', function()
            assert.are.same({ rootId = 'archive', relativePath = 'a.arw' },
                PathMap.map('//nas/photos/a.arw', mappings))
            assert.are.same({ rootId = 'archive', relativePath = 'a.arw' },
                PathMap.map('\\\\nas\\photos\\a.arw', { mapping('//nas/photos', 'archive') }))
        end)

        it('does not match another share or server', function()
            assert.is_nil(PathMap.map('\\\\nas\\photos2\\a.arw', mappings))
            assert.is_nil(PathMap.map('\\\\nas2\\photos\\a.arw', mappings))
        end)

        it('does not match a drive path', function()
            assert.is_nil(PathMap.map('Z:\\nas\\photos\\a.arw', mappings))
        end)
    end)

    describe('POSIX paths', function()
        local mappings = { mapping('/Volumes/Photos', 'archive') }

        it('maps a file under the prefix', function()
            assert.are.same({ rootId = 'archive', relativePath = '2024/a.arw' },
                PathMap.map('/Volumes/Photos/2024/a.arw', mappings))
            assert.are.same({ rootId = 'archive', relativePath = 'a.arw' },
                PathMap.map('/Volumes/Photos/a.arw', { mapping('/Volumes/Photos/', 'archive') }))
        end)

        it('compares case-sensitively', function()
            assert.is_nil(PathMap.map('/volumes/photos/a.arw', mappings))
        end)

        it('treats a backslash as an ordinary character', function()
            assert.are.same({ rootId = 'archive', relativePath = 'a\\b.arw' },
                PathMap.map('/Volumes/Photos/a\\b.arw', mappings))
        end)

        it('does not match a Windows path', function()
            assert.is_nil(PathMap.map('Z:\\Volumes\\Photos\\a.arw', mappings))
        end)
    end)

    describe('dot segments', function()
        it("rejects '..' after the prefix", function()
            local result, message = PathMap.map('Z:\\Photos\\..\\Private\\a.arw', { mapping('Z:\\', 'archive') })
            assert.is_nil(result)
            assert.matches('%.%.', message)
            assert.is_nil(PathMap.map('Z:\\Photos\\..\\a.arw', { mapping('Z:\\Photos', 'photos') }))
            assert.is_nil(PathMap.map('/data/x/../../etc/passwd', { mapping('/data', 'data') }))
            assert.is_nil(PathMap.map('\\\\nas\\photos\\..\\a.arw', { mapping('\\\\nas\\photos', 'archive') }))
        end)

        it("rejects '.' after the prefix", function()
            assert.is_nil(PathMap.map('Z:\\Photos\\.\\a.arw', { mapping('Z:\\', 'archive') }))
        end)

        it('accepts names that merely contain dots', function()
            assert.are.same({ rootId = 'archive', relativePath = '..hidden/a..b.arw' },
                PathMap.map('Z:\\..hidden\\a..b.arw', { mapping('Z:\\', 'archive') }))
        end)
    end)

    describe('bad input', function()
        it('returns nil when nothing matches', function()
            local result, message = PathMap.map('C:\\a.arw', { mapping('Z:\\', 'archive') })
            assert.is_nil(result)
            assert.is_string(message)
            assert.is_nil(PathMap.map('Z:\\a.arw', {}))
        end)

        it('returns nil for a missing or empty path', function()
            assert.is_nil(PathMap.map(nil, { mapping('Z:\\', 'archive') }))
            assert.is_nil(PathMap.map('', { mapping('Z:\\', 'archive') }))
            assert.is_nil(PathMap.map(42, { mapping('Z:\\', 'archive') }))
        end)

        it('returns nil without a mapping list', function()
            assert.is_nil(PathMap.map('Z:\\a.arw', nil))
        end)

        it('skips invalid mappings', function()
            local mappings = {
                mapping('', 'empty-prefix'),
                mapping('Z:\\', ''),
                mapping('Photos', 'relative'),
                mapping('Z:\\', 'has/slash'),
                mapping('Z:\\Photos\\..', 'dots'),
                'not a table',
                mapping('Z:\\', 'archive'),
            }
            assert.are.same({ rootId = 'archive', relativePath = 'Photos/a.arw' },
                PathMap.map('Z:\\Photos\\a.arw', mappings))
        end)
    end)
end)

describe('PathMap.localPaths', function()
    it('maps a root and relative path back to drive, UNC and POSIX prefixes', function()
        assert.are.same({ 'Z:\\2026\\2026.06.20 - shoot\\IMG_0001.ARW' },
            PathMap.localPaths('archive', '2026/2026.06.20 - shoot/IMG_0001.ARW', { mapping('Z:\\', 'archive') }))
        assert.are.same({ 'Z:\\Photos\\a\\b.arw' },
            PathMap.localPaths('p', 'a/b.arw', { mapping('Z:/Photos/', 'p') }))
        assert.are.same({ '\\\\nas\\photos\\Trip\\IMG_0021.CR2' },
            PathMap.localPaths('archive', 'Trip/IMG_0021.CR2', { mapping('\\\\nas\\photos', 'archive') }))
        assert.are.same({ '/Volumes/Photos/2026/a.arw' },
            PathMap.localPaths('p', '2026/a.arw', { mapping('/Volumes/Photos/', 'p') }))
        assert.are.same({ '/a.arw' }, PathMap.localPaths('p', 'a.arw', { mapping('/', 'p') }))
    end)

    it('lists one path per mapping of the root, in order, each spelling once', function()
        local mappings = { mapping('Z:\\', 'archive'), mapping('Y:\\Other', 'other'),
            mapping('\\\\nas\\photos', 'archive'), mapping('z:/', 'archive'), mapping('relative', 'archive') }
        assert.are.same({ 'Z:\\a\\b.arw', '\\\\nas\\photos\\a\\b.arw' },
            PathMap.localPaths('archive', 'a/b.arw', mappings))
        assert.are.same({}, PathMap.localPaths('nowhere', 'a/b.arw', mappings))
    end)

    it('is the reverse of PathMap.map', function()
        local mappings = { mapping('Z:\\', 'archive'), mapping('Z:\\Photos', 'photos'), mapping('/Volumes/P', 'p') }
        local paths = { 'Z:\\2026\\Caf\195\169\\IMG_0001.ARW', 'Z:\\Photos\\x\\y.cr2', '/Volumes/P/q/r.nef' }
        for _, path in ipairs(paths) do
            local mapped = assert(PathMap.map(path, mappings))
            local back = PathMap.localPaths(mapped.rootId, mapped.relativePath, mappings)
            assert.are.equal(PathMap.fileKey(path), PathMap.fileKey(back[1]))
        end
    end)

    it('refuses relative paths the server should never send', function()
        local mappings = { mapping('Z:\\', 'archive') }
        for _, bad in ipairs({ '', '/a.arw', 'a\\b.arw', 'a//b.arw', 'a/', './a.arw', 'a/../b.arw', 'C:/a.arw',
            'a\0b' }) do
            local paths, message = PathMap.localPaths('archive', bad, mappings)
            assert.is_nil(paths, bad)
            assert.is_string(message)
        end
        assert.is_nil(PathMap.localPaths('', 'a.arw', mappings))
        assert.is_nil(PathMap.localPaths(nil, 'a.arw', mappings))
    end)
end)

describe('PathMap.fileKey', function()
    it('gives one key for every spelling of the same Windows path', function()
        assert.are.equal(PathMap.fileKey('Z:\\Photos\\A.ARW'), PathMap.fileKey('z:/photos//a.arw'))
        assert.are.equal(PathMap.fileKey('\\\\nas\\photos\\a.arw'), PathMap.fileKey('//NAS/Photos/A.ARW'))
    end)

    it('keeps POSIX paths case-sensitive', function()
        assert.are_not.equal(PathMap.fileKey('/Volumes/P/a.arw'), PathMap.fileKey('/Volumes/P/A.arw'))
        assert.are.equal(PathMap.fileKey('/Volumes/P/a.arw'), PathMap.fileKey('/Volumes//P/a.arw'))
    end)

    it('returns nil for no path', function()
        assert.is_nil(PathMap.fileKey(nil))
        assert.is_nil(PathMap.fileKey(''))
    end)
end)

describe('PathMap.checkMapping', function()
    it('accepts drive, UNC and POSIX prefixes', function()
        assert.is_true(PathMap.checkMapping('Z:\\', 'archive'))
        assert.is_true(PathMap.checkMapping('\\\\nas\\photos\\', 'archive'))
        assert.is_true(PathMap.checkMapping('/Volumes/Photos', 'archive'))
    end)

    it('explains what is wrong', function()
        local cases = {
            { '', 'archive' },
            { 'Z:\\', '' },
            { 'Z:\\', 'two words' },
            { 'Photos\\2024', 'archive' },
            { '\\\\', 'archive' },
            { 'Z:\\a\\..\\b', 'archive' },
        }
        for _, case in ipairs(cases) do
            local ok, message = PathMap.checkMapping(case[1], case[2])
            assert.is_nil(ok)
            assert.is_string(message)
        end
    end)
end)
