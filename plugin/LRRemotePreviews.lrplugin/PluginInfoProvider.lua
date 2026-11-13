-- The plug-in's section in File > Plug-in Manager: server URL, access token, one path mapping, and a
-- "Test connection" button. Values are copied from LrPrefs into the dialog's property table when the
-- section opens and written back when the dialog closes (or another plug-in is selected).
local LrDialogs = import 'LrDialogs'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local Log = require 'Log'
local PathMap = require 'PathMap'
local ServerClient = require 'ServerClient'
local ServerInfo = require 'ServerInfo'
local Settings = require 'Settings'

local bind = LrView.bind
local share = LrView.share

local TEST_TITLE = 'LR Remote Previews: test connection'

local function mappingProblem(settings)
    if settings.localPrefix == '' and settings.rootId == '' then
        return nil
    end
    local ok, why = PathMap.checkMapping(settings.localPrefix, settings.rootId)
    if ok then
        return nil
    end
    return 'Path mapping: ' .. why .. '.'
end

local function testConnection(propertyTable)
    LrTasks.startAsyncTask(function()
        local settings = Settings.read(propertyTable)
        propertyTable.testResult = 'Testing...'
        local info, problem = ServerClient.fetchInfo(settings)
        local note = mappingProblem(settings)
        if info then
            propertyTable.testResult = 'Connected: ' .. ServerInfo.summary(info)
            local text = ServerInfo.formatReport(info, settings)
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

local provider = {}

function provider.startDialog(propertyTable)
    local settings = Settings.read(LrPrefs.prefsForPlugin())
    for _, key in ipairs(Settings.KEYS) do
        propertyTable[key] = settings[key]
    end
    propertyTable.testResult = ''
end

function provider.endDialog(propertyTable)
    local prefs = LrPrefs.prefsForPlugin()
    Settings.write(prefs, propertyTable)
    Log.info('settings saved (server URL: "%s")', Settings.read(prefs).serverUrl)
end

function provider.sectionsForTopOfDialog(f, propertyTable)
    local function label(title)
        return f:static_text { title = title, alignment = 'right', width = share 'labelWidth' }
    end
    local function field(key)
        return f:edit_field { value = bind(key), immediate = true, width_in_chars = 36 }
    end
    return {
        {
            title = 'LR Remote Previews',
            bind_to_object = propertyTable,
            f:row {
                label 'Server URL:',
                field 'serverUrl',
            },
            f:row {
                label '',
                f:static_text { title = 'For example http://nas.local:8787' },
            },
            f:row {
                label 'Access token:',
                f:password_field { value = bind 'token', width_in_chars = 36 },
            },
            f:row {
                label '',
                f:static_text { title = 'Leave empty when the server runs without a token.' },
            },
            f:row {
                label 'Local prefix:',
                field 'localPrefix',
            },
            f:row {
                label 'Server root id:',
                field 'rootId',
            },
            f:row {
                label '',
                f:static_text { title = 'Photos under the local prefix (for example Z:\\) are found on the server' },
            },
            f:row {
                label '',
                f:static_text { title = 'under the root with this id (for example archive).' },
            },
            f:row {
                label '',
                f:push_button {
                    title = 'Test connection',
                    action = function()
                        testConnection(propertyTable)
                    end,
                },
                f:static_text { title = bind 'testResult', fill_horizontal = 1, width_in_chars = 50 },
            },
        },
    }
end

return provider
