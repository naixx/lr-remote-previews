-- Library > Plug-in Extras > Fetch ready smart previews.
--
-- Asks which photos (the selected ones, or everything this catalog sent; the latter when nothing is selected), then
-- brings in what the server has finished: checked, written under a temporary name and renamed, never over an existing
-- file, registered with photo:buildSmartPreview(). The work is Fetcher's; this file asks for the scope. It also lets
-- the automatic fetch go on when a cancel of its progress bar paused it.
local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'

local FastFetch = require 'FastFetch'
local Fetcher = require 'Fetcher'
local Log = require 'Log'
local PhotoAccess = require 'PhotoAccess'
local Pipeline = require 'Pipeline'
local Settings = require 'Settings'

local TITLE = 'Fetch ready smart previews'
local EVERYTHING = 'Everything this catalog sent'
local SCOPES = 'Selected photos: asks the server about these photos, whoever sent them, and fetches what is ready.\n'
    .. 'Everything this catalog sent: goes through the jobs this catalog sent to the server and fetches what is '
    .. 'ready.\n\nPhotos that already have a smart preview are left alone.'

local function run(context)
    local catalog = LrApplication.activeCatalog()
    local settings = Settings.read(LrPrefs.prefsForPlugin())
    if settings.serverUrl == '' then
        LrDialogs.message(TITLE, 'No server is configured yet. Enter its URL in '
            .. 'File > Plug-in Manager > LR Remote Previews.', 'info')
        return
    end
    local photos, selected = PhotoAccess.selection(catalog)
    local scope
    if selected then
        local answer = LrDialogs.confirm(TITLE .. ': which photos?', SCOPES,
            string.format('Selected photos (%d)', #photos), 'Cancel', EVERYTHING)
        scope = (answer == 'ok' and 'selection') or (answer == 'other' and 'everything') or nil
    else
        local answer = LrDialogs.confirm(TITLE, 'No photos are selected.\n\n' .. SCOPES, EVERYTHING, 'Cancel')
        scope = answer == 'ok' and 'everything' or nil
    end
    if not scope then
        Log.info('fetch: not confirmed')
        return
    end
    Log.info('fetch: scope %s', scope)
    FastFetch.resume(LrPrefs.prefsForPlugin()) -- the automatic fetch goes on, if a cancel of its progress bar paused it
    Fetcher.runInteractive(context, TITLE, catalog, scope, photos)
end

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext('LRRemotePreviews.fetch', function(context)
        local ok, err = LrTasks.pcall(run, context)
        if not ok then
            Log.error('fetch: unexpected error: %s', tostring(err))
            LrDialogs.message(TITLE, 'Unexpected error: ' .. tostring(err) .. '\n\n' .. Pipeline.LOG_HINT, 'critical')
        end
    end)
end)
