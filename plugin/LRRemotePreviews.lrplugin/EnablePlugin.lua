-- LrEnablePlugin: runs when the plug-in is enabled in the Plug-in Manager. Starts the automatic fetch when the
-- setting is on (if Lightroom also runs InitPlugin.lua, the second start ends the first loop; see AutoFetch).
local Log = require 'Log'

-- Plain pcall: this script runs outside a task and nothing in it waits.
local ok, err = pcall(function()
    require('AutoFetch').startIfEnabled('plug-in enabled')
end)
if not ok then
    Log.error('automatic fetch: could not start: %s', tostring(err))
end
