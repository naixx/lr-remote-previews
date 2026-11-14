-- Runs the sqlite3 command-line tool with LrTasks.execute. The SDK cannot capture a command's output, so the
-- command line (built by SqliteCommand, pure and unit tested) reads a script file and redirects stdout and
-- stderr to two files, all in the temporary folder; they are deleted afterwards. The catalog is opened
-- read-only and only the SELECT from SqliteCommand.lookupSql or ImportQuery's SELECT is passed (decision record
-- 0002). Must run inside an LrTasks task.
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local Log = require 'Log'
local SqliteCommand = require 'SqliteCommand'

local SqliteRunner = {}

local counter = 0

local function isWindows()
    return WIN_ENV == true
end

-- Paths for one run: script, output and error file.
local function tempFiles()
    counter = counter + 1
    local folder = LrPathUtils.getStandardFilePath('temp')
    local stem = string.format('lrrp-sqlite-%d-%d-%d', os.time(), math.random(1000000), counter)
    return LrPathUtils.child(folder, stem .. '.sql'), LrPathUtils.child(folder, stem .. '.out'),
        LrPathUtils.child(folder, stem .. '.err')
end

local function writeFile(path, text)
    local file, err = io.open(path, 'wb')
    if not file then
        return nil, err
    end
    local ok, writeError = file:write(text)
    file:close()
    if not ok then
        return nil, writeError
    end
    return true
end

local function readFile(path)
    local file = io.open(path, 'rb')
    if not file then
        return nil
    end
    local text = file:read('*a')
    file:close()
    return text
end

local function removeFile(path)
    if LrFileUtils.exists(path) then
        local ok, err = LrTasks.pcall(LrFileUtils.delete, path)
        if not ok then
            Log.warn('cannot delete the temporary file %s: %s', path, tostring(err))
        end
    end
end

local function countKeys(map)
    local n = 0
    for _ in pairs(map) do
        n = n + 1
    end
    return n
end

local function firstLine(text)
    if type(text) ~= 'string' then
        return ''
    end
    return (text:match('^%s*([^\r\n]*)') or ''):sub(1, 300)
end

-- Runs the command line that build(scriptFile, outputFile, errorFile) returns, after writing script (if any)
-- to scriptFile. Returns { status, stdout, stderr }, or nil plus a message when the command could not be built
-- or started. The three files are deleted afterwards. quiet: the command line goes to the log at the trace level only
-- (the automatic send reads every few seconds while an import comes in).
local function run(build, script, quiet)
    local scriptFile, output, errors = tempFiles()
    local line, lineError = build(scriptFile, output, errors)
    if not line then
        return nil, lineError
    end
    if script then
        local written, writeError = writeFile(scriptFile, script)
        if not written then
            removeFile(scriptFile)
            return nil, 'cannot write the temporary file ' .. scriptFile .. ': ' .. tostring(writeError)
        end
    end
    if quiet then
        Log.trace('sqlite3 command: %s', line)
    else
        Log.info('sqlite3 command: %s', line)
    end
    local started = os.time()
    local ok, status = LrTasks.pcall(LrTasks.execute, line)
    if os.time() - started >= 10 then
        Log.warn('sqlite3 took %d s to come back (Lightroom busy?)', os.time() - started)
    end
    local stdout, stderr = readFile(output), readFile(errors)
    removeFile(scriptFile)
    removeFile(output)
    removeFile(errors)
    if not ok then
        return nil, 'LrTasks.execute failed: ' .. tostring(status)
    end
    return { status = status, stdout = stdout or '', stderr = stderr or '' }
end

-- The version of the tool ('3.45.1'), or nil plus a message.
function SqliteRunner.version(tool)
    local result, err = run(function(_, output, errors)
        return SqliteCommand.versionCommand({ tool = tool, output = output, errors = errors, windows = isWindows() })
    end)
    if not result then
        return nil, err
    end
    local version = SqliteCommand.parseVersion(result.stdout)
    if result.status == 0 and version then
        return version
    end
    local why = firstLine(result.stderr)
    if why == '' then
        why = firstLine(result.stdout)
    end
    return nil, 'exit code ' .. tostring(result.status) .. (why ~= '' and (': ' .. why) or '')
