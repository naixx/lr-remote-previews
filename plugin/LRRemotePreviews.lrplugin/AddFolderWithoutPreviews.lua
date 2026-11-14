-- Library > Plug-in Extras > Add a folder without previews...
--
-- Adds the photo files of one or more folders to the catalog without Lightroom's import dialog and without asking
-- Lightroom for any preview: the folders are listed (no file is opened), files already in the catalog are left alone,
-- and the rest are added with catalog:addPhoto in batches inside catalog:withWriteAccessDo (PhotoAdder). Afterwards,
-- when chosen, the added photos go through the same steps as «Send to the server» (Pipeline.prepareSend and
-- Pipeline.sendJobs), so that the server builds their smart previews. It is Lightroom that changes its catalog here,
-- through its own plug-in interface, on the user's command, as its import does; the plug-in writes no catalog or
-- database itself, and never changes, moves or deletes a file on disk or writes anything next to the originals.
--
-- No photo is sent twice when the automatic send is on as well: when the photos are to be sent and the server said at
-- the start that it can take them, their catalog ids are recorded right after each batch (AutoSendPlan.recordSent),
-- and the automatic send leaves them out.
--
-- The decisions live in pure, unit-tested modules (FolderListing, AddPlan, Settings, AutoSendPlan); this file asks,
-- lists, looks up, and runs the steps. What Lightroom does by itself with such photos (thumbnails, previews when they
-- are shown) has not been measured.
local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrPrefs = import 'LrPrefs'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local AddPlan = require 'AddPlan'
local AutoSendPlan = require 'AutoSendPlan'
local FolderListing = require 'FolderListing'
local Log = require 'Log'
local PhotoAccess = require 'PhotoAccess'
local PhotoAdder = require 'PhotoAdder'
local Pipeline = require 'Pipeline'
local RunSummary = require 'RunSummary'
local ServerClient = require 'ServerClient'
local Selection = require 'Selection'
local Settings = require 'Settings'

local TITLE = 'Add a folder without previews'
local P = AddPlan.LOG_PREFIX
local LATER_HINT = 'To send them later, select them and use Library > Plug-in Extras > Send to the server (the '
    .. 'automatic send leaves photos added with this option alone).'
local PLAIN_HINT = 'To send them later, select them and use Library > Plug-in Extras > Send to the server.'

local now = PhotoAdder.now

