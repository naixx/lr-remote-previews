# LR Remote Previews: Lightroom Classic plug-in

The plug-in asks an LR Remote Previews server, which runs next to the photo originals (for example on a NAS), to
build smart previews, and brings them into the catalog. It covers **stage 2** of [the plan](../docs/plan.md)
(Lightroom does not have to stay open while the server works) and, since version 0.4.0, parts of stages 4 and 5.
Three commands send and fetch (**Send to the server**, **Fetch ready smart previews**, **Build smart previews on the
server**), an optional automatic fetch runs while Lightroom is open, **Server status...** shows this catalog's jobs and
can retry failed ones, **Check the server against Lightroom** compares the server's DNG with a smart preview Lightroom
built itself (stage 5), and an optional automatic send sends photos added to the catalog (stage 4). Since version
0.5.0, **Add a folder without previews...** adds the photos of a folder to the catalog without Lightroom's import
dialog and without asking Lightroom for any preview, and can send them to the server in the same go.

Status: **most of 0.3.0 and all of 0.4.0 and 0.5.0 have not been run in Lightroom.** Version 0.2.0 (the build
command) was run in Lightroom Classic 15.6 on Windows on 157 photos, and of 0.3.0 «Send to the server» and «Fetch
ready smart previews» for the selection on 143 photos whose originals lie on a NAS (see the tables at the end).
Everything else that is new in 0.3.0 to 0.5.0 is
checked only by the unit tests and by runs with stand-in Lightroom functions (cooperative tasks, a virtual clock)
against a fake server that follows the protocol, and the plug-in's server calls also against the real server without
a converter (no Lightroom involved in either).

## Install

1. Get the plug-in folder `LRRemotePreviews.lrplugin`. Nothing is published yet: add
   `plugin/LRRemotePreviews.lrplugin` from a checkout of this repository directly, or make
   `dist/LRRemotePreviews-<version>.zip` with `python tools/package_plugin.py` and unzip it.
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
  `id_global`, `baseName` and `extension` for the photos concerned (`Adobe_images` joined to `AgLibraryFile`), at most
  500 photos per run. Nothing else is ever passed, and nothing writes.
- The catalog path goes into the script, not onto the command line, because some Windows builds of sqlite3 read their
  arguments in the ANSI code page and then cannot open a path with other characters (seen with 3.50.6 from Android's
  platform-tools: a catalog under a folder with Cyrillic letters failed on the command line and worked through the
  script).
- The output goes to temporary files in the system's temporary folder, which are deleted afterwards.
- A sqlite3 too old to know `.open --readonly` is expected to stop with its own error, so that nothing is read (not
  tried with such a version).

