-- Library > Plug-in Extras > Import a folder without the dialog...
--
-- Starts Lightroom's own import of one folder without its dialog (catalog:triggerImportFromPathWithPreviousSettings),
-- with the settings of the previous import, and, when chosen, sends the imported photos to the server afterwards.
--
-- Before anything starts, the plug-in reads what the catalog records about the previous import (sqlite3, read-only)
-- and starts the import only when that was «Add» without a second copy (ImportPlan.judge): then Lightroom only adds
-- references to the files where they are. It reads the record again right before the trigger. If it cannot read it,
-- it starts nothing.
--
-- Nothing slow runs in the plug-in's task: no listing of the folder, no call per file of it. Plug-in tasks run on
-- Lightroom's main thread (seen in Lightroom Classic 15.6: a stack of the main thread inside a plug-in call), so the
-- plug-in only waits: LrTasks.sleep between reads, and the reads are sqlite3 processes (LrTasks.execute). Every
-- POLL_SECONDS it reads the photos added since the import started (ImportQuery) and takes the import as finished when
-- the count of photos under the folder has not changed for SETTLED_SECONDS (ImportPlan.observe). Cancel stops the
-- waiting, not Lightroom's import.
--
-- When the photos are to be sent, the plug-in holds the fetch lock from before the trigger until it has sent, so no
-- round of the automatic send can send them meanwhile, and records their catalog ids before it sends
-- (AutoSendPlan.recordSent), so later rounds skip them. The send itself is «Send to the server»'s
-- (Pipeline.prepareSend, Pipeline.sendJobs), without its confirmation.
--
-- The log has the timings this command exists to learn from: when the trigger was called and when it returned, every
-- read with its count, every photo as it appears, when the import was taken as finished, and the send.
local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrPrefs = import 'LrPrefs'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local AutoSendPlan = require 'AutoSendPlan'
local ImportPlan = require 'ImportPlan'
local ImportQuery = require 'ImportQuery'
local Log = require 'Log'
local PhotoAccess = require 'PhotoAccess'
local Pipeline = require 'Pipeline'
local RunSummary = require 'RunSummary'
local Selection = require 'Selection'
local ServerClient = require 'ServerClient'
local Settings = require 'Settings'
local SqliteRunner = require 'SqliteRunner'

local TITLE = 'Import a folder without the dialog'
local P = ImportPlan.LOG_PREFIX
local LATER_HINT = 'To send them later, select them and use Library > Plug-in Extras > Send to the server (the '
    .. 'automatic send leaves these photos alone).'
local PLAIN_HINT = 'To send them later, select them and use Library > Plug-in Extras > Send to the server.'

-- The time in seconds. LrDate.currentTime() has fractions of a second (the timings of 0.5.0's log in Lightroom
-- Classic 15.6 show them).
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

-- The catalog's record of the previous import and the mark. Returns ImportQuery.parseState's result, or nil plus a
-- message.
local function readState(tool, catalogPath)
    local text, err = SqliteRunner.query(tool.tool, catalogPath, ImportQuery.stateSql())
    if not text then
        return nil, err
    end
    local state, problems = ImportQuery.parseState(text)
    for _, problem in ipairs(problems) do
        Log.warn('%ssqlite3 output: %s', P, problem)
    end
    return state
end

-- The dialog: what Lightroom will do, and the send checkbox. Returns true/false (send), or nil when cancelled.
local function askToImport(context, folder, verdict, choices, sendOk, sendWhy)
    local f = LrView.osFactory()
    local props = LrBinding.makePropertyTable(context)
    props.send = sendOk and choices.importFolderSend or false
    local contents = f:column {
        bind_to_object = props,
        f:static_text { title = ImportPlan.dialogText(folder, verdict) },
        f:checkbox { title = 'Send the imported photos to the server afterwards', value = LrView.bind 'send',
            enabled = sendOk },
        f:static_text { title = sendOk and 'As «Send to the server» does; the automatic send leaves them alone.'
            or sendWhy },
    }
    local answer = LrDialogs.presentModalDialog { title = TITLE, contents = contents, actionVerb = 'Import' }
    if answer ~= 'ok' then
        return nil
    end
    return sendOk and props.send == true
