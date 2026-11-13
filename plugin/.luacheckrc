-- luacheck configuration for the Lightroom plug-in and its tests.
-- luacheck reads .luacheckrc from the current directory or its parents only, so from the repository root run
--   luacheck --config plugin/.luacheckrc plugin
-- or, from this folder, just: luacheck .
-- With --config the paths below are taken relative to the current directory, without it relative to this
-- folder; the globs start with "**/" so they match either way.

std = "lua51"
max_line_length = 120

-- Globals Lightroom gives plug-in scripts.
read_globals = {
    "import",   -- loads an SDK namespace: import 'LrTasks'
    "LOC",      -- localisation: LOC '$$$/Key=Default text'
    "_PLUGIN",  -- the running plug-in (path, id, ...)
    "WIN_ENV",  -- true on Windows
    "MAC_ENV",  -- true on macOS
}

exclude_files = {
    "**/LRRemotePreviews.lrplugin/Json.lua",  -- rxi/json.lua, vendored unmodified (see THIRD-PARTY.md)
}

files["**/spec/**/*_spec.lua"] = { std = "+busted" }