With Lightroom Classic 15.6 on Windows the tool found on the PATH read the file UUIDs of 157 photos of a test catalog
that Lightroom had open, and every name it read matched its photo, so `photo.localIdentifier` equals
`Adobe_images.id_local` there. The plug-in still checks that the base name and extension it reads equal the photo's
file name, and leaves the photo out otherwise.

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
| Downloads at once | `4` | 1 to 8. How many smart previews are downloaded at the same time while fetching. They are still checked, written and registered one at a time. 1 downloads one file after the other in the command's own task, as version 0.2.0 did |
| Automatic fetch | off, every 1 minute | Fetch ready smart previews in the background while Lightroom runs (see below). Intervals from 30 seconds to 30 minutes |
| Automatic send | off | Send raw photos added to the catalog after it was switched on, at the same interval, in the same background task (see below) |

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
slashes, never a local path ([protocol](../docs/protocol.md#paths)). Fetching «everything this catalog sent» maps the
server's root id and relative path back with the same mappings (`PathMap.localPaths`): one candidate per mapping with
that root id, in the order of the mappings.

Besides the settings, the plug-in keeps four things per catalog in its preferences, keyed by the catalog's path: the
catalog's `clientId`, how far fetching got for each of the catalog's jobs, how far the automatic send got, and the
catalog ids of the photos **Add a folder without previews...** added and sent itself, which the automatic send leaves
out (all as JSON text). It also remembers the choices of **Add a folder without previews...** and the folder chosen
last. None of this is shown in the Plug-in Manager.

## Commands

All under **Library > Plug-in Extras**.

### Which command when

| Command | Use it when | Lightroom must stay open |
|---|---|---|
| **Send to the server** | You want smart previews for many photos and do not want to wait: send, close Lightroom, fetch later | No |
| **Fetch ready smart previews** | The server has finished (or partly finished) what was sent, from this catalog or from anywhere else | Only while it fetches |
| **Build smart previews on the server** | A smaller selection that you want right away: it sends, waits and fetches in one go, as version 0.2.0 did | Yes, until it is done |
| **Check the server against Lightroom** | After an update of Lightroom or of the server's Adobe DNG Converter: is the server's DNG still the file Lightroom builds? | Yes, until it is done |
| **Add a folder without previews...** | Photos on the NAS are not in the catalog yet: add them without the import dialog and without asking Lightroom for previews, and optionally send them to the server. Not yet run in Lightroom | Yes, while it adds and sends |

The first three leave out photos that already have a smart preview and never replace a file, so running one of them
again, or another one after it, is harmless. The check writes nothing at all. **Add a folder without previews...**
leaves files that are in the catalog already alone, so running it again on the same folder adds only what is new.

### The clientId

Every job the plug-in creates carries a `clientId`: a random text in the form of a UUID
(`c1f0a6e2-7d0b-4c55-9d0e-3f6a1b2c4d5e`) that the plug-in makes up the first time a catalog sends something and keeps
in its preferences, keyed by the catalog's path. It is not a Lightroom identifier and says nothing about the catalog;
it only lets the plug-in ask the server for "the jobs this catalog sent" later
([protocol](../docs/protocol.md#the-job-object)). It is made with a small random generator seeded from the time,
the processor clock, a counter, `math.random` and the catalog path (`ClientId.lua`), so two catalogs are very unlikely
to get the same one. A catalog that is moved or renamed gets a new `clientId`; its old jobs are then no longer found
by «everything this catalog sent», but fetching by selection still finds their files.

### Send to the server

For the selected photos (Lightroom's target photos: with nothing selected, that is every photo in the filmstrip; the
confirmation shows the count):

1. Asks the server for `GET /api/v1/info` and stops with a message when it cannot be used: another API version, no
   Adobe DNG Converter installed, no accepted file types, no path mapping, or no mapped root available.
2. Leaves out, and counts per reason: videos; photos without a file path; photos that already have a smart preview
   (Lightroom's `smartPreviewInfo`); files whose extension the server does not accept; files under no local prefix;
   files whose server root is missing or not available; a second photo of the same file (virtual copies: the
   original is preferred).
3. Reads the file UUIDs from the catalog with sqlite3 (see above), so that the same photos are left out as by the
   build command (not found in the catalog database, or the database names a different file).
4. Asks for confirmation, then creates one job per `maxItemsPerJob` photos (`POST /api/v1/jobs`), each with this
   catalog's `clientId`, and returns: a dialog says how many photos were sent, how many the server had built already,
   how many it refused (with the reasons), and that Lightroom may be closed. Nothing is downloaded or placed.

### Fetch ready smart previews

First a dialog asks which photos: **Selected photos** (the default when photos are selected) or **Everything this
catalog sent** (the only choice when nothing is selected). Then, in a progress bar that can be cancelled:

- **Selected photos.** The same checks as when sending (step 2 above), then `POST /api/v1/lookup` for those files, in
  chunks of at most 1000 (and at most `maxItemsPerJob`). A lookup never makes the server build. Files that are `ready`
  are delivered; the summary counts the others: still being built (`pending`), not on the server (`absent`: never
  sent, or sent before the original changed), refused (`rejected`, with the reasons). This finds files whoever asked
  for them: this catalog, another catalog, or the dashboard.
- **Everything this catalog sent.** Lists the server's jobs with this catalog's `clientId`
  (`GET /api/v1/jobs?clientId=…&limit=200`), reads the `ready` items of the jobs that may have something new
  (`GET /api/v1/jobs/{id}/items?since=…&state=ready`), maps each item's root and path back to a local path, finds the
  photo with `catalog:findPhotoByPath` (for Windows paths also without regard to case, then compares the photo's own
  path), applies the same checks as for a selection (so photos that already have a smart preview are left out), then
  looks the files up (`POST /api/v1/lookup`) and delivers what is `ready`. The lookup means a file is delivered as the
  server has it *now*: a file whose original changed after the job built it shows up as `absent`.

  The plug-in remembers per job how far it got: every ready item up to a `seq` that needs nothing more (placed,
  already there, discarded by the check, refused, no longer in the catalog...), and that a job was completely dealt
  with (no longer `active` and nothing left to fetch). Such a job is not read again while its `seq` stays the same; a
  retry of its failed items changes the `seq` and makes it read again. Jobs the server no longer lists (it deletes
  them `jobRetentionDays` after they finished) are forgotten. If a catalog ever has more than 200 jobs on the server,
  only the newest 200 are looked at.

Delivery is the same for both, and the same as in the build command: several downloads at once
(`GET /api/v1/files/{key}`; the setting "Downloads at once"), then, strictly one at a time and only in the command's
own task, the checks, writing and registering described under the build command below. A file the server no longer
has (`404 not_in_cache`) is counted as such and tried again by the next fetch.

Fetching is **resumable**: cancelled, interrupted by an error, or cut off by Lightroom closing, the next fetch simply
continues, because a photo that already has a smart preview is left out and nothing is ever overwritten. A cancelled
run remembers what it finished; a run that ended with an error remembers nothing, so the next one reads those items
again and leaves the placed ones alone.

### Build smart previews on the server

For the selected photos, in one progress bar that can be cancelled: steps 1 to 3 of **Send to the server**, the
confirmation, then one job (with the `clientId`; more photos than the server's `maxItemsPerJob` are refused with a
message, use **Send to the server** for those). Then:

1. Polls `GET /api/v1/jobs/{id}/items?since=<largest seq seen>` about once a second, waiting up to 5 seconds when
   nothing changes. Every item that becomes `ready` goes into the download queue (`GET /api/v1/items/{id}/file`,
   several at once), and between polls the command delivers what has arrived, one file at a time:
   - checks the length against `result.size`;
   - reads `DNGVersion`, `OriginalRawFileName` and `OriginalDefaultFinalSize` from the file itself and requires the
     original file name to equal the photo's file name (ignoring case) and, when both the file and Lightroom give a
     pixel size, the two sizes to match in either orientation;
   - writes it as `<UUID>.dng.lrrp-<run tag>-<ref>.tmp` in the destination folder and renames it to `<UUID>.dng`;
   - never replaces a file that is already there;
   - calls `photo:buildSmartPreview()`, which answers `existed` when Lightroom has taken the file.
2. **Cancel** stops polling and sends `DELETE /api/v1/jobs/{id}`; files already placed stay. Cancelling after the
   server finished stops only the fetching; **Fetch ready smart previews** brings the rest later.
3. Shows a summary: placed (and how many Lightroom did not answer `existed` for), already there, discarded by the
   check, download or write failures, the server's `failed` and `rejected` items with their error codes, not finished,
   and the reasons for photos that were not sent. The log has one line per photo.

While it waits, the command holds the fetch lock (below), so the automatic fetch does not deliver the same files.

The pixel size the plug-in compares is Lightroom's `dimensions` metadata; with Lightroom Classic 15.6 it matched the
DNG's `OriginalDefaultFinalSize` for all 157 photos of the test catalog; other cameras are not verified. When
Lightroom gives no size, the photo is placed after the name check and the log line says "original size not checked".
The SHA-256 is not checked: the SDK has no SHA-256 and Lightroom's Lua has no bit operations; the length and the
content checks are made instead.

When polling fails ten times in a row, the token is rejected, or the server no longer knows the job, the command stops
and leaves the job on the server; **Fetch ready smart previews** brings what it builds later.

### Server status...

Shows what the server says about itself (name and version, protocol version, whether it needs a token, whether Adobe
DNG Converter is installed there, its roots, the state of the root of each path mapping), then this catalog's jobs
that still matter (active ones, ones not fully fetched, ones with failed items; label, when it was sent, and the counts
ready / building / queued / failed), and how many smart previews are ready on the server and not fetched by this
catalog yet (an upper bound: some may have been placed in another way). The dialog has three actions:

- **Fetch now**: fetches everything this catalog sent, as the Fetch command does.
- **Retry** (shown when a job has failed items): picks a job and sends `POST /api/v1/jobs/{id}/retry`; the answer is
  shown under the button. The server checks each retried file again as it is now.
- **Open the dashboard**: opens the server URL in the browser.

A server URL that is not set or malformed, a server that cannot be reached, a rejected token (401) and an answer that
is not the expected JSON each get their own message.

### Check the server against Lightroom

The whole project rests on the server's DNG being the file Lightroom would build itself; that was shown by hand
([the research](../docs/research/smart-previews.md)). This command repeats the comparison for one photo, for example
after an update of Lightroom or of the converter on the server.

1. Select **one** raw photo that already has a smart preview **built by Lightroom itself** (select it and choose
   **Library > Previews > Build Smart Previews** first). A photo without a smart preview is refused with that advice;
   the command never builds, changes or deletes a smart preview, and never calls `buildSmartPreview()`.
2. It reads that smart preview file (`smartPreviewInfo.smartPreviewPath`), maps the photo's path to the server
   (`POST /api/v1/lookup`) and, when the server does not have the DNG, has it built by a one-item job labelled
   «Compatibility check» (without the catalog's `clientId`, so the fetch commands never look at it) and waits for it,
   in a progress bar that can be cancelled (a cancel also cancels the job). It downloads the server's DNG into memory
   only; nothing is written anywhere, and no fetch lock is taken because nothing is placed.
3. It compares the two files (`DngCompare.lua`). The raw image is the first SubIFD of IFD0. Compared: its
   NewSubFileType, width, height, bits per sample, compression, photometric interpretation, samples per pixel, planar
   configuration, tile size and number of tiles, then **every tile byte for byte**; and in IFD0 `DNGVersion`,
   `OriginalRawFileName` and `OriginalDefaultFinalSize`. Reported without counting against the result, because two
   programs are expected to write them differently: `Software`, `PreviewApplicationName` and `...Version`,
   `DateTime`, `PreviewDateTime`, the XMP packet (compared without the tool, dates, document ids and `crs:Version`),
   the small thumbnail in IFD0, `RawDataUniqueID` and `NewRawImageDigest`. Every other tag of IFD0 and of the raw
   image directory is compared too (file offsets and byte counts left out); one that differs is listed as not
   expected.
4. The verdict, in a dialog and in the log, with Lightroom's version (`LrApplication.versionString()`), the
   `Software` tag of each file and the server's version and converter version:
   - **identical image data**: all tiles byte-identical (an information dialog; a warning when another tag differs
     unexpectedly);
   - **N of M tiles identical**: same structure, some tiles differ (a warning: during development 6 of 7 photos were
     fully identical and one had 27 of 28 identical tiles);
   - **different structure**: another compression, size, tile layout or identity (an error).
   A file that cannot be read (for example a truncated download) is reported as not compared. When the catalog's
   smart preview names Adobe DNG Converter as its software, it was most likely delivered from the server, and the
   dialog says that the check then says nothing about Lightroom.

The plan's «refuse to deliver when the check fails» is not part of this version: the check is a command to run by
hand.

### Add a folder without previews...

New in 0.5.0, **not yet run in Lightroom.** It adds the photo files of one or more folders to the catalog without
Lightroom's import dialog and without asking Lightroom for any preview, so that the smart previews can be built on the
server instead. What Lightroom then does by itself when it shows such photos (thumbnails, previews, what it reads from
the NAS for them) has not been measured. It is Lightroom that changes its catalog here, through its own plug-in
interface and on the user's command, as its import does
([decision record 0007](../docs/adr/0007-photos-added-through-lightroom-on-the-users-command.md)); the command never
opens, changes, moves or deletes a file and writes nothing next to the originals.

1. A folder dialog (`LrDialogs.runOpenPanel`, folders only, several allowed) that opens in the folder holding the one
   chosen last. Then the options (`LrDialogs.presentModalDialog`): **Include sub-folders** (on by default); **Also add
   JPEG, TIFF, PNG, HEIC and PSD files** (off: camera raw files only); **Send the added photos to the server
   afterwards** (on by default, offered only when a server URL is set and a chosen folder lies under a path mapping;
   otherwise it is off and the dialog says why). The choices and the folder are remembered in the plug-in's
   preferences, apart from the Plug-in Manager's settings (`Settings.readAddFolder`).
2. When a server URL is set, `GET /api/v1/info`: the camera raw types are the extensions the server accepts. Without
   a server, or when it does not answer, a built-in list of the same 22 types (`FolderListing.RAW_EXTENSIONS`; a spec
   keeps it equal to `server/src/lrrp/converter.py`).
3. The listing (`FolderListing.lua`), with `LrFileUtils.files` and `LrFileUtils.directoryEntries`, which read folder
   listings only; no file is opened. Left out and counted: files whose name starts with a dot; files of other types;
   a JPEG (`.jpg`, `.jpeg`) next to a raw file of the same name in the same folder (the base name compared without
   regard to case), counted as paired with that raw file. That is because Lightroom's own import, with its default
   setting, treats such a JPEG as part of the raw photo and not as a photo of its own. Whether Lightroom records the
   JPEG with the raw photo when the raw file is added this way is not known. Folders not looked into (the chosen
   folders always are): names starting with a dot, Lightroom's data folders (`*.lrdata`: the previews and smart
   previews of a catalog, whose DNGs must never become photos), the NAS system folders `@eaDir`, `#recycle`,
   `#snapshot`, `@Recycle` and `@Recently-Snapshot`, and anything more than 32 levels deep. Overlapping folders are
   listed once; the files are sorted by folder, then by name.
4. Every file is looked up with `catalog:findPhotoByPath` (Windows paths also without regard to case,
   `PhotoAccess.findByPath`); files in the catalog already are left alone. A confirmation shows the counts.
5. The rest are added with `catalog:addPhoto(path)` (the path only: no stacking, no presets), 50 files per
   `catalog:withWriteAccessDo` with a timeout of 30 seconds (`PhotoAdder.lua`, decisions in `AddPlan.lua`). Cancel
   is honoured between writes. Each `addPhoto` runs through `LrTasks.pcall` inside the write, so a file Lightroom
   refuses (the SDK: it throws when the path does not exist or the format is not supported) is counted and logged with
   Lightroom's text, and the rest of the batch stays; whether a refusal counts as «not supported» or as another
   failure is told only by that text. A write that an error leaves anyway is rolled back by Lightroom (as the SDK
   says), and its files are tried again one write each, each looked up first. A write that does not run (`'aborted'`
   after its timeout, or refused before it starts) is tried again after 2 seconds, looking its files up first; after
   3 such tries in a row the run stops and says so. `'queued'` is not expected, because the writes are not
   asynchronous.
6. With «send afterwards», when the server said at the start that it can build (otherwise the confirmation and the
   summary say why not) and only when the adding finished: the added photos go through the same steps as **Send to
   the server** (`Pipeline.prepareSend`, `Pipeline.sendJobs`: the checks, the file UUIDs with sqlite3, one job per
   `maxItemsPerJob`), without its confirmation, labelled «Lightroom folder (added without previews)» with the
   catalog's `clientId`, so that **Fetch ready smart previews** or the automatic fetch brings their smart previews in.
   Photos that were in the catalog already are not sent. That sqlite3 sees the file records of photos added a moment
   before is assumed; a photo it does not find is left out as «not found in the catalog database» and can be sent
   later with **Send to the server**.
7. The summary: added; already in the catalog; not supported; failed (the first 5 with Lightroom's reason); not added
   because the run stopped; what the listing left out (paired JPEGs, other files, hidden files, folders not looked
   into); the times; what was sent (job numbers) or why nothing was; where the photos are (the Library's Folders panel)
   and how to take them out (select them, Photo > Remove Photos, «Remove from Lightroom»; nothing on disk is touched).

**Its log.** One line per file, for example `add folder: Z:\2026\IMG_0001.ARW: added (0.19 s)`,
`… IMG_0001.JPG: pairedJpeg (next to IMG_0001.ARW)`, `… notes.txt: notPhoto (.txt)`, `… alreadyInCatalog (…)`,
`… notSupported (<Lightroom's text>, 0.05 s)`, `… notAdded (…)`; one per folder not looked into; and the timings:
`add folder: listing: 3 folder(s) looked into, 812 file(s) found, 600 to look up in the catalog, 2.31 s`,
`add folder: catalog lookup: …`, one line per write
(`add folder: batch 3 of 12: 50 files: 50 added; 9.81 s in all, 9.50 s inside the write (0.190 s per file), 0.31 s
waiting for and finishing it`), the total (`add folder: adding: 500 files in 10 writes: …; 98.2 s, 0.196 s per file,
0.205 s per added photo`) and `add folder: sending: …`. The times come from `LrDate.currentTime()`; that it has
fractions of a second is assumed.

**With the automatic send on.** Photos added with «send afterwards» are sent by this command, and the automatic send
leaves them out, so none is sent twice. Right after each write the command records the new photos' catalog ids in the
plug-in's preferences (`AutoSendPlan.recordSent`); the automatic send takes a photo only in the round after the one
that first saw it (at least 30 seconds later) and skips recorded ids, which its log line counts as «added and sent by
«Add a folder without previews»». The ids are recorded only when the server answered at the start and can build
(`Selection.serverProblem`); otherwise the confirmation already says that nothing will be sent, and the automatic send
treats the photos like any other. A run that was cancelled or stopped, or a send that failed later, leaves recorded
photos unsent: send them with **Send to the server**. Photos added without «send afterwards» are new photos like any
other for the automatic send, which sends the raw ones when it is on. The record keeps only ids the automatic send
could still take (above its mark; without its state, those of the latest run).

**Paths.** Choose the folder by the same path the catalog uses for those photos (the same drive letter or network
path). A file reached by another spelling is not found by `findPhotoByPath`, and Lightroom would get a second photo
for the same file (not tried).

### Automatic fetch

Off by default. When it is switched on in the Plug-in Manager, a background task fetches everything this catalog sent
every interval (the first time about 20 seconds after it starts), **quietly**: no dialog, no progress bar; one line in
the log per result (the same result twice in a row is logged once), errors only in the log. A round with nothing new
costs one request (the job list); the server's info is asked for only when there is something to fetch.

- It starts when the plug-in loads (`LrInitPlugin`; `Info.lua` sets `LrForceInitPlugin` so that this happens when
  Lightroom starts), when the plug-in is enabled, and when the setting (or the automatic send, below) is switched on in
  the Plug-in Manager. With both settings off, no task is started.
- It stops within about a second (or after the file it is placing) when both settings are switched off, when the plug-in
  is disabled (`LrDisablePlugin`) or unloaded, reloaded or Lightroom quits (`LrShutdownPlugin`), or when Lightroom
  reports the plug-in as disabled. Two signals reach it: a stop flag in the module `AutoFetch` and a run token in the
  plug-in's preferences (every start writes a new one; a loop whose token is no longer the stored one ends, so a
  reloaded plug-in never leaves two loops running).
- **The fetch lock.** A manual fetch, the automatic fetch and the build command (while it waits for its job) never run
  at the same time: each takes a lock kept in the plug-in's preferences and refreshes it while it works. The automatic
  fetch skips a round when the lock is taken; a manual command says so in a dialog. A lock left behind when Lightroom
  closed in the middle of a fetch frees itself within 3 minutes (a lock claiming a longer life, after the computer's
  clock was set back, is ignored).

### Automatic send

Off by default. When **Automatic send** is switched on in the Plug-in Manager, the same background task as the
automatic fetch (one loop, two duties; it runs while either setting is on, at the same interval) first sends new
photos, then fetches. It sends raw photos **added to the catalog after the option was switched on** that have no smart
preview and whose path maps to an available server root, as one job labelled «Lightroom import (automatic)» with this
catalog's `clientId`, so the automatic fetch (or **Fetch ready smart previews**) brings their smart previews in. It
shows no dialog and logs one line per round that did something; a round with nothing to do logs nothing, and the same
line twice in a row (for example the same error) is logged once.

How new photos are found. The SDK has no import event; `catalog:findPhotos` has no criterion for the import date or
for smart previews (its documented date criteria are `captureTime` and `touchTime`, «Edit Date»); and the «Previous
Import» collection (`catalog.kPreviousImport`) can only be reached by making it the user's active source with
`catalog:setActiveSources`, which a background task must not do. So:

- Each round reads `catalog:getAllPhotos()` and every photo's catalog id, `photo.localIdentifier`, and compares it with
  a mark remembered per catalog; only photos above the mark are read further (`PhotoAccess.describe`). The task yields
  every 500 photos. The SDK documents `localIdentifier` as «unique within this catalog»; **that new photos get larger
  ids than every photo before them is not documented** (the catalog's id counter suggests it) and has not been
  checked in Lightroom. If it did not hold, photos would be missed, never sent twice.
- Fallback, used only when `getAllPhotos` fails: `catalog:findPhotos` with `touchTime` «in the last N hours» (N from
  the last change of the remembered state). **That an import gives a photo an Edit Date is not documented and not
  checked**; if it does not, the fallback finds nothing.
- **Diagnostics: new photos for the automatic send** shows what both ways see now, so this can be checked in Lightroom.

The rules (`AutoSendPlan.lua`):

- The first round for a catalog only records the mark: what is in the catalog when the option is switched on is never
  sent. Switching the option off forgets the marks of all catalogs, so switching it on again starts from that moment.
- A photo is taken in the round **after** the one that first saw it, so that an import in progress has settled.
- Left out for good: virtual copies, videos, photos that already have a smart preview, file types the server does not
  take, photos under no path mapping or whose server root is not available, photos whose catalog record names another
  file, and photos that **Add a folder without previews...** added and sends itself (see there).
- A photo whose file record cannot be read from the catalog database yet (sqlite3) waits, together with the photos
  after it, for the next round; after 3 rounds it is left out and the others go ahead.
- At most 500 photos per round (and at most the server's `maxItemsPerJob`); the rest follow in the next rounds.
- The mark moves only after the job was created; a round that fails (the server cannot be reached, the job is
  refused, sqlite3 is missing, an SDK call fails) leaves it where it was and the next round tries again. No photo is
  sent twice by the automatic send, also across restarts; anything sent earlier in another way costs the server
  nothing, because its cache answers at once.
- The send takes the fetch lock while it talks to the server; when another task holds it, the round is skipped.

If **Build Smart Previews** is ticked in Lightroom's import dialog, Lightroom builds the smart previews of an import
itself; photos it has not finished within a round may be sent too. Nothing is overwritten either way.

The plug-in logs to `LRRemotePreviews.log` in Lightroom's log folder. With Lightroom Classic 15.6 on Windows that is
`%LOCALAPPDATA%\Adobe\Lightroom\Logs\LrClassicLogs`; older versions used an `LrClassicLogs` folder in your Documents
folder. The access token is never logged.

### Diagnostics

- **Diagnostics: smart preview report (all photos)** writes a tab-separated file `smart-preview-report-<time>.txt`
  next to the catalog: for every photo the file name, the SDK's `uuid` (the image id, which is *not* the file UUID
  that names a smart preview), the smart preview size and its path as Lightroom reports them. It changes nothing.
- **Diagnostics: try buildSmartPreview on selected photos** calls `photo:buildSmartPreview()` on 1 to 20 selected
  photos and writes `smart-preview-trybuild-<time>.txt` next to the catalog with the result (`created`, `existed` or
  `failed`) and the smart preview before and after. It does what **Library > Previews > Build Smart Previews** does
  for those photos, so try it on a test catalog.
- **Diagnostics: new photos for the automatic send** shows the number of photos and the largest catalog id, how long
  reading them took, the 10 photos with the largest catalog ids, the automatic send's mark and how many photos lie
  above it, and what `catalog:findPhotos` with `touchTime` in the last 24 hours finds (the fallback). It sends and
  writes nothing and does not move the mark; the result goes to a dialog and to the log.

## Safety rules

From [decision record 0005](../docs/adr/0005-nothing-of-the-users-is-put-at-risk.md) and the last section of the
[protocol](../docs/protocol.md), with [decision record 0007](../docs/adr/0007-photos-added-through-lightroom-on-the-users-command.md)
since 0.5.0, the same for every command, the automatic fetch and the automatic send (which places nothing itself; its
photos are placed by a fetch):

- The plug-in only reads the catalog, with sqlite3 in read-only mode, and never writes to it itself. Lightroom changes
  its catalog through its own plug-in interface: it registers a placed file when `buildSmartPreview()` is called
  ([decision record 0001](../docs/adr/0001-register-by-placing-the-file.md)), and it adds photos when **Add a folder
  without previews...** calls `catalog:addPhoto` on the user's command (decision record 0007).
- **Add a folder without previews...** reads folder listings only. It never opens, changes, moves or deletes a file
  and writes nothing next to the originals, and it asks Lightroom for no preview of any kind.
- A DNG is placed only after its length, its original file name and (when known) its original pixel size match the
  photo. A file that fails is discarded and reported; it is never written into the store.
- Files are written under a temporary name in the destination folder and renamed. An existing smart preview is never
  replaced. The check for an existing file happens right before writing and again right before the rename; a file
  that Lightroom itself creates in the moment between that check and the rename is not detected.
- Placing happens one file at a time, in one task only (concurrent downloads only download), and the fetch lock keeps
  two fetches from placing at the same time.
- **Check the server against Lightroom** only reads: the smart preview from the store, and the server's DNG into
  memory. It writes no file and never calls `buildSmartPreview()`.

## Layout

All modules sit at the top level of `LRRemotePreviews.lrplugin/`, because Lightroom's `require` takes a script name,
not a path: the plug-in sandbox of Lightroom Classic 15.6 contains the error "require: invalid characters in script
name" for names with `/`, `\` or `:` (seen in its code, not tried). Top-level modules do load by bare name there
(tried). The pure modules say so in their header and have no `import` of Lightroom namespaces, so they run under plain
Lua 5.1:

| Module | Pure | Purpose |
|---|---|---|
| `PathMap.lua` | yes | Local path → `{rootId, relativePath}` and back; one key per file for spotting virtual copies |
| `SmartPreviewPath.lua` | yes | Catalog path + file UUID → smart preview store folder and DNG path |
| `ServerInfo.lua` | yes | Info request URL and headers, checking the answer, the status text |
| `Settings.lua` | yes | Reading and writing the settings in a key-value store, the path mappings, the options |
| `Selection.lua` | yes | Whether the server can be used; which photos are sent or looked up and why the others are not |
| `SqliteCommand.lua` | yes | The `SELECT`, the read-only script, the command lines for `cmd.exe` and POSIX shells, parsing the output |
| `FileIds.lua` | yes | Matching photos to the file UUIDs read from the catalog; the smart preview path of each |
| `HttpJson.lua` | yes | JSON request headers, turning an HTTP answer into a decoded body or a problem |
| `Jobs.lua` | yes | Job, item, lookup and file URLs, the request bodies, checking job, item and lookup objects |
| `JobTracker.lua` | yes | Item states as they arrive; the largest `seq` seen |
| `JobRunner.lua` | yes | The polling loop with back-off and cancel, with Lightroom and the network passed in |
| `DownloadQueue.lua` | yes | Several downloads at once, placing one at a time in the owning task, cancel, with tasks passed in |
| `ClientId.lua` | yes | Making up a catalog's `clientId` |
| `CatalogState.lua` | yes | The `clientId` and the job records of each catalog, in a key-value store |
| `FetchPlan.lua` | yes | Which of the catalog's jobs to read, and what to remember about each afterwards |
| `Lease.lua` | yes | The fetch lock in a key-value store: take, refresh, release, expiry |
| `AutoFetchLoop.lua` | yes | The loop of the automatic fetch and send, with Lightroom passed in |
| `AutoSendPlan.lua` | yes | The automatic send: which photos are new, when they are taken, the mark per catalog, the log line |
| `StatusReport.lua` | yes | The texts of the status dialog |
| `DngReader.lua` | yes | `DNGVersion`, `OriginalRawFileName`, `OriginalDefaultFinalSize` from a DNG's first IFD, both byte orders; the directories, entries and tiles a comparison needs |
| `DngCompare.lua` | yes | Comparing two DNGs: raw image structure, every tile, identity tags, expected and unexpected differences, the texts |
| `CompatCheck.lua` | yes | «Check the server against Lightroom»: which photo can be checked, what to do with the server's answers, the result text |
| `Delivery.lua` | yes | Checking a downloaded DNG, placing it (temporary name, rename, no overwrite), `buildSmartPreview()` |
| `RunSummary.lua` | yes | Counts per outcome and reason, the dialog texts, the per-photo log lines |
| `FolderListing.lua` | yes | «Add a folder without previews...»: walking the folders (file system passed in), the folders not looked into, which files are added, RAW+JPEG pairs, the order |
| `AddPlan.lua` | yes | «Add a folder without previews...»: whether it can send, the batches, what a write's answer means, the counts, the confirmation and summary, the log lines and timings |
| `Json.lua` | yes | JSON, [rxi/json.lua](https://github.com/rxi/json.lua) unmodified (see [THIRD-PARTY.md](THIRD-PARTY.md)) |
| `Log.lua` | no | `LrLogger` wrapper |
| `ServerClient.lua` | no | `LrHttp` calls to the server |
| `SqliteRunner.lua` | no | Finding and running sqlite3 with `LrTasks.execute` |
| `PhotoAccess.lua` | no | Reading photos, finding them by path, the selection, the file operations for `Delivery` |
| `Pipeline.lua` | no | The steps the commands share: preparing a send and creating its jobs, lookups, the download queue, the fetch lock, the `clientId` |
| `PhotoAdder.lua` | no | `catalog:addPhoto` in batches inside `catalog:withWriteAccessDo`: retries, rollbacks, the timings |
| `Fetcher.lua` | no | Fetching for a selection or for everything this catalog sent |
| `AutoFetch.lua` | no | Starting and stopping the automatic loop (fetch and send) |
| `AutoSend.lua` | no | One round of the automatic send: finding new photos (scan, fallback), sending them |
| `PluginInfoProvider.lua` | no | The Plug-in Manager section |
| `AddFolderWithoutPreviews.lua`, `SendToServer.lua`, `FetchSmartPreviews.lua`, `BuildSmartPreviews.lua`, `ServerStatus.lua`, `CheckServer.lua`, `Diagnostics*.lua` | no | The menu commands |
| `InitPlugin.lua`, `EnablePlugin.lua`, `DisablePlugin.lua`, `ShutdownPlugin.lua` | no | Start and stop the automatic loop |

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
the synthetic TIFF/DNG files the specs read (`TestDng.full` a smart-preview-like DNG with a thumbnail, a raw image
directory and tiles, in either byte order); it is a helper, not a spec. `spec/DownloadQueue_spec.lua` stands in for
Lightroom's tasks with coroutines and for `LrTasks.pcall` with a pcall that can be yielded across.

Nothing in CI can run Lightroom. A change that touches the SDK has to be tried by hand on a **test catalog**; say in the
pull request on which Lightroom version and platform.

## Not in this version

- Checking the SHA-256 of a download.
- More than 200 jobs per catalog on the server for «everything this catalog sent» (the protocol's largest list).
- Finding the jobs of a catalog that was moved or renamed (it gets a new `clientId`); fetch by selection instead.
- Refusing to deliver when the compatibility check fails (the plan's stage 5); the check is a command run by hand.
- Detecting an import as it happens: the SDK has no import event; the automatic send looks for new photos every
  interval.

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

Version 0.2.0, same Lightroom, 2026-11-14, a test catalog with 157 raw photos whose DNGs were already in the server's
cache:

| What | Result |
|---|---|
| The settings section with three mappings and «Check sqlite3» (a `sqlite3` 3.50.6 found on the PATH); 0.1.0 settings appearing as mapping 1 | works |
| «Build smart previews on the server» on 157 selected photos: the confirmation, the progress, the summary | works: 157 sent, 157 placed and registered, at the first attempt |
| Finding and running `sqlite3` with `LrTasks.execute`; reading the answer back | works: 157 of 157 catalog ids found |
| `photo.localIdentifier` equal to `Adobe_images.id_local` | holds (every looked-up file name matched its photo) |
| Lightroom's `dimensions` usable for the check against the DNG's `OriginalDefaultFinalSize` | works (no photo was reported as «original size not checked») |
| `LrHttp.post` for creating the job; downloading a DNG with `LrHttp.get` | works: 157 files in 30 s, about 0.19 s per photo including the checks, placing and the registration, one at a time |
| Writing, renaming and registering a delivered DNG (`io.open`, `LrFileUtils.move`, `buildSmartPreview()`) | works: `buildSmartPreview()` answered `'existed'` for all; afterwards the catalog had 157 smart previews, each file checked independently against the catalog (name and original size), no temporary files left |
| Cancelling a run (`LrHttp.post` with method `DELETE`) | not tried |
| A run in which the server has to build (not only serve from its cache); failed and rejected items | not tried |
| Videos, virtual copies, non-raw files and photos that already have a smart preview in the selection | not tried |
| The path setting for `sqlite3`, and a `sqlite3` next to the plug-in | not tried |
| A catalog or temporary folder whose path has non-ASCII characters | not tried |

Version 0.3.0: send and fetch for the selection ran in Lightroom Classic 15.6 on Windows (33 and 110 photos,
originals on a NAS); the rest has not been tried.

| What | Result |
|---|---|
| The new settings (downloads at once, automatic fetch, interval: `popup_menu`, `checkbox`) | not tried |
| «Send to the server»: creating the job with the `clientId` and returning at once; several jobs past `maxItemsPerJob` | works: jobs of 33 and of 110 photos; several jobs not tried |
| «Fetch ready smart previews»: the scope dialog (`LrDialogs.confirm` with a third button); `catalog:getTargetPhoto()` returning `nil` when nothing is selected | the dialog works (selection chosen); nothing selected: not tried |
| Fetch by selection: `POST /api/v1/lookup`, download by cache key | works: 33 of 33 and 110 of 110 placed and registered, 0.09–0.16 s per photo |
| Fetch «everything this catalog sent»: `catalog:findPhotoByPath` (and its case-insensitive form), the job records, a job deleted by the server | not tried |
| Several downloads at once (`LrTasks.startAsyncTask` tasks with `LrHttp.get`), placing one at a time | works (four at once) |
| A cancelled or interrupted fetch followed by one that finishes the rest | not tried |
| «Build smart previews on the server» with the download queue and the fetch lock | not tried |
| «Server status...»: the dialog (`LrDialogs.presentModalDialog`, `LrBinding.makePropertyTable`, `LrView.osFactory`), «Retry», «Fetch now», «Open the dashboard» (`LrHttp.openUrlInBrowser`) | not tried |
| The automatic fetch: `LrInitPlugin` with `LrForceInitPlugin`, `LrEnablePlugin`, `LrDisablePlugin`, `LrShutdownPlugin`, the background task, a quiet fetch, the fetch lock against a manual fetch, stopping | not tried |
| Lightroom quitting while the automatic fetch runs | not tried |

Version 0.4.0: nothing has been tried in Lightroom yet.

| What | Result |
|---|---|
| The new menu items «Check the server against Lightroom» and «Diagnostics: new photos for the automatic send»; the new setting «Automatic send» (`checkbox`) | not tried |
| The check: reading a smart preview with `io.open(path, 'rb')`; `LrApplication.versionString()`; a one-item job without `clientId`, its cancel | not tried |
| The check on a smart preview Lightroom built, against the server's DNG for the same raw file: the verdict | not tried (the comparison itself only on synthetic files; the hand comparison in [the research](../docs/research/smart-previews.md) used `tools/dng_compare.py`) |
| The automatic send: `catalog:getAllPhotos()` and `photo.localIdentifier` in a background task, `LrTasks.yield` during the scan, the time the scan takes on a large catalog | not tried |
| New photos of an import getting larger `localIdentifier` values than every photo before them | not checked (undocumented) |
| The fallback `catalog:findPhotos` with `touchTime` «inLast» N hours; whether an import sets the Edit Date | not tried (undocumented) |
| The automatic send and fetch in one loop; switching the send off and on; a restart of Lightroom in between | not tried |

Version 0.5.0: nothing has been tried in Lightroom yet. What to look at when it is:

| What | Result |
|---|---|
| The menu item «Add a folder without previews...»; `LrDialogs.runOpenPanel` with folders only and several folders; the options dialog (`presentModalDialog`, `checkbox` with `enabled`) | not tried |
| `LrFileUtils.files` and `LrFileUtils.directoryEntries` on a NAS folder: full paths, hidden files, the time a large folder takes | not tried |
| `catalog:findPhotoByPath` for every file of a folder before adding: the time it takes | not tried |
| `catalog:addPhoto` inside `catalog:withWriteAccessDo` with `{ timeout = 30 }`: the answer `'executed'`, the photo it returns, the time per photo over the network | not tried |
| `addPhoto` on a file of an unsupported type, an unreadable file, a file that is in the catalog already: whether it raises and with which text | not tried (the SDK documents an error for a missing path and an unsupported format only) |
| `LrTasks.pcall` around each `addPhoto` inside the write, and `LrTasks.yield` there: the rest of the batch kept | not tried |
| What Lightroom does by itself with photos added this way: thumbnails or previews when they are shown, what it reads from the NAS for them, the «Previous Import» collection, a JPEG next to a raw file recorded with the raw photo or not | not measured |
| Sending right afterwards: sqlite3 finding the file records of the photos just added | not tried |
| The automatic send leaving the command's photos out | not tried |
| `LrDate.currentTime()` having fractions of a second (the log's timings) | not checked |
