-- Library > Plug-in Extras > Build smart previews on the server.
--
-- For the selected photos: ask the server what it can do; keep the photos it can build; read their file UUIDs
-- from the catalog with sqlite3 (read-only); create one job; poll it; deliver every finished DNG into the smart
-- preview store (checked, written under a temporary name and renamed, never over an existing file) and let
-- Lightroom register it with photo:buildSmartPreview(); show a summary and log a line per photo.
--
-- The decisions live in pure, unit-tested modules (Selection, SqliteCommand, Jobs, JobTracker, JobRunner,
-- Delivery, RunSummary). This file only reads Lightroom's data and connects those modules to the SDK.
local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrPrefs = import 'LrPrefs'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'

local Delivery = require 'Delivery'
local JobRunner = require 'JobRunner'
local JobTracker = require 'JobTracker'
local Jobs = require 'Jobs'
local Log = require 'Log'
local RunSummary = require 'RunSummary'
local Selection = require 'Selection'
local ServerClient = require 'ServerClient'
local Settings = require 'Settings'
local SmartPreviewPath = require 'SmartPreviewPath'
local SqliteCommand = require 'SqliteCommand'
local SqliteRunner = require 'SqliteRunner'

local TITLE = 'Build smart previews on the server'
local LOG_HINT = 'Every photo is listed in LRRemotePreviews.log in Lightroom\'s log folder (Lightroom Classic 15.6 '
    .. 'on Windows: %LOCALAPPDATA%\\Adobe\\Lightroom\\Logs\\LrClassicLogs).'

-- Calls fn; returns its value, or nil when it raised an error (logged once per what).
local warned = {}
local function try(what, fn)
    local ok, value = LrTasks.pcall(fn)
    if ok then
        return value
    end
    if not warned[what] then
        warned[what] = true
        Log.warn('%s failed: %s (logged once)', what, tostring(value))
    end
    return nil
end

-- photo.localIdentifier as a positive integer, or nil.
local function catalogId(value)
    local number = tonumber(value)
    if number and number >= 1 and number == math.floor(number) then
        return number
    end
    return nil
end

-- A plain description of one photo for the pure modules.
local function describePhoto(photo, index)
    local function raw(key)
        return try('getRawMetadata(' .. key .. ')', function()
            return photo:getRawMetadata(key)
        end)
    end
    local smartPreview = raw('smartPreviewInfo')
    local fileFormat = raw('fileFormat')
    local width, height = Selection.dimensions(raw('dimensions'))
    local fileName = try('getFormattedMetadata(fileName)', function()
        return photo:getFormattedMetadata('fileName')
    end)
    return {
        index = index,
        photo = photo,
        fileName = type(fileName) == 'string' and fileName or '?',
        path = raw('path'),
        isVideo = raw('isVideo') == true or fileFormat == 'VIDEO',
        isVirtualCopy = raw('isVirtualCopy') == true,
        smartPreviewPath = type(smartPreview) == 'table' and smartPreview.smartPreviewPath or nil,
        localId = catalogId(try('photo.localIdentifier', function()
            return photo.localIdentifier
        end)),
        width = width,
        height = height,
    }
end

local function exists(path)
    local kind = LrFileUtils.exists(path)
    return kind ~= nil and kind ~= false
end

local function writeFile(path, data)
    local file, openError = io.open(path, 'wb')
    if not file then
        return false, openError
    end
    local written, writeError = file:write(data)
    local closed, closeError = file:close()
    if not written or not closed then
        return false, writeError or closeError or 'write failed'
    end
    return true
end

-- The file operations Delivery needs, for one photo.
local function fileSystem(photo)
    return {
        exists = exists,
        makeFolder = function(path)
            return LrTasks.pcall(LrFileUtils.createAllDirectories, path)
        end,
        writeFile = writeFile,
        move = function(from, to)
            return LrTasks.pcall(LrFileUtils.move, from, to)
        end,
        delete = function(path)
            return LrTasks.pcall(LrFileUtils.delete, path)
        end,
        buildSmartPreview = function()
            return LrTasks.pcall(function()
                return photo:buildSmartPreview()
            end)
        end,
    }
end

