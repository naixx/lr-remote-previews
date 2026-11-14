-- Help > Plug-in Extras > Server status...: what the server says about itself (GET /api/v1/info), this
-- catalog's jobs that still matter, how many smart previews wait to be fetched, and three actions: «Fetch now»
-- (everything this catalog sent), retrying the failed items of a job, and opening the dashboard in the browser.
local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrHttp = import 'LrHttp'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local CatalogState = require 'CatalogState'
local FetchPlan = require 'FetchPlan'
local Fetcher = require 'Fetcher'
local Log = require 'Log'
local PendingJobs = require 'PendingJobs'
local Pipeline = require 'Pipeline'
local ServerClient = require 'ServerClient'
local ServerInfo = require 'ServerInfo'
local Settings = require 'Settings'
local StatusReport = require 'StatusReport'

local TITLE = 'LR Remote Previews: server status'
local FETCH_TITLE = 'Fetch ready smart previews'

-- The «Retry» button: asks the server in a task of its own and shows the answer under the button. A retried job is
-- pending again, so the automatic fetch follows it.
local function retry(props, settings, catalogPath)
    LrTasks.startAsyncTask(function()
        local jobId = props.retryJob
        if type(jobId) ~= 'number' then
            return
        end
        props.retryResult = string.format('Asking the server to retry job %d...', jobId)
        local ok, job, problem = LrTasks.pcall(ServerClient.retryJob, settings, jobId)
        if not ok then
            props.retryResult = 'Retry failed: ' .. tostring(job)
        elseif job then
            props.retryResult = StatusReport.retryText(job)
            PendingJobs.add(LrPrefs.prefsForPlugin(), catalogPath, { jobId }, os.time())
            Log.info('status: %s', props.retryResult)
        else
            props.retryResult = 'Retry failed: ' .. problem.message
        end
    end, 'LR Remote Previews retry')
end

local function run(context)
    local settings = Settings.read(LrPrefs.prefsForPlugin())
    if settings.serverUrl == '' then
        LrDialogs.message(TITLE, 'No server is configured yet. Enter its URL in '
            .. 'File > Plug-in Manager > LR Remote Previews.', 'info')
        return
    end
    local info, problem = ServerClient.fetchInfo(settings)
    if not info then
        LrDialogs.message(TITLE, problem.message, 'critical')
        return
    end

    local catalog = LrApplication.activeCatalog()
    local catalogPath = catalog:getPath()
    local prefs = LrPrefs.prefsForPlugin()
    local clientId = CatalogState.clientId(prefs, catalogPath)
    local jobsContext = { clientId = clientId, jobs = {}, now = os.time(),
        retentionDays = info.capabilities.jobRetentionDays }
    local choices = {}
    if clientId then
        local jobs, listProblem = ServerClient.listJobs(settings, clientId)
        if not jobs then
            jobsContext.problem = listProblem.message
        else
            local records = CatalogState.jobs(prefs, catalogPath)
            jobsContext.jobs = FetchPlan.interesting(jobs, records, clientId)
            jobsContext.listed = 0
            for _, job in ipairs(jobs) do
                if job.clientId == clientId then
                    jobsContext.listed = jobsContext.listed + 1
                end
            end
            jobsContext.waiting = Fetcher.countWaiting(settings, jobs, records, clientId)
            choices = StatusReport.retryChoices(jobsContext.jobs)
        end
    end
    local text = ServerInfo.formatReport(info, { serverUrl = settings.serverUrl,
        mappings = Settings.mappings(settings) }) .. '\n\n' .. StatusReport.jobsText(jobsContext)

    local f = LrView.osFactory()
    local props = LrBinding.makePropertyTable(context)
    props.retryJob = choices[1] and choices[1].value or nil
    props.retryResult = ''
    local rows = { bind_to_object = props, f:static_text { title = text } }
    if #choices > 0 then
        rows[#rows + 1] = f:row {
            f:static_text { title = 'Retry the failed items of' },
            f:popup_menu { items = choices, value = LrView.bind 'retryJob' },
            f:push_button {
                title = 'Retry',
                action = function()
                    retry(props, settings, catalogPath)
                end,
            },
        }
        rows[#rows + 1] = f:static_text { title = LrView.bind 'retryResult', width_in_chars = 80 }
    end
    local answer = LrDialogs.presentModalDialog {
        title = TITLE,
        contents = f:column(rows),
        actionVerb = 'Fetch now',
        cancelVerb = 'Close',
        otherVerb = 'Open the dashboard',
    }
    Log.info('status: %s', tostring(answer))
    if answer == 'ok' then
        Fetcher.runInteractive(context, FETCH_TITLE, catalog, 'everything')
    elseif answer == 'other' then
        local url = (ServerInfo.baseUrl(settings.serverUrl) or settings.serverUrl) .. '/'
        local ok, err = LrTasks.pcall(LrHttp.openUrlInBrowser, url)
        if not ok then
            Log.warn('status: openUrlInBrowser failed: %s', tostring(err))
            LrDialogs.message(TITLE, 'The browser could not be opened (' .. tostring(err) .. '). The dashboard is at '
                .. url, 'warning')
        end
    end
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext('LRRemotePreviews.status', function(context)
        local ok, err = LrTasks.pcall(run, context)
        if not ok then
            Log.error('status: unexpected error: %s', tostring(err))
            LrDialogs.message(TITLE, 'Unexpected error: ' .. tostring(err) .. '\n\n' .. Pipeline.LOG_HINT, 'critical')
        end
    end)
end)
