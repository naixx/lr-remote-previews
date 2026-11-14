-- Library > Plug-in Extras > Send to the server.
--
-- For the selected photos: the same checks as «Build smart previews on the server» (the server, the selection, the
-- file UUIDs read with sqlite3, read-only), then one job per maxItemsPerJob photos, tagged with this catalog's
-- clientId, and back at once. Nothing is downloaded or placed; Lightroom may be closed afterwards. The smart
-- previews are brought in later by «Fetch ready smart previews» (or the automatic fetch).
local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrPrefs = import 'LrPrefs'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'

local Jobs = require 'Jobs'
local Log = require 'Log'
local PhotoAccess = require 'PhotoAccess'
local Pipeline = require 'Pipeline'
local RunSummary = require 'RunSummary'
local ServerClient = require 'ServerClient'
local Settings = require 'Settings'
local SqliteCommand = require 'SqliteCommand'

local TITLE = 'Send to the server'

local function run(context)
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()
    if #photos == 0 then
        LrDialogs.message(TITLE, 'Select the photos first.', 'info')
        return
    end
    PhotoAccess.resetWarnings()
    local settings = Settings.read(LrPrefs.prefsForPlugin())
    for _, problem in ipairs(Settings.mappingProblems(settings)) do
        Log.warn('settings: %s', problem)
    end
    Log.info('send: %d photo(s) selected, %d path mapping(s)', #photos, #Settings.mappings(settings))

    local progress = LrProgressScope { title = TITLE, functionContext = context }
    PhotoAccess.try('progress:setCancelable', function()
        progress:setCancelable(true)
    end)
    local function stop(text, style)
        progress:done()
        LrDialogs.message(TITLE, text, style or 'info')
    end

    local summary = RunSummary.new(#photos)
    local prepared, problem = Pipeline.prepareSend(settings, catalog, photos, summary, Pipeline.progressUi(progress))
    if not prepared then
        if problem.cancelled then
            return progress:done()
        end
        return stop(problem.message, problem.style)
    end
    local entries = prepared.entries
    if LrDialogs.confirm(TITLE, summary:plan(#entries), 'Send', 'Cancel') ~= 'ok' then
        Log.info('send: not confirmed')
        return progress:done()
    end

    local clientId = Pipeline.clientId(catalog:getPath())
    local maxItems = prepared.info.capabilities.maxItemsPerJob
    local parts = SqliteCommand.chunks(entries, maxItems or #entries)
    local jobIds, ready, rejected, failedParts = {}, 0, 0, nil
    for i, part in ipairs(parts) do
        progress:setCaption(#parts == 1 and 'Sending the job' or string.format('Sending job %d of %d', i, #parts))
        local label = #parts > 1 and string.format('%s (part %d of %d)', Jobs.LABEL, i, #parts) or nil
        local body, bodyError = Jobs.createBody(part, { clientId = clientId, label = label })
        local created, createProblem
        if body then
            created, createProblem = ServerClient.createJob(settings, body)
        else
            createProblem = { message = 'Cannot build the job request: ' .. bodyError }
        end
        local refsOk, refsProblem = true, nil
        if created then
            refsOk, refsProblem = Jobs.checkRefs(created.items, part)
            if not refsOk then
                ServerClient.cancelJob(settings, created.job.id)
            end
        end
        if not created or not refsOk then
            local why = created and ('the server\'s answer does not match the request (' .. refsProblem
                .. '); that job was cancelled') or Jobs.createProblemText(createProblem, maxItems)
            Log.warn('send: part %d of %d failed: %s', i, #parts, why)
            failedParts = string.format('Part %d of %d (%d photos) and the parts after it were not sent: %s', i,
                #parts, #part, why)
            break
        end
        local jobId = created.job.id
        jobIds[#jobIds + 1] = jobId
        summary.sent = summary.sent + #part
        local byRef = {}
        for _, entry in ipairs(part) do
            byRef[entry.ref] = entry
        end
        for _, item in ipairs(created.items) do
            local entry = byRef[item.ref]
            if item.state == 'rejected' then
                local code = (item.error and item.error.code) or 'unknown'
                rejected = rejected + 1
                summary:outcome('rejected', code)
                Log.info('%s', RunSummary.photoLine(entry.fileName, 'rejected', 'job ' .. jobId .. ', ' .. code))
            else
                if item.state == 'ready' then
                    ready = ready + 1
                end
                Log.info('%s', RunSummary.photoLine(entry.fileName, 'sent', 'job ' .. jobId .. ', ' .. item.state))
            end
        end
        Log.info('send: job %d created with %d item(s)', jobId, #part)
    end

    if #jobIds == 0 then
        return stop(failedParts, 'critical')
    end
    local text = summary:sendText({
        jobIds = jobIds,
        ready = ready,
        rejected = rejected,
        failedParts = failedParts,
        fetchHint = Pipeline.FETCH_HINT,
        logHint = Pipeline.LOG_HINT,
    })
    Log.info('send: summary:\n%s', text)
    stop(text, failedParts and 'warning' or 'info')
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext('LRRemotePreviews.send', function(context)
        local ok, err = LrTasks.pcall(run, context)
        if not ok then
            Log.error('send: unexpected error: %s', tostring(err))
            LrDialogs.message(TITLE, 'Unexpected error: ' .. tostring(err) .. '\n\n' .. Pipeline.LOG_HINT, 'critical')
        end
    end)
end)
