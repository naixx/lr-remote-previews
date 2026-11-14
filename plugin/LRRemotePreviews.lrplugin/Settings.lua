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
Settings.TEXT_KEYS = { 'serverUrl', 'token' }
for i = 1, Settings.MAPPING_COUNT do
    Settings.TEXT_KEYS[#Settings.TEXT_KEYS + 1] = 'localPrefix' .. i
    Settings.TEXT_KEYS[#Settings.TEXT_KEYS + 1] = 'rootId' .. i
end
Settings.TEXT_KEYS[#Settings.TEXT_KEYS + 1] = 'sqlitePath'

-- Settings that are not text (version 0.3.0):
-- downloadConcurrency: how many smart previews are downloaded at the same time (placing stays one at a time)
-- autoFetch:           fetch ready smart previews in the background while Lightroom runs
-- autoFetchInterval:   seconds between two rounds of the automatic loop (30 seconds to 30 minutes)
-- and version 0.4.0:
-- autoSend:            send raw photos added to the catalog that have no smart preview, in the same loop
Settings.OPTIONS = {
    downloadConcurrency = { kind = 'integer', default = 4, min = 1, max = 8 },
    autoFetch = { kind = 'boolean', default = false },
    autoFetchInterval = { kind = 'integer', default = 60, min = 30, max = 1800 },
    autoSend = { kind = 'boolean', default = false },
}
Settings.OPTION_KEYS = { 'downloadConcurrency', 'autoFetch', 'autoFetchInterval', 'autoSend' }

-- The choices of «Import a folder without the dialog...» (version 0.6.0), remembered from one run to the next. They
-- are not part of the Plug-in Manager's section (Settings.KEYS), so that closing the Plug-in Manager never overwrites
-- them. (Version 0.5.0's «Add a folder without previews...» kept addFolder* keys; they are no longer read.)
-- importFolderSend: send the imported photos to the server afterwards (offered when a server and a path mapping are
--                   set up)
-- importFolderLast: (text) the folder chosen last; the folder dialog opens in the folder that holds it
Settings.IMPORT_FOLDER_OPTIONS = {
    importFolderSend = { kind = 'boolean', default = true },
}
Settings.IMPORT_FOLDER_KEYS = { 'importFolderSend' }

-- The choices the Plug-in Manager offers.
Settings.CONCURRENCY_CHOICES = { 1, 2, 3, 4, 5, 6, 7, 8 }
Settings.INTERVAL_CHOICES = { 30, 60, 120, 300, 600, 1800 }

-- Every key the settings section holds.
Settings.KEYS = {}
for _, key in ipairs(Settings.TEXT_KEYS) do
    Settings.KEYS[#Settings.KEYS + 1] = key
end
for _, key in ipairs(Settings.OPTION_KEYS) do
    Settings.KEYS[#Settings.KEYS + 1] = key
end

local function trim(value)
    if type(value) ~= 'string' then
        return ''
    end
    return (value:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- A stored value of an option (an entry of Settings.OPTIONS or Settings.IMPORT_FOLDER_OPTIONS) in its kind, within
-- its bounds; the default when missing or unusable.
local function optionValue(option, value)
    if option.kind == 'boolean' then
        if type(value) == 'boolean' then
            return value
        end
        return option.default
    end
    local number = tonumber(value)
    if not number or number ~= number then
        return option.default
    end
    number = math.floor(number)
    return math.max(option.min, math.min(option.max, number))
end

-- A stored option value in its kind, within its bounds; the default when missing or unusable.
function Settings.option(key, value)
    return optionValue(Settings.OPTIONS[key], value)
end

-- The remembered choices of «Import a folder without the dialog...»: the Settings.IMPORT_FOLDER_KEYS in their kind
-- (the default when missing) and importFolderLast as text ('' when missing).
function Settings.readImportFolder(store)
    local choices = {}
    for _, key in ipairs(Settings.IMPORT_FOLDER_KEYS) do
        choices[key] = optionValue(Settings.IMPORT_FOLDER_OPTIONS[key], store and store[key])
    end
    choices.importFolderLast = trim(store and store.importFolderLast)
    return choices
end

-- Remembers the choices of «Import a folder without the dialog...». Only the keys present in values are written, so
-- a choice the dialog did not offer (sending, when no server is set up) keeps its remembered value.
function Settings.writeImportFolder(store, values)
    for _, key in ipairs(Settings.IMPORT_FOLDER_KEYS) do
        if values[key] ~= nil then
            store[key] = optionValue(Settings.IMPORT_FOLDER_OPTIONS[key], values[key])
        end
    end
    if values.importFolderLast ~= nil then
        store.importFolderLast = trim(values.importFolderLast)
    end
end

-- Returns a plain table with every key from Settings.KEYS; missing text values become '', missing options their
-- default.
function Settings.read(store)
    local settings = {}
    for _, key in ipairs(Settings.TEXT_KEYS) do
        settings[key] = trim(store and store[key])
    end
    if store and store.localPrefix1 == nil and store.rootId1 == nil then
        settings.localPrefix1 = trim(store.localPrefix)
        settings.rootId1 = trim(store.rootId)
    end
    for _, key in ipairs(Settings.OPTION_KEYS) do
        settings[key] = Settings.option(key, store and store[key])
    end
    return settings
end

-- Copies every key from Settings.KEYS from values into store (text trimmed, options in their kind and bounds),
-- and mapping 1 into the 0.1.0 keys.
function Settings.write(store, values)
    for _, key in ipairs(Settings.TEXT_KEYS) do
        store[key] = trim(values[key])
    end
    for _, key in ipairs(Settings.OPTION_KEYS) do
        store[key] = Settings.option(key, values[key])
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
