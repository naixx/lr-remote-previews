# LR Remote Previews: Lightroom Classic plug-in

The plug-in asks an LR Remote Previews server, which runs next to the photo originals (for example on a NAS), to
build smart previews, and later brings them into the catalog. This is **stage 0**: the plug-in loads, keeps its
settings, checks the server, and carries two diagnostic commands. Building smart previews on the server comes in
stage 1 (see below and [the plan](../docs/plan.md)).

Status: the plug-in as a whole has **not yet been run in Lightroom**. The two diagnostic commands are taken over
unchanged in behaviour from a probe plug-in that was run in Lightroom Classic 15.6 on Windows. Everything else is
checked only by the unit tests and by a run with stand-in Lightroom functions (no Lightroom involved).

## Install

1. Get the plug-in folder `LRRemotePreviews.lrplugin`: unzip `LRRemotePreviews-<version>.zip`, or use
   `plugin/LRRemotePreviews.lrplugin` from a clone of this repository.
2. In Lightroom Classic: **File > Plug-in Manager > Add**, pick the `LRRemotePreviews.lrplugin` folder.
3. Select **LR Remote Previews** in the Plug-in Manager's list and fill in the settings.

## Settings

The plug-in's section in the Plug-in Manager. The values are stored in Lightroom's preferences for this plug-in
(`LrPrefs`) when the Plug-in Manager is closed or another plug-in is selected.

| Setting | Example | Meaning |
|---|---|---|
| Server URL | `http://nas.local:8787` | Base address of the server. A path is allowed, for a server behind a reverse proxy |
| Access token | | Sent as `Authorization: Bearer <token>`. Leave empty when the server runs without a token. It is stored in plain text in Lightroom's preferences |
| Local prefix | `Z:\` | A folder on this computer that holds originals the server can read |
| Server root id | `archive` | The id of that folder on the server (the server's status lists its roots) |

**Test connection** asks the server for `GET /api/v1/info`, shows the answer in a dialog and a one-line result next
to the button. It also says whether the server has a root with the configured id.

Path mapping rules (implemented in `PathMap.lua`, used from stage 1): the longest matching prefix wins; a prefix
matches whole folder names only (`Z:\Photos` does not cover `Z:\Photos2`); Windows paths (drive letter or UNC, for
example `\\server\share\`) accept both slash kinds and compare without regard to case (ASCII letters only); other paths
compare case-sensitively; paths with `.` or `..` segments are refused. The server gets the root id and the path
relative to the root with forward slashes, never a local path ([protocol](../docs/protocol.md#paths)).

## Commands

All under **Library > Plug-in Extras**.

- **Server status...** asks the server for `GET /api/v1/info` and shows its name and version, the protocol version,
  whether it needs a token, whether Adobe DNG Converter is installed there, and its roots. A server URL that is not
  set or malformed, a server that cannot be reached, a rejected token (401) and an answer that is not the expected
  JSON each get their own message.
- **Diagnostics: smart preview report (all photos)** writes a tab-separated file `smart-preview-report-<time>.txt`
  next to the catalog: for every photo the file name, the SDK's `uuid` (the image id, which is *not* the file UUID
  that names a smart preview), the smart preview size and its path as Lightroom reports them. It changes nothing.
- **Diagnostics: try buildSmartPreview on selected photos** calls `photo:buildSmartPreview()` on 1 to 20 selected
  photos and writes `smart-preview-trybuild-<time>.txt` next to the catalog with the result (`created`, `existed` or
  `failed`) and the smart preview before and after. It does what **Library > Previews > Build Smart Previews** does
  for those photos, so try it on a test catalog.

The plug-in logs to `LRRemotePreviews.log` in Lightroom's log folder (in recent versions the `LrClassicLogs` folder in
your Documents folder). The access token is never logged.

## Layout

All modules sit at the top level of `LRRemotePreviews.lrplugin/`, because Lightroom's `require` takes a script name,
not a path: the plug-in sandbox of Lightroom Classic 15.6 contains the error "require: invalid characters in script
name" for names with `/`, `\` or `:` (seen in its code; not yet tried with a running plug-in). The pure modules say so
in their header and have no `import` of Lightroom namespaces, so they run under plain Lua 5.1:

| Module | Pure | Purpose |
|---|---|---|
| `PathMap.lua` | yes | Local path → `{rootId, relativePath}` |
| `SmartPreviewPath.lua` | yes | Catalog path + file UUID → smart preview store folder and DNG path |
| `ServerInfo.lua` | yes | Info request URL and headers, checking the answer, the status text |
| `Settings.lua` | yes | Reading and writing the settings in a key-value store |
| `Json.lua` | yes | JSON, [rxi/json.lua](https://github.com/rxi/json.lua) unmodified (see [THIRD-PARTY.md](THIRD-PARTY.md)) |
| `Log.lua` | no | `LrLogger` wrapper |
| `ServerClient.lua` | no | `LrHttp` call to the server |
| `PluginInfoProvider.lua` | no | The Plug-in Manager section |
| `ServerStatus.lua`, `Diagnostics*.lua` | no | The menu commands |

A smart preview lives at `<catalog folder>\<catalog name> Smart Previews.lrdata\<U[0]>\<U[0..3]>\<U>.dng`, where `U`
is the file UUID (`AgLibraryFile.id_global`), upper case with dashes (found with Lightroom Classic 15.6 on Windows,
see [the research](../docs/research/smart-previews.md)). For example, `C:\Photos\Main\Main.lrcat` and
`62823DFE-E7D3-40FF-938C-518FDECC6CF6` give
`C:\Photos\Main\Main Smart Previews.lrdata\6\6282\62823DFE-E7D3-40FF-938C-518FDECC6CF6.dng`.

## Tests and lint

Install the tools once with [LuaRocks](https://luarocks.org/) (for Lua 5.1 or LuaJIT, like Lightroom):

```sh
luarocks install busted
luarocks install luacheck
```

From the repository root:

```sh
busted plugin/spec                            # unit tests of the pure modules
luacheck --config plugin/.luacheckrc plugin   # lint
python tools/package_plugin.py                # builds dist/LRRemotePreviews-<version>.zip
```

luacheck looks for `.luacheckrc` only in the current folder and its parents, so from the repository root it needs
`--config plugin/.luacheckrc`; inside `plugin/` a plain `luacheck .` finds it. The spec files find the plug-in's
modules relative to their own location, so `busted spec` from inside `plugin/` works too.

Nothing in CI can run Lightroom. A change that touches the SDK has to be tried by hand on a **test catalog**; say in the
pull request on which Lightroom version and platform.

## Planned for stage 1

- The command **Build smart previews on the server** for the selected photos: keep raw photos that have no smart
  preview and whose path maps to a root, read their file UUIDs from the catalog with a `sqlite3` command-line helper
  (read-only), send the job, show progress, download each DNG, check it against the photo (original file name and
  pixel size), place it into the smart preview store under a temporary name and rename it (never over an existing
  file), call `buildSmartPreview()` so Lightroom registers it, and show a summary.
- More than one path mapping.
