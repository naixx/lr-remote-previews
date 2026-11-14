-- The decisions and texts of «Import a folder without the dialog...» (version 0.6.0). Pure Lua 5.1: no Lightroom
-- imports.
--
-- The command starts Lightroom's own import of one folder with catalog:triggerImportFromPathWithPreviousSettings
-- ("Triggers an import, bypassing the import dialog, using the settings from the most recent import", SDK 4.0). The
-- previous settings could be «Copy» or «Move», which would copy or move files, so before it starts anything the
-- plug-in reads what the catalog records about the previous import (ImportQuery, sqlite3, read-only) and judges it
-- here (ImportPlan.judge): only «Add» (importBehavior "refInPlace": the files stay where they are and only references
-- are added to the catalog) without a second copy is allowed. What this check cannot know: that the trigger uses
-- exactly these recorded values (the names say so, Adobe does not), and what Lightroom decides by itself about
-- sub-folders and about files of the folder that are in the catalog already.
--
-- After the trigger the plug-in only watches the catalog (ImportPlan.observe): every POLL_SECONDS it reads the photos
-- added since the mark; the import is taken as finished when at least one photo of the folder has appeared and the
-- count has not changed for SETTLED_SECONDS.
local PathMap = require 'PathMap'

local ImportPlan = {}

ImportPlan.POLL_SECONDS = 3 -- between two reads of the catalog while Lightroom imports
ImportPlan.SETTLED_SECONDS = 20 -- the count unchanged this long (after at least one photo): the import is finished
ImportPlan.NO_PHOTO_SECONDS = 300 -- no photo of the folder this long after the trigger: stop waiting
ImportPlan.LIMIT_SECONDS = 4 * 3600 -- stop waiting after this long in any case
ImportPlan.MAX_POLL_FAILURES = 5 -- reads of the catalog that may fail in a row
ImportPlan.JOB_LABEL = 'Lightroom folder import'
ImportPlan.LOG_PREFIX = 'import folder: '
ImportPlan.LEASE_LABEL = '«Import a folder without the dialog»'

-- The preview setting codes whose meaning was seen: "bthm" in two test catalogs whose last import used «Embedded &
-- Sidecar» (Lightroom Classic 15.6). Other codes (for example "sbig") are shown as they are.
ImportPlan.PREVIEW_NAMES = { bthm = 'Embedded & Sidecar' }

local function plural(n, one, many)
    return n .. ' ' .. (n == 1 and one or many)
end

-- Seconds as text: '0.19 s', '12.3 s', '125 s'.
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

