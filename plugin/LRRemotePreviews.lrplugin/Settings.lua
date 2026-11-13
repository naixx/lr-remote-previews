-- The plug-in's settings, read from and written to a key-value store. In Lightroom the store is
-- LrPrefs.prefsForPlugin() (or the Plug-in Manager's property table); the caller passes it in, so this
-- module is pure Lua and runs in unit tests.
local Settings = {}

-- serverUrl:   base URL of the server, e.g. http://nas.local:8787
-- token:       access token sent as "Authorization: Bearer <token>"; empty = no token
-- localPrefix: local folder that the server sees as a root, e.g. Z:\
-- rootId:      id of that root on the server, e.g. archive
Settings.KEYS = { 'serverUrl', 'token', 'localPrefix', 'rootId' }

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
    return settings
end

-- Copies every key from Settings.KEYS from values into store, trimmed.
function Settings.write(store, values)
    for _, key in ipairs(Settings.KEYS) do
        store[key] = trim(values[key])
    end
end

-- The path mappings in the form PathMap.map() takes. Stage 0 stores a single mapping.
function Settings.mappings(settings)
    if settings.localPrefix ~= '' and settings.rootId ~= '' then
        return { { localPrefix = settings.localPrefix, rootId = settings.rootId } }
    end
    return {}
end

return Settings