-- A folder listing as a list. The LrFileUtils iterators must run to their end (the SDK says not to leave them with
-- break), so the whole listing is read first.
local function collect(iterate, folder)
    local ok, list = LrTasks.pcall(function()
        local paths = {}
        for path in iterate(folder) do
            paths[#paths + 1] = path
        end
        return paths
    end)
    if not ok then
        return nil, tostring(list)
    end
    return list
end

-- The folder dialog; it opens in the folder that holds the folder chosen last. Returns the chosen folders or nil.
local function chooseFolders(lastFolder)
    local args = { title = TITLE .. ': choose the folders', prompt = 'Choose', canChooseFiles = false,
        canChooseDirectories = true, canCreateDirectories = false, allowsMultipleSelection = true }
    if lastFolder ~= '' then
        local parent = FolderListing.split(lastFolder)
        if parent:match('^%a:$') then
            parent = parent .. '\\'
        end
        if parent ~= '' then
            args.initialDirectory = parent
        end
    end
    local folders = LrDialogs.runOpenPanel(args)
    if type(folders) ~= 'table' or #folders == 0 then
        return nil
    end
    return folders
end

-- The options dialog. Returns { recursive, otherFormats, send } or nil when cancelled.
local function askOptions(context, folders, choices, sendOk, sendWhy)
    local f = LrView.osFactory()
    local bind = LrView.bind
    local props = LrBinding.makePropertyTable(context)
    props.subfolders = choices.addFolderSubfolders
    props.otherFormats = choices.addFolderOtherFormats
    props.send = sendOk and choices.addFolderSend or false
    local folderLines = {}
    for i, folder in ipairs(folders) do
        folderLines[i] = folder
    end
    local contents = f:column {
        bind_to_object = props,
        f:static_text { title = (#folders == 1 and 'Folder: ' or 'Folders:\n') .. table.concat(folderLines, '\n') },
        f:checkbox { title = 'Include sub-folders', value = bind 'subfolders' },
        f:checkbox { title = 'Also add JPEG, TIFF, PNG, HEIC and PSD files (otherwise camera raw files only)',
            value = bind 'otherFormats' },
        f:static_text { title = 'A JPEG next to a raw file of the same name is left out, as in Lightroom\'s import.' },
        f:checkbox { title = 'Send the added photos to the server afterwards', value = bind 'send', enabled = sendOk },
        f:static_text { title = sendOk and 'As «Send to the server» does; the automatic send leaves them alone.'
            or sendWhy },
        f:static_text { title = 'Lightroom is not asked for any preview, and no file on disk is changed.' },
    }
    local answer = LrDialogs.presentModalDialog { title = TITLE, contents = contents, actionVerb = 'Continue' }
    if answer ~= 'ok' then
        return nil
    end
    return { recursive = props.subfolders == true, otherFormats = props.otherFormats == true,
        send = sendOk and props.send == true }
end

-- Sends the added photos as «Send to the server» does, without its confirmation. Returns the text for the summary
-- and whether it went well (every job created; photos left out for a reason are fine).
local function sendAdded(settings, catalog, photos, ui)
    local summary = RunSummary.new(#photos)
    local prepared, problem = Pipeline.prepareSend(settings, catalog, photos, summary, ui)
    if not prepared then
        if problem.cancelled then
            return 'Sending to the server was cancelled. ' .. LATER_HINT, false
        end
        if problem.style == 'info' then
            return summary:text({ header = string.format('None of the %s was sent to the server.',
                #photos == 1 and 'added photo' or (#photos .. ' added photos')) }), true
        end
        return 'Not sent to the server: ' .. tostring(problem.message) .. '\n' .. LATER_HINT, false
    end
    local sent = Pipeline.sendJobs(settings, catalog:getPath(), prepared, summary, ui, AddPlan.JOB_LABEL)
    if #sent.jobIds == 0 then
        return 'Not sent to the server: ' .. tostring(sent.failedParts) .. '\n' .. LATER_HINT, false
    end
    return summary:sendText({ jobIds = sent.jobIds, ready = sent.ready, rejected = sent.rejected,
        failedParts = sent.failedParts, fetchHint = Pipeline.FETCH_HINT }), sent.failedParts == nil
end

local function run(context)
    local catalog = LrApplication.activeCatalog()
    local prefs = LrPrefs.prefsForPlugin()
    PhotoAccess.resetWarnings()
    local settings = Settings.read(prefs)
    local choices = Settings.readAddFolder(prefs)

    -- 1. The folders and the options.
    local folders = chooseFolders(choices.addFolderLast)
    if not folders then
        Log.info('%sno folder chosen', P)
        return
    end
    local mappings = Settings.mappings(settings)
    local sendOk, sendWhy = AddPlan.sendAvailability(settings, mappings, folders)
    local options = askOptions(context, folders, choices, sendOk, sendWhy)
    if not options then
        Log.info('%snot started', P)
        return
    end
    local remembered = { addFolderSubfolders = options.recursive, addFolderOtherFormats = options.otherFormats,
        addFolderLast = folders[1] }
    if sendOk then -- when the box was not offered, the remembered choice stays as it was
        remembered.addFolderSend = options.send
    end
    Settings.writeAddFolder(prefs, remembered)
    Log.info('%sstarted: %s; other formats: %s; send afterwards: %s', P,
        (AddPlan.folderText(folders, options.recursive):gsub('\n', ' ')), options.otherFormats and 'yes' or 'no',
        options.send and 'yes' or ('no' .. (sendOk and '' or (' (' .. sendWhy .. ')'))))

    local progress = LrProgressScope { title = TITLE, functionContext = context }
    PhotoAccess.try('progress:setCancelable', function()
        progress:setCancelable(true)
    end)
    local ui = Pipeline.progressUi(progress)
    local function stop(text, style)
        progress:done()
        LrDialogs.message(TITLE, text, style or 'info')
    end

    -- 2. The camera raw types: the server's list when it answers, otherwise the built-in one.
    local rawExtensions, rawSource, info, infoProblem = FolderListing.RAW_EXTENSIONS, 'built-in', nil, nil
    if settings.serverUrl ~= '' then
        ui.caption('Asking the server which file types it takes')
        info, infoProblem = ServerClient.fetchInfo(settings)
        if info and #info.capabilities.extensions > 0 then
            rawExtensions, rawSource = info.capabilities.extensions, 'server'
        end
    end
    Log.info('%scamera raw types (%s): %s', P, rawSource == 'server' and 'from the server' or 'built-in list',
        table.concat(rawExtensions, ' '))
    -- Whether the server can take the photos, known before adding: only then are they recorded for the automatic send.
    local sendProblem
    if options.send then
        if not info then
            sendProblem = infoProblem and infoProblem.message or 'The server did not answer.'
        else
            sendProblem = Selection.serverProblem(info, mappings)
        end
        if sendProblem then
            Log.warn('%sthe photos cannot be sent afterwards: %s', P, sendProblem)
        end
    end

    -- 3. The files: listed without opening any of them.
    local addRun = AddPlan.newRun()
    local started = now()
    local found = 0
    ui.caption('Listing the files')
    local listing = FolderListing.walk(folders, {
        files = function(folder)
            local list, problem = collect(LrFileUtils.files, folder)
            found = found + (list and #list or 0)
            return list, problem
        end,
        entries = function(folder)
            return collect(LrFileUtils.directoryEntries, folder)
        end,
        step = function()
            LrTasks.yield()
            ui.caption(string.format('Listing the files: %d found', found))
            return ui.isCanceled()
        end,
    }, { recursive = options.recursive })
    if listing.stopped then
        Log.info('%scancelled while listing', P)
        return progress:done()
    end
    for _, skipped in ipairs(listing.skippedFolders) do
        addRun.skippedFolders = addRun.skippedFolders + 1
        Log.info('%s%s: folder not looked into (%s)', P, skipped.path, skipped.reason)
    end
    for _, problem in ipairs(listing.problems) do
        addRun.problems = addRun.problems + 1
        Log.warn('%s%s: could not be listed: %s', P, problem.path, problem.message)
    end
    local sorted = FolderListing.classify(listing.files, { rawExtensions = rawExtensions,
        otherExtensions = options.otherFormats and FolderListing.OTHER_EXTENSIONS or nil })
    for _, skipped in ipairs(sorted.skipped) do
        addRun:skip(skipped.reason)
        Log.info('%s', AddPlan.fileLine(skipped.path, skipped.reason, skipped.reason == 'pairedJpeg'
            and ('next to ' .. skipped.detail) or skipped.detail))
    end
    local listingSeconds = now() - started
    Log.info('%slisting: %d folder(s) looked into, %d file(s) found, %d to look up in the catalog, %s', P,
        listing.folders, #listing.files, #sorted.candidates, AddPlan.seconds(listingSeconds))

    -- 4. Files already in the catalog are left alone.
    started = now()
    ui.caption(string.format('Looking %d file(s) up in the catalog', #sorted.candidates))
    local toAdd = {}
    for i, file in ipairs(sorted.candidates) do
        if ui.isCanceled() then
            Log.info('%scancelled while looking the files up in the catalog', P)
            return progress:done()
        end
        if PhotoAccess.findByPath(catalog, file.path) then
            addRun:outcome('alreadyInCatalog', file.name)
            Log.info('%s', AddPlan.fileLine(file.path, 'alreadyInCatalog'))
        else
            toAdd[#toAdd + 1] = file
        end
        ui.portion(i, #sorted.candidates)
        if i % 200 == 0 then
            LrTasks.yield()
        end
    end
    local checkingSeconds = now() - started
    Log.info('%scatalog lookup: %d file(s), %d already in the catalog, %s', P, #sorted.candidates,
        addRun:count('alreadyInCatalog'), AddPlan.seconds(checkingSeconds))

    local times = { listing = listingSeconds, checking = checkingSeconds }
    if #toAdd == 0 then
        local text = AddPlan.summaryText(addRun, { folders = folders, recursive = options.recursive, times = times,
            logHint = Pipeline.LOG_HINT })
        Log.info('%ssummary:\n%s', P, text)
        return stop(text, addRun:troubled() and 'warning' or 'info')
    end
    if LrDialogs.confirm(TITLE, AddPlan.planText(addRun, { folders = folders, recursive = options.recursive,
        otherFormats = options.otherFormats, rawSource = rawSource, toAdd = #toAdd, send = options.send,
        sendProblem = sendProblem }), 'Add', 'Cancel') ~= 'ok' then
        Log.info('%snot confirmed', P)
        return progress:done()
    end

    -- 5. Adding, in batches. When they are to be sent, each batch's photos are recorded for the automatic send at once.
    local catalogPath = catalog:getPath()
    local runTag = Pipeline.runTag()
    local onWritten
    if options.send and not sendProblem then
        onWritten = function(photos)
            local ids = {}
            for _, photo in ipairs(photos) do
                local id = PhotoAccess.try('photo.localIdentifier', function()
                    return photo.localIdentifier
                end)
                if type(id) == 'number' then
                    ids[#ids + 1] = id
                end
            end
            AutoSendPlan.recordSent(prefs, catalogPath, ids, runTag)
        end
    end
    ui.portion(0, #toAdd)
    local added = PhotoAdder.addAll(catalog, toAdd, addRun, ui, onWritten)
    times.adding = added.seconds

    -- 6. Sending, when chosen.
    local sendText, sentWell = nil, true
    if options.send and #added.added == 0 then
        sendText = 'Nothing was sent to the server: no photo was added.'
    elseif options.send then
        sentWell = false
        if sendProblem then
            sendText = 'Not sent to the server: ' .. sendProblem .. '\n' .. PLAIN_HINT
        elseif added.cancelled or added.stopped then
            sendText = 'The added photos were not sent to the server, because the run did not finish. ' .. LATER_HINT
        else
            started = now()
            sendText, sentWell = sendAdded(settings, catalog, added.added, ui)
            times.sending = now() - started
            Log.info('%ssending: %d photo(s), %s', P, #added.added, AddPlan.seconds(times.sending))
        end
    end

    -- 7. The summary.
    local text = AddPlan.summaryText(addRun, { folders = folders, recursive = options.recursive,
        cancelled = added.cancelled, stopped = added.stopped, times = times, sendText = sendText,
        logHint = Pipeline.LOG_HINT })
    Log.info('%ssummary:\n%s', P, text)
    stop(text, (addRun:troubled() or added.stopped or not sentWell) and 'warning' or 'info')
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext('LRRemotePreviews.addFolder', function(context)
        local ok, err = LrTasks.pcall(run, context)
        if not ok then
            Log.error('%sunexpected error: %s', P, tostring(err))
            LrDialogs.message(TITLE, 'Unexpected error: ' .. tostring(err) .. '\n\n' .. Pipeline.LOG_HINT, 'critical')
        end
    end)
end)
