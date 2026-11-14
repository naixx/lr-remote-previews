-- Help > Plug-in Extras > Check the server against Lightroom.
--
-- For ONE selected raw photo that already has a smart preview built by Lightroom itself: reads that smart preview,
-- gets the server's DNG for the same raw file (looked up; built by a one-item job when the server does not have it,
-- which can be cancelled), keeps it in memory only, and compares the two (DngCompare). The verdict goes to a dialog
-- and to the log, with the versions involved. Nothing is written anywhere: not into the smart preview store, not
-- into the catalog, not to any file. The command never calls buildSmartPreview(), and it takes no fetch lock
-- because it places nothing. Photos without a smart preview are refused with a note on how to get one.
--
-- The decisions and texts are in CompatCheck and DngCompare (pure, tested); this file connects them to the SDK.
local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrPrefs = import 'LrPrefs'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'

local CompatCheck = require 'CompatCheck'
local DngCompare = require 'DngCompare'
local JobRunner = require 'JobRunner'
local JobTracker = require 'JobTracker'
local Jobs = require 'Jobs'
local Log = require 'Log'
local PhotoAccess = require 'PhotoAccess'
local Pipeline = require 'Pipeline'
local Selection = require 'Selection'
local ServerClient = require 'ServerClient'
local Settings = require 'Settings'
local TextWrap = require 'TextWrap'

local TITLE = 'Check the server against Lightroom'

-- The smart preview's content, read only. Returns the bytes, or nil plus a message.
local function readFile(path)
    local ok, data, err = LrTasks.pcall(function()
        local file, openError = io.open(path, 'rb')
        if not file then
            return nil, openError
        end
        local content = file:read('*a')
        file:close()
        return content
    end)
    if not ok then
        return nil, tostring(data)
    end
    if type(data) ~= 'string' then
        return nil, tostring(err or 'nothing could be read')
    end
    return data
end

-- Lightroom's version as the SDK gives it (LrApplication.versionString), or nil.
local function lightroomVersion()
    local ok, version = LrTasks.pcall(function()
        return LrApplication.versionString()
    end)
    if ok and type(version) == 'string' and version ~= '' then
        return version
    end
    Log.warn('check: LrApplication.versionString failed: %s', tostring(version))
    return nil
end

