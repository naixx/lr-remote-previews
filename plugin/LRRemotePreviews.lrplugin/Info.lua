-- LR Remote Previews: asks a server that sits next to the photo originals to build smart previews.
-- Install: File > Plug-in Manager > Add, pick this folder. Commands: Library > Plug-in Extras.
--
-- Every module sits at the top level of this folder on purpose: Lightroom's require() takes a script name, not
-- a path. The plug-in sandbox of Lightroom Classic 15.6 has the error "require: invalid characters in script
-- name" for names containing '/', '\' or ':' (seen in its code, not tried). Top-level modules do load by bare name there (tried).
return {
    LrSdkVersion = 10.0,
    LrSdkMinimumVersion = 6.0,
    LrToolkitIdentifier = 'org.lrremotepreviews.plugin',
    LrPluginName = 'LR Remote Previews',
    LrPluginInfoProvider = 'PluginInfoProvider.lua',
    LrLibraryMenuItems = {
        { title = 'Server status...', file = 'ServerStatus.lua' },
        { title = 'Diagnostics: smart preview report (all photos)', file = 'DiagnosticsReport.lua' },
        { title = 'Diagnostics: try buildSmartPreview on selected photos', file = 'DiagnosticsTryBuild.lua' },
    },
    VERSION = { major = 0, minor = 1, revision = 0, build = 0 },
}