local function minutes(seconds)
    if seconds % 3600 == 0 then
        return plural(seconds / 3600, 'hour', 'hours')
    end
    return plural(math.floor(seconds / 60), 'minute', 'minutes')
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
-- (why it could not be read). Returns { ok = true, behavior, previewCode, previewName (or nil), smartPreviews,
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
        return refuse('The plug-in cannot read the catalog\'s photo ids, so it could not tell which photos the import '
            .. 'adds; it starts no import.')
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
    return { ok = true, behavior = behavior, previewCode = preview, previewName = ImportPlan.PREVIEW_NAMES[preview],
        smartPreviews = smart, presets = presets, extras = extras }
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

-- The dialog's text above the send checkbox.
function ImportPlan.dialogText(folder, verdict)
    local lines = { 'Lightroom will import ' .. folder .. ' with the settings of the previous import in this catalog, '
        .. 'without showing its dialog:' }
    for _, line in ipairs(ImportPlan.settingsLines(verdict)) do
        lines[#lines + 1] = line
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'Whether it takes sub-folders, and what it does with files that are in the catalog already, is '
        .. 'up to Lightroom. The plug-in changes no file and writes nothing to the catalog itself.'
    return table.concat(lines, '\n')
end

-- Sending -----------------------------------------------------------------------------------------------------------

-- Whether the photos can be sent to the server afterwards. settings: { serverUrl }, mappings: Settings.mappings(),
-- folder: the chosen folder. Returns true, or false plus the reason (a sentence for the dialog).
function ImportPlan.sendAvailability(settings, mappings, folder)
    if type(settings.serverUrl) ~= 'string' or settings.serverUrl == '' then
        return false, 'No server is set up (File > Plug-in Manager > LR Remote Previews).'
    end
    if #mappings == 0 then
        return false, 'No path mapping is set up (File > Plug-in Manager > LR Remote Previews).'
    end
    if PathMap.map(folder .. '/x', mappings) then
        return true
    end
    return false, 'The folder is under none of the path mappings, so the server cannot read these files.'
end

-- Paths ---------------------------------------------------------------------------------------------------------------

-- True when a folder as the catalog spells it ('Z:/2026/shoot/') is the chosen folder or lies below it. Windows paths
-- compare without regard to case and slash kind (PathMap.fileKey).
function ImportPlan.isUnder(catalogFolder, chosen)
    local folder, root = PathMap.fileKey(catalogFolder), PathMap.fileKey(chosen)
    if not folder or not root then
        return false
    end
    return folder == root or folder:sub(1, #root + 1) == root .. '/'
end

-- The path of a photo found by ImportQuery, in the form Lightroom's SDK uses: backslashes for Windows paths.
function ImportPlan.photoPath(photo)
    local path = photo.folder .. photo.name
    if path:match('^%a:') or path:match('^[/\\][/\\]') then
        path = path:gsub('/', '\\')
    end
    return path
end

-- Splits the photos added since the mark into those under the chosen folder and the number elsewhere.
function ImportPlan.underFolder(photos, chosen)
    local under, elsewhere = {}, 0
    for _, photo in ipairs(photos) do
        if ImportPlan.isUnder(photo.folder, chosen) then
            under[#under + 1] = photo
        else
            elsewhere = elsewhere + 1
        end
    end
    return under, elsewhere
end

-- Waiting for the import -------------------------------------------------------------------------------------------

-- A watch that starts at now (seconds).
function ImportPlan.newWatch(now)
    return { started = now, count = 0, changed = now, first = nil, last = nil, polls = 0, failures = 0, imports = 0 }
end

local function limits(watch, now)
    local elapsed = now - watch.started
    if watch.count > 0 and now - watch.changed >= ImportPlan.SETTLED_SECONDS then
        return 'settled'
    end
    if elapsed >= ImportPlan.LIMIT_SECONDS then
        return 'timeLimit'
    end
    if watch.count == 0 and elapsed >= ImportPlan.NO_PHOTO_SECONDS then
        return 'noPhotos'
    end
    return 'waiting'
end

-- Records one read of the catalog: count = photos of the folder added since the mark, imports = import records added
-- since the mark. Returns 'waiting', 'settled', 'noPhotos' or 'timeLimit'.
function ImportPlan.observe(watch, count, imports, now)
    watch.polls = watch.polls + 1
    watch.failures = 0
    watch.imports = imports or watch.imports
    if count ~= watch.count then
        watch.count = count
        watch.changed = now
        if count > 0 then
            watch.first = watch.first or now
            watch.last = now
        end
    end
    return limits(watch, now)
end

-- Records a read of the catalog that failed. Returns 'pollFailed' after MAX_POLL_FAILURES in a row, otherwise what
-- the limits say ('waiting', 'timeLimit', ...; never 'settled' on a failed read).
function ImportPlan.pollFailed(watch, now)
    watch.polls = watch.polls + 1
    watch.failures = watch.failures + 1
    if watch.failures >= ImportPlan.MAX_POLL_FAILURES then
        return 'pollFailed'
    end
    local state = limits(watch, now)
    if state == 'settled' then
        return 'waiting'
    end
    return state
end

-- Whether the photos found are sent when the waiting ended this way.
function ImportPlan.sendsAfter(outcome)
    return outcome == 'settled' or outcome == 'timeLimit'
end

-- Texts -----------------------------------------------------------------------------------------------------------

-- The progress caption while waiting.
function ImportPlan.caption(count)
    return string.format('Lightroom is importing: %s so far', plural(count, 'photo', 'photos'))
end

-- What the end of the waiting means, for the summary.
function ImportPlan.outcomeText(outcome, watch, lastError)
    local count = plural(watch.count, 'photo', 'photos')
    if outcome == 'settled' then
        return string.format('Lightroom imported %s from this folder. No new one came for %d seconds, so the plug-in '
            .. 'took the import as finished.', count, ImportPlan.SETTLED_SECONDS)
    elseif outcome == 'timeLimit' then
        return string.format('The plug-in stopped waiting after %s, with %s imported so far.',
            minutes(ImportPlan.LIMIT_SECONDS), count)
    elseif outcome == 'noPhotos' then
        return string.format('No photo of this folder appeared in the catalog within %s of the start. Lightroom may '
            .. 'have found nothing to import in it (for example when every file is in the catalog already), or the '
            .. 'import did not start.', minutes(ImportPlan.NO_PHOTO_SECONDS))
    elseif outcome == 'pollFailed' then
        return string.format('The plug-in stopped waiting: reading the catalog failed %d times in a row (%s). '
            .. 'Lightroom goes on with its import by itself; %s of this folder had appeared.',
            ImportPlan.MAX_POLL_FAILURES, tostring(lastError), count)
    elseif outcome == 'cancelled' then
        return string.format('You stopped the waiting. Lightroom goes on with its import by itself; %s of this folder '
            .. 'had appeared by then.', count)
    end
    return tostring(outcome)
end

-- The summary dialog's text. context: { folder, outcome, watch, lastError, sidecars = n (photos with a sidecar
-- recorded), elsewhere = n (photos added to other folders meanwhile), times = { trigger, waited, sending },
-- sendText, logHint }.
function ImportPlan.summaryText(context)
    local lines = {}
    local function add(line)
        lines[#lines + 1] = line
    end
    local watch = context.watch
    add(context.folder .. ':')
    add('')
    add(ImportPlan.outcomeText(context.outcome, watch, context.lastError))
    if (context.sidecars or 0) > 0 then
        add('Of them with a sidecar recorded (for example a JPEG next to the raw file): ' .. context.sidecars .. '.')
    end
    if (context.elsewhere or 0) > 0 then
        add('Meanwhile ' .. plural(context.elsewhere, 'photo was', 'photos were') .. ' added to other folders; they '
            .. 'were not counted.')
    end
    local times = context.times or {}
    local parts = {}
    if times.trigger then
        parts[#parts + 1] = 'starting the import ' .. ImportPlan.seconds(times.trigger)
    end
    if watch.first then
        parts[#parts + 1] = 'first photo after ' .. ImportPlan.seconds(watch.first - watch.started)
    end
    if watch.last and watch.last ~= watch.first then
        parts[#parts + 1] = 'last after ' .. ImportPlan.seconds(watch.last - watch.started)
    end
    if times.waited then
        parts[#parts + 1] = 'waited ' .. ImportPlan.seconds(times.waited)
    end
    if times.sending then
        parts[#parts + 1] = 'sending ' .. ImportPlan.seconds(times.sending)
    end
    if #parts > 0 then
        add('')
        add('Times: ' .. table.concat(parts, ', ') .. '.')
    end
    if context.sendText then
        add('')
        add(context.sendText)
    end
    if watch.count > 0 then
        add('')
        add('Lightroom lists the photos in the Library\'s Folders panel. To take them out of the catalog again, select '
            .. 'them and choose Photo > Remove Photos, then «Remove from Lightroom» (never «Delete from Disk»): the '
            .. 'files on disk are not touched.')
    end
    if context.logHint then
        add('')
        add(context.logHint)
    end
    return table.concat(lines, '\n')
end

-- Log lines -----------------------------------------------------------------------------------------------------------

-- 'import folder: poll 5 at 15.2 s: 120 photos under the folder (+40), 0 elsewhere, 1 import record, 0.21 s'.
function ImportPlan.pollLine(info)
    local delta = info.count - (info.before or 0)
    return string.format('%spoll %d at %s: %s under the folder (%s%d), %d elsewhere, %s, read in %s',
        ImportPlan.LOG_PREFIX, info.poll, ImportPlan.seconds(info.at), plural(info.count, 'photo', 'photos'),
        delta >= 0 and '+' or '', delta, info.elsewhere or 0, plural(info.imports or 0, 'import record',
            'import records'), ImportPlan.seconds(info.read))
end

-- 'import folder: imported Z:\\2026\\IMG_0001.ARW (catalog id 50478, sidecar JPG)'.
function ImportPlan.photoLine(photo)
    local detail = 'catalog id ' .. tostring(photo.id)
    if photo.sidecars and photo.sidecars ~= '' then
        detail = detail .. ', sidecar ' .. photo.sidecars
    end
    return ImportPlan.LOG_PREFIX .. 'imported ' .. ImportPlan.photoPath(photo) .. ' (' .. detail .. ')'
end

return ImportPlan
