-- The decisions and texts of «Import a folder without the dialog...» (version 0.7.0). Pure Lua 5.1: no Lightroom
-- imports.
--
-- The command starts Lightroom's own import of one folder with catalog:triggerImportFromPathWithPreviousSettings
-- ("Triggers an import, bypassing the import dialog, using the settings from the most recent import", SDK 4.0). The
-- previous settings could be «Copy» or «Move», which would copy or move files, so before it starts anything the
-- plug-in reads what the catalog records about the previous import (ImportQuery, sqlite3, read-only) and judges it
-- here (ImportPlan.judge): only «Add» (importBehavior "refInPlace": the files stay where they are and only references
-- are added to the catalog) without a second copy is allowed. What this check cannot know: that the trigger uses
-- exactly these recorded values (the names say so, Adobe does not), and what Lightroom decides by itself about
-- sub-folders. After the trigger the command ends; sending the new photos is the automatic send's job.
local PathMap = require 'PathMap'

local ImportPlan = {}

ImportPlan.LOG_PREFIX = 'import folder: '

-- The preview setting codes whose meaning was seen: "bthm" in two test catalogs whose last import used «Embedded &
-- Sidecar» (Lightroom Classic 15.6). Other codes (for example "sbig") are shown as they are.
ImportPlan.PREVIEW_NAMES = { bthm = 'Embedded & Sidecar' }

-- Seconds as text: '0.16 s', '12.3 s', '125 s'.
function ImportPlan.seconds(value)
    value = tonumber(value) or 0
    if value < 0 then
        value = 0
    end
    if value < 10 then
        return string.format('%.2f s', value)
    elseif value < 100 then
        return string.format('%.1f s', value)
    end
    return string.format('%d s', math.floor(value + 0.5))
end

-- Settings ---------------------------------------------------------------------------------------------------------

local function flag(value)
    if value == '1' or value == 'true' then
        return true
    elseif value == '0' or value == 'false' then
        return false
    end
    return nil
end

local function isSet(value)
    return value ~= nil and value ~= '' and value ~= '<none>'
end

local AGAIN = 'Run one import through Lightroom\'s import dialog with «Add» (File > Import Photos and Video), then try '
    .. 'again.'

