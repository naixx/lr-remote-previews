-- Library > Plug-in Extras > Server status...: asks the server for GET /api/v1/info and shows the answer.
local LrDialogs = import 'LrDialogs'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'

local ServerClient = require 'ServerClient'
local ServerInfo = require 'ServerInfo'
local Settings = require 'Settings'

local TITLE = 'LR Remote Previews: server status'

LrTasks.startAsyncTask(function()
    local settings = Settings.read(LrPrefs.prefsForPlugin())
    if settings.serverUrl == '' then
        LrDialogs.message(TITLE, 'No server is configured yet. Enter its URL in '
            .. 'File > Plug-in Manager > LR Remote Previews.', 'info')
        return
    end
    local info, problem = ServerClient.fetchInfo(settings)
    if info then
        LrDialogs.message(TITLE, ServerInfo.formatReport(info, { serverUrl = settings.serverUrl,
            mappings = Settings.mappings(settings) }), 'info')
    else
        LrDialogs.message(TITLE, problem.message, 'critical')
    end
end)
