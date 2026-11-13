-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local SqliteCommand = require 'SqliteCommand'

local UUID = '62823DFE-E7D3-40FF-938C-518FDECC6CF6'

local function hex(text)
    return (text:gsub('.', function(c)
        return string.format('%02X', c:byte())
    end))
end

describe('SqliteCommand.lookupSql', function()
    it('selects the file of each photo by catalog id', function()
        assert.are.equal('SELECT i.id_local, f.id_global, hex(f.baseName), hex(f.extension) FROM Adobe_images i '
            .. 'JOIN AgLibraryFile f ON f.id_local = i.rootFile WHERE i.id_local IN (17,2,123456789);',
            SqliteCommand.lookupSql({ 17, 2, 123456789 }))
    end)

    it('refuses anything that is not a positive integer', function()
        for _, ids in ipairs({ {}, { 0 }, { -1 }, { 1.5 }, { '1' }, { 1, '2); DROP TABLE x; --' }, { 0 / 0 } }) do
            local sql, message = SqliteCommand.lookupSql(ids)
            assert.is_nil(sql)
            assert.is_string(message)
        end
        assert.is_nil(SqliteCommand.lookupSql(nil))
    end)
end)

describe('SqliteCommand.chunks', function()
    it('splits a list into chunks of the given size', function()
        assert.are.same({ { 1, 2 }, { 3, 4 }, { 5 } }, SqliteCommand.chunks({ 1, 2, 3, 4, 5 }, 2))
        assert.are.same({ { 1, 2 } }, SqliteCommand.chunks({ 1, 2 }, 2))
        assert.are.same({}, SqliteCommand.chunks({}, 2))
        assert.are.equal(3, #SqliteCommand.chunks((function()
            local list = {}
            for i = 1, 1001 do
                list[i] = i
            end
            return list
        end)()))
    end)
end)

describe('SqliteCommand.quote', function()
    it('wraps Windows arguments in double quotes', function()
        assert.are.equal('"C:\\Program Files\\x.exe"', SqliteCommand.quote('C:\\Program Files\\x.exe', true))
        assert.are.equal('"a & b | (c) ^ <d> !e"', SqliteCommand.quote('a & b | (c) ^ <d> !e', true))
        assert.are.equal('"Caf\195\169"', SqliteCommand.quote('Caf\195\169', true))
    end)

    it('refuses what cmd.exe or the C runtime would change', function()
        for _, argument in ipairs({ 'a"b', '100%', 'C:\\dir\\', 'a\nb', 'a\0b', '' }) do
            local quoted, message = SqliteCommand.quote(argument, true)
            assert.is_nil(quoted)
            assert.is_string(message)
        end
    end)

    it('wraps POSIX arguments in single quotes', function()
        assert.are.equal("'/Users/x/My Photos/Main.lrcat'", SqliteCommand.quote('/Users/x/My Photos/Main.lrcat'))
        assert.are.equal("'it'\\''s $HOME `x` \"q\" %p%'", SqliteCommand.quote('it\'s $HOME `x` "q" %p%'))
        assert.is_nil(SqliteCommand.quote('a\nb'))
    end)
end)

describe('SqliteCommand.lookupScript', function()
    local sql = SqliteCommand.lookupSql({ 1, 2 })

    it('opens the catalog read-only and runs the SELECT', function()
        assert.are.equal('.open --readonly "C:\\\\Photos\\\\Main Catalog 100%\\\\Main.lrcat"\n.timeout 5000\n'
            .. '.headers off\n.mode list\n' .. sql .. '\n',
            SqliteCommand.lookupScript('C:\\Photos\\Main Catalog 100%\\Main.lrcat', sql))
    end)

    it('escapes double quotes and keeps other characters as they are', function()
        local script = SqliteCommand.lookupScript('/Users/x/"Best" \208\164\208\190\209\130\208\190/Main.lrcat', sql)
        assert.matches('.open --readonly "/Users/x/\\"Best\\" \208\164\208\190\209\130\208\190/Main.lrcat"\n', script,
            1, true)
    end)

    it('passes nothing but a plain SELECT', function()
        for _, bad in ipairs({ 'DELETE FROM Adobe_images;', "SELECT 'x';", 'SELECT 1; DROP TABLE x;', 'SELECT 1',
            '.shell calc', 'SELECT 1;\n.shell calc', 42 }) do
            local script, message = SqliteCommand.lookupScript('/a.lrcat', bad)
            assert.is_nil(script)
            assert.matches('SELECT', message)
        end
    end)

    it('refuses a catalog path that would break the script', function()
        for _, path in ipairs({ '', 'C:\\a\nb.lrcat', 'C:\\a\rb.lrcat', 42 }) do
            assert.is_nil(SqliteCommand.lookupScript(path, sql))
        end
    end)
end)

