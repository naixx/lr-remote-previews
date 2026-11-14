-- The sqlite3 command line and script that read file UUIDs from the catalog, and the parsing of the output.
-- Pure Lua 5.1: no Lightroom imports, so it runs in unit tests. Running the command is SqliteRunner's job.
--
-- The catalog is opened read-only (.open --readonly), and the only SQL ever passed is the SELECT built by
-- lookupSql, ImportQuery's or CatalogRead's. Nothing here writes to the catalog (decision record 0002).
--
-- The catalog path is not put on the command line: it goes into a small script (lookupScript) that sqlite3
-- reads from standard input. Some Windows builds of sqlite3 (seen: 3.50.6 from Android's platform-tools) read
-- their arguments in the ANSI code page and cannot open a path with other characters, for example under a user
-- folder with a non-Latin name; a script file is read as UTF-8 bytes by every build. All paths on the command
-- line (tool, script, output files) are then handled by the shell.
--
-- The command line is meant for LrTasks.execute, which runs it through a shell, so the output is redirected
-- to files that the caller reads afterwards:
--   Windows (cmd.exe /c):  ""<tool>" -readonly -batch -bail < "<script>" > "<out>" 2> "<err>""
--     cmd.exe removes the first and the last quote of a /c command line that starts with a quote and has more
--     than two quotes, so the whole line gets one extra pair of quotes. Inside quotes cmd.exe leaves & | < > ^ ( )
--     alone but still expands %NAME%, so arguments containing % are refused, as are " (not allowed in Windows
--     file names), control characters and a trailing backslash (the C runtime would read \" as a quote).
--   POSIX (/bin/sh -c):    '<tool>' -readonly -batch -bail < '<script>' > '<out>' 2> '<err>'
--     Single quotes, with ' written as '\''.
local SmartPreviewPath = require 'SmartPreviewPath'

local SqliteCommand = {}

SqliteCommand.CHUNK_SIZE = 500
SqliteCommand.BUSY_TIMEOUT_MS = 5000

-- Splits a list into lists of at most size elements.
function SqliteCommand.chunks(list, size)
    size = size or SqliteCommand.CHUNK_SIZE
    local result, current = {}, {}
    for _, value in ipairs(list) do
        current[#current + 1] = value
        if #current == size then
            result[#result + 1] = current
            current = {}
        end
    end
    if #current > 0 then
        result[#result + 1] = current
    end
    return result
end

local function isPositiveInteger(value)
    return type(value) == 'number' and value >= 1 and value == math.floor(value) and value < 2 ^ 53
end

-- The SELECT for a list of Adobe_images.id_local values (the SDK's photo.localIdentifier); or nil plus a
-- message. baseName and extension are read through hex() so that any character in a file name (a '|', a line
-- break, non-ASCII text in whatever code page the tool writes) arrives as plain ASCII.
function SqliteCommand.lookupSql(ids)
    if type(ids) ~= 'table' or #ids == 0 then
        return nil, 'no catalog ids given'
    end
    local parts = {}
    for i, id in ipairs(ids) do
        if not isPositiveInteger(id) then
            return nil, 'not a catalog id: ' .. tostring(id)
        end
        parts[i] = string.format('%d', id)
    end
    return 'SELECT i.id_local, f.id_global, hex(f.baseName), hex(f.extension) FROM Adobe_images i '
        .. 'JOIN AgLibraryFile f ON f.id_local = i.rootFile WHERE i.id_local IN (' .. table.concat(parts, ',') .. ');'
end

-- One argument quoted for the shell; or nil plus a message.
function SqliteCommand.quote(argument, windows)
    if type(argument) ~= 'string' or argument == '' then
        return nil, 'empty argument'
    end
    if argument:find('[%z\1-\31\127]') then
        return nil, 'contains a control character: ' .. argument
    end
    if windows then
        if argument:find('"', 1, true) then
            return nil, 'contains a double quote: ' .. argument
        end
        if argument:find('%', 1, true) then
            return nil, "contains '%', which cmd.exe would expand: " .. argument
        end
        if argument:sub(-1) == '\\' then
            return nil, 'ends with a backslash: ' .. argument
        end
        return '"' .. argument .. '"'
    end
    return "'" .. argument:gsub("'", "'\\''") .. "'"
end

local function commandLine(parts, windows)
    local quoted = {}
    for i, part in ipairs(parts) do
        if part.raw then
            quoted[i] = part.raw
        else
            local value, err = SqliteCommand.quote(part[1], windows)
            if not value then
                return nil, (part.what or 'argument') .. ' ' .. err
            end
            quoted[i] = value
        end
    end
    local line = table.concat(quoted, ' ')
    if windows then
        line = '"' .. line .. '"'
    end
    return line
end

-- The script for one SELECT whose characters all match allowed (a character class).
local function script(database, sql, allowed)
    if type(sql) ~= 'string' or not sql:match('^SELECT ' .. allowed .. '+;$') then
        return nil, 'refusing to pass anything but a plain SELECT to sqlite3'
    end
    if type(database) ~= 'string' or database == '' then
        return nil, 'no catalog path'
    end
    if database:find('[%z\1-\31\127]') then
        return nil, 'the catalog path contains a control character: ' .. database
    end
    local quoted = '"' .. (database:gsub('\\', '\\\\'):gsub('"', '\\"')) .. '"'
    return table.concat({
        '.open --readonly ' .. quoted,
        '.timeout ' .. SqliteCommand.BUSY_TIMEOUT_MS,
        '.headers off',
        '.mode list',
        sql,
        '',
    }, '\n')
end

-- The script sqlite3 reads on standard input for one lookup: open the catalog read-only, wait up to
-- BUSY_TIMEOUT_MS for a lock, plain "a|b|c" lines without a header, then the SELECT. Returns the text, or nil
-- plus a message. The catalog path is written as a double-quoted dot-command argument, in which sqlite3
-- resolves backslash escapes, so \ is written as \\ and " as \".
function SqliteCommand.lookupScript(database, sql)
    return script(database, sql, '[%w%s_.,=()]')
end

-- The same for the SELECTs of ImportQuery and CatalogRead: one statement on one line, which may also hold quoted names
-- and '>' (no ';' inside, no line break, so no dot-command can follow).
function SqliteCommand.readScript(database, sql)
    return script(database, sql, "[%w _.,=()'>]")
end

-- The same for the SELECTs of PreviewWatch on Lightroom's preview index: quoted file UUIDs, which hold dashes.
function SqliteCommand.previewScript(database, sql)
    return script(database, sql, "[%w _.,=()'%-]")
end

-- The command line that runs a lookup script. spec: { tool, script, output, errors, windows }.
-- tool is a path or a bare name looked up on the PATH; script is the file with lookupScript's text;
-- output/errors are the files stdout/stderr go to.
function SqliteCommand.queryCommand(spec)
    return commandLine({
        { spec.tool, what = 'the sqlite3 path' },
        { raw = '-readonly -batch -bail' },
        { raw = '<' }, { spec.script, what = 'the script file' },
        { raw = '>' }, { spec.output, what = 'the output file' },
        { raw = '2>' }, { spec.errors, what = 'the error file' },
    }, spec.windows)
end

-- The command line for "sqlite3 -version". spec: { tool, output, errors, windows }.
function SqliteCommand.versionCommand(spec)
    return commandLine({
        { spec.tool, what = 'the sqlite3 path' },
        { raw = '-version' },
        { raw = '>' }, { spec.output, what = 'the output file' },
        { raw = '2>' }, { spec.errors, what = 'the error file' },
    }, spec.windows)
end

-- The places to look for the tool, in order: { { tool = ..., kind = 'configured' | 'plugin' | 'path' } }.
-- A configured path is the only candidate when set (a wrong setting must not silently fall back to another
-- tool). Otherwise sqlite3.exe (Windows) or sqlite3 next to the plug-in's Info.lua, then sqlite3 on the PATH.
function SqliteCommand.candidates(configured, pluginPath, windows)
    if type(configured) == 'string' and configured ~= '' then
        return { { tool = configured, kind = 'configured' } }
    end
    local list = {}
    if type(pluginPath) == 'string' and pluginPath ~= '' then
        local separator = windows and '\\' or '/'
        local folder = pluginPath:gsub('[/\\]+$', '')
        list[#list + 1] = { tool = folder .. separator .. (windows and 'sqlite3.exe' or 'sqlite3'), kind = 'plugin' }
    end
    list[#list + 1] = { tool = 'sqlite3', kind = 'path' }
    return list
end

-- The version from "sqlite3 -version" output ('3.45.1 2024-01-30 ...' --> '3.45.1'), or nil.
function SqliteCommand.parseVersion(text)
    if type(text) ~= 'string' then
        return nil
    end
    return text:match('^%s*(3%.%d+[%.%d]*)')
end

local function unhex(hex)
    return (hex:gsub('%x%x', function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

-- Parses the lookup output: one line per photo, "id_local|id_global|hex(baseName)|hex(extension)".
-- Returns rows keyed by id_local: { fileUuid (upper case), baseName, extension }, plus a list of problems
-- (lines that do not have that form; ids that came back twice, which are then left out).
function SqliteCommand.parseLookup(text)
    local rows, problems, seen = {}, {}, {}
    if type(text) ~= 'string' then
        return rows, { 'no output' }
    end
    for line in text:gmatch('[^\r\n]+') do
        local id, uuid, baseHex, extensionHex = line:match('^(%d+)|([%x%-]+)|(%x*)|(%x*)$')
        local number = tonumber(id)
        if not number or not SmartPreviewPath.isValidUuid(uuid) or #baseHex % 2 == 1 or #extensionHex % 2 == 1 then
            problems[#problems + 1] = 'unexpected line: ' .. line:sub(1, 200)
        elseif seen[number] then
            rows[number] = nil
            problems[#problems + 1] = 'catalog id ' .. id .. ' came back more than once'
        else
            seen[number] = true
            rows[number] = { fileUuid = uuid:upper(), baseName = unhex(baseHex), extension = unhex(extensionHex) }
        end
    end
    return rows, problems
end

-- The file name a lookup row stands for: baseName plus '.' plus extension (no dot without an extension).
function SqliteCommand.fileNameOf(row)
    if row.extension == '' then
        return row.baseName
    end
    return row.baseName .. '.' .. row.extension
end

return SqliteCommand
