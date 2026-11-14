-- The automatic fetch: a background task that, while Lightroom runs and the setting is on (the default since 0.7.0),
-- fetches what the server has finished for this catalog's jobs, quietly (no dialogs, no progress bar; a line in the
-- log, a short notice when it placed something; errors go to the log only). It contacts the server only while this
-- catalog has a pending job (PendingJobs: sent, not yet all delivered or final, not older than 7 days); with nothing
-- pending it makes no request at all, so an idle Lightroom never wakes a sleeping NAS. After a failed contact it
-- waits 1, 2, 5, 10, 30, then 60 minutes before the next one. The loop itself is AutoFetchLoop (pure, tested); this
-- file connects it to the SDK.
--
-- Since version 0.8.0 the jobs whose refs are catalog ids are fetched by FastFetch (a waiting request per job, files
-- placed without calls into the catalog, registration after the import); the others, sent by older versions, still by
-- fetchOnce below at the interval of the settings (not while an import is in progress).
--
-- Started by InitPlugin.lua (when the plug-in loads), EnablePlugin.lua, and the Plug-in Manager when the setting is
-- switched on; it only starts a task when the setting is on, and the loop ends by itself when it is switched off.
-- Stopped by ShutdownPlugin.lua and DisablePlugin.lua. Two things stop a running loop:
--   * AutoFetch.stopRequested, a flag in this module (seen by the loop when the scripts of the plug-in share
--     their modules, which this version assumes but which is not verified);
--   * the run token in the plug-in's preferences (prefs.autoFetchRun): every start writes a new one and the loop
--     ends as soon as the stored token is not its own. So a reloaded plug-in stops the old loop, and two starts
--     never leave two loops running.
-- Placing takes the fetch lock (Pipeline.withLease, Pipeline.acquireLease), so it never runs together with a manual
-- fetch; when the lock is taken, placing waits for a later step.
--
-- Since version 0.4.0 the same loop has a second duty, the automatic send (AutoSend.lua, its own setting, off by
-- default): when it is on, it looks for new photos (every few seconds while an import comes in: WatchMode) and sends
-- them at once. The loop runs while either setting is on. Since 0.8.0 the send no longer takes the fetch lock (nothing
-- else sends what it sends), so a long manual fetch does not hold it up.
local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'

local AutoFetchLoop = require 'AutoFetchLoop'
local AutoSend = require 'AutoSend'
local FastFetch = require 'FastFetch'
local Fetcher = require 'Fetcher'
local Log = require 'Log'
local PendingJobs = require 'PendingJobs'
local Pipeline = require 'Pipeline'
local ServerClient = require 'ServerClient'
local Settings = require 'Settings'

local AutoFetch = {
    stopRequested = false,
    token = nil, -- the run token of the loop this module started last
    running = false,
}

AutoFetch.RUN_KEY = 'autoFetchRun'
AutoFetch.LABEL = 'the automatic fetch'
AutoFetch.TRIGGER_KEY = 'importTriggered' -- os.time() when «Import a folder without the dialog...» last started one

local function prefs()
    return LrPrefs.prefsForPlugin()
end

-- True when Lightroom reports the plug-in as disabled (read defensively: an error counts as "not disabled").
local function pluginDisabled()
    local ok, enabled = LrTasks.pcall(function()
        return _PLUGIN.enabled
    end)
    return ok and enabled == false
end

-- The short notice when the automatic fetch placed smart previews (protected: it is only a notice).
local function notice(placed)
    LrTasks.pcall(function()
        LrDialogs.showBezel(string.format('%d smart preview%s arrived from the server', placed,
            placed == 1 and '' or 's'), 3)
    end)
end

-- One quiet fetch of everything this catalog sent, only while this catalog has a pending job (PendingJobs) and is
-- not backing off after a failed contact; otherwise no request at all. Returns a short text for the log (the loop
-- logs the same text only once in a row).
function AutoFetch.fetchOnce(shouldStop)
    local store = prefs()
    local settings = Settings.read(store)
    if settings.serverUrl == '' then
        return 'no server URL is set; nothing done'
    end
    local catalog = LrApplication.activeCatalog()
    local catalogPath = catalog:getPath()
    local decision, retryAt = PendingJobs.decide(store, catalogPath, os.time())
    if decision == 'idle' then
        return 'nothing pending for this catalog; the server is not asked'
    elseif decision == 'wait' then
        return string.format('the server did not answer; next try at %s', os.date('%H:%M', retryAt))
    end
    local started, outcome = Pipeline.withLease(AutoFetch.LABEL, function(lease)
        local ui = Pipeline.quietUi(function()
            return shouldStop() or not lease.refresh()
        end)
        local result = Fetcher.everything(settings, function()
            return ServerClient.fetchInfo(settings)
        end, catalog, ui, true)
        if result.problem then
            local nextTry = PendingJobs.contacted(store, catalogPath, false, os.time())
            return string.format('not done: %s (next try at %s)', result.problem, os.date('%H:%M', nextTry))
        end
        PendingJobs.contacted(store, catalogPath, true, os.time())
        local placed = result.summary:placed()
        if placed > 0 then
            notice(placed)
        end
        local text = result.nothingNew and 'nothing new to fetch' or result.summary:shortText()
        if result.cancelled then
            text = text .. ' (stopped before the end; the next fetch continues)'
        end
        local pending = result.pending or 0
        return text .. (pending > 0 and string.format('; %d job(s) still pending', pending)
            or '; nothing pending any more')
    end)
    if not started then
        return 'skipped: another fetch holds the lock'
    end
    return outcome
