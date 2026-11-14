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

local function downloadFrom(settings, url)
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

-- GET /api/v1/items/{id}/file. Returns the file content (a string), or nil plus a problem.
function ServerClient.download(settings, itemId)
    local root, problem = base(settings)
    if not root then
        return nil, problem
    end
    return downloadFrom(settings, Jobs.fileUrl(root, itemId))
end

-- GET /api/v1/files/{key}. Returns the file content, or nil plus a problem (problem.code 'not_in_cache' when the
-- server no longer has it).
function ServerClient.downloadByKey(settings, key)
    local root, problem = base(settings)
    if not root then
        return nil, problem
    end
    local url, urlError = Jobs.fileByKeyUrl(root, key)
    if not url then
        return nil, { kind = 'badJson', message = 'The server named the file with an invalid key (' .. urlError
            .. ').' }
    end
    return downloadFrom(settings, url)
end

-- GET /api/v1/jobs?clientId=. Returns the jobs (Jobs.parseJobList), or nil plus a problem. quiet: no log line on
-- success (the automatic fetch asks every minute).
function ServerClient.listJobs(settings, clientId, quiet)
    local root, problem = base(settings)
    if not root then
        return nil, problem
    end
    local url = Jobs.listUrl(root, clientId)
    if not quiet then
        Log.info('GET %s', url)
    end
    local body, status, transportError = exchange('GET', url, settings.token, nil, TIMEOUT_SECONDS)
    local decoded, failure = HttpJson.decode(body, status, transportError, hasToken(settings))
    if not decoded then
        Log.warn('listing the jobs failed: %s', failure.message)
        return nil, failure
    end
    local jobs, err = Jobs.parseJobList(decoded)
    if not jobs then
        return nil, { kind = 'badJson', message = 'The list of jobs is not as expected: ' .. err .. '.' }
    end
    return jobs
end

-- Every item of a job in one state with seq > since, all pages. Returns the items (ordered by seq), or nil plus a
-- problem; problem.gone is set when the server no longer knows the job.
-- isCanceled (optional) is asked between pages; a cancel returns nil plus { kind = 'cancelled' }.
function ServerClient.readItems(settings, jobId, since, state, isCanceled)
    local root, problem = base(settings)
    if not root then
        return nil, problem
    end
    local items = {}
    while true do
        if isCanceled and isCanceled() then
            return nil, { kind = 'cancelled', message = 'Cancelled.' }
        end
        local url = Jobs.itemsUrl(root, jobId, since, Jobs.READ_LIMIT, state)
        Log.trace('GET %s', url)
        local body, status, transportError = exchange('GET', url, settings.token, nil, TIMEOUT_SECONDS)
        local decoded, failure = HttpJson.decode(body, status, transportError, hasToken(settings))
        if not decoded then
            failure.gone = failure.status == 404
            return nil, failure
        end
        local page, err = Jobs.parseItemsPage(decoded)
        if not page then
            return nil, { kind = 'badJson', message = 'The list of items is not as expected: ' .. err .. '.' }
        end
        for _, item in ipairs(page.items) do
            items[#items + 1] = item
            if item.seq > since then
                since = item.seq
            end
        end
        if not page.more or #page.items == 0 then
            return items
        end
    end
end

-- POST /api/v1/lookup for entries { ref, rootId, relativePath }. Returns the answers keyed by ref
-- (Jobs.parseLookup), or nil plus a problem.
function ServerClient.lookup(settings, entries)
    local root, problem = base(settings)
    if not root then
        return nil, problem
    end
    local body, bodyError = Jobs.lookupBody(entries)
    if not body then
        return nil, { kind = 'request', message = 'Cannot build the lookup request: ' .. bodyError .. '.' }
    end
    local url = Jobs.lookupUrl(root)
    Log.info('POST %s (%d file(s))', url, #entries)
    local answer, status, transportError = exchange('POST', url, settings.token, body, JOB_TIMEOUT_SECONDS)
    local decoded, failure = HttpJson.decode(answer, status, transportError, hasToken(settings))
    if not decoded then
        if failure.status == 404 or failure.status == 405 then
            failure.message = 'The server cannot look files up; it needs to be version 0.3.0 or newer. '
                .. failure.message
        end
        Log.warn('lookup failed: %s', failure.message)
        return nil, failure
    end
    local byRef, err = Jobs.parseLookup(decoded, entries)
    if not byRef then
        return nil, { kind = 'badJson', message = 'The answer to the lookup is not as expected: ' .. err .. '.' }
    end
    return byRef
end

-- POST /api/v1/jobs/{id}/retry. Returns the job, or nil plus a problem.
function ServerClient.retryJob(settings, jobId)
    local root, problem = base(settings)
    if not root then
        return nil, problem
    end
    local url = Jobs.retryUrl(root, jobId)
    Log.info('POST %s', url)
    local body, status, transportError = exchange('POST', url, settings.token, nil, TIMEOUT_SECONDS)
    local decoded, failure = HttpJson.decode(body, status, transportError, hasToken(settings))
    if not decoded then
        if failure.code == 'job_cancelled' then
            failure.message = 'Job ' .. tostring(jobId) .. ' was cancelled; its items cannot be retried. '
                .. failure.message
        end
        Log.warn('retrying job %s failed: %s', tostring(jobId), failure.message)
        return nil, failure
    end
    local job, err = Jobs.parseJobAnswer(decoded)
    if not job then
        return nil, { kind = 'badJson', message = 'The answer to the retry is not as expected: ' .. err .. '.' }
    end
    return job
end

return ServerClient
