-- LR Remote Previews: asks a server that sits next to the photo originals to build smart previews.
-- Install: File > Plug-in Manager > Add, pick this folder. Commands: Library > Plug-in Extras; the server status, the
-- check and the diagnostics: Help > Plug-in Extras.
--
-- Every module sits at the top level of this folder on purpose: Lightroom's require() takes a script name, not
-- a path. The plug-in sandbox of Lightroom Classic 15.6 has the error "require: invalid characters in script
-- name" for names containing '/', '\' or ':' (seen in its code, not tried). Top-level modules do load by bare
-- name there (tried).
--
-- The init, enable, disable and shutdown scripts start and stop the automatic fetch (AutoFetch.lua).
-- LrForceInitPlugin asks Lightroom to load the plug-in at start-up rather than when it is first used, so that the
-- automatic fetch runs without a menu command first. None of the four scripts nor LrForceInitPlugin has been tried
-- in Lightroom yet.
return {
    LrSdkVersion = 10.0,
    LrSdkMinimumVersion = 6.0,
    LrToolkitIdentifier = 'org.lrremotepreviews.plugin',
    LrPluginName = 'LR Remote Previews',
    LrPluginInfoProvider = 'PluginInfoProvider.lua',
    LrInitPlugin = 'InitPlugin.lua',
    LrForceInitPlugin = true,
    LrEnablePlugin = 'EnablePlugin.lua',
    LrDisablePlugin = 'DisablePlugin.lua',
    LrShutdownPlugin = 'ShutdownPlugin.lua',
    -- Every title starts with 'LRRP: ' so that the items can be told apart when several plug-ins add theirs.
    LrLibraryMenuItems = {
        { title = 'LRRP: Import a folder without the dialog...', file = 'ImportFolder.lua' },
        { title = 'LRRP: Build smart previews on the server', file = 'BuildSmartPreviews.lua' },
        { title = 'LRRP: Fetch ready smart previews', file = 'FetchSmartPreviews.lua' },
    },
    -- Help > Plug-in Extras: the status, the check and the diagnostics, out of the way of the three commands above.
    -- Lightroom Classic 15.6 reads LrExportMenuItems, LrLibraryMenuItems and LrHelpMenuItems in one place, with the
    -- same entry fields (title, file, enabledWhen); seen in its code, not tried.
    LrHelpMenuItems = {
        { title = 'LRRP: Server status...', file = 'ServerStatus.lua' },
        { title = 'LRRP: Check the server against Lightroom', file = 'CheckServer.lua' },
        { title = 'LRRP: Diagnostics: smart preview report (all photos)', file = 'DiagnosticsReport.lua' },
        { title = 'LRRP: Diagnostics: try buildSmartPreview on selected photos', file = 'DiagnosticsTryBuild.lua' },
        { title = 'LRRP: Diagnostics: new photos for the automatic send', file = 'DiagnosticsNewPhotos.lua' },
    },
    VERSION = { major = 0, minor = 8, revision = 0, build = 0 },
}
