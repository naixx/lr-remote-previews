-- JSON over HTTP for the server's API: request headers, and turning what LrHttp returned into a decoded body
-- or a problem. Pure Lua 5.1: no Lightroom imports, so it runs in unit tests.
--
-- Error bodies follow docs/protocol.md: {"detail": "<text for a person>", "code": "<identifier>"}, code optional.
local Json = require 'Json'

local HttpJson = {}

local SETTINGS_HINT = 'File > Plug-in Manager > LR Remote Previews'
local MAX_DETAIL_LENGTH = 300

local function trim(value)
    return (value:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Request headers in LrHttp's form: an array of { field = ..., value = ... }. hasJsonBody adds the
-- Content-Type of a JSON request body.
function HttpJson.headers(token, hasJsonBody)
    local headers = { { field = 'Accept', value = 'application/json' } }
    if hasJsonBody then
        headers[#headers + 1] = { field = 'Content-Type', value = 'application/json' }
    end
    if type(token) == 'string' and trim(token) ~= '' then
        headers[#headers + 1] = { field = 'Authorization', value = 'Bearer ' .. trim(token) }
    end
    return headers
end

-- { detail = ..., code = ... } from an error body; a field is nil when absent. detail is shortened.
function HttpJson.errorInfo(body)
    if type(body) ~= 'string' then
        return {}
    end
    local ok, decoded = pcall(Json.decode, body)
    if not ok or type(decoded) ~= 'table' then
        return {}
    end
    local info = {}
    if type(decoded.detail) == 'string' and decoded.detail ~= '' then
        info.detail = decoded.detail
        if #info.detail > MAX_DETAIL_LENGTH then
            info.detail = info.detail:sub(1, MAX_DETAIL_LENGTH) .. '...'
        end
    end
    if type(decoded.code) == 'string' and decoded.code ~= '' then
        info.code = decoded.code
    end
    return info
end

local function problem(kind, message, status, code)
    return { kind = kind, message = message, status = status, code = code }
end

-- Classifies an HTTP exchange. Returns nil for a 2xx answer, otherwise a problem
-- { kind, message, status, code }, kind one of 'unreachable', 'unauthorized', 'http'.
--   body, status:   what LrHttp returned (status may be a number, a string or nil)
--   transportError: text of a network-level error, nil when an answer arrived
--   sentToken:      whether the request carried an access token
function HttpJson.problem(body, status, transportError, sentToken)
    if transportError ~= nil then
        return problem('unreachable', 'Cannot reach the server: ' .. tostring(transportError) .. '.')
    end
    status = tonumber(status)
    if status == nil then
        if body == nil then
            return problem('unreachable', 'The server did not answer.')
        end
        return nil -- LrHttp gave a body without a status; treat it as an answer and let the caller check it
    end
    if status >= 200 and status <= 299 then
        return nil
    end
    local info = HttpJson.errorInfo(body)
    local message
    if status == 401 or status == 403 then
        if sentToken then
            message = 'The server did not accept the access token (HTTP ' .. status .. ').'
        else
            message = 'The server needs an access token (HTTP ' .. status .. '). Enter it in ' .. SETTINGS_HINT .. '.'
        end
        if info.detail then
            message = message .. ' Server says: ' .. info.detail
        end
        return problem('unauthorized', message, status, info.code)
    end
    message = 'The server answered HTTP ' .. status .. '.'
    if info.detail then
        message = message .. ' Server says: ' .. info.detail
    end
    return problem('http', message, status, info.code)
end

-- Like HttpJson.problem, but also decodes a 2xx body as a JSON object.
-- Returns the decoded table and the status, or nil plus a problem (kind 'badJson' for a body that is not one).
function HttpJson.decode(body, status, transportError, sentToken)
    local failure = HttpJson.problem(body, status, transportError, sentToken)
    if failure then
        return nil, failure
    end
    status = tonumber(status)
    if type(body) ~= 'string' or not body:find('%S') then
        return nil, problem('badJson', 'The server sent an empty answer.', status)
    end
    local ok, decoded = pcall(Json.decode, body)
    if not ok then
        local reason = tostring(decoded):gsub('^.-:%d+: ', '') -- drop the "Json.lua:185: " location
        return nil, problem('badJson', 'The server answer is not valid JSON (' .. reason .. ').', status)
    end
    if type(decoded) ~= 'table' or decoded[1] ~= nil then
        return nil, problem('badJson', 'The server answer is not a JSON object.', status)
    end
    return decoded, status
end

return HttpJson