end

-- Sends the photos as «Send to the server» does, without its confirmation. Returns the text for the summary and
-- whether it went well (every job created; photos left out for a reason are fine).
local function sendPhotos(settings, catalog, photos, ui)
    local summary = RunSummary.new(#photos)
    local prepared, problem = Pipeline.prepareSend(settings, catalog, photos, summary, ui)
    if not prepared then
        if problem.cancelled then
            return 'Sending to the server was cancelled. ' .. LATER_HINT, false
        end
        if problem.style == 'info' then
            return summary:text({ header = string.format('None of the %s was sent to the server.',
                #photos == 1 and 'imported photo' or (#photos .. ' imported photos')) }), true
        end
        return 'Not sent to the server: ' .. tostring(problem.message) .. '\n' .. LATER_HINT, false
    end
    local sent = Pipeline.sendJobs(settings, catalog:getPath(), prepared, summary, ui, ImportPlan.JOB_LABEL)
    if #sent.jobIds == 0 then
        return 'Not sent to the server: ' .. tostring(sent.failedParts) .. '\n' .. LATER_HINT, false
    end
    return summary:sendText({ jobIds = sent.jobIds, ready = sent.ready, rejected = sent.rejected,
        failedParts = sent.failedParts, fetchHint = Pipeline.FETCH_HINT }), sent.failedParts == nil
end

-- The photos of the folder through the SDK, by path (catalog:findPhotoByPath; 1384 such lookups took 1.86 s in
-- Lightroom Classic 15.6 with 0.5.0). Returns the photos and the number not found.
local function findPhotos(catalog, found)
    local photos, missing = {}, 0
    for i, photo in ipairs(found) do
        local lrPhoto = PhotoAccess.findByPath(catalog, ImportPlan.photoPath(photo))
        if lrPhoto then
            photos[#photos + 1] = lrPhoto
        else
            missing = missing + 1
            Log.warn('%s%s: not found through the plug-in interface; not sent', P, ImportPlan.photoPath(photo))
        end
        if i % 200 == 0 then
            LrTasks.yield()
        end
    end
    return photos, missing
end

-- Starts the import and waits for it; sends when asked. lease: the fetch lock when sending, else nil. Returns the
-- summary text and the dialog style.
local function importAndWait(job, lease)
    local catalog, settings, folder, tool, progress = job.catalog, job.settings, job.folder, job.tool, job.progress
    local catalogPath = catalog:getPath()
    local ui = Pipeline.progressUi(progress)

    -- The gate again, right before the trigger: the record must still say what the dialog showed.
    local state, problem = readState(tool, catalogPath)
    local verdict = ImportPlan.judge(state, problem)
    if not verdict.ok then
        Log.warn('%snot started: %s', P, verdict.refusal)
        return verdict.refusal, 'warning'
    end
    if ImportPlan.settingsLogText(verdict) ~= ImportPlan.settingsLogText(job.verdict) then
        Log.warn('%snot started: the settings changed since the dialog: %s', P, ImportPlan.settingsLogText(verdict))
        return 'The settings of the previous import changed since the dialog (another import ran meanwhile?). Run the '
            .. 'command again to see them.', 'warning'
    end
    local mark = state.mark

    -- The trigger.
    progress:setCaption('Starting Lightroom\'s import')
    if type(catalog.triggerImportFromPathWithPreviousSettings) ~= 'function' then
        return 'This version of Lightroom has no catalog:triggerImportFromPathWithPreviousSettings.', 'critical'
    end
    local started = now()
    Log.info('%strigger called at %s (catalog ids above %d are new): %s', P, os.date('%Y-%m-%d %H:%M:%S'), mark, folder)
    local ok, value = LrTasks.pcall(function()
        return catalog:triggerImportFromPathWithPreviousSettings(folder)
    end)
    local triggerSeconds = now() - started
    Log.info('%strigger returned after %s: %s', P, ImportPlan.seconds(triggerSeconds),
        ok and ('value ' .. tostring(value)) or ('error ' .. tostring(value)))
    if not ok then
        return 'Lightroom did not start the import: ' .. tostring(value) .. '\n\n' .. Pipeline.LOG_HINT, 'critical'
    end

    -- Waiting: a read of the catalog every POLL_SECONDS.
    local watch = ImportPlan.newWatch(started)
    local under, elsewhere, imports, logged = {}, 0, 0, {}
    local outcome, lastError
    progress:setCaption(ImportPlan.caption(0))
    while true do
        if ui.isCanceled() then
            outcome = 'cancelled'
            break
        end
        LrTasks.sleep(ImportPlan.POLL_SECONDS)
        if lease then
            lease.refresh()
        end
        if ui.isCanceled() then
            outcome = 'cancelled'
            break
        end
        local readStarted = now()
        local sql = ImportQuery.newSinceSql(mark)
        local text, err = SqliteRunner.query(tool.tool, catalogPath, sql)
        local state2
        if text then
            local found, problems = ImportQuery.parseNewSince(text)
            for _, line in ipairs(problems) do
                Log.warn('%ssqlite3 output: %s', P, line)
            end
            local before = #under
            under, elsewhere = ImportPlan.underFolder(found.photos, folder)
            imports = #found.imports
            for _, photo in ipairs(under) do
                if not logged[photo.id] then
                    logged[photo.id] = true
                    Log.info('%s', ImportPlan.photoLine(photo))
                end
            end
            state2 = ImportPlan.observe(watch, #under, imports, now())
            Log.info('%s', ImportPlan.pollLine({ poll = watch.polls, at = now() - started, count = #under,
                before = before, elsewhere = elsewhere, imports = imports, read = now() - readStarted }))
            progress:setCaption(ImportPlan.caption(#under))
        else
            lastError = err
            state2 = ImportPlan.pollFailed(watch, now())
            Log.warn('%spoll %d failed: %s', P, watch.polls, tostring(err))
        end
        if state2 ~= 'waiting' then
            outcome = state2
            break
        end
    end
    local waited = now() - started
    Log.info('%swaiting ended (%s) after %s: %d photo(s) under the folder, %d elsewhere, %d import record(s)', P,
        outcome, ImportPlan.seconds(waited), #under, elsewhere, imports)

    -- Sending.
    local sendText, sentWell, sending = nil, true, nil
    if job.send then
        if #under == 0 then
            sendText = 'Nothing was sent to the server: no photo of this folder appeared.'
        elseif not ImportPlan.sendsAfter(outcome) then
            sentWell = false
            sendText = 'The imported photos were not sent to the server, because the waiting did not end normally. '
                .. PLAIN_HINT
        else
            local sendStarted = now()
            progress:setCaption(string.format('Finding the %d imported photo(s)', #under))
            local photos, missing = findPhotos(catalog, under)
            local ids = {}
            for _, photo in ipairs(photos) do
                local id = PhotoAccess.try('photo.localIdentifier', function()
                    return photo.localIdentifier
                end)
                if type(id) == 'number' then
                    ids[#ids + 1] = id
                end
            end
            AutoSendPlan.recordSent(LrPrefs.prefsForPlugin(), catalogPath, ids, Pipeline.runTag())
            Log.info('%sfound %d of %d photo(s) through the plug-in interface in %s', P, #photos, #under,
                ImportPlan.seconds(now() - sendStarted))
            sendText, sentWell = sendPhotos(settings, catalog, photos, ui)
            if missing > 0 then
                sentWell = false
                sendText = sendText .. '\n\n' .. missing .. ' imported photo(s) could not be found through '
                    .. 'Lightroom\'s plug-in interface and were not sent; the log names them.'
            end
            sending = now() - sendStarted
            Log.info('%ssending: %d photo(s), %s', P, #photos, ImportPlan.seconds(sending))
        end
    end

    local sidecars = 0
    for _, photo in ipairs(under) do
        if photo.sidecars ~= '' then
            sidecars = sidecars + 1
        end
    end
    local text = ImportPlan.summaryText({ folder = folder, outcome = outcome, watch = watch, lastError = lastError,
        sidecars = sidecars, elsewhere = elsewhere, times = { trigger = triggerSeconds, waited = waited,
            sending = sending }, sendText = sendText, logHint = Pipeline.LOG_HINT })
    local fine = (outcome == 'settled') and sentWell
    return text, fine and 'info' or 'warning'
end

local function run(context)
    local catalog = LrApplication.activeCatalog()
    local prefs = LrPrefs.prefsForPlugin()
    PhotoAccess.resetWarnings()
    local settings = Settings.read(prefs)
    local choices = Settings.readImportFolder(prefs)

    -- 1. The folder.
    local folder = chooseFolder(choices.importFolderLast)
    if not folder then
        Log.info('%sno folder chosen', P)
        return
    end

    -- 2. The record of the previous import (sqlite3, read-only): no import without it.
    local tool, toolProblem = SqliteRunner.locate(settings.sqlitePath, _PLUGIN and _PLUGIN.path)
    local state, problem
    if tool then
        state, problem = readState(tool, catalog:getPath())
    else
        problem = toolProblem
    end
    local verdict = ImportPlan.judge(state, problem)
    Log.info('%s%s; previous import: %s', P, folder, verdict.ok and ImportPlan.settingsLogText(verdict)
        or ('refused: ' .. verdict.refusal))
    if not verdict.ok then
        LrDialogs.message(TITLE, verdict.refusal, 'warning')
        return
    end

    -- 3. The dialog.
    local mappings = Settings.mappings(settings)
    local sendOk, sendWhy = ImportPlan.sendAvailability(settings, mappings, folder)
    local send = askToImport(context, folder, verdict, choices, sendOk, sendWhy)
    if send == nil then
        Log.info('%snot started', P)
        return
    end
    local remembered = { importFolderLast = folder }
    if sendOk then -- when the box was not offered, the remembered choice stays as it was
        remembered.importFolderSend = send
    end
    Settings.writeImportFolder(prefs, remembered)

    local progress = LrProgressScope { title = TITLE, functionContext = context }
    PhotoAccess.try('progress:setCancelable', function()
        progress:setCancelable(true)
    end)
    local function stop(text, style)
        progress:done()
        LrDialogs.message(TITLE, text, style or 'info')
    end

    -- 4. Can the server take them? Asked before anything starts.
    if send then
        progress:setCaption('Asking the server')
        local info, infoProblem = ServerClient.fetchInfo(settings)
        local sendProblem = info and Selection.serverProblem(info, mappings) or (not info and infoProblem.message)
        if sendProblem then
            Log.warn('%sthe photos cannot be sent afterwards: %s', P, sendProblem)
            if LrDialogs.confirm(TITLE, 'The imported photos cannot be sent to the server afterwards: ' .. sendProblem
                .. '\n\nImport the folder anyway, without sending?', 'Import', 'Cancel') ~= 'ok' then
                Log.info('%snot started', P)
                return progress:done()
            end
            send = false
        end
    end
    Log.info('%sstarting; send afterwards: %s', P, send and 'yes' or 'no')

    -- 5. Import and wait; when sending, holding the fetch lock from before the trigger to the end of the send.
    local job = { catalog = catalog, settings = settings, folder = folder, tool = tool, progress = progress,
        verdict = verdict, send = send }
    local text, style
    if send then
        local started, a, b = Pipeline.withLease(ImportPlan.LEASE_LABEL, function(lease)
            return importAndWait(job, lease)
        end)
        if not started then
            return stop(a .. '\n\nThe import was not started; while that runs, the imported photos could be sent '
                .. 'twice.', 'info')
        end
        text, style = a, b
    else
        text, style = importAndWait(job, nil)
    end
    Log.info('%ssummary:\n%s', P, text)
    stop(text, style)
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext('LRRemotePreviews.importFolder', function(context)
        local ok, err = LrTasks.pcall(run, context)
        if not ok then
            Log.error('%sunexpected error: %s', P, tostring(err))
            LrDialogs.message(TITLE, 'Unexpected error: ' .. tostring(err) .. '\n\n' .. Pipeline.LOG_HINT, 'critical')
        end
    end)
end)