end

-- How a found tool is described to the user.
function SqliteRunner.describe(tool)
    if tool.kind == 'configured' then
        return 'set in the plug-in settings: ' .. tool.tool
    elseif tool.kind == 'plugin' then
        return 'next to the plug-in: ' .. tool.tool
    end
    return 'sqlite3 on the PATH'
end

-- Finds a working sqlite3 tool (see SqliteCommand.candidates for the order). configured: the path from the
-- settings ('' for none); pluginPath: _PLUGIN.path. Returns { tool, kind, version }, or nil plus a message
-- that lists what was tried.
function SqliteRunner.locate(configured, pluginPath)
    local tried = {}
    for _, candidate in ipairs(SqliteCommand.candidates(configured, pluginPath, isWindows())) do
        local name = SqliteRunner.describe(candidate)
        if candidate.kind ~= 'path' and not LrFileUtils.exists(candidate.tool) then
            tried[#tried + 1] = name .. ': no such file'
        else
            local version, why = SqliteRunner.version(candidate.tool)
            if version then
                candidate.version = version
                return candidate
            end
            tried[#tried + 1] = name .. ': ' .. why
        end
    end
    local hint = isWindows()
        and 'Put sqlite3.exe (from sqlite.org, "sqlite-tools" for Windows) next to the plug-in\'s Info.lua, or set its '
            .. 'path in File > Plug-in Manager > LR Remote Previews.'
        or 'macOS ships /usr/bin/sqlite3; otherwise set the path in File > Plug-in Manager > LR Remote Previews.'
    return nil, 'No working sqlite3 tool was found. Tried:\n' .. table.concat(tried, '\n') .. '\n\n' .. hint
end

-- Runs one SELECT that SqliteCommand.readScript accepts (ImportQuery's, CatalogRead's) against the catalog, read-only.
-- Returns the output text, or nil plus a message. quiet: see run.
function SqliteRunner.query(tool, catalogPath, sql, quiet)
    local script, scriptError = SqliteCommand.readScript(catalogPath, sql)
    if not script then
        return nil, scriptError
    end
    local result, err = run(function(scriptFile, output, errors)
        return SqliteCommand.queryCommand({ tool = tool, script = scriptFile, output = output, errors = errors,
            windows = isWindows() })
    end, script, quiet)
    if not result then
        return nil, err
    end
    if result.status ~= 0 then
        return nil, 'sqlite3 failed with exit code ' .. tostring(result.status) .. ': ' .. firstLine(result.stderr)
    end
    return result.stdout
end

-- Reads the file UUIDs of the photos with these catalog ids (photo.localIdentifier), in chunks.
-- Returns rows keyed by id (see SqliteCommand.parseLookup) plus a list of problems, or nil plus a message.
-- isCanceled (optional) is asked between chunks; a cancel returns nil, 'cancelled'.
function SqliteRunner.lookup(tool, catalogPath, ids, isCanceled)
    local rows, problems = {}, {}
    for _, chunk in ipairs(SqliteCommand.chunks(ids)) do
        if isCanceled and isCanceled() then
            return nil, 'cancelled'
        end
        local sql, sqlError = SqliteCommand.lookupSql(chunk)
        if not sql then
            return nil, sqlError
        end
        local script, scriptError = SqliteCommand.lookupScript(catalogPath, sql)
        if not script then
            return nil, scriptError
        end
        local result, err = run(function(scriptFile, output, errors)
            return SqliteCommand.queryCommand({ tool = tool, script = scriptFile, output = output, errors = errors,
                windows = isWindows() })
        end, script)
        if not result then
            return nil, err
        end
        if result.status ~= 0 then
            return nil, 'sqlite3 failed with exit code ' .. tostring(result.status) .. ': ' .. firstLine(result.stderr)
        end
        local chunkRows, chunkProblems = SqliteCommand.parseLookup(result.stdout)
        for id, row in pairs(chunkRows) do
            rows[id] = row
        end
        for _, problem in ipairs(chunkProblems) do
            problems[#problems + 1] = problem
        end
        Log.info('sqlite3: %d of %d catalog ids found', countKeys(chunkRows), #chunk)
    end
    return rows, problems
end

return SqliteRunner
