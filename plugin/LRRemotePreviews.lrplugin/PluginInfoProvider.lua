-- The plug-in's section in File > Plug-in Manager: server URL, access token, up to three path mappings, the
-- sqlite3 tool, and the "Test connection" and "Check sqlite3" buttons. Values are copied from LrPrefs into the
-- dialog's property table when the section opens and written back when the dialog closes (or another plug-in
-- is selected).
local LrDialogs = import 'LrDialogs'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local Log = require 'Log'
local ServerClient = require 'ServerClient'
local ServerInfo = require 'ServerInfo'
local Settings = require 'Settings'
local SqliteRunner = require 'SqliteRunner'

local bind = LrView.bind
local share = LrView.share

local TEST_TITLE = 'LR Remote Previews: test connection'
local SQLITE_TITLE = 'LR Remote Previews: sqlite3'

local function mappingNote(settings)
    local problems = Settings.mappingProblems(settings)
    if #problems == 0 then
        return nil
    end
    return table.concat(problems, '\n')
end

local function testConnection(propertyTable)
    LrTasks.startAsyncTask(function()
        local settings = Settings.read(propertyTable)
        propertyTable.testResult = 'Testing...'
        local info, problem = ServerClient.fetchInfo(settings)
        local note = mappingNote(settings)
        if info then
            propertyTable.testResult = 'Connected: ' .. ServerInfo.summary(info)
            local text = ServerInfo.formatReport(info, { serverUrl = settings.serverUrl,
                mappings = Settings.mappings(settings) })
            if note then
                text = text .. '\n\n' .. note
            end
            LrDialogs.message(TEST_TITLE, text, 'info')
        else
            propertyTable.testResult = 'Failed: ' .. ServerInfo.shortProblem(problem)
            local text = problem.message
            if note then
                text = text .. '\n\n' .. note
            end
            LrDialogs.message(TEST_TITLE, text, 'critical')
        end
    end)
end

local function checkSqlite(propertyTable)
    LrTasks.startAsyncTask(function()
        local settings = Settings.read(propertyTable)
        propertyTable.sqliteResult = 'Checking...'
        local tool, problem = SqliteRunner.locate(settings.sqlitePath, _PLUGIN and _PLUGIN.path)
        if tool then
            propertyTable.sqliteResult = 'Found sqlite3 ' .. tool.version
            Log.info('sqlite3 check: %s, %s', tool.version, SqliteRunner.describe(tool))
            LrDialogs.message(SQLITE_TITLE, 'sqlite3 ' .. tool.version .. '\n' .. SqliteRunner.describe(tool), 'info')
        else
            propertyTable.sqliteResult = 'Not found'
            Log.warn('sqlite3 check: %s', problem)
            LrDialogs.message(SQLITE_TITLE, problem, 'critical')
        end
    end)
end

local provider = {}

function provider.startDialog(propertyTable)
    local settings = Settings.read(LrPrefs.prefsForPlugin())
    for _, key in ipairs(Settings.KEYS) do
        propertyTable[key] = settings[key]
    end
    propertyTable.testResult = ''
    propertyTable.sqliteResult = ''
end

function provider.endDialog(propertyTable)
    local prefs = LrPrefs.prefsForPlugin()
    Settings.write(prefs, propertyTable)
    local saved = Settings.read(prefs)
    Log.info('settings saved (server URL: "%s", %d path mapping(s), sqlite3 path: "%s")', saved.serverUrl,
        #Settings.mappings(saved), saved.sqlitePath)
end

function provider.sectionsForTopOfDialog(f, propertyTable)
    local function label(title)
        return f:static_text { title = title, alignment = 'right', width = share 'labelWidth' }
    end
    local function field(key, chars)
        return f:edit_field { value = bind(key), immediate = true, width_in_chars = chars or 36 }
    end
    local function note(title)
        return f:row {
            label '',
            f:static_text { title = title },
        }
    end

    local rows = {
        title = 'LR Remote Previews',
        bind_to_object = propertyTable,
        f:row {
            label 'Server URL:',
            field 'serverUrl',
        },
        note 'For example http://nas.local:8787',
        f:row {
            label 'Access token:',
            f:password_field { value = bind 'token', width_in_chars = 36 },
        },
        note 'Leave empty when the server runs without a token.',
        f:row {
            label 'Path mappings:',
            f:static_text { title = 'local prefix', width_in_chars = 24 },
            f:static_text { title = 'server root id' },
        },
    }
    for i = 1, Settings.MAPPING_COUNT do
        rows[#rows + 1] = f:row {
            label(tostring(i) .. ':'),
            field('localPrefix' .. i, 24),
            f:static_text { title = '->' },
            field('rootId' .. i, 12),
        }
    end
    rows[#rows + 1] = note('Photos under a local prefix (for example Z:\\) are found on the server under the root')
    rows[#rows + 1] = note('with that id (for example archive). The longest matching prefix wins.')
    rows[#rows + 1] = f:row {
        label 'sqlite3 tool:',
        field 'sqlitePath',
    }
    rows[#rows + 1] = note('Optional. Empty: sqlite3.exe (Windows) or sqlite3 next to the plug-in\'s Info.lua,')
    rows[#rows + 1] = note('then sqlite3 on the PATH. Used read-only to find the catalog\'s file ids.')
    rows[#rows + 1] = f:row {
        label '',
        f:push_button {
            title = 'Check sqlite3',
            action = function()
                checkSqlite(propertyTable)
            end,
        },
        f:static_text { title = bind 'sqliteResult', fill_horizontal = 1, width_in_chars = 50 },
    }
    rows[#rows + 1] = f:row {
        label '',
        f:push_button {
            title = 'Test connection',
            action = function()
                testConnection(propertyTable)
            end,
        },
        f:static_text { title = bind 'testResult', fill_horizontal = 1, width_in_chars = 50 },
    }
    return { rows }
end

return provider
