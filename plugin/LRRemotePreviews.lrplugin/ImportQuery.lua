-- The read-only SELECT of «Import a folder without the dialog...» and the parsing of its output. Pure Lua 5.1: no
-- Lightroom imports. It runs through SqliteRunner.query, read-only like every catalog read of the plug-in (decision
-- record 0002); nothing writes.
--
-- The catalog tables, as found in Lightroom Classic 15.6 catalogs (schema read with sqlite3, read-only):
--   Adobe_variablesTable (id_local, id_global, name, type, value): the settings of the previous import are rows whose
--     name starts with "AgImportDialog_", for example importBehavior = "refInPlace" after an import with «Add».
--   Adobe_images (id_local, ...): one row per photo; id_local is the SDK's photo.localIdentifier.
--   AgLibraryImport (id_local, importDate, imageCount, name): one row per import.
-- id_local values of these tables come from one counter (Adobe_entityIDCounter), so photos added after the mark (the
-- largest id_local of Adobe_images and AgLibraryImport now) have larger ids. That they always do is what the catalog
-- suggests and what the automatic send relies on too; it is not documented.
--
-- Every text is read through hex(), so that any character arrives as plain ASCII whatever the tool's code page.
local ImportQuery = {}

-- The settings of the previous import that the plug-in reads (ImportPlan judges them).
ImportQuery.VARIABLES = {
    'AgImportDialog_importBehavior',
    'AgImportDialog_previewBuildQuality',
    'AgImportDialog_generateDNGProxies',
    'AgImportDialog_doCopyToBackupFolder',
    'AgImportDialog_crSettingsID',
    'AgImportDialog_metadataPresetID',
    'AgImportDialog_ignoreSuspectedDuplicates',
    'AgImportDialog_importServiceProvider',
    'AgImportDialog_suppressImportDialog',
}

local function unhex(hex)
    return (hex:gsub('%x%x', function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

local function isHex(text)
    return text ~= nil and #text % 2 == 0 and text:find('^%x*$') ~= nil
end

-- The SELECT for the state before an import: the settings of the previous import ('v' lines) and the largest catalog
-- ids of photos and of imports ('m' lines).
function ImportQuery.stateSql()
    local names = {}
    for i, name in ipairs(ImportQuery.VARIABLES) do
        names[i] = "'" .. name .. "'"
    end
    return "SELECT 'v', hex(name), hex(value) FROM Adobe_variablesTable WHERE name IN (" .. table.concat(names, ', ')
        .. ") UNION ALL SELECT 'm', ifnull(max(id_local), 0), '' FROM Adobe_images"
        .. " UNION ALL SELECT 'm', ifnull(max(id_local), 0), '' FROM AgLibraryImport;"
end

-- Parses stateSql's output. Returns { variables = { [name] = value }, mark = the largest id (or nil when no 'm' line
-- came), duplicates = { name, ... } (names with two different values; such a name is left out of variables) },
-- plus a list of problems (lines of another form).
function ImportQuery.parseState(text)
    local state, problems, values = { variables = {}, mark = nil, duplicates = {} }, {}, {}
    for line in tostring(text or ''):gmatch('[^\r\n]+') do
        local nameHex, valueHex = line:match('^v|(%x*)|(%x*)$')
        local mark = line:match('^m|(%d+)|$')
        if isHex(nameHex) and isHex(valueHex) then
            local name, value = unhex(nameHex), unhex(valueHex)
            if values[name] ~= nil and values[name] ~= value then
                state.duplicates[#state.duplicates + 1] = name
                values[name] = false
            elseif values[name] == nil then
                values[name] = value
            end
        elseif mark then
            state.mark = math.max(state.mark or 0, tonumber(mark))
        else
            problems[#problems + 1] = 'unexpected line: ' .. line:sub(1, 200)
        end
    end
    for name, value in pairs(values) do
        if value ~= false then
            state.variables[name] = value
        end
    end
    table.sort(state.duplicates)
    return state, problems
end

return ImportQuery
