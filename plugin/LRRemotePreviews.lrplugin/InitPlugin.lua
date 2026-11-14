-- LrInitPlugin: runs when Lightroom loads the plug-in (Info.lua sets LrForceInitPlugin, so that is at start-up).
-- Starts the automatic fetch when the setting is on; otherwise it starts nothing.
local Log = require 'Log'

-- Plain pcall: this script runs outside a task and nothing in it waits.
local ok, err = pcall(function()
    require('AutoFetch').startIfEnabled('plug-in loaded')
end)
if not ok then
    Log.error('automatic fetch: could not start: %s', tostring(err))
end
