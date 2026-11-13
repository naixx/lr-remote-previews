-- The plug-in's settings, read from and written to a key-value store. In Lightroom the store is
-- LrPrefs.prefsForPlugin() (or the Plug-in Manager's property table); the caller passes it in, so this
-- module is pure Lua and runs in unit tests.
local PathMap = require 'PathMap'

local Settings = {}

Settings.MAPPING_COUNT = 3

-- serverUrl:     base URL of the server, e.g. http://nas.local:8787
-- token:         access token sent as "Authorization: Bearer <token>"; empty = no token
-- localPrefixN:  local folder that the server sees as a root, e.g. Z:\  (N = 1 .. MAPPING_COUNT)
-- rootIdN:       id of that root on the server, e.g. archive
-- sqlitePath:    the sqlite3 command-line tool; empty = look next to the plug-in, then on the PATH
-- Version 0.1.0 stored a single mapping as localPrefix / rootId; Settings.read takes it as mapping 1 when the
-- store has no mapping 1 yet, and Settings.write keeps those two keys equal to mapping 1.
Settings.KEYS = { 'serverUrl', 'token' }
for i = 1, Settings.MAPPING_COUNT do
    Settings.KEYS[#Settings.KEYS + 1] = 'localPrefix' .. i
    Settings.KEYS[#Settings.KEYS + 1] = 'rootId' .. i
end
Settings.KEYS[#Settings.KEYS + 1] = 'sqlitePath'

local function trim(value)
    if type(value) ~= 'string' then
        return ''
    end
    return (value:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Returns a plain table with every key from Settings.KEYS; missing values become ''.
function Settings.read(store)
    local settings = {}
    for _, key in ipairs(Settings.KEYS) do
        settings[key] = trim(store and store[key])
    end
    if store and store.localPrefix1 == nil and store.rootId1 == nil then
        settings.localPrefix1 = trim(store.localPrefix)
        settings.rootId1 = trim(store.rootId)
    end
    return settings
end

-- Copies every key from Settings.KEYS from values into store, trimmed, and mapping 1 into the 0.1.0 keys.
function Settings.write(store, values)
    for _, key in ipairs(Settings.KEYS) do
        store[key] = trim(values[key])
    end
    store.localPrefix = trim(values.localPrefix1)
    store.rootId = trim(values.rootId1)
end

-- The path mappings in the form PathMap.map() takes: the rows with both halves filled in, in order.
function Settings.mappings(settings)
    local mappings = {}
    for i = 1, Settings.MAPPING_COUNT do
        local prefix, rootId = trim(settings['localPrefix' .. i]), trim(settings['rootId' .. i])
        if prefix ~= '' and rootId ~= '' then
            mappings[#mappings + 1] = { localPrefix = prefix, rootId = rootId }
        end
    end
    return mappings
end

-- Messages for mapping rows that are half filled in or invalid; an empty list when all are fine.
function Settings.mappingProblems(settings)
    local problems = {}
    for i = 1, Settings.MAPPING_COUNT do
        local prefix, rootId = trim(settings['localPrefix' .. i]), trim(settings['rootId' .. i])
        if prefix ~= '' or rootId ~= '' then
            local ok, why = PathMap.checkMapping(prefix, rootId)
            if not ok then
                problems[#problems + 1] = 'Path mapping ' .. i .. ': ' .. why .. '.'
            end
        end
    end
    return problems
end

return Settings
