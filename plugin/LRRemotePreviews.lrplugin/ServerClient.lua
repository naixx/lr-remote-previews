-- Talks to the server over LrHttp. The checking and wording live in ServerInfo (pure, unit tested).
local LrHttp = import 'LrHttp'
local LrTasks = import 'LrTasks'

local Log = require 'Log'
local ServerInfo = require 'ServerInfo'

local ServerClient = {}

local TIMEOUT_SECONDS = 15

local function transportErrorText(response)
    local err = response.error
    if type(err) ~= 'table' then
        return nil
    end
    local name, code = err.name, err.errorCode
    if name and code and tostring(name) ~= tostring(code) then
        return tostring(name) .. ' (' .. tostring(code) .. ')'
    end
    return tostring(name or code or 'network error')
end

-- GET <serverUrl>/api/v1/info. Must run inside an LrTasks task, because LrHttp waits for the answer.
-- settings: as returned by Settings.read. Returns info (see ServerInfo.normalize), or nil plus a problem
-- { kind, message, status } where kind is 'notConfigured' or one of ServerInfo.fromHttpResponse's kinds.
function ServerClient.fetchInfo(settings)
    local url, urlError = ServerInfo.infoUrl(settings.serverUrl)
    if not url then
        return nil, { kind = 'notConfigured', message = urlError }
    end
    local sentToken = settings.token ~= nil and settings.token ~= ''
    Log.info('GET %s (access token: %s)', url, sentToken and 'yes' or 'no')

    local ok, body, response = LrTasks.pcall(function()
        return LrHttp.get(url, ServerInfo.requestHeaders(settings.token), TIMEOUT_SECONDS)
    end)
    local info, problem
    if not ok then
        info, problem = ServerInfo.fromHttpResponse(nil, nil, tostring(body), sentToken)
    else
        if type(response) ~= 'table' then
            response = {}
        end
        info, problem = ServerInfo.fromHttpResponse(body, response.status, transportErrorText(response), sentToken)
    end

    if info then
        Log.info('server: %s %s, API %s, converter installed: %s, %d root(s)', info.name, info.version,
            tostring(info.api), tostring(info.converter.installed), #info.roots)
    else
        Log.warn('server info failed (%s): %s', problem.kind, problem.message)
    end
    return info, problem
end

return ServerClient