local function run(context)
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()
    if #photos == 0 then
        LrDialogs.message(TITLE, 'Select the photos first.', 'info')
        return
    end
    local settings = Settings.read(LrPrefs.prefsForPlugin())
    local mappings = Settings.mappings(settings)
    for _, problem in ipairs(Settings.mappingProblems(settings)) do
        Log.warn('settings: %s', problem)
    end
    Log.info('build: %d photo(s) selected, %d path mapping(s)', #photos, #mappings)

    local progress = LrProgressScope { title = TITLE, functionContext = context }
    try('progress:setCancelable', function()
        progress:setCancelable(true)
    end)
    local function stop(text, style)
        progress:done()
        LrDialogs.message(TITLE, text, style or 'info')
    end

    -- 1. The server.
    progress:setCaption('Asking the server')
    local info, infoProblem = ServerClient.fetchInfo(settings)
    if not info then
        return stop(infoProblem.message, 'critical')
    end
    local serverProblem = Selection.serverProblem(info, mappings)
    if serverProblem then
        Log.warn('build: %s', serverProblem)
        return stop(serverProblem, 'critical')
    end

    -- 2. The selection.
    progress:setCaption('Reading the selection')
    local described = {}
    for i, photo in ipairs(photos) do
        if progress:isCanceled() then
            return progress:done()
        end
        described[i] = describePhoto(photo, i)
        progress:setPortionComplete(i, #photos)
    end
    local summary = RunSummary.new(#photos)
    local selection = Selection.classify(described, {
        extensions = info.capabilities.extensions,
        mappings = mappings,
        availableRoots = Selection.availableRoots(info),
    })
    local function skip(photo, reason, detail)
        summary:skip(reason)
        Log.info('%s', RunSummary.photoLine(photo.fileName, reason, detail))
    end
    for _, skipped in ipairs(selection.skipped) do
        skip(skipped.photo, skipped.reason, skipped.detail)
    end
    if #selection.eligible == 0 then
        return stop(summary:text({ stoppedBefore = 'Nothing to send.', logHint = LOG_HINT }))
    end

    -- 3. File UUIDs from the catalog, read-only.
    progress:setCaption('Looking for sqlite3')
    local tool, toolProblem = SqliteRunner.locate(settings.sqlitePath, _PLUGIN and _PLUGIN.path)
    if not tool then
        Log.warn('build: %s', toolProblem)
        return stop(toolProblem, 'critical')
    end
    Log.info('sqlite3 %s, %s', tool.version, SqliteRunner.describe(tool))
    local catalogPath = catalog:getPath()
    local ids = {}
    for _, photo in ipairs(selection.eligible) do
        if type(photo.localId) == 'number' then
            ids[#ids + 1] = photo.localId
        end
    end
    local rows = {}
    if #ids > 0 then
        progress:setCaption('Reading file ids from the catalog')
        local lookupProblems
        rows, lookupProblems = SqliteRunner.lookup(tool.tool, catalogPath, ids, function()
            return progress:isCanceled()
        end)
        if not rows then
            if progress:isCanceled() then
                return progress:done()
            end
            Log.warn('build: reading the catalog failed: %s', lookupProblems)
            return stop('Reading the file ids from the catalog failed: ' .. lookupProblems, 'critical')
        end
        for _, problem in ipairs(lookupProblems) do
            Log.warn('sqlite3 output: %s', problem)
        end
    end

    local entries, byUuid = {}, {}
    for _, photo in ipairs(selection.eligible) do
        local row = type(photo.localId) == 'number' and rows[photo.localId] or nil
        local reason, detail
        if type(photo.localId) ~= 'number' then
            reason = 'noLocalId'
        elseif not row then
            reason, detail = 'noFileId', 'catalog id ' .. string.format('%d', photo.localId)
        elseif SqliteCommand.fileNameOf(row):lower() ~= photo.fileName:lower() then
            reason, detail = 'fileIdMismatch', 'the catalog database names "' .. SqliteCommand.fileNameOf(row)
                .. '" for catalog id ' .. string.format('%d', photo.localId)
        elseif byUuid[row.fileUuid] then
            reason, detail = 'sameFile', byUuid[row.fileUuid].fileName
        else
            photo.dest, detail = SmartPreviewPath.dngPath(catalogPath, row.fileUuid)
            if not photo.dest then
                reason = 'noFileId'
            end
        end
        if reason then
            skip(photo, reason, detail)
        else
            photo.ref = tostring(#entries + 1)
            photo.fileUuid = row.fileUuid
            byUuid[row.fileUuid] = photo
            entries[#entries + 1] = photo
        end
    end
    if #entries == 0 then
        return stop(summary:text({ stoppedBefore = 'Nothing to send.', logHint = LOG_HINT }))
    end
    local maxItems = info.capabilities.maxItemsPerJob
    if maxItems and #entries > maxItems then
        return stop(string.format('%d photos would be sent, but the server takes at most %d per job. '
            .. 'Select fewer photos.', #entries, maxItems))
    end

    -- 4. The job.
    if LrDialogs.confirm(TITLE, summary:plan(#entries), 'Build', 'Cancel') ~= 'ok' then
        Log.info('build: not confirmed')
        return progress:done()
    end
    progress:setCaption('Sending the job')
    local body, bodyError = Jobs.createBody(entries)
    if not body then
        return stop('Cannot build the job request: ' .. bodyError, 'critical')
    end
    local created, createProblem = ServerClient.createJob(settings, body)
    if not created then
        Log.warn('build: creating the job failed: %s', createProblem.message)
        return stop(Jobs.createProblemText(createProblem, maxItems), 'critical')
    end
    local jobId = created.job.id
    local refsOk, refsProblem = Jobs.checkRefs(created.items, entries)
    if not refsOk then
        ServerClient.cancelJob(settings, jobId)
        return stop('The server\'s answer does not match the request (' .. refsProblem .. '). The job was cancelled.',
            'critical')
    end
    summary.sent = #entries
    Log.info('build: job %d created with %d item(s)', jobId, #entries)

    -- 5. Polling and delivery.
    local byRef, refs = {}, {}
    for i, entry in ipairs(entries) do
        byRef[entry.ref] = entry
        refs[i] = entry.ref
    end
    local runTag = string.format('lrrp-%d', os.time())
    local function record(entry, key, detail, code)
        entry.outcome = key
        summary:outcome(key, code)
        Log.info('%s', RunSummary.photoLine(entry.fileName, key, detail))
    end
    local function handle(item)
        local entry = byRef[item.ref]
        if item.state == 'ready' then
            progress:setCaption('Downloading ' .. entry.fileName)
            local data, problem = ServerClient.download(settings, item.id)
            if not data then
                return record(entry, 'downloadFailed', problem.message)
            end
            local outcome, detail = Delivery.deliver(entry, item.result, data, fileSystem(entry.photo),
                runTag .. '-' .. entry.ref)
            if outcome == 'delivered' or outcome == 'deliveredOther' or outcome == 'destinationExists' then
                detail = (detail and detail ~= entry.dest) and (detail .. ', ' .. entry.dest) or entry.dest
            end
            record(entry, outcome, detail)
        elseif item.state == 'failed' or item.state == 'rejected' then
            local code = (item.error and item.error.code) or 'unknown'
            local message = item.error and item.error.message
            record(entry, item.state, code .. (message and (': ' .. message) or ''), code)
        else
            record(entry, 'cancelled')
        end
    end

    local result = JobRunner.run({
        fetchItems = function(since)
            return ServerClient.fetchItems(settings, jobId, since)
        end,
        handle = handle,
        isCanceled = function()
            return progress:isCanceled()
        end,
        sleep = function(seconds)
            LrTasks.sleep(seconds)
        end,
        cancelJob = function()
            return ServerClient.cancelJob(settings, jobId)
        end,
        progress = function(tracker)
            progress:setPortionComplete(tracker.final, tracker.total)
            progress:setCaption(string.format('%d of %d finished on the server, %d placed', tracker.final,
                tracker.total, summary:count('delivered') + summary:count('deliveredOther')))
        end,
        log = function(...)
            Log.info(...)
        end,
    }, JobTracker.new(refs), created.items)

    for _, entry in ipairs(entries) do
        if not entry.outcome then
            record(entry, 'notDelivered')
        end
    end

    -- 6. The summary.
    local aborted = result.aborted
    if aborted then
        aborted = aborted .. ' Job ' .. jobId .. ' was left on the server; what it builds stays in its cache, so '
            .. 'running the command again later fetches those files quickly.'
        Log.warn('build: stopped: %s', aborted)
    end
    local text = summary:text({
        cancelled = result.cancelled,
        cancelProblem = result.cancelProblem and result.cancelProblem.message,
        aborted = aborted,
        logHint = LOG_HINT,
    })
    Log.info('build: summary:\n%s', text)
    local troubled = aborted or summary:count('checkFailed') + summary:count('writeFailed')
        + summary:count('downloadFailed') + summary:count('deliveredOther') > 0
    stop(text, troubled and 'warning' or 'info')
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext('LRRemotePreviews.buildSmartPreviews', function(context)
        local ok, err = LrTasks.pcall(run, context)
        if not ok then
            Log.error('build: unexpected error: %s', tostring(err))
            LrDialogs.message(TITLE, 'Unexpected error: ' .. tostring(err) .. '\n\n' .. LOG_HINT, 'critical')
        end
    end)
end)
