-- Thin wrapper over LrLogger. Messages go to LRRemotePreviews.log in Lightroom's log folder. Seen with
-- Lightroom Classic 15.6 on Windows: %LOCALAPPDATA%\Adobe\Lightroom\Logs\LrClassicLogs (older versions used a
-- LrClassicLogs folder inside the user's Documents folder).
-- Usage: local Log = require 'Log'; Log.info('built %d previews', n)
local LrLogger = import 'LrLogger'

local logger = LrLogger('LRRemotePreviews')
logger:enable('logfile')

local Log = {}

local function format(fmt, ...)
    if select('#', ...) == 0 then
        return tostring(fmt)
    end
    local ok, text = pcall(string.format, fmt, ...)
    if ok then
        return text
    end
    return tostring(fmt) .. ' [log format error: ' .. tostring(text) .. ']'
end

function Log.trace(fmt, ...)
    logger:trace(format(fmt, ...))
end

function Log.info(fmt, ...)
    logger:info(format(fmt, ...))
end

function Log.warn(fmt, ...)
    logger:warn(format(fmt, ...))
end

function Log.error(fmt, ...)
    logger:error(format(fmt, ...))
end

return Log