describe('SqliteCommand.queryCommand', function()
    it('builds the Windows line with one extra pair of quotes around it', function()
        assert.are.equal('""C:\\Program Files\\sqlite\\sqlite3.exe" -readonly -batch -bail < "C:\\Temp\\o.sql" '
            .. '> "C:\\Temp\\o.out" 2> "C:\\Temp\\o.err""',
            SqliteCommand.queryCommand({ tool = 'C:\\Program Files\\sqlite\\sqlite3.exe', script = 'C:\\Temp\\o.sql',
                output = 'C:\\Temp\\o.out', errors = 'C:\\Temp\\o.err', windows = true }))
    end)

    it('builds the POSIX line', function()
        assert.are.equal("'sqlite3' -readonly -batch -bail < '/tmp/o.sql' > '/tmp/o.out' 2> '/tmp/o.err'",
            SqliteCommand.queryCommand({ tool = 'sqlite3', script = '/tmp/o.sql', output = '/tmp/o.out',
                errors = '/tmp/o.err', windows = false }))
    end)

    it('names the path it cannot quote', function()
        local line, message = SqliteCommand.queryCommand({ tool = 'sqlite3', script = 'C:\\50%\\o.sql',
            output = 'C:\\o', errors = 'C:\\e', windows = true })
        assert.is_nil(line)
        assert.matches('the script file', message)
    end)
end)

describe('SqliteCommand.versionCommand', function()
    it('builds both forms', function()
        assert.are.equal('""sqlite3" -version > "C:\\T\\v.out" 2> "C:\\T\\v.err""',
            SqliteCommand.versionCommand({ tool = 'sqlite3', output = 'C:\\T\\v.out', errors = 'C:\\T\\v.err',
                windows = true }))
        assert.are.equal("'/usr/bin/sqlite3' -version > '/t/v.out' 2> '/t/v.err'",
            SqliteCommand.versionCommand({ tool = '/usr/bin/sqlite3', output = '/t/v.out', errors = '/t/v.err' }))
    end)
end)

describe('SqliteCommand.candidates', function()
    it('uses only the configured path when one is set', function()
        assert.are.same({ { tool = 'D:\\bin\\sqlite3.exe', kind = 'configured' } },
            SqliteCommand.candidates('D:\\bin\\sqlite3.exe', 'C:\\Plugins\\LRRemotePreviews.lrplugin', true))
    end)

    it('looks next to the plug-in, then on the PATH', function()
        assert.are.same({
            { tool = 'C:\\Plugins\\LRRemotePreviews.lrplugin\\sqlite3.exe', kind = 'plugin' },
            { tool = 'sqlite3', kind = 'path' },
        }, SqliteCommand.candidates('', 'C:\\Plugins\\LRRemotePreviews.lrplugin\\', true))
        assert.are.same({
            { tool = '/Library/Plugins/LRRemotePreviews.lrplugin/sqlite3', kind = 'plugin' },
            { tool = 'sqlite3', kind = 'path' },
        }, SqliteCommand.candidates(nil, '/Library/Plugins/LRRemotePreviews.lrplugin', false))
        assert.are.same({ { tool = 'sqlite3', kind = 'path' } }, SqliteCommand.candidates('', nil, true))
    end)
end)

describe('SqliteCommand.parseVersion', function()
    it('reads the version number', function()
        assert.are.equal('3.45.1', SqliteCommand.parseVersion('3.45.1 2024-01-30 16:01:20 e876e51a0e (64-bit)\n'))
        assert.are.equal('3.39.5', SqliteCommand.parseVersion('3.39.5 2022-10-14 20:58:05 554764a6e7\r\n'))
        assert.is_nil(SqliteCommand.parseVersion("'sqlite3' is not recognized as an internal or external command"))
        assert.is_nil(SqliteCommand.parseVersion(nil))
    end)
end)

describe('SqliteCommand.parseLookup', function()
    it('decodes rows keyed by catalog id, with any characters in the names', function()
        local text = '17|' .. UUID:lower() .. '|' .. hex('IMG_0001') .. '|' .. hex('ARW') .. '\r\n'
            .. '18|11111111-2222-3333-4444-555555555555|' .. hex('a|b\nc Caf\195\169') .. '|' .. hex('cr3') .. '\n'
            .. '19|AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE|' .. hex('README') .. '|\n'
        local rows, problems = SqliteCommand.parseLookup(text)
        assert.are.same({}, problems)
        assert.are.same({ fileUuid = UUID, baseName = 'IMG_0001', extension = 'ARW' }, rows[17])
        assert.are.same({ fileUuid = '11111111-2222-3333-4444-555555555555', baseName = 'a|b\nc Caf\195\169',
            extension = 'cr3' }, rows[18])
        assert.are.equal('README', SqliteCommand.fileNameOf(rows[19]))
        assert.are.equal('IMG_0001.ARW', SqliteCommand.fileNameOf(rows[17]))
    end)

    it('reports lines it does not understand and leaves out ids that came twice', function()
        local good = '|' .. UUID .. '|' .. hex('A') .. '|' .. hex('ARW')
        local rows, problems = SqliteCommand.parseLookup(table.concat({
            '1' .. good,
            '2' .. good,
            '2' .. good,
            'Error: in prepare, no such table: Adobe_images',
            '3|not-a-uuid|41|41',
            '4|' .. UUID .. '|414|41',
            '',
        }, '\n'))
        assert.is_not_nil(rows[1])
        assert.is_nil(rows[2])
        assert.is_nil(rows[3])
        assert.is_nil(rows[4])
        assert.are.equal(4, #problems)
    end)

    it('copes with no output', function()
        assert.are.same({}, (SqliteCommand.parseLookup('')))
        local rows, problems = SqliteCommand.parseLookup(nil)
        assert.are.same({}, rows)
        assert.are.equal(1, #problems)
    end)
end)
