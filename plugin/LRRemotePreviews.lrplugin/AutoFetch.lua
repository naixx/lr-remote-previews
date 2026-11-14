-- The automatic fetch: a background task that, while Lightroom runs and the setting is on, fetches what the server
-- has finished for this catalog's jobs, quietly (no dialogs, no progress bar; a line in the log; errors go to the
-- log only). The loop itself is AutoFetchLoop (pure, tested); this file connects it to the SDK.
--
-- Started by InitPlugin.lua (when the plug-in loads), EnablePlugin.lua, and the Plug-in Manager when the setting is
-- switched on; it only starts a task when the setting is on, and the loop ends by itself when it is switched off.
-- Stopped by ShutdownPlugin.lua and DisablePlugin.lua. Two things stop a running loop:
--   * AutoFetch.stopRequested, a flag in this module (seen by the loop when the scripts of the plug-in share
--     their modules, which this version assumes but which is not verified);
--   * the run token in the plug-in's preferences (prefs.autoFetchRun): every start writes a new one and the loop
--     ends as soon as the stored token is not its own. So a reloaded plug-in stops the old loop, and two starts
--     never leave two loops running.
-- A fetch takes the fetch lock (Pipeline.withLease), so it never runs together with a manual fetch, the build
-- command, or another automatic fetch; when the lock is taken, the round is skipped.
local LrApplication = import 'LrApplication'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'

local AutoFetchLoop = require 'AutoFetchLoop'
local CatalogState = require 'CatalogState'
local Fetcher = require 'Fetcher'
local Log = require 'Log'
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

-- One quiet fetch of everything this catalog sent. Returns a short text for the log.
function AutoFetch.fetchOnce(shouldStop)
    local settings = Settings.read(prefs())
    if settings.serverUrl == '' then
        return 'no server URL is set; nothing done'
    end
    local catalog = LrApplication.activeCatalog()
    local catalogPath = catalog:getPath()
    if not CatalogState.clientId(prefs(), catalogPath) then
        return 'this catalog has not sent anything to the server yet; nothing done'
    end
    local started, outcome = Pipeline.withLease(AutoFetch.LABEL, function(lease)
        local ui = Pipeline.quietUi(function()
            return shouldStop() or not lease.refresh()
        end)
        local result = Fetcher.everything(settings, function()
            return ServerClient.fetchInfo(settings)
        end, catalog, ui, true)
        if result.problem then
            return 'not done: ' .. result.problem
        end
        if result.nothingNew then
            return 'nothing new to fetch'
        end
        local text = result.summary:shortText()
        if result.cancelled then
            text = text .. ' (stopped before the end; the next fetch continues)'
        end
        return text
    end)
    if not started then
        return 'skipped: another fetch holds the lock'
    end
    return outcome
end

-- Starts the loop when the setting is on. reason: for the log.
function AutoFetch.startIfEnabled(reason)
    local settings = Settings.read(prefs())
    if not settings.autoFetch then
        Log.info('automatic fetch: off (%s)', reason)
        return false
    end
    local token = Pipeline.runTag()
    AutoFetch.token = token
    AutoFetch.stopRequested = false
    prefs()[AutoFetch.RUN_KEY] = token
    Log.info('automatic fetch: starting (%s), every %d s', reason, settings.autoFetchInterval)
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
                return current.autoFetch, current.autoFetchInterval
            end,
            fetch = function()
                local fetched, text = LrTasks.pcall(AutoFetch.fetchOnce, shouldStop)
                if not fetched then
                    return 'failed: ' .. tostring(text)
                end
                return text
            end,
            sleep = function(seconds)
                LrTasks.sleep(seconds)
            end,
            now = os.time,
            log = function(...)
                Log.info(...)
            end,
        })
        if AutoFetch.token == token then
            AutoFetch.running = false
        end
        if not ok then
            Log.error('automatic fetch: the loop stopped with an error: %s', tostring(err))
        end
    end, 'LR Remote Previews automatic fetch')
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