end

-- One step of the automatic fetch: FastFetch for the jobs with catalog ids as refs; when the slow interval has passed
-- and no import is in progress, fetchOnce for jobs sent by older versions (only when there are such).
local function fetchStep(importing, sweepDue, shouldStop)
    local text, nextStep = FastFetch.step(importing, shouldStop)
    if sweepDue and not importing then
        local catalogPath = LrApplication.activeCatalog():getPath()
        for _, job in ipairs(PendingJobs.list(prefs(), catalogPath, os.time())) do
            if not job.byId then
                return AutoFetch.fetchOnce(shouldStop), nextStep
            end
        end
    end
    return text, nextStep
end

-- Starts the loop when the automatic fetch or the automatic send is on. reason: for the log.
function AutoFetch.startIfEnabled(reason)
    local upgraded = Settings.upgrade(prefs())
    if upgraded then
        Log.info('%s', upgraded)
    end
    local settings = Settings.read(prefs())
    if not settings.autoFetch and not settings.autoSend then
        Log.info('automatic fetch: off (%s)', reason)
        return false
    end
    local token = Pipeline.runTag()
    AutoFetch.token = token
    AutoFetch.stopRequested = false
    prefs()[AutoFetch.RUN_KEY] = token
    Log.info('automatic fetch: starting (%s), every %d s (fetch %s, send %s)', reason, settings.autoFetchInterval,
        settings.autoFetch and 'on' or 'off', settings.autoSend and 'on' or 'off')
    local function shouldStop()
        return (AutoFetch.stopRequested and AutoFetch.token == token) or prefs()[AutoFetch.RUN_KEY] ~= token
            or pluginDisabled()
    end
    LrTasks.startAsyncTask(function()
        AutoFetch.running = true
        local ok, err = LrTasks.pcall(AutoFetchLoop.run, {
            shouldStop = shouldStop,
            settings = function()
                local current = Settings.read(prefs())
                return current.autoFetch, current.autoFetchInterval, current.autoSend
            end,
            triggered = function()
                return tonumber(prefs()[AutoFetch.TRIGGER_KEY])
            end,
            fetch = function(importing, sweepDue)
                AutoFetch.heartbeat = os.time()
                local fetched, text, nextStep = LrTasks.pcall(fetchStep, importing, sweepDue, shouldStop)
                if not fetched then
                    return 'failed: ' .. tostring(text)
                end
                return text, nextStep
            end,
            send = function()
                AutoFetch.heartbeat = os.time()
                local sent, text, found, imports = LrTasks.pcall(AutoSend.sendOnce, shouldStop)
                if not sent then
                    return 'failed: ' .. tostring(text), 0, {}
                end
                return text, found, imports
            end,
            sleep = function(seconds)
                AutoFetch.heartbeat = os.time()
                LrTasks.sleep(seconds)
            end,
            now = os.time,
            log = function(...)
                Log.info(...)
            end,
        })
        FastFetch.stopAll()
        if AutoFetch.token == token then
            AutoFetch.running = false
        end
        if not ok then
            Log.error('automatic fetch: the loop stopped with an error: %s', tostring(err))
        end
    end, 'LR Remote Previews automatic fetch')
    -- The watchdog of this loop: when the loop has taken no step for AutoFetchLoop.STALL_SECONDS (a call that never
    -- comes back, such as an LrTasks.execute of sqlite3 that Lightroom does not run), it starts a new loop. The old
    -- one, should it ever come back, sees that its run token is no longer the stored one and ends without doing
    -- anything.
    AutoFetch.heartbeat = os.time()
    LrTasks.startAsyncTask(function()
        while AutoFetch.token == token and prefs()[AutoFetch.RUN_KEY] == token and not AutoFetch.stopRequested do
            LrTasks.sleep(30)
            if AutoFetch.running and AutoFetch.token == token and prefs()[AutoFetch.RUN_KEY] == token
                and AutoFetchLoop.stalled(AutoFetch.heartbeat, os.time()) then
                Log.warn('automatic fetch: the loop has taken no step for %d minutes (a call into Lightroom, for '
                    .. 'example running sqlite3, did not come back); starting a new one',
                    math.floor(AutoFetchLoop.STALL_SECONDS / 60))
                AutoFetch.startIfEnabled('the old loop did not move')
                return
            end
        end
    end, 'LR Remote Previews watchdog')
    return true
end

-- Starts the loop when the setting is on and no loop of this module runs (the Plug-in Manager calls this after
-- saving the settings).
function AutoFetch.ensureRunning(reason)
    if AutoFetch.running and AutoFetch.token ~= nil and prefs()[AutoFetch.RUN_KEY] == AutoFetch.token then
        return false
    end
    return AutoFetch.startIfEnabled(reason)
end

-- Asks the loop to stop. always: also clear the stored run token when it is not this module's (disable).
function AutoFetch.stop(reason, always)
    AutoFetch.stopRequested = true
    local store = prefs()
    if always or (AutoFetch.token ~= nil and store[AutoFetch.RUN_KEY] == AutoFetch.token) then
        store[AutoFetch.RUN_KEY] = nil
    end
    Log.info('automatic fetch: stop requested (%s)', reason)
end

return AutoFetch
