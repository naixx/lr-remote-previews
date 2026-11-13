-- Maps a local file path to a server root and a path relative to that root.
-- Pure Lua 5.1: no Lightroom imports, so it runs in unit tests.
--
--   PathMap.map('Z:\\2024\\IMG_0001.ARW', { { localPrefix = 'Z:\\', rootId = 'archive' } })
--   --> { rootId = 'archive', relativePath = '2024/IMG_0001.ARW' }
--
-- Rules:
-- * The longest matching prefix wins (the first one listed on a tie). A prefix matches whole path segments
--   only: Z:\Photos matches Z:\Photos\a.arw but not Z:\Photos2\a.arw.
-- * Windows paths (a drive letter such as Z:\, or UNC such as \\server\share\) accept both slash kinds,
--   ignore repeated slashes and compare case-insensitively (ASCII letters only).
-- * Any other path is POSIX: compared case-sensitively, and a backslash is an ordinary character.
-- * The relative path uses forward slashes and has no leading slash.
-- * A path with a '.' or '..' segment after the prefix is rejected.
-- Functions return nil plus a message when they cannot give an answer.
local PathMap = {}

local function isWindowsPath(path)
    return path:match('^%a:') ~= nil or path:match('^[/\\][/\\]') ~= nil
end

-- The path in the form used for matching: Windows paths get forward slashes; repeated slashes are
-- collapsed (a leading UNC '//' stays); no trailing slash. Also returns whether it is a Windows path.
local function canonical(path)
    local windows = isWindowsPath(path)
    local lead, rest = '', path
    if windows then
        rest = rest:gsub('\\', '/')
        if rest:sub(1, 2) == '//' then
            lead, rest = '//', rest:sub(3)
        end
    end
    rest = rest:gsub('/+', '/')
    rest = rest:gsub('/$', '')
    return lead .. rest, windows
end

local function hasDotSegment(path)
    for segment in path:gmatch('[^/]+') do
        if segment == '.' or segment == '..' then
            return true
        end
    end
    return false
end

local function comparable(path, windows)
    if windows then
        return path:lower()
    end
    return path
end

-- Checks one mapping. Returns true, or nil plus a message.
function PathMap.checkMapping(localPrefix, rootId)
    if type(localPrefix) ~= 'string' or localPrefix == '' then
        return nil, 'the local prefix is empty'
    end
    if type(rootId) ~= 'string' or rootId == '' then
        return nil, 'the server root id is empty'
    end
    if rootId:find('[%s/\\]') then
        return nil, 'the server root id must not contain spaces or slashes'
    end
    local prefix, windows = canonical(localPrefix)
    if not windows and localPrefix:sub(1, 1) ~= '/' then
        return nil, 'the local prefix must be an absolute path, e.g. Z:\\ or \\\\server\\share\\ or /Volumes/Photos'
    end
    if prefix == '//' then
        return nil, 'the local prefix needs a server name after \\\\'
    end
    if hasDotSegment(prefix) then
        return nil, "the local prefix must not contain '.' or '..' segments"
    end
    return true
end

-- A key that is the same for two spellings of the same file path: Windows paths with either slash kind and
-- any letter case, repeated slashes collapsed. Returns nil for a missing or empty path.
function PathMap.fileKey(path)
    if type(path) ~= 'string' or path == '' then
        return nil
    end
    local canon, windows = canonical(path)
    return comparable(canon, windows)
end

-- Maps localPath with a list of { localPrefix = ..., rootId = ... }. Invalid mappings are skipped.
-- Returns { rootId = ..., relativePath = ... }, or nil plus a message.
function PathMap.map(localPath, mappings)
    if type(localPath) ~= 'string' or localPath == '' then
        return nil, 'no path given'
    end
    if type(mappings) ~= 'table' then
        return nil, 'no mappings given'
    end
    local path, windows = canonical(localPath)
    local key = comparable(path, windows)
    local best, bestLength
    for _, mapping in ipairs(mappings) do
        if type(mapping) == 'table' and PathMap.checkMapping(mapping.localPrefix, mapping.rootId) then
            local prefix, prefixWindows = canonical(mapping.localPrefix)
            if prefixWindows == windows then
                local prefixKey = comparable(prefix, windows)
                local length = #prefixKey
                if key:sub(1, length + 1) == prefixKey .. '/' and (bestLength == nil or length > bestLength) then
                    best, bestLength = mapping, length
                end
            end
        end
    end
    if not best then
        return nil, 'no mapping covers ' .. localPath
    end
    local relativePath = path:sub(bestLength + 2)
    if hasDotSegment(relativePath) then
        return nil, "the path contains a '.' or '..' segment: " .. localPath
    end
    return { rootId = best.rootId, relativePath = relativePath }
end

return PathMap
