-- Talks to the server over LrHttp. The checking and wording live in pure modules (ServerInfo, HttpJson, Jobs).
-- Every function must run inside an LrTasks task, because LrHttp waits for the answer. The access token is
-- sent in a header and never logged.
local LrHttp = import 'LrHttp'
local LrTasks = import 'LrTasks'

local HttpJson = require 'HttpJson'
local Jobs = require 'Jobs'
local Log = require 'Log'
local ServerInfo = require 'ServerInfo'

local ServerClient = {}

local TIMEOUT_SECONDS = 15
local JOB_TIMEOUT_SECONDS = 60
local DOWNLOAD_TIMEOUT_SECONDS = 120

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

local function hasToken(settings)
    return settings.token ~= nil and settings.token ~= ''
end

-- One HTTP exchange. method 'GET' uses LrHttp.get; anything else LrHttp.post with that method.
-- Returns body, status, transportError (text or nil).
local function exchange(method, url, token, jsonBody, timeout)
    local headers = HttpJson.headers(token, jsonBody ~= nil)
    local ok, body, response = LrTasks.pcall(function()
        if method == 'GET' then
            return LrHttp.get(url, headers, timeout)
        end
        return LrHttp.post(url, jsonBody or '', headers, method, timeout)
    end)
    if not ok then
        return nil, nil, tostring(body)
    end
    if type(response) ~= 'table' then
        response = {}
    end
    return body, response.status, transportErrorText(response)
end

local function base(settings)
    local url, urlError = ServerInfo.baseUrl(settings.serverUrl)
    if not url then
        return nil, { kind = 'notConfigured', message = urlError }
    end
    return url
end

-- GET <serverUrl>/api/v1/info.
-- settings: as returned by Settings.read. Returns info (see ServerInfo.normalize), or nil plus a problem
-- { kind, message, status } where kind is 'notConfigured' or one of ServerInfo.fromHttpResponse's kinds.
function ServerClient.fetchInfo(settings)
    local url, urlError = ServerInfo.infoUrl(settings.serverUrl)
    if not url then
        return nil, { kind = 'notConfigured', message = urlError }
    end
    Log.info('GET %s (access token: %s)', url, hasToken(settings) and 'yes' or 'no')

    local ok, body, response = LrTasks.pcall(function()
        return LrHttp.get(url, ServerInfo.requestHeaders(settings.token), TIMEOUT_SECONDS)
    end)
    local info, problem
    if not ok then
        info, problem = ServerInfo.fromHttpResponse(nil, nil, tostring(body), hasToken(settings))
    else
        if type(response) ~= 'table' then
            response = {}
        end
        info, problem = ServerInfo.fromHttpResponse(body, response.status, transportErrorText(response),
            hasToken(settings))
    end

    if info then
        Log.info('server: %s %s, API %s, converter installed: %s, %d root(s)', info.name, info.version,
            tostring(info.api), tostring(info.converter.installed), #info.roots)
    else
        Log.warn('server info failed (%s): %s', problem.kind, problem.message)
    end
    return info, problem
end

-- POST /api/v1/jobs with a body from Jobs.createBody. Returns { job, items } or nil plus a problem
-- { kind, message, status, code }.
function ServerClient.createJob(settings, body)
    local root, problem = base(settings)
    if not root then
        return nil, problem
    end
    local url = Jobs.jobsUrl(root)
    Log.info('POST %s (%d bytes)', url, #body)
    local answer, status, transportError = exchange('POST', url, settings.token, body, JOB_TIMEOUT_SECONDS)
    local decoded, failure = HttpJson.decode(answer, status, transportError, hasToken(settings))
    if not decoded then
        return nil, failure
    end
    local created, err = Jobs.parseCreated(decoded)
    if not created then
        return nil, { kind = 'badJson', message = 'The answer to the job request is not as expected: ' .. err .. '.' }
    end
    return created
end

-- GET /api/v1/jobs/{id}/items?since=. Returns { job, items, more } or nil plus a problem; problem.fatal is set
-- when asking again cannot help (token rejected, job unknown to the server).
function ServerClient.fetchItems(settings, jobId, since)
    local root, problem = base(settings)
    if not root then
        problem.fatal = true
        return nil, problem
    end
    local url = Jobs.itemsUrl(root, jobId, since)
    Log.trace('GET %s', url)
    local body, status, transportError = exchange('GET', url, settings.token, nil, TIMEOUT_SECONDS)
    local decoded, failure = HttpJson.decode(body, status, transportError, hasToken(settings))
    if not decoded then
        failure.fatal = failure.kind == 'unauthorized' or failure.status == 404
        if failure.status == 404 then
            failure.message = 'The server no longer knows job ' .. tostring(jobId) .. '. ' .. failure.message
        end
        return nil, failure
    end
    local page, err = Jobs.parseItemsPage(decoded)
    if not page then
        return nil, { kind = 'badJson', message = 'The list of items is not as expected: ' .. err .. '.' }
    end
    return page
end

-- DELETE /api/v1/jobs/{id}. Returns true, or nil plus a problem.
function ServerClient.cancelJob(settings, jobId)
    local root, problem = base(settings)
    if not root then
        return nil, problem
    end
    local url = Jobs.jobUrl(root, jobId)
    Log.info('DELETE %s', url)
    local body, status, transportError = exchange('DELETE', url, settings.token, nil, TIMEOUT_SECONDS)
    local decoded, failure = HttpJson.decode(body, status, transportError, hasToken(settings))
    if not decoded then
        Log.warn('cancelling job %s failed: %s', tostring(jobId), failure.message)
        return nil, failure
    end
    return true
end

-- GET /api/v1/items/{id}/file. Returns the file content (a string), or nil plus a problem.
function ServerClient.download(settings, itemId)
    local root, problem = base(settings)
    if not root then
        return nil, problem
    end
    local url = Jobs.fileUrl(root, itemId)
    Log.trace('GET %s', url)
    local body, status, transportError = exchange('GET', url, settings.token, nil, DOWNLOAD_TIMEOUT_SECONDS)
    local failure = HttpJson.problem(body, status, transportError, hasToken(settings))
    if failure then
        return nil, failure
    end
    if type(body) ~= 'string' then
        return nil, { kind = 'http', message = 'The server sent no file.' }
    end
    return body
end

return ServerClient
