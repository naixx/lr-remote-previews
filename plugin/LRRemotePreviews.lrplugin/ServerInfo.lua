-- The server's GET /api/v1/info answer: building the request, checking the response, and the text the
-- status dialog shows. Pure Lua 5.1: no Lightroom imports, so it runs in unit tests.
--
-- Contract (API 1, docs/protocol.md):
--   {"name": "LR Remote Previews", "version": "0.3.0", "api": 1, "auth": "token",
--    "converter": {"installed": false, "path": "C:\\...\\Adobe DNG Converter.exe", "version": null},
--    "roots": [{"id": "archive", "label": "Archive", "available": true}],
--    "capabilities": {"extensions": [".arw", ".cr2"], "previewLongEdge": 2560, "maxItemsPerJob": 5000,
--                     "jobRetentionDays": 30}}
-- A 401 answer carries {"detail": "..."}.
local Json = require 'Json'

local ServerInfo = {}

ServerInfo.API_VERSION = 1
ServerInfo.INFO_PATH = '/api/v1/info'

local SETTINGS_HINT = 'File > Plug-in Manager > LR Remote Previews'
local MAX_DETAIL_LENGTH = 300

local function trim(value)
    return (value:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Server URL ----------------------------------------------------------------------------------------------

-- The base URL without trailing slashes, e.g. 'http://nas.local:8787'; or nil plus a message.
-- A path is allowed (for a server behind a reverse proxy): 'https://example.org/lrrp'.
function ServerInfo.baseUrl(url)
    if type(url) ~= 'string' or trim(url) == '' then
        return nil, 'No server URL is set. Enter it in ' .. SETTINGS_HINT .. '.'
    end
    url = trim(url)
    if not url:lower():match('^https?://[^/%s?#]') then
        return nil, 'The server URL must start with http:// or https:// and a host name, '
            .. 'e.g. http://nas.local:8787 (got "' .. url .. '").'
    end
    if url:find('[%s?#]') then
        return nil, 'The server URL must not contain spaces, "?" or "#" (got "' .. url .. '").'
    end
    return (url:gsub('/+$', ''))
end

-- The URL of the info endpoint; or nil plus a message.
function ServerInfo.infoUrl(serverUrl)
    local base, err = ServerInfo.baseUrl(serverUrl)
    if not base then
        return nil, err
    end
    return base .. ServerInfo.INFO_PATH
end

-- Request headers in LrHttp's form: an array of { field = ..., value = ... }.
function ServerInfo.requestHeaders(token)
    local headers = { { field = 'Accept', value = 'application/json' } }
    if type(token) == 'string' and trim(token) ~= '' then
        headers[#headers + 1] = { field = 'Authorization', value = 'Bearer ' .. trim(token) }
    end
    return headers
end

-- Validation ----------------------------------------------------------------------------------------------

-- Validation errors are raised as { invalidInfo = message } and caught in ServerInfo.normalize.
local function fail(message)
    error({ invalidInfo = message }, 0)
end

local function isList(value)
    local count = 0
    for _ in pairs(value) do
        count = count + 1
    end
    return count == #value
end

local function requiredString(object, key, name)
    local value = object[key]
    if type(value) ~= 'string' or value == '' then
        fail('"' .. (name or key) .. '" must be a non-empty string')
    end
    return value
end

local TYPE_NAMES = { string = 'a string', number = 'a number', boolean = 'true or false', table = 'an object' }

local function optionalOfType(object, key, name, expected)
    local value = object[key]
    if value ~= nil and type(value) ~= expected then
        fail('"' .. (name or key) .. '" must be ' .. TYPE_NAMES[expected])
    end
    return value
end

local function optionalObject(object, key, name)
    local value = optionalOfType(object, key, name, 'table')
    if value ~= nil and value[1] ~= nil then
        fail('"' .. (name or key) .. '" must be an object')
    end
    return value
end

local function optionalList(object, key, name)
    local value = object[key]
    if value ~= nil and (type(value) ~= 'table' or not isList(value)) then
        fail('"' .. (name or key) .. '" must be a list')
    end
    return value
end

local function build(decoded)
    if type(decoded) ~= 'table' or decoded[1] ~= nil then
        fail('the response is not a JSON object')
    end
    local info = {
        name = requiredString(decoded, 'name'),
        version = requiredString(decoded, 'version'),
        api = decoded.api,
        auth = optionalOfType(decoded, 'auth', nil, 'string') or 'unknown',
    }
    if type(info.api) ~= 'number' then
        fail('"api" must be a number')
    end
    info.apiSupported = info.api == ServerInfo.API_VERSION

    local converter = optionalObject(decoded, 'converter') or {}
    info.converter = {
        installed = optionalOfType(converter, 'installed', 'converter.installed', 'boolean') == true,
        path = optionalOfType(converter, 'path', 'converter.path', 'string'),
        version = optionalOfType(converter, 'version', 'converter.version', 'string'),
    }

    info.roots = {}
    for i, root in ipairs(optionalList(decoded, 'roots') or {}) do
        local name = 'roots[' .. i .. ']'
        if type(root) ~= 'table' or root[1] ~= nil then
            fail('"' .. name .. '" must be an object')
        end
        local id = requiredString(root, 'id', name .. '.id')
        info.roots[i] = {
            id = id,
            label = optionalOfType(root, 'label', name .. '.label', 'string') or id,
            available = optionalOfType(root, 'available', name .. '.available', 'boolean') == true,
        }
    end

    local capabilities = optionalObject(decoded, 'capabilities') or {}
    info.capabilities = {
        extensions = {},
        previewLongEdge = optionalOfType(capabilities, 'previewLongEdge', 'capabilities.previewLongEdge', 'number'),
        maxItemsPerJob = optionalOfType(capabilities, 'maxItemsPerJob', 'capabilities.maxItemsPerJob', 'number'),
        jobRetentionDays = optionalOfType(capabilities, 'jobRetentionDays', 'capabilities.jobRetentionDays',
            'number'),
        appendItems = optionalOfType(capabilities, 'appendItems', 'capabilities.appendItems', 'boolean') == true,
        maxWaitSeconds = optionalOfType(capabilities, 'maxWaitSeconds', 'capabilities.maxWaitSeconds', 'number'),
    }
    for i, extension in ipairs(optionalList(capabilities, 'extensions', 'capabilities.extensions') or {}) do
        if type(extension) ~= 'string' then
            fail('"capabilities.extensions[' .. i .. ']" must be a string')
        end
        info.capabilities.extensions[i] = extension:lower()
    end
    return info
end

-- Checks a decoded info document and returns a normalised copy:
--   { name, version, api, apiSupported, auth ('unknown' when missing),
--     converter = { installed (boolean), path (or nil), version (or nil) },
--     roots = { { id, label (defaults to id), available (boolean) }, ... },
--     capabilities = { extensions = { lower-case strings }, previewLongEdge (or nil), maxItemsPerJob (or nil),
--                      jobRetentionDays (or nil), appendItems (boolean; false when absent: servers before 0.6.0),
--                      maxWaitSeconds (or nil: the server cannot hold a request) } }
-- Unknown fields are ignored. Returns nil plus a message when a field is missing or has the wrong type.
function ServerInfo.normalize(decoded)
    local ok, result = pcall(build, decoded)
    if ok then
        return result
    end
    if type(result) == 'table' and result.invalidInfo then
        return nil, result.invalidInfo
    end
    error(result, 0)
end

-- HTTP response -------------------------------------------------------------------------------------------

local function problem(kind, message, status)
    return { kind = kind, message = message, status = status }
end

local function detailFrom(body)
    if type(body) ~= 'string' then
        return nil
    end
    local ok, decoded = pcall(Json.decode, body)
    if not ok or type(decoded) ~= 'table' or type(decoded.detail) ~= 'string' or decoded.detail == '' then
        return nil
    end
    local detail = decoded.detail
    if #detail > MAX_DETAIL_LENGTH then
        detail = detail:sub(1, MAX_DETAIL_LENGTH) .. '...'
    end
    return detail
end

-- Turns what LrHttp.get returned into server info, or nil plus a problem { kind, message, status }.
--   body:           response body (string or nil)
--   status:         HTTP status code (number, string or nil)
--   transportError: text of a network-level error (nil when a response arrived)
--   sentToken:      whether the request carried an access token
-- Problem kinds: 'unreachable', 'unauthorized', 'http', 'badJson', 'badInfo'.
function ServerInfo.fromHttpResponse(body, status, transportError, sentToken)
    if transportError ~= nil then
        return nil, problem('unreachable', 'Cannot reach the server: ' .. tostring(transportError) .. '.')
    end
    status = tonumber(status)
    if status == nil and body == nil then
        return nil, problem('unreachable', 'The server did not answer.')
    end
    if status == 401 or status == 403 then
        local message
        if sentToken then
            message = 'The server did not accept the access token (HTTP ' .. status .. ').'
        else
            message = 'The server needs an access token (HTTP ' .. status .. '). Enter it in ' .. SETTINGS_HINT .. '.'
        end
        local detail = detailFrom(body)
        if detail then
            message = message .. ' Server says: ' .. detail
        end
        return nil, problem('unauthorized', message, status)
    end
    if status ~= nil and (status < 200 or status > 299) then
        local message = 'The server answered HTTP ' .. status .. '.'
        if status == 404 then
            message = message .. ' Check that the URL points to an LR Remote Previews server.'
        end
        local detail = detailFrom(body)
        if detail then
            message = message .. ' Server says: ' .. detail
        end
        return nil, problem('http', message, status)
    end
    if type(body) ~= 'string' or not body:find('%S') then
        return nil, problem('badJson', 'The server sent an empty answer.', status)
    end
    local ok, decoded = pcall(Json.decode, body)
    if not ok then
        local reason = tostring(decoded):gsub('^.-:%d+: ', '')  -- drop the "Json.lua:185: " location
        return nil, problem('badJson', 'The server answer is not valid JSON (' .. reason .. ').', status)
    end
    local info, err = ServerInfo.normalize(decoded)
    if not info then
        return nil, problem('badInfo', 'The server answer is not an LR Remote Previews info document: ' .. err .. '.',
            status)
    end
    return info
end

-- Text ----------------------------------------------------------------------------------------------------

-- The root with this id, or nil.
function ServerInfo.findRoot(info, rootId)
    for _, root in ipairs(info.roots) do
        if root.id == rootId then
            return root
        end
    end
    return nil
end

local function authText(auth)
    if auth == 'token' then
        return 'access token required'
    elseif auth == 'none' then
        return 'no access token required'
    end
    return auth
end

-- One line for the Plug-in Manager, e.g. 'LR Remote Previews 0.1.0, converter not installed, 1 root'.
function ServerInfo.summary(info)
    local roots = #info.roots == 1 and '1 root' or (#info.roots .. ' roots')
    return string.format('%s %s, converter %s, %s', info.name, info.version,
        info.converter.installed and 'installed' or 'not installed', roots)
end

-- What the server says about a root id: 'available', 'not on this server' or 'on this server but not available'.
function ServerInfo.rootState(info, rootId)
    local root = ServerInfo.findRoot(info, rootId)
    if not root then
        return 'not on this server'
    elseif root.available then
        return 'available'
    end
    return 'on this server but not available'
end

-- The status dialog's text. settings (optional) gives serverUrl and the path mappings to show: mappings =
-- { { localPrefix, rootId }, ... } (Settings.mappings), or a single localPrefix / rootId.
function ServerInfo.formatReport(info, settings)
    settings = settings or {}
    local lines = {}
    local function add(line)
        lines[#lines + 1] = line
    end

    add(info.name .. ' ' .. info.version)
    local address = settings.serverUrl and (ServerInfo.baseUrl(settings.serverUrl) or settings.serverUrl)
    if address and address ~= '' then
        add('Address: ' .. address)
    end
    if info.apiSupported then
        add('API: ' .. tostring(info.api))
    else
        add('API: ' .. tostring(info.api) .. ' (this plug-in speaks API ' .. ServerInfo.API_VERSION
            .. '; update the plug-in or the server)')
    end
    add('Access: ' .. authText(info.auth))

    local converter = info.converter
    if converter.installed then
        add('Adobe DNG Converter: installed' .. (converter.version and (', version ' .. converter.version) or ''))
    else
        add('Adobe DNG Converter: not installed')
    end
    if converter.path then
        add('Converter path: ' .. converter.path)
    end

    if #info.roots == 0 then
        add('Roots: none')
    else
        add('Roots:')
        for _, root in ipairs(info.roots) do
            local state = root.available and 'available' or 'not available'
            add(string.format('    %s (%s): %s', root.id, root.label, state))
        end
    end

    local mappings = settings.mappings
    if mappings == nil and settings.rootId and settings.rootId ~= '' then
        mappings = { { localPrefix = settings.localPrefix or '', rootId = settings.rootId } }
    end
    for _, mapping in ipairs(mappings or {}) do
        add(string.format('Path mapping: %s -> %s (%s)', mapping.localPrefix, mapping.rootId,
            ServerInfo.rootState(info, mapping.rootId)))
    end
    return table.concat(lines, '\n')
end

-- A few words for the Plug-in Manager's result line.
function ServerInfo.shortProblem(problemTable)
    local texts = {
        notConfigured = 'no valid server URL',
        unreachable = 'server not reachable',
        unauthorized = 'access token rejected',
        http = 'HTTP error ' .. tostring(problemTable.status),
        badJson = 'not a valid answer',
        badInfo = 'not an LR Remote Previews server',
    }
    return texts[problemTable.kind] or tostring(problemTable.kind)
end

return ServerInfo
