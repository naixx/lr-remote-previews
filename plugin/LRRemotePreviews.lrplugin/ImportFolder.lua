-- Library > Plug-in Extras > Import a folder without the dialog...
--
-- Starts Lightroom's own import of one folder without its dialog (catalog:triggerImportFromPathWithPreviousSettings),
-- with the settings of the previous import, and is done: three steps, then a short notice and a few log lines.
--   1. The gate: the plug-in reads what the catalog records about the previous import (sqlite3, read-only) and goes on
--      only when that was «Add» without a second copy (ImportPlan.judge): then Lightroom only adds references to the
--      files where they are. If it cannot read the record, it starts nothing.
--   2. The confirmation: what Lightroom will do, and one checkbox, «Send new photos to the server automatically», which
--      shows and sets the plug-in's automatic send (the setting of the Plug-in Manager). Switched on here, the plug-in
--      records the catalog's largest id as the automatic send's mark before the import, so that every photo of the
--      import counts as new; the automatic send then sends what is new, round by round, while Lightroom imports.
--   3. The record read again (it must not have changed since the dialog), then the trigger.
-- Dialogs appear only before the import and for refusals and errors. No progress bar, no waiting, no sending, no fetch
-- lock: Lightroom shows its own progress, and the automatic send works in the background. Seen with plug-in 0.6.0 in
-- Lightroom Classic 15.6: the trigger returned after 0.16 s, and Lightroom then imported by itself for minutes.
local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local AutoSendPlan = require 'AutoSendPlan'
local ImportPlan = require 'ImportPlan'
local ImportQuery = require 'ImportQuery'
local Log = require 'Log'
local Settings = require 'Settings'
local SqliteRunner = require 'SqliteRunner'

local TITLE = 'Import a folder without the dialog'
local P = ImportPlan.LOG_PREFIX

-- The time in seconds; LrDate.currentTime() has fractions of a second (seen in Lightroom Classic 15.6).
local function now()
    local ok, value = LrTasks.pcall(LrDate.currentTime)
    if ok and type(value) == 'number' then
        return value
    end
    return os.time()
end

-- The folder dialog, one folder; it opens in the folder that holds the one chosen last. Returns the folder or nil.
local function chooseFolder(lastFolder)
    local args = { title = TITLE .. ': choose the folder', prompt = 'Choose', canChooseFiles = false,
        canChooseDirectories = true, canCreateDirectories = false, allowsMultipleSelection = false }
    if lastFolder ~= '' then
        local parent = lastFolder:match('^(.*)[/\\][^/\\]*$') or ''
        if parent:match('^%a:$') then
            parent = parent .. '\\'
        end
        if parent ~= '' then
            args.initialDirectory = parent
        end
    end
    local folders = LrDialogs.runOpenPanel(args)
    if type(folders) ~= 'table' or type(folders[1]) ~= 'string' or folders[1] == '' then
        return nil
    end
    return folders[1]
end

-- The catalog's record of the previous import, judged (ImportPlan.judge).
local function readVerdict(tool, toolProblem, catalogPath)
    if not tool then
        return ImportPlan.judge(nil, toolProblem)
    end
    local text, err = SqliteRunner.query(tool.tool, catalogPath, ImportQuery.stateSql())
    if not text then
        return ImportPlan.judge(nil, err)
    end
    local state, problems = ImportQuery.parseState(text)
    for _, problem in ipairs(problems) do
        Log.warn('%ssqlite3 output: %s', P, problem)
    end
    return ImportPlan.judge(state)
end

-- The confirmation. Returns the state of the automatic send's checkbox, or nil when cancelled.
local function askToImport(context, folder, verdict, autoSend, sendProblem)
    local f = LrView.osFactory()
    local props = LrBinding.makePropertyTable(context)
    props.autoSend = autoSend == true
    local contents = f:column {
        bind_to_object = props,
        f:static_text { title = ImportPlan.dialogText(folder, verdict) },
        f:checkbox { title = 'Send new photos to the server automatically', value = LrView.bind 'autoSend' },
        f:static_text { title = ImportPlan.autoSendNote(sendProblem) },
    }
    local answer = LrDialogs.presentModalDialog { title = TITLE, contents = contents, actionVerb = 'Import' }
    if answer ~= 'ok' then
        return nil
    end
    return props.autoSend == true
end