-- Judges the recorded settings of the previous import. state: ImportQuery.parseState's result, or nil plus problem
-- (why it could not be read). Returns { ok = true, mark, behavior, previewCode, previewName (or nil), smartPreviews,
-- presets = { text, ... }, extras = { [name] = value } (every setting read, for the log and for comparing the record
-- right before the trigger with the one the dialog showed) } or { ok = false, refusal = text }.
function ImportPlan.judge(state, problem)
    local function refuse(text)
        return { ok = false, refusal = text }
    end
    if not state then
        return refuse('The plug-in cannot read how the previous import in this catalog was set up ('
            .. tostring(problem) .. '), so it starts no import: it only starts one it has checked.')
    end
    local v = state.variables or {}
    local duplicate = (state.duplicates or {})[1]
    if duplicate then
        return refuse('The catalog holds two different values for ' .. duplicate .. ', so the plug-in cannot tell how '
            .. 'the previous import was set up and starts no import.')
    end
    if type(state.mark) ~= 'number' then
        return refuse('The plug-in cannot read the catalog\'s photo ids, so it starts no import.')
    end
    local behavior = v.AgImportDialog_importBehavior
    if behavior == nil then
        return refuse('This catalog has no record of a previous import, so the plug-in cannot check what Lightroom '
            .. 'would do and starts no import. ' .. AGAIN)
    end
    if behavior ~= 'refInPlace' then
        return refuse('The previous import in this catalog was not «Add» (Lightroom\'s setting: «' .. behavior .. '»). '
            .. 'An import with «Copy» or «Move» copies or moves files, so the plug-in does not start it. ' .. AGAIN)
    end
    local backup = v.AgImportDialog_doCopyToBackupFolder
    if backup ~= nil and flag(backup) ~= false then
        return refuse('The previous import in this catalog also made a second copy of the files («Make a Second Copy '
            .. 'To»), which writes files, so the plug-in does not start it. ' .. AGAIN)
    end
    local preview = v.AgImportDialog_previewBuildQuality
    local smart = flag(v.AgImportDialog_generateDNGProxies)
    if preview == nil or preview == '' or smart == nil then
        return refuse('The catalog\'s record of the previous import is incomplete (preview or smart preview setting '
            .. 'missing or unreadable), so the plug-in starts no import. ' .. AGAIN)
    end
    local presets = {}
    if isSet(v.AgImportDialog_crSettingsID) then
        presets[#presets + 1] = 'a develop preset'
    end
    if isSet(v.AgImportDialog_metadataPresetID) then
        presets[#presets + 1] = 'a metadata preset'
    end
    local extras = {}
    for name, value in pairs(v) do
        extras[name] = value
    end
    return { ok = true, mark = state.mark, behavior = behavior, previewCode = preview,
        previewName = ImportPlan.PREVIEW_NAMES[preview], smartPreviews = smart, presets = presets, extras = extras }
end

-- The settings as lines for the dialog.
function ImportPlan.settingsLines(verdict)
    local lines = { '    Add: the files stay where they are; only references to them are added to the catalog.' }
    if verdict.previewName then
        lines[#lines + 1] = '    Previews: ' .. verdict.previewName .. '.'
    else
        lines[#lines + 1] = '    Previews: Lightroom builds its own, reading the originals (its setting «'
            .. verdict.previewCode .. '»; which choice of the dialog that is has not been established).'
    end
    if verdict.smartPreviews then
        lines[#lines + 1] = '    Build Smart Previews: ON. Lightroom builds them itself, reading every original over '
            .. 'the network; switch it off in the import dialog if the server is to build them.'
    else
        lines[#lines + 1] = '    Build Smart Previews: off.'
    end
    if #verdict.presets > 0 then
        lines[#lines + 1] = '    Also applied, as in the previous import: ' .. table.concat(verdict.presets, ' and ')
            .. ' (catalog settings only; files are not changed).'
    end
    return lines
end

-- One log line with every setting read: 'AgImportDialog_importBehavior=refInPlace, ...' (sorted).
function ImportPlan.settingsLogText(verdict)
    local names = {}
    for name in pairs(verdict.extras or {}) do
        names[#names + 1] = name
    end
    table.sort(names)
    for i, name in ipairs(names) do
        names[i] = name .. '=' .. tostring(verdict.extras[name])
    end
    return table.concat(names, ', ')
end

-- The dialog's text above the checkbox of the automatic send.
function ImportPlan.dialogText(folder, verdict)
    local lines = { 'Lightroom will import ' .. folder .. ' with the settings of the previous import in this catalog, '
        .. 'without showing its dialog:' }
    for _, line in ipairs(ImportPlan.settingsLines(verdict)) do
        lines[#lines + 1] = line
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'Whether it takes sub-folders is up to Lightroom. The plug-in changes no file and writes '
        .. 'nothing to the catalog itself; it starts the import and is done.'
    return table.concat(lines, '\n')
end

-- The automatic send -------------------------------------------------------------------------------------------------

-- Why the photos of the folder could not be sent by the server, or nil when they can: no server URL, no path mapping,
-- or the folder under none of the mappings. settings: { serverUrl }, mappings: Settings.mappings().
function ImportPlan.sendProblem(settings, mappings, folder)
    if type(settings.serverUrl) ~= 'string' or settings.serverUrl == '' then
        return 'No server is set up (File > Plug-in Manager > LR Remote Previews).'
    end
    if #mappings == 0 then
        return 'No path mapping is set up (File > Plug-in Manager > LR Remote Previews).'
    end
    if not PathMap.map(folder .. '/x', mappings) then
        return 'This folder is under none of the path mappings, so the server cannot read its files.'
    end
    return nil
end

-- The line under the checkbox «Send new photos to the server automatically».
function ImportPlan.autoSendNote(problem)
    if problem then
        return problem
    end
    return 'The plug-in\'s automatic send (the same setting as in the Plug-in Manager) sends new raw photos to the '
        .. 'server in the background, round by round, while Lightroom imports. Off: send them later with «Build '
        .. 'smart previews on the server».'
end

-- The short notice after the trigger.
function ImportPlan.bezelText(folder, autoSend)
    local name = folder:match('([^/\\]+)[/\\]*$') or folder
    return 'Lightroom is importing ' .. name .. (autoSend and '; the automatic send sends the new photos' or '')
end

return ImportPlan