-- Has the server build the file with a one-item job (no clientId: it is not one of this catalog's jobs) and waits
-- for it. Returns { result, itemId }, or nil plus a message and whether it was cancelled.
local function buildOnServer(settings, target, progress)
    local entries = { { ref = '1', rootId = target.rootId, relativePath = target.relativePath } }
    local body, bodyError = Jobs.createBody(entries, { label = CompatCheck.LABEL })
    if not body then
        return nil, 'Cannot build the job request: ' .. bodyError
    end
    progress:setCaption('Asking the server to build the file')
    local created, createProblem = ServerClient.createJob(settings, body)
    if not created then
        return nil, Jobs.createProblemText(createProblem, 1)
    end
    local jobId = created.job.id
    local refsOk, refsProblem = Jobs.checkRefs(created.items, entries)
    if not refsOk then
        ServerClient.cancelJob(settings, jobId)
        return nil, 'The server\'s answer does not match the request (' .. refsProblem .. '). The job was cancelled.'
    end
    Log.info('check: job %d created to build %s', jobId, target.relativePath)
    local finalItem
    local result = JobRunner.run({
        fetchItems = function(since)
            return ServerClient.fetchItems(settings, jobId, since)
        end,
        handle = function(item)
            finalItem = item
        end,
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
            if not tracker:isComplete() then
                progress:setCaption('Waiting for the server to build the file (job ' .. jobId .. ')')
            end
        end,
        log = function(...)
            Log.info(...)
        end,
    }, JobTracker.new({ '1' }), created.items)
    if result.cancelled then
        local text = 'Cancelled. Job ' .. jobId .. ' was cancelled on the server.'
        if result.cancelProblem then
            text = text .. ' (Cancelling it failed: ' .. tostring(result.cancelProblem.message) .. ')'
        end
        return nil, text, true
    end
    if result.aborted then
        return nil, result.aborted .. ' (job ' .. jobId .. ')'
    end
    local decision, why = CompatCheck.afterJob(finalItem)
    if not decision then
        return nil, why
    end
    return decision
end

local function run(context)
    local catalog = LrApplication.activeCatalog()
    local settings = Settings.read(LrPrefs.prefsForPlugin())
    if settings.serverUrl == '' then
        LrDialogs.message(TITLE, 'No server is configured yet. Enter its URL in ' .. CompatCheck.SETTINGS_HINT .. '.',
            'info')
        return
    end
    local photos, selected = PhotoAccess.selection(catalog)
    if not selected or #photos ~= 1 then
        LrDialogs.message(TITLE, CompatCheck.SELECT_ONE .. string.format(' (%d selected.)', selected and #photos or 0),
            'info')
        return
    end
    PhotoAccess.resetWarnings()
    local photo = PhotoAccess.describe(photos[1], 1)
    Log.info('check: %s, smart preview: %s', photo.fileName, tostring(photo.smartPreviewPath))

    local progress = LrProgressScope { title = TITLE, functionContext = context }
    PhotoAccess.try('progress:setCancelable', function()
        progress:setCancelable(true)
    end)
    local function stop(text, style)
        progress:done()
        Log.info('check: %s', text)
        LrDialogs.message(TITLE, text, style)
    end

    progress:setCaption('Asking the server')
    local info, infoProblem = ServerClient.fetchInfo(settings)
    if not info then
        return stop(infoProblem.message, 'critical')
    end
    local mappings = Settings.mappings(settings)
    local serverProblem = Selection.serverProblem(info, mappings, { fetchOnly = true })
    if serverProblem then
        return stop(serverProblem, 'critical')
    end
    local target, refusal = CompatCheck.target(photo, { extensions = info.capabilities.extensions,
        mappings = mappings, availableRoots = Selection.availableRoots(info) })
    if not target then
        return stop(refusal, 'info')
    end

    progress:setCaption('Reading Lightroom\'s smart preview')
    local lightroomBytes, readError = readFile(photo.smartPreviewPath)
    if not lightroomBytes then
        Log.warn('check: cannot read %s: %s', photo.smartPreviewPath, readError)
        return stop('Cannot read the smart preview Lightroom lists for ' .. photo.fileName .. ' ('
            .. TextWrap.shortPath(photo.smartPreviewPath) .. '): ' .. readError, 'critical')
    end
    if progress:isCanceled() then
        return progress:done()
    end

    progress:setCaption('Looking the file up on the server')
    local answers, lookupProblem = ServerClient.lookup(settings, { { ref = '1', rootId = target.rootId,
        relativePath = target.relativePath } })
    if not answers then
        return stop(lookupProblem.message, 'critical')
    end
    local decision, why = CompatCheck.afterLookup(answers['1'], info.converter.installed)
    if not decision then
        return stop(why, 'warning')
    end
    local built = decision.action == 'build'
    if built then
        local cancelled
        decision, why, cancelled = buildOnServer(settings, target, progress)
        if not decision then
            return stop(why, cancelled and 'info' or 'critical')
        end
    end

    progress:setCaption('Downloading the server\'s file')
    local serverBytes, downloadProblem
    if Jobs.isCacheKey(decision.result.key) then
        serverBytes, downloadProblem = ServerClient.downloadByKey(settings, decision.result.key)
    else
        serverBytes, downloadProblem = ServerClient.download(settings, decision.itemId)
    end
    if not serverBytes then
        return stop('Downloading the server\'s file failed: ' .. downloadProblem.message, 'critical')
    end
    if #serverBytes ~= decision.result.size then
        return stop(string.format('The download is incomplete: %d bytes, the server announced %d.', #serverBytes,
            decision.result.size), 'critical')
    end

    progress:setCaption('Comparing')
    local report = DngCompare.compare(lightroomBytes, serverBytes)
    local text = CompatCheck.text(report, {
        fileName = photo.fileName,
        lightroomVersion = lightroomVersion(),
        serverName = info.name,
        serverVersion = info.version,
        converterVersion = info.converter.version,
        built = built,
    })
    Log.info('check: verdict %s for %s', report.verdict, photo.fileName)
    stop(text, CompatCheck.style(report))
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext('LRRemotePreviews.checkServer', function(context)
        local ok, err = LrTasks.pcall(run, context)
        if not ok then
            Log.error('check: unexpected error: %s', tostring(err))
            LrDialogs.message(TITLE, 'Unexpected error: ' .. tostring(err) .. '\n\n' .. Pipeline.LOG_HINT, 'critical')
        end
    end)
end)