-- Sets the automatic send as the checkbox says, as the Plug-in Manager would. Switched on, the catalog's largest id
-- becomes its mark unless it has one (so every photo of the import is new to it) and its loop is started; switched
-- off, what it remembered is forgotten.
local function applyAutoSend(prefs, catalogPath, on, mark)
    local was = Settings.read(prefs).autoSend
    Settings.setOption(prefs, 'autoSend', on)
    if on then
        if not AutoSendPlan.load(prefs, catalogPath) then
            AutoSendPlan.save(prefs, catalogPath, AutoSendPlan.prime(mark, os.time()))
            Log.info('%sautomatic send: photos up to catalog id %d count as present before this import', P, mark)
        end
        local ok, err = LrTasks.pcall(function()
            require('AutoFetch').ensureRunning('import folder')
        end)
        if not ok then
            Log.error('%sautomatic send: could not start: %s', P, tostring(err))
        end
    elseif was then
        AutoSendPlan.forget(prefs)
    end
    Log.info('%sautomatic send: %s (was %s)', P, on and 'on' or 'off', was and 'on' or 'off')
end

local function run(context)
    local catalog = LrApplication.activeCatalog()
    local catalogPath = catalog:getPath()
    local prefs = LrPrefs.prefsForPlugin()
    local settings = Settings.read(prefs)

    -- 1. The folder and the gate: no import without a readable record of an «Add» import.
    local folder = chooseFolder(Settings.lastImportFolder(prefs))
    if not folder then
        Log.info('%sno folder chosen', P)
        return
    end
    local tool, toolProblem = SqliteRunner.locate(settings.sqlitePath, _PLUGIN and _PLUGIN.path)
    local verdict = readVerdict(tool, toolProblem, catalogPath)
    Log.info('%s%s; previous import: %s', P, folder, verdict.ok and ImportPlan.settingsLogText(verdict)
        or ('refused: ' .. verdict.refusal))
    if not verdict.ok then
        LrDialogs.message(TITLE, verdict.refusal, 'warning')
        return
    end

    -- 2. The confirmation.
    local sendProblem = ImportPlan.sendProblem(settings, Settings.mappings(settings), folder)
    local autoSend = askToImport(context, folder, verdict, settings.autoSend, sendProblem)
    if autoSend == nil then
        Log.info('%snot started', P)
        return
    end
    Settings.setLastImportFolder(prefs, folder)

    -- 3. The record again, right before the trigger; then the automatic send as chosen, then the trigger.
    local again = readVerdict(tool, toolProblem, catalogPath)
    if not again.ok then
        Log.warn('%snot started: %s', P, again.refusal)
        LrDialogs.message(TITLE, again.refusal, 'warning')
        return
    end
    if ImportPlan.settingsLogText(again) ~= ImportPlan.settingsLogText(verdict) then
        Log.warn('%snot started: the settings changed since the dialog: %s', P, ImportPlan.settingsLogText(again))
        LrDialogs.message(TITLE, 'The settings of the previous import changed since the dialog (another import ran '
            .. 'meanwhile?). Run the command again to see them.', 'warning')
        return
    end
    applyAutoSend(prefs, catalogPath, autoSend, again.mark)
    if type(catalog.triggerImportFromPathWithPreviousSettings) ~= 'function' then
        LrDialogs.message(TITLE, 'This version of Lightroom has no catalog:triggerImportFromPathWithPreviousSettings.',
            'critical')
        return
    end
    local started = now()
    Log.info('%strigger called at %s (catalog ids up to %d were there before): %s', P, os.date('%Y-%m-%d %H:%M:%S'),
        again.mark, folder)
    local ok, value = LrTasks.pcall(function()
        return catalog:triggerImportFromPathWithPreviousSettings(folder)
    end)
    Log.info('%strigger returned after %s: %s', P, ImportPlan.seconds(now() - started),
        ok and ('value ' .. tostring(value)) or ('error ' .. tostring(value)))
    if not ok then
        LrDialogs.message(TITLE, 'Lightroom did not start the import: ' .. tostring(value), 'critical')
        return
    end
    LrTasks.pcall(function()
        LrDialogs.showBezel(ImportPlan.bezelText(folder, autoSend), 4)
    end)
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext('LRRemotePreviews.importFolder', function(context)
        local ok, err = LrTasks.pcall(run, context)
        if not ok then
            Log.error('%sunexpected error: %s', P, tostring(err))
            LrDialogs.message(TITLE, 'Unexpected error: ' .. tostring(err), 'critical')
        end
    end)
end)
