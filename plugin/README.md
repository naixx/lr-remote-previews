# LR Remote Previews: Lightroom Classic plug-in

The plug-in asks an LR Remote Previews server, which runs next to the photo originals (for example on a NAS), to
build smart previews, and brings them into the catalog. This is **stage 1** of [the plan](../docs/plan.md): the
command **Build smart previews on the server** for the selected photos, the settings, a server check, and two
diagnostic commands.

Status: **version 0.2.0 has not been run in Lightroom.** Version 0.1.0 (settings, server status, the report) was
tried in Lightroom Classic 15.6 on Windows (see the table at the end). The new command is checked only by the unit
tests and by runs with stand-in Lightroom functions against a fake server (no Lightroom involved); its sqlite3
command lines were also run for real through `cmd.exe` on Windows.

## Install

1. Get the plug-in folder `LRRemotePreviews.lrplugin`: unzip `LRRemotePreviews-<version>.zip`, or use
   `plugin/LRRemotePreviews.lrplugin` from a clone of this repository.
2. In Lightroom Classic: **File > Plug-in Manager > Add**, pick the `LRRemotePreviews.lrplugin` folder.
3. Select **LR Remote Previews** in the Plug-in Manager's list and fill in the settings.
4. Make sure a `sqlite3` command-line tool is available (next section) and press **Check sqlite3**.

## The sqlite3 tool

