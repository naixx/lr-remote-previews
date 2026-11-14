-- LrShutdownPlugin: runs when the plug-in is unloaded (reloaded in the Plug-in Manager, or Lightroom quits). Asks
-- the automatic fetch to stop; it ends within about a second, or after the file it is placing.
local Log = require 'Log'

-- Plain pcall: this script runs outside a task and nothing in it waits.
local ok, err = pcall(function()
    require('AutoFetch').stop('plug-in unloaded', false)
end)
if not ok then
    Log.error('automatic fetch: could not ask it to stop: %s', tostring(err))
end
