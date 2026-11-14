-- LrDisablePlugin: runs when the plug-in is disabled in the Plug-in Manager. Stops the automatic fetch (it ends
-- within about a second, or after the file it is placing).
local Log = require 'Log'

-- Plain pcall: this script runs outside a task and nothing in it waits.
local ok, err = pcall(function()
    require('AutoFetch').stop('plug-in disabled', true)
end)
if not ok then
    Log.error('automatic fetch: could not ask it to stop: %s', tostring(err))
end