A new smart preview is named after the file's UUID in the catalog (`AgLibraryFile.id_global`), which the SDK does not
give ([decision record 0002](../docs/adr/0002-read-the-catalog-read-only.md)). The plug-in reads it with the public
domain `sqlite3` command-line tool from [sqlite.org](https://sqlite.org/download.html). It is not part of this
repository, and the plug-in never downloads it.

The plug-in looks for the tool in this order:

1. the path set in the plug-in's settings (when set, only this one is tried);
2. `sqlite3.exe` (Windows) or `sqlite3` (macOS) in the plug-in folder, next to `Info.lua`;
3. `sqlite3` on the PATH (macOS ships one in `/usr/bin`).

On Windows, the `sqlite3.exe` from sqlite.org's "sqlite-tools" archive for Windows is the one meant. How the tool is
used:

- It is started through the shell (`LrTasks.execute`) with the options `-readonly -batch -bail` and a small script on
  standard input: `.open --readonly "<catalog>"`, a 5-second busy timeout, and one `SELECT` of `id_local`,
  `id_global`, `baseName` and `extension` for the selected photos (`Adobe_images` joined to `AgLibraryFile`), at most
  500 photos per run. Nothing else is ever passed, and nothing writes.
- The catalog path goes into the script, not onto the command line, because some Windows builds of sqlite3 read their
  arguments in the ANSI code page and then cannot open a path with other characters (seen with 3.50.6 from Android's
  platform-tools: a catalog under a folder with Cyrillic letters failed on the command line and worked through the
  script).
- The output goes to temporary files in the system's temporary folder, which are deleted afterwards.
- A sqlite3 too old to know `.open --readonly` is expected to stop with its own error, so that nothing is read (not
  tried with such a version).

The `SELECT` and the read-only open were run against a scratch database with the same two tables, held open in WAL
mode with a pending write (as Lightroom keeps its catalog); a write through the same command line was refused with
"attempt to write a readonly database". They have **not** been run against a real Lightroom catalog by this plug-in.
The match between the SDK's `photo.localIdentifier` and `Adobe_images.id_local` is **not verified**; the plug-in
therefore checks that the base name and extension it reads equal the photo's file name, and skips the photo otherwise.

## Settings

The plug-in's section in the Plug-in Manager. The values are stored in Lightroom's preferences for this plug-in
(`LrPrefs`) when the Plug-in Manager is closed or another plug-in is selected.

| Setting | Example | Meaning |
|---|---|---|
| Server URL | `http://nas.local:8787` | Base address of the server. A path is allowed, for a server behind a reverse proxy |
| Access token | | Sent as `Authorization: Bearer <token>`. Leave empty when the server runs without a token. It is stored in plain text in Lightroom's preferences |
| Path mappings 1–3: local prefix | `Z:\` | A folder on this computer that holds originals the server can read |
| Path mappings 1–3: server root id | `archive` | The id of that folder on the server (the server's status lists its roots) |
| sqlite3 tool | `C:\Tools\sqlite3.exe` | Optional; see above |

Version 0.1.0 had a single mapping; its values appear as mapping 1, and mapping 1 is also saved under the old keys,
so going back to 0.1.0 keeps it.

**Test connection** asks the server for `GET /api/v1/info`, shows the answer in a dialog and a one-line result next
to the button, with the state of the root of every mapping, and names mapping rows that are half filled in.
**Check sqlite3** looks for the tool as described above, runs `sqlite3 -version` and shows the version and where the
tool was found.

Path mapping rules (`PathMap.lua`): the longest matching prefix wins; a prefix matches whole folder names only
(`Z:\Photos` does not cover `Z:\Photos2`); Windows paths (drive letter or UNC, for example `\\server\share\`) accept
both slash kinds and compare without regard to case (ASCII letters only); other paths compare case-sensitively; paths
with `.` or `..` segments are refused. The server gets the root id and the path relative to the root with forward
slashes, never a local path ([protocol](../docs/protocol.md#paths)).

## Commands

All under **Library > Plug-in Extras**.

### Build smart previews on the server

For the selected photos, in one progress bar that can be cancelled:

1. Asks the server for `GET /api/v1/info` and stops with a message when it cannot be used: another API version, no
   Adobe DNG Converter installed, no accepted file types, no path mapping, or no mapped root available.
2. Leaves out, and counts per reason: videos; photos without a file path; photos that already have a smart preview
   (Lightroom's `smartPreviewInfo`); files whose extension the server does not accept; files under no local prefix;
   files whose server root is missing or not available; a second photo of the same file (virtual copies: the
   original is preferred).
3. Reads the file UUIDs from the catalog with sqlite3 (see above). Photos whose id is not found, or for which the
   catalog database names a different file, are left out.
4. Asks for confirmation ("N photos of the M selected will be sent", with the reasons for the others), then creates
   one job (`POST /api/v1/jobs`). Each item's `ref` is the plug-in's own running number. More photos than the
   server's `maxItemsPerJob` are refused with a message.
5. Polls `GET /api/v1/jobs/{id}/items?since=<largest seq seen>` about once a second, waiting up to 5 seconds when
   nothing changes. For every item that becomes `ready` it downloads the DNG and:
   - checks the length against `result.size`;
   - reads `DNGVersion`, `OriginalRawFileName` and `OriginalDefaultFinalSize` from the file itself and requires the
     original file name to equal the photo's file name (ignoring case) and, when both the file and Lightroom give a
     pixel size, the two sizes to match in either orientation;
   - writes it as `<UUID>.dng.lrrp-<time>-<ref>.tmp` in the destination folder and renames it to `<UUID>.dng`;
   - never replaces a file that is already there;
   - calls `photo:buildSmartPreview()`, which answers `existed` when Lightroom has taken the file.
6. **Cancel** stops polling and sends `DELETE /api/v1/jobs/{id}`; files already placed stay.
7. Shows a summary: placed (and how many Lightroom did not answer `existed` for), already there, discarded by the
   check, download or write failures, the server's `failed` and `rejected` items with their error codes, not finished,
   and the reasons for photos that were not sent. The log has one line per photo.

The pixel size the plug-in compares is Lightroom's `dimensions` metadata. Whether that is the same size the DNG
records as `OriginalDefaultFinalSize` for every camera is **not verified**; when Lightroom gives no size, the photo
is placed after the name check and the log line says "original size not checked". The SHA-256 is not checked: the
SDK has no SHA-256 and Lightroom's Lua has no bit operations; the length and the content checks are made instead.

When polling fails ten times in a row, the token is rejected, or the server no longer knows the job, the command stops
and leaves the job on the server; what the server builds stays in its cache, so running the command again fetches those files quickly.

### Other commands

- **Server status...** asks the server for `GET /api/v1/info` and shows its name and version, the protocol version,
  whether it needs a token, whether Adobe DNG Converter is installed there, its roots, and the state of the root of
  each path mapping. A server URL that is not set or malformed, a server that cannot be reached, a rejected token
  (401) and an answer that is not the expected JSON each get their own message.
- **Diagnostics: smart preview report (all photos)** writes a tab-separated file `smart-preview-report-<time>.txt`
  next to the catalog: for every photo the file name, the SDK's `uuid` (the image id, which is *not* the file UUID
  that names a smart preview), the smart preview size and its path as Lightroom reports them. It changes nothing.
- **Diagnostics: try buildSmartPreview on selected photos** calls `photo:buildSmartPreview()` on 1 to 20 selected
  photos and writes `smart-preview-trybuild-<time>.txt` next to the catalog with the result (`created`, `existed` or
  `failed`) and the smart preview before and after. It does what **Library > Previews > Build Smart Previews** does
  for those photos, so try it on a test catalog.

The plug-in logs to `LRRemotePreviews.log` in Lightroom's log folder. With Lightroom Classic 15.6 on Windows that is
`%LOCALAPPDATA%\Adobe\Lightroom\Logs\LrClassicLogs`; older versions used an `LrClassicLogs` folder in your Documents
folder. The access token is never logged.

## Safety rules

From [decision record 0005](../docs/adr/0005-nothing-of-the-users-is-put-at-risk.md) and the last section of the
[protocol](../docs/protocol.md):

- The catalog is only read, with sqlite3 in read-only mode; nothing writes to it. Lightroom registers a placed file
  itself when `buildSmartPreview()` is called ([decision record 0001](../docs/adr/0001-register-by-placing-the-file.md)).
- A DNG is placed only after its length, its original file name and (when known) its original pixel size match the
  photo. A file that fails is discarded and reported; it is never written into the store.
- Files are written under a temporary name in the destination folder and renamed. An existing smart preview is never
  replaced. The check for an existing file happens right before writing and again right before the rename; a file
  that Lightroom itself creates in the moment between that check and the rename is not detected.

## Layout

All modules sit at the top level of `LRRemotePreviews.lrplugin/`, because Lightroom's `require` takes a script name,
not a path: the plug-in sandbox of Lightroom Classic 15.6 contains the error "require: invalid characters in script
name" for names with `/`, `\` or `:` (seen in its code, not tried). Top-level modules do load by bare name there
(tried). The pure modules say so in their header and have no `import` of Lightroom namespaces, so they run under plain
Lua 5.1:

| Module | Pure | Purpose |
|---|---|---|
| `PathMap.lua` | yes | Local path → `{rootId, relativePath}`; one key per file for spotting virtual copies |
| `SmartPreviewPath.lua` | yes | Catalog path + file UUID → smart preview store folder and DNG path |
| `ServerInfo.lua` | yes | Info request URL and headers, checking the answer, the status text |
| `Settings.lua` | yes | Reading and writing the settings in a key-value store, the path mappings |
| `Selection.lua` | yes | Whether the server can be used; which selected photos are sent and why the others are not |
| `SqliteCommand.lua` | yes | The `SELECT`, the read-only script, the command lines for `cmd.exe` and POSIX shells, parsing the output |
| `HttpJson.lua` | yes | JSON request headers, turning an HTTP answer into a decoded body or a problem |
| `Jobs.lua` | yes | Job and item URLs, the job request, checking job and item objects |
| `JobTracker.lua` | yes | Item states as they arrive; the largest `seq` seen |
| `JobRunner.lua` | yes | The polling loop with back-off and cancel, with Lightroom and the network passed in |
| `DngReader.lua` | yes | `DNGVersion`, `OriginalRawFileName`, `OriginalDefaultFinalSize` from a DNG's first IFD, both byte orders |
| `Delivery.lua` | yes | Checking a downloaded DNG, placing it (temporary name, rename, no overwrite), `buildSmartPreview()` |
| `RunSummary.lua` | yes | Counts per outcome and reason, the confirmation and summary texts, the per-photo log lines |
| `Json.lua` | yes | JSON, [rxi/json.lua](https://github.com/rxi/json.lua) unmodified (see [THIRD-PARTY.md](THIRD-PARTY.md)) |
| `Log.lua` | no | `LrLogger` wrapper |
| `ServerClient.lua` | no | `LrHttp` calls to the server |
| `SqliteRunner.lua` | no | Finding and running sqlite3 with `LrTasks.execute` |
| `PluginInfoProvider.lua` | no | The Plug-in Manager section |
| `BuildSmartPreviews.lua`, `ServerStatus.lua`, `Diagnostics*.lua` | no | The menu commands |

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
modules relative to their own location, so `busted spec` from inside `plugin/` works too. `spec/TestDng.lua` builds
the synthetic TIFF/DNG files the specs read; it is a helper, not a spec.

Nothing in CI can run Lightroom. A change that touches the SDK has to be tried by hand on a **test catalog**; say in the
pull request on which Lightroom version and platform.

## Not in this version

- Sending and fetching later, with Lightroom closed in between (stage 2 of the plan).
- More photos than the server takes in one job (`maxItemsPerJob`) in one run.
- Checking the SHA-256 of a download.

## What has been tried in Lightroom

Lightroom Classic 15.6 on Windows, 2026-11-14, version 0.1.0 of the plug-in:

| What | Result |
|---|---|
| Adding the plug-in in the Plug-in Manager; the settings section; saving the settings | works |
| «Test connection» against a server with a token | works |
| «Server status...» | works |
| «Diagnostics: smart preview report (all photos)» | works |
| «Diagnostics: try buildSmartPreview on selected photos» | not tried in this plug-in (the same code ran in the earlier probe plug-in) |
| A wrong token, an unreachable server, a server without a token | not tried |
| macOS, other Lightroom versions | not tried |

Version 0.2.0:

| What | Result |
|---|---|
| The settings section with three mappings, the sqlite3 path and «Check sqlite3»; 0.1.0 settings appearing as mapping 1 | not tried |
| «Build smart previews on the server»: reading the selection's metadata, the progress bar and its cancel button | not tried |
| Finding and running sqlite3 with `LrTasks.execute` (the command line was run through `cmd.exe` outside Lightroom) | not tried |
| `photo.localIdentifier` equal to `Adobe_images.id_local` | not tried |
| Lightroom's `dimensions` equal to the DNG's `OriginalDefaultFinalSize` | not tried |
| `LrHttp.post` for creating the job and, with method `DELETE`, for cancelling it; downloading a DNG with `LrHttp.get` | not tried |
| Writing, renaming and registering a delivered DNG (`io.open`, `LrFileUtils.move`, `buildSmartPreview()`) | not tried |
| A catalog or temporary folder whose path has non-ASCII characters | not tried |
