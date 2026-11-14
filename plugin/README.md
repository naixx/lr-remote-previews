# LR Remote Previews: Lightroom Classic plug-in

The plug-in asks an LR Remote Previews server, which runs next to the photo originals (for example on a NAS), to
build smart previews, and brings them into the catalog. It covers **stage 2** of [the plan](../docs/plan.md)
(Lightroom does not have to stay open while the server works) and, since version 0.4.0, parts of stages 4 and 5.
**Build smart previews on the server** sends the selected photos and returns at once, **Fetch ready smart previews**
fetches what is ready, and the automatic fetch (on by default) brings the smart previews in while Lightroom is open,
asking the server only while this catalog waits for something. **Server status...** shows this catalog's jobs and can
retry failed ones, **Check the server against Lightroom** compares the server's DNG with a smart preview Lightroom
built itself (stage 5), and an optional automatic send sends photos added to the catalog (stage 4). **Import a folder
without the dialog...** starts Lightroom's own import of a folder without its dialog, with the settings of the previous
import (only when that was «Add»), and leaves the sending to the automatic send. It replaces 0.5.0's «Add a folder
without previews...», which ran once and was far too slow (see «What has been tried in Lightroom»).

Status: **version 0.8.4, which has not been run in Lightroom.** Version 0.7.0 ran end to end in Lightroom Classic
15.6 on Windows: the import of 1384 raw files from a NAS, the automatic send and the automatic fetch placed and
registered all 1384 smart previews, in 16.5 minutes. 0.8.0 rebuilt that automatic path for speed; in its run the fast
path worked but sent only 650 of 1384 photos, and 0.8.1 fixed that. 0.8.2 ran once: every photo sent into one job,
nothing downloaded during the import, but the user closed Lightroom in the middle of the fetch because nothing on the
screen showed it. 0.8.3 shows a progress bar and starts the fetch after Lightroom's own preview task; its one session
waited for an import that was not there (an old import record after a restart), which 0.8.4 fixes (see the tables at
the end). Before that, 0.2.0's build command ran on 157 photos, 0.3.0's send and «Fetch ready smart previews» for the
selection on 143 photos from a NAS, 0.5.0's «Add a folder without previews...» once and 0.6.0's «Import a folder
without the dialog...» once. Everything else is checked only by the unit tests and by runs with stand-in Lightroom
functions (cooperative tasks, a virtual clock) against a fake server that follows the protocol, and the plug-in's
server calls also against the real server without a converter (no Lightroom involved in either).

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
  standard input: `.open --readonly "<catalog>"`, a 5-second busy timeout, and one `SELECT`: either `id_local`,
  `id_global`, `baseName` and `extension` for the photos concerned (`Adobe_images` joined to `AgLibraryFile`), at most
  500 photos per run; or, for **Import a folder without the dialog...**, the `SELECT` of `ImportQuery.lua` (the
  settings of the previous import and the largest catalog ids); or, for the automatic send and fetch (since 0.8.0), a
  `SELECT` of `CatalogRead.lua`: the photos above a catalog id, or with given ids, with their folder
  (`AgLibraryFolder`, `AgLibraryRootFolder`), file name and file UUID (`AgLibraryFile`), import
  (`AgLibraryImportImage`), pixel size, whether they are videos or virtual copies (`Adobe_images`) and whether
  Lightroom has a smart preview for them (`AgDNGProxyInfo`), plus the import records above that id
  (`AgLibraryImport`). Since 0.8.3 also, for the automatic fetch, a second Lightroom database: the preview index
  `<catalog name> Previews.lrdata\previews.db` next to the catalog, opened the same read-only way, with one `SELECT`
  per 500 photos (`PreviewWatch.lua`): how many of the file UUIDs the session sent have a row in `Pyramid` whose
  `quality` is not `thumbnail`. Nothing else is ever passed (the script builder refuses anything but one plain
  `SELECT`), and nothing writes.
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
| Automatic fetch | on, every 1 minute | Fetch ready smart previews in the background while Lightroom runs, asking the server only while this catalog waits for something (see below). A server of version 0.6.0 or newer says when each smart preview is ready; older servers are asked at the interval (30 seconds to 30 minutes). 0.7.0 switches it on once in settings of older versions (key `settingsVersion`) |
| Automatic send | off | Send raw photos added to the catalog after it was switched on, in the same background task: it looks every 3 seconds while an import comes in, otherwise at the interval (see below) |

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

Besides the settings, the plug-in keeps six things per catalog in its preferences, keyed by the catalog's path: the
catalog's `clientId`, how far fetching got for each of the catalog's jobs, how far the automatic send got, the jobs
the automatic fetch still waits for (`pendingJobs`), the job of each Lightroom import (`importJobs`, since 0.8.0) and
the placed smart previews still to be registered (`registerQueue`, since 0.8.0), all as JSON text. It also remembers
the file types the server took last (`serverExtensions`, so that the automatic send can leave out other files without
asking the server), what the server can do (`serverCapabilities`: waiting requests, adding items), the time «Import a
folder without the dialog...» last started an import (`importTriggered`) and the folder chosen last in it
(`importFolderLast`; 0.6.0's `importFolderSend`, 0.6.0's list of photos that command sent and 0.5.0's `addFolder*`
keys are no longer read). None of this is shown in the Plug-in Manager.

## Commands

**Library > Plug-in Extras** holds the three everyday commands: **Import a folder without the dialog...**, **Build
smart previews on the server**, **Fetch ready smart previews**. **Help > Plug-in Extras** holds **Server status...**,
**Check the server against Lightroom** and the three diagnostics. Every title starts with `LRRP: ` (for example
`LRRP: Server status...`), so that the items stand out next to those of other plug-ins; this document names the
commands without it. The Help menu entries come from the key `LrHelpMenuItems` in `Info.lua`; they worked in the run
of 0.7.0.

### Which command when

| Command | Use it when | Lightroom must stay open |
|---|---|---|
| **Build smart previews on the server** | You want smart previews for the selected photos: it sends them and returns at once; the automatic fetch brings them in | No (only for the automatic fetch) |
| **Fetch ready smart previews** | You want what the server has finished now, from this catalog or from anywhere else | Only while it fetches |
| **Check the server against Lightroom** | After an update of Lightroom or of the server's Adobe DNG Converter: is the server's DNG still the file Lightroom builds? | Yes, until it is done |
| **Import a folder without the dialog...** | A folder on the NAS is not in the catalog yet: Lightroom imports it with the settings of the previous import (which must have been «Add»), without the dialog; the automatic send (one checkbox) sends the new photos | Yes, while Lightroom imports and the automatic send sends |

The first two leave out photos that already have a smart preview and never replace a file, so running one of them
again, or another one after it, is harmless. The check writes nothing at all. In its one run, Lightroom's import
started by **Import a folder without the dialog...** left the photos of the folder that were in the catalog already
alone.

### The clientId

Every job the plug-in creates carries a `clientId`: a random text in the form of a UUID
(`c1f0a6e2-7d0b-4c55-9d0e-3f6a1b2c4d5e`) that the plug-in makes up the first time a catalog sends something and keeps
in its preferences, keyed by the catalog's path. It is not a Lightroom identifier and says nothing about the catalog;
it only lets the plug-in ask the server for "the jobs this catalog sent" later
([protocol](../docs/protocol.md#the-job-object)). It is made with a small random generator seeded from the time,
the processor clock, a counter, `math.random` and the catalog path (`ClientId.lua`), so two catalogs are very unlikely
to get the same one. A catalog that is moved or renamed gets a new `clientId`; its old jobs are then no longer found
by «everything this catalog sent», but fetching by selection still finds their files.

### Build smart previews on the server

For the selected photos (Lightroom's target photos: with nothing selected, that is every photo in the filmstrip). Since
0.7.0 this is the one send command: it does what 0.3.0 to 0.6.0 called «Send to the server», without the
confirmation; 0.2.0's command of this name, which waited for the job and placed the files itself, is gone.

1. Asks the server for `GET /api/v1/info` and stops with a message when it cannot be used: another API version, no
   Adobe DNG Converter installed, no accepted file types, no path mapping, or no mapped root available.
2. Leaves out, and counts per reason: videos; photos without a file path; photos that already have a smart preview
   (Lightroom's `smartPreviewInfo`); files whose extension the server does not accept; files under no local prefix;
   files whose server root is missing or not available; a second photo of the same file (virtual copies: the
   original is preferred).
3. Reads the file UUIDs from the catalog with sqlite3 (see above) and leaves out photos that are not found in the
   catalog database or for which the database names a different file.
4. Creates one job per `maxItemsPerJob` photos (`POST /api/v1/jobs`), each with this catalog's `clientId`, adds each
   job to the jobs the automatic fetch waits for (`PendingJobs`), and returns. Nothing is downloaded or placed. Since
   0.8.0 the `ref` of each item is the photo's catalog id, and what is needed to place its smart preview is kept, so
   the automatic fetch places the files without asking Lightroom for the photos (see «Automatic fetch»).
   - Every selected photo was taken: no dialog, only a short notice that fades by itself (`LrDialogs.showBezel`):
     `5 photos sent to the server; their smart previews arrive by themselves` (with the automatic fetch off: «fetch
     their smart previews with «Fetch ready smart previews» when they are ready»).
   - Photos were left out or refused by the server, or a part could not be created (`RunSummary:sendNeedsAttention`):
     a dialog says how many photos were sent (job numbers), how many the server had built already, how many it
     refused (with the reasons), why the others were left out, and that Lightroom may be closed.
   - A server that cannot be reached, a rejected token or another error: a dialog, as before.

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

Delivery is the same for both (and for the automatic fetch): several downloads at once (`GET /api/v1/files/{key}`;
the setting "Downloads at once"), then, strictly one at a time and only in the fetching task, for each file:

- checks the length against the size the server announced;
- reads `DNGVersion`, `OriginalRawFileName` and `OriginalDefaultFinalSize` from the file itself and requires the
  original file name to equal the photo's file name (ignoring case) and, when both the file and Lightroom give a
  pixel size, the two sizes to match in either orientation;
- writes it as `<UUID>.dng.lrrp-<run tag>-<ref>.tmp` in the destination folder and renames it to `<UUID>.dng`;
- never replaces a file that is already there;
- calls `photo:buildSmartPreview()`, which answers `existed` when Lightroom has taken the file.

A file the server no longer has (`404 not_in_cache`) is counted as such and tried again by the next fetch. The
summary counts placed (and how many Lightroom did not answer `existed` for), already there, discarded by the check,
download or write failures, the server's `failed` and `rejected` items with their error codes, not finished, and the
reasons for photos that were left out. The log has one line per photo.

The pixel size the plug-in compares is Lightroom's `dimensions` metadata; with Lightroom Classic 15.6 it matched the
DNG's `OriginalDefaultFinalSize` for all 157 photos of the test catalog; other cameras are not verified. When
Lightroom gives no size, the photo is placed after the name check and the log line says "original size not checked".
The SHA-256 is not checked: the SDK has no SHA-256 and Lightroom's Lua has no bit operations; the length and the
content checks are made instead.

Fetching is **resumable**: cancelled, interrupted by an error, or cut off by Lightroom closing, the next fetch simply
continues, because a photo that already has a smart preview is left out and nothing is ever overwritten. A cancelled
run remembers what it finished; a run that ended with an error remembers nothing, so the next one reads those items
again and leaves the placed ones alone.

### Server status...

Shows what the server says about itself (name and version, protocol version, whether it needs a token, whether Adobe
DNG Converter is installed there, its roots, the state of the root of each path mapping), then this catalog's jobs
that still matter (active ones, ones not fully fetched, ones with failed items; label, when it was sent, and the counts
ready / building / queued / failed), and how many smart previews are ready on the server and not fetched by this
catalog yet (an upper bound: some may have been placed in another way). The dialog has three actions:

- **Fetch now**: fetches everything this catalog sent, as the Fetch command does.
- **Retry** (shown when a job has failed items): picks a job and sends `POST /api/v1/jobs/{id}/retry`; the answer is
  shown under the button. The server checks each retried file again as it is now, and the automatic fetch waits for
  that job again.
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

### Import a folder without the dialog...

New in 0.6.0, which ran once in Lightroom; 0.7.0 cut it down to the check, the dialog and the start of the import, and
that version **has not been run in Lightroom**. It starts Lightroom's own import of one folder without the import
dialog, with the settings of the previous import, and leaves the sending to the automatic send. It replaces 0.5.0's
«Add a folder without previews...», which added photos one by one with
`catalog:addPhoto` and was far too slow on a NAS (see «What has been tried in Lightroom»). It is Lightroom that changes
its catalog here, with its own import, on the user's command
([decision record 0007](../docs/adr/0007-photos-added-through-lightroom-on-the-users-command.md)); the plug-in never
lists the folder, never opens, changes, moves or deletes a file, and writes nothing next to the originals.

1. A folder dialog (`LrDialogs.runOpenPanel`, one folder) that opens in the folder holding the one chosen last.
2. **The check.** The plug-in reads, with sqlite3 and read-only (`ImportQuery.stateSql`), what the catalog records
   about the previous import: the rows of `Adobe_variablesTable` named `AgImportDialog_importBehavior`,
   `…_previewBuildQuality`, `…_generateDNGProxies`, `…_doCopyToBackupFolder`, `…_crSettingsID`, `…_metadataPresetID`,
   `…_ignoreSuspectedDuplicates`, `…_importServiceProvider` and `…_suppressImportDialog`, and the largest catalog id
   of photos and of imports (the mark). It goes on only when `importBehavior` is `refInPlace` («Add»: the files stay
   where they are and only references are added) and «Make a Second Copy To» is off (`ImportPlan.judge`). Any other
   value, a missing row, two different values for one name, or no working sqlite3 stops it with a message: import
   one folder through Lightroom's dialog with «Add» first. Every value read goes into the log.
   In the test catalogs of Lightroom Classic 15.6 read for this (their last imports were «Add» with Build Smart
   Previews off), `importBehavior` was `refInPlace` and `generateDNGProxies` `0`; `previewBuildQuality` was `bthm` in
   the two whose last import used «Embedded & Sidecar», and `sbig` in the others (which mode that is was not
   established).
3. A dialog (`LrDialogs.presentModalDialog`) shows what Lightroom will do: «Add», the previews (`bthm` is shown as
   «Embedded & Sidecar»; any other code as «Lightroom builds its own», with the code), whether Build Smart Previews is
   on (with a warning), and a develop or metadata preset of the previous import. One checkbox, **Send new photos to the
   server automatically**, shows and sets the plug-in's automatic send (the same setting as in the Plug-in Manager);
   the line under it says what that does, or names what stands in the way (no server URL, the folder under no path
   mapping: `ImportPlan.sendProblem`), and that with it off the photos can be sent later with **Build smart previews
   on the server**. The folder is remembered (`importFolderLast`). The dialog asks the server nothing.
4. **The trigger.** Right before it, the plug-in reads the record again and stops if anything in it changed. It sets
   the automatic send as the checkbox says; switched on, it remembers the catalog's largest photo id read in the
   check as the automatic send's mark (unless the automatic send already has one), so that every photo of this import
   counts as new however late the first look runs, starts the background loop, and stores the time of the trigger
   (`importTriggered`) so that the automatic send looks every 3 seconds until the photos have come. Then
   `catalog:triggerImportFromPathWithPreviousSettings(folder)` ("Triggers an import, bypassing the import dialog, using
   the settings from the most recent import", SDK 4.0), and a short notice (`LrDialogs.showBezel`):
   `Lightroom is importing <folder>; the automatic send sends the new photos`. The command ends there: no progress
   bar, no waiting, no fetch lock, no summary. Dialogs come only before the trigger and for refusals and errors (the
   check says no, no sqlite3, Lightroom raised an error).
5. **Sending** is the automatic send's job (below). It reads the catalog every 3 seconds while the import comes in
   and sends each burst in the look that finds it, all into one job for the import.

**Its log** (lines start with `import folder:`): every setting read; `automatic send: on (was off)`; `trigger called at
<time> (catalog ids up to <mark> were there before): <folder>`; `trigger returned after 0.16 s: value nil`.

**What the check cannot know.** That the trigger uses exactly the values the catalog records (the names say so; Adobe
documents nothing about them), whether Lightroom takes sub-folders, and which previews it builds for a code other than
`bthm`.

### Automatic fetch

On by default since 0.7.0 (`Settings.upgrade` switches it on once in settings saved by an older version, which stored
the old default, off; key `settingsVersion`). A background task fetches what this catalog waits for, **quietly**: no
dialog, no progress bar; one line in the log per photo and per result (the same result twice in a row is logged
once), errors only in the log, and a short notice that fades by itself when the smart previews of a job are in
(`600 smart previews arrived from the server`; once per job, not per file). It delivers as a manual fetch does (every DNG checked, nothing replaced) and never at the
same time as one.

**When it talks to the server** (`PendingJobs.lua`), so that an idle Lightroom never wakes a sleeping NAS or keeps it
awake:

- **Pending jobs.** Every job this catalog creates is recorded as pending, per catalog, in the plug-in's preferences
  (`pendingJobs`), so the list survives a restart: by **Build smart previews on the server**, by the automatic send
  (also when it adds photos to a job), and by **Retry** in **Server status...** (which starts the job's clock again).
- **Nothing pending: no request at all**, not even the job list or the server's info. The log says once
  `automatic fetch: nothing pending for this catalog; the server is not asked`.
- **Something pending, jobs sent since 0.8.0** (their `ref`s are the photos' catalog ids; `FastFetch.lua`): for each
  such job one task keeps a request open, `GET /api/v1/jobs/{id}/items?since=<largest seq>&state=ready&wait=25`
  (`WaitPlan.lua`). The server answers as soon as an item becomes ready, otherwise after the wait with no items; that
  is the normal case, and the next request follows at once. At most one such request per job. When an answer shows the
  job no longer `active` (from `job.state`: a wait with `state=ready` is ended only by a ready item, so a job that ends
  without one is seen when the wait has passed) and nothing is left to read, the task ends. Against a server without
  `capabilities.maxWaitSeconds` (before server 0.6.0) the task asks without `wait`, once per interval of the settings.
- **Something pending, jobs sent by older versions:** at the interval (and not while an import is in progress), a fetch
  of everything this catalog sent, as 0.7.0 did (the job list, the items of jobs that may have something new, the
  server's info only when there is something to fetch).
- **The end of a job's life.** A job stops being pending when the fetch finds it done (no longer `active` on the server
  and every ready item dealt with), when the server no longer knows it (`404`; it deletes jobs some days after they
  finished), or **7 days after it was sent** (`MAX_AGE_DAYS`), whatever its state. Its files can still be fetched by
  hand.
- **Back-off.** A request that fails (no answer, or an error such as a rejected token) puts off the next one, for the
  whole catalog, by 1, 2, 5, 10 and 30 minutes, then an hour each time (`BACKOFF`, by failures in a row); before then
  no request is made, and the log says `next try at <HH:MM>` once. No dialog. Adding a job or an answer resets it. An
  empty answer that comes back at once although the server was asked to wait (a server that shuts down answers its
  waiting requests that way) is followed by a 5-second pause, so that nothing ever asks in a loop.
- **LrHttp's timeout.** The SDK describes the `timeout` of `LrHttp.get` as «the length of time (in seconds) to wait
  during each phase of the connection before canceling the request», with the error code `timedOut`; waiting for the
  answer is such a phase. So the plug-in asks the server to wait at most 25 seconds (and never longer than
  `maxWaitSeconds`) and gives LrHttp the wait plus 30 seconds. Should a waiting request still end with `timedOut`, the
  wait is halved for the rest of the session, down to 5 seconds, instead of counting the server as not answering. How
  long LrHttp really lets a request wait has not been measured.

**Nothing downloaded while an import is in progress** (since 0.8.2, `FetchGo.lua`). While Lightroom imports from the
NAS it reads the originals over the same link, so the plug-in only sends (small requests; the server builds meanwhile)
and downloads nothing. «In progress» is the fast period of the automatic send (below: new photos still coming, or an
import seen whose first photos are still to come). The waiting requests go on during it: they cost nothing on the link
and tell which smart previews are ready. When the import is over, everything ready is fetched **in one go**, with
«Downloads at once» downloads at the same time; what becomes ready later is fetched as it comes. A job sent while no
import is in progress (**Build smart previews on the server** on a selection) is fetched as its files become ready.
Downloads already under way when an import begins are taken back until it is over.

**When the import is over** (since 0.8.3, `PreviewWatch.lua`). In the run of 0.8.2, Lightroom's own task «Fetching
Initial Previews» (it reads the previews embedded in the originals, over the same link) went on for 3.5 minutes after
the last photo was added, at 0.34 s per photo, and the user took the end of that task for the end of the import. So
the import is over when no new photo has come for 2 minutes **and** Lightroom's previews of the import's photos have
stopped coming: the number of them with a preview better than the 160-pixel placeholder has not grown for 30 seconds,
or all have one. The plug-in reads that from Lightroom's preview index (below, «The sqlite3 tool») every 10 seconds.
At most 15 minutes after the photos stopped, the fetch begins anyway (a preview task the user cancelled, photos that
never get a preview; at Lightroom's pace that covers imports of about 5000 photos); when the index cannot be read, or
after a restart (when the session no longer knows which photos it sent), it begins as before 0.8.3.

**The progress bar** (since 0.8.3, `FetchProgress.lua`). While the automatic fetch has at least 20 smart previews to
bring in (received and not yet placed, or still being built on the server), Lightroom's activity area shows one bar,
`LRRP: smart previews`, advancing per file: `836 of 1384 fetched`, with `; 184 still being built on the server` while
the server builds, or `; the server does not answer (next try at 21:58)`. While it waits for an import, it says what
it waits for and the latest time it waits (since 0.8.4): `Waiting while Lightroom adds photos, until 21:50 if no more
come: ...`, `Waiting for the photos of Lightroom's import, at the latest until 21:47: ...`, `Waiting for Lightroom's
previews of the import (600 of 1384), at the latest until 22:05: ...`. After a restart with files left over it shows
`N of M fetched` at once, the files already in place counted. It ends when nothing is left to bring in; while the
server still builds it stays and says so, so that it never sits still without saying why. A trickle of a few files
shows no bar. The registration call afterwards shows Lightroom's own bar. **Cancelling the bar pauses the automatic
fetch** for the rest of the session (the run of its loop): nothing is downloaded, placed or registered until **Fetch
ready smart previews** is run or Lightroom starts again; the automatic send goes on. The bar has no function context
and is ended with `done()`.

**Placing without calling into the catalog.** Plug-in calls into the catalog are very slow while Lightroom imports (in
the run of 0.7.0, 4.7 minutes passed in one fetch before its lookup; in 0.6.0's, `findPhotoByPath` for 425 photos took
45.8 s). So the ready files are downloaded, checked and placed (temporary name, rename, never over an existing file)
with what the send read from the catalog: the file UUID that names the smart preview, the file name and the pixel size
for the check. After a restart of Lightroom, when that is no longer in memory, the same facts are read again with
sqlite3 by catalog id (`CatalogRead.byIdSql`). A photo that Lightroom meanwhile counts as having a smart preview
(`AgDNGProxyInfo`) is left alone.

**Registration afterwards, one call** (since 0.8.2). Lightroom does not take a placed file by itself (checked with
0.8.0: no smart preview row within 10 minutes; the row came when the plug-in asked). So the placed photos are queued
(`RegisterQueue.lua`, kept in the preferences as `registerQueue`, so it survives a restart) and registered with **one
`catalog:buildSmartPreviews(photos)` call** (SDK 5.0; one progress bar in Lightroom instead of one operation per photo):
right after a fetch in one go, all photos placed in it; otherwise once nothing has been placed for 30 seconds (or after
5 minutes at most). Never while an import is in progress. Before the call the photos are read again with sqlite3 (one
that already has a smart preview needs no call), a photo is included only when its smart preview file is in place
(without it Lightroom would build one from the original, over the network), and the photo objects are found with
`findPhotoByPath` (one lookup per photo; 1384 took 1.9 s with no import running, in 0.5.0's run). What the call returns:

- `existed`: registered. `created` would mean Lightroom built the smart preview itself; logged as a warning.
- `failed`, and a call that stops at the first failure: the failed photo is tried again a minute later, the photos the
  call did not reach go into the next, smaller call; a photo that was in 3 calls without being registered gets a call
  of its own (`photo:buildSmartPreview()`), and after 5 failed tries it is given up (logged; its file stays).
- Photos the call did not reach although none failed (the user cancelled the progress bar): no dialog, no new call by
  itself; they are registered after the next fetch in one go or at the next start.
- A Lightroom without `catalog:buildSmartPreviews`, or a call that raises an error: one call per photo for the rest of
  the session.

The log tells the two states apart: `IMG_0001.ARW: placed (DNG 1.7.0.0, <path>; ready -> placed 0.8 s; not registered
yet)`, later `IMG_0001.ARW: registered (Lightroom answered existed; ready -> registered 152 s)`; **Server status...**
says how many are placed and not registered yet.

**An interrupted fetch finishes by itself**; nothing needs to be done after one:

- **Lightroom quits in the middle.** The placed photos not yet registered are in `registerQueue`; a job stays pending
  until every ready item is dealt with, so at the next start its task reads the ready items again, finds the files
  already in place (`is there already (placed before); not downloaded again`), downloads the rest and registers all.
- **The server cannot be reached** (the NAS asleep, the network gone; no answer, `502`/`503`/`504`, a refused token):
  the downloads wait for the back-off below, without counting a try, and go on when the server answers again.
- **Smart previews built after the fetch in one go** are fetched as they become ready (the job's waiting request stays
  open while the job is active).
- **A failed download, or a DNG that fails the check** (for example damaged on the way): tried again 30 seconds later,
  3 times in all, then logged (`given up after 3 tries`) and left; a later **Fetch ready smart previews** tries it again.
- **Temporary files.** A file is written as `<UUID>.dng.lrrp-<...>.tmp` and renamed. The name of the one being written
  is kept in the preferences (`placingTemp`) and that file is deleted at the next start; before a file is placed, any
  such temporary file next to it is deleted (one left by a crash). Lightroom looks only for `<UUID>.dng`, and the
  plug-in counts only that name as placed, so a temporary file is never taken for a finished one.

**Log lines to measure with.** For each photo sent: `IMG_0001.ARW: sent (job 12, queued; first seen in the catalog ->
sent 2.1 s)`. When an import begins: `automatic fetch: an import is in progress; nothing is downloaded until it is
over`; when the photos stopped: `automatic send: no new photo for 120 s; ...` and `automatic fetch: the photos stopped
coming; waiting for Lightroom's previews of them before fetching (at most 15 minutes)`; when the previews stopped:
`automatic fetch: the previews stopped coming: 1384 of 1384 photos of the import have a preview` (or `...; none new for
30 s`, `...; still more to come after 15 minutes, fetching anyway`, `the preview index cannot be read (...)`); the bar:
`automatic fetch: progress bar shown (...)` and `automatic fetch: progress bar ended (1384 of 1384 fetched)`; when it
is judged over: `automatic fetch: the import is taken as over; fetching the 1384 smart preview(s) ready so
far in one go (4 download(s) at once)`; when that is done: `automatic fetch: the fetch in one go is done: 1384 placed, 0
left out, 0 to be tried again later; 2071.3 MB in 95.2 s (21.76 MB/s)`. For the registration: `automatic fetch: one
registration call (catalog:buildSmartPreviews) for 1384 photo(s) took 12.3 s: 1384 existed, 0 created, 0 failed, 0 not
reached`. For each smart preview: the `placed` and `registered` lines above. For each job, once it is done and
registered: `automatic fetch: job 12 «Lightroom import 2026-11-14 15:15, shoot»: 1384 sent (first seen in the catalog ->
sent: median 1.6 s, max 3.2 s), 1384 placed (ready -> placed: ...), 1384 registered (ready -> registered: ...), 0
failed`. «Ready» is when the answer reached the plug-in, which with waiting requests is within a moment of the server;
since 0.8.2 «ready -> placed» includes the wait for the import to end.

- It starts when the plug-in loads (`LrInitPlugin`; `Info.lua` sets `LrForceInitPlugin` so that this happens when
  Lightroom starts), when the plug-in is enabled, and when the setting (or the automatic send, below) is switched on in
  the Plug-in Manager. With both settings off, no task is started.
- It stops within about a second (or after the file it is placing) when both settings are switched off, when the plug-in
  is disabled (`LrDisablePlugin`) or unloaded, reloaded or Lightroom quits (`LrShutdownPlugin`), or when Lightroom
  reports the plug-in as disabled. Two signals reach it: a stop flag in the module `AutoFetch` and a run token in the
  plug-in's preferences (every start writes a new one; a loop whose token is no longer the stored one ends, so a
  reloaded plug-in never leaves two loops running). A waiting request that is open then ends by itself.
- **The fetch lock.** A manual fetch and the automatic fetch never place at the same time: each takes a lock kept in
  the plug-in's preferences and refreshes it while it places. The automatic fetch places nothing while a manual fetch
  holds the lock (downloads wait); a manual fetch says so in a dialog. A lock left behind when Lightroom closed in the
  middle of a fetch frees itself within 3 minutes (a lock claiming a longer life, after the computer's clock was set
  back, is ignored).

### Automatic send

Off by default. When **Automatic send** is switched on in the Plug-in Manager, the same background task as the
automatic fetch (one loop, two duties; it runs while either setting is on) looks for new photos and sends them at
once. It sends raw photos **added to the catalog after the option was switched on** that have no smart preview and
whose path maps to an available server root, with this catalog's `clientId`, so the automatic fetch (or **Fetch ready
smart previews**) brings their smart previews in. It shows no dialog, logs one line per photo sent and one per look
that did something; a look with nothing to do logs nothing, and the same line twice in a row (for example the same
error) is logged once.

**How new photos are found** (since 0.8.0). One read of the catalog with sqlite3 (`CatalogRead.newSql`, an external
process that does not hold up Lightroom's window) gives every photo above a mark remembered per catalog, with
everything the send and the fetch need (see «The sqlite3 tool»), and the import records above the mark. No call into
the catalog is made on this path (0.7.0 used `catalog:getAllPhotos()`, with `findPhotos` as a fallback). **Diagnostics:
new photos for the automatic send** shows what the read sees now.

**Rows that come out of order** (since 0.8.1). Lightroom gives an import the ids of all its photos at once, one block,
but makes the rows visible in an order that is not ascending (several places of the block advance at once, burst by
burst). 0.8.0 moved its mark to the largest id it had seen, and so skipped every photo that became visible later
below it. Since 0.8.1 the mark is a low-water mark: every photo above it is read in every look (1384 rows took 5 ms),
the photos dealt with are kept as a set (in the preferences as id ranges, so it survives a restart), and the mark
moves only when no new photo has come for **5 minutes** and nothing waits, and never past a photo it can see that has
not been dealt with. The log says when it moves (`every photo up to catalog id 164949 is dealt with`).

**How often it looks** (`WatchMode.lua`). At the interval of the settings while nothing happens; **every 3 seconds**
from the trigger of **Import a folder without the dialog...** (it stores the time, `importTriggered`) or an import
record not seen before, for up to 5 minutes until the first photo comes, and after every look that found new photos
until none has come for **2 minutes**. An import record that the first read of a run finds was there before (the mark
moves only after five quiet minutes, so the record of an import that ended just before Lightroom was closed still lies
above it) counts only when no photo is linked to it yet and its date is less than 5 minutes old (2 minutes of clock
error allowed either way); a record that appears later counts whatever its date says (since 0.8.4: 0.8.3 took such an
old record for a new import after a restart and waited five minutes). (Lightroom prepares an import for 2 to 3 minutes before the first photo, then
commits photos in bursts of about a hundred every 22 to 26 seconds.) While it looks fast, an import counts as in
progress: nothing is downloaded, placed or registered. In the run of 0.8.0 the looks came only every 20 to 26 seconds while Lightroom
imported, in step with its bursts: plug-in tasks run between them. So nothing depends on the 3 seconds; every logged
look line says how long after the previous look it came, and the end of a fast period says how often the looks
really came (`… (61 looks while photos came in, every 22 s on average, the longest gap 26 s)`).

**One import, one job** (`JobGroups.lua`). The photos found are sent in the same look, as many as the server's
`maxItemsPerJob` per job. The first photos of a Lightroom import (`AgLibraryImportImage`) create a job labelled with
the import's local time and folder, `Lightroom import 2026-11-14 15:15, 2026.06.20 - shoot`; later photos of the same
import are added to that job (`POST /api/v1/jobs/{id}/items`), also after a restart (`importJobs`). When the job would
hold more than `maxItemsPerJob` items, the rest goes into a new job, `... (part 2)`; when the server refuses an
addition with `too_many_items`, `job_cancelled`, `duplicate_ref` or `404` (the job is gone), a new job takes the
photos. The link of a photo to its import appears a moment after the photo's row (in the run of 0.8.0, ten small jobs
of 2 to 13 photos came from that), so while an import record lies above the mark, a photo without a link waits for it
up to 90 seconds before it is sent as a photo of no import. Photos that belong to no import record are sent per look
as one job, «Lightroom import (automatic)». A new import always gets a new job. Against a server without `capabilities.appendItems` (before server 0.6.0) every look
creates new jobs, still one per import, with the part numbers going on.

The rules (`AutoSendPlan.lua`):

- The first look for a catalog only records the mark: what is in the catalog when the option is switched on is never
  sent. Switching the option off forgets the marks of all catalogs, so switching it on again starts from that moment.
- **Import a folder without the dialog...** with its checkbox on sets the mark to the catalog's largest photo id read
  before the import, when the automatic send has none yet, so that all photos of that import count as new.
- Left out for good, without asking the server: virtual copies, videos, photos that already have a smart preview, no
  path mapping, a file type the server did not take when last asked (`serverExtensions`); after asking it: file types
  it does not take, server roots that are not available.
- A photo whose rows (file, folder, root) are not all in the catalog database yet waits; after 3 looks and at least 60
  seconds it is left out. The other photos go ahead meanwhile.
- It asks the server only when it has photos to send. The server's info is kept for 5 minutes, so a burst costs one
  request (two when the info is due again). When the server does not answer, the next try waits as for the fetch (1,
  2, 5, ... minutes) while the reads of the catalog go on.
- Photos of a look that could not be sent (the server cannot be reached, the job is refused) stay in the set of
  photos not dealt with and are sent by a later look; the mark does not pass them. No photo is sent twice by the
  automatic send, also across restarts.
- It no longer takes the fetch lock (nothing else sends what it sends), so a long manual fetch does not hold it up.
- A look that comes back after its loop was told to stop (for example from a sqlite3 run that took minutes) changes
  nothing. A loop that has taken no step for 10 minutes is taken as hanging: once, on an evening of the 0.8.0 run while
  Lightroom was busy removing 1384 photos, a sqlite3 run never came back (its `.sql` file was written, no output file
  appeared). A small watchdog task then starts a new loop and logs it; the old one, should it ever come back, ends.
  sqlite3 runs that take 10 seconds or more are logged.

If **Build Smart Previews** is ticked in Lightroom's import dialog, Lightroom builds the smart previews of an import
itself; photos it has not finished when they are found may be sent too. Nothing is overwritten either way.

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
- **Diagnostics: new photos for the automatic send** shows what the automatic send's read of the catalog sees now: its
  mark, the largest catalog id, how many photos lie above the mark and the 10 newest of them (file name, import, smart
  preview or not, path), the import records above the mark, and how long the reads took. It sends and writes nothing
  and does not move the mark; the result goes to a dialog and to the log.

## Safety rules

From [decision record 0005](../docs/adr/0005-nothing-of-the-users-is-put-at-risk.md) and the last section of the
[protocol](../docs/protocol.md), with [decision record 0007](../docs/adr/0007-photos-added-through-lightroom-on-the-users-command.md)
since 0.5.0 (amended for 0.6.0), the same for every command, the automatic fetch and the automatic send (which places
nothing itself; its photos are placed by a fetch):

- The plug-in only reads the catalog, with sqlite3 in read-only mode, and never writes to it itself. Lightroom changes
  its catalog through its own plug-in interface: it registers a placed file when `buildSmartPreview()` is called
  ([decision record 0001](../docs/adr/0001-register-by-placing-the-file.md)), and it imports a folder when **Import
  a folder without the dialog...** starts its import on the user's command (decision record 0007).
- **Import a folder without the dialog...** starts that import only after it has read, read-only, that the previous
  import in the catalog was «Add» without a second copy, so the import only adds references to the files where they
  are; it reads that record again right before the start, and starts nothing when it cannot read it. It never lists
  the folder, never opens, changes, moves or deletes a file, and writes nothing next to the originals. What it cannot
  know is listed in its section.
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
| `SqliteCommand.lua` | yes | The file UUID `SELECT`, the read-only scripts (only one plain `SELECT` each), the command lines for `cmd.exe` and POSIX shells, parsing the output |
| `FileIds.lua` | yes | Matching photos to the file UUIDs read from the catalog; the smart preview path of each |
| `HttpJson.lua` | yes | JSON request headers, turning an HTTP answer into a decoded body or a problem |
| `Jobs.lua` | yes | Job, item, lookup and file URLs, the request bodies, checking job, item and lookup objects |
| `JobTracker.lua` | yes | Item states as they arrive; the largest `seq` seen |
| `JobRunner.lua` | yes | The polling loop with back-off and cancel (used by the check), with Lightroom and the network passed in |
| `DownloadQueue.lua` | yes | Several downloads at once, placing one at a time in the owning task, cancel, with tasks passed in |
| `ClientId.lua` | yes | Making up a catalog's `clientId` |
| `CatalogState.lua` | yes | The `clientId` and the job records of each catalog, in a key-value store |
| `FetchPlan.lua` | yes | Which of the catalog's jobs to read, and what to remember about each afterwards |
| `Lease.lua` | yes | The fetch lock in a key-value store: take, refresh, release, expiry |
| `AutoFetchLoop.lua` | yes | The loop of the automatic fetch and send (looks for new photos, fetch steps, the time between looks), and when a loop counts as hanging; Lightroom passed in |
| `WatchMode.lua` | yes | How often the automatic send looks: every 3 s while an import comes in, otherwise the interval |
| `CatalogRead.lua` | yes | The read-only `SELECT`s of the automatic path (photos above a mark or by id, the largest ids) and their parsing |
| `JobGroups.lua` | yes | One job per Lightroom import: which photos go into which job, the labels, what to do when a job takes no more |
| `WaitPlan.lua` | yes | The waiting requests: how long to wait, LrHttp's timeout, what each answer means; what a failed download means (wait for the back-off, try again, give up) |
| `RegisterQueue.lua` | yes | Placed smart previews waiting to be registered: when a call is due, one call for many, what its answer means, tries again and giving up |
| `JobStats.lua` | yes | The times and counts per job for the log |
| `FastState.lua` | yes | What the send and the fetch share in a session (placing data per job and ref), what the server can do |
| `AutoSendPlan.lua` | yes | The automatic send: the low-water mark and the photos dealt with per catalog, photos that wait for their rows or import link, the file types the server took, the log line |
| `PendingJobs.lua` | yes | The jobs each catalog waits for, when the automatic fetch may ask the server, the back-off, the end of a job's life |
| `StatusReport.lua` | yes | The texts of the status dialog |
| `TextWrap.lua` | yes | The text of the plug-in's own dialogs in lines of at most 90 characters (an LrView `static_text` without a width grows to its longest line); short paths for messages |
| `DngReader.lua` | yes | `DNGVersion`, `OriginalRawFileName`, `OriginalDefaultFinalSize` from a DNG's first IFD, both byte orders; the directories, entries and tiles a comparison needs |
| `DngCompare.lua` | yes | Comparing two DNGs: raw image structure, every tile, identity tags, expected and unexpected differences, the texts |
| `CompatCheck.lua` | yes | «Check the server against Lightroom»: which photo can be checked, what to do with the server's answers, the result text |
| `Delivery.lua` | yes | Checking a downloaded DNG, placing it (temporary name, rename, no overwrite), `buildSmartPreview()` |
| `RunSummary.lua` | yes | Counts per outcome and reason, the dialog texts and short notices, whether a send needs a dialog, the per-photo log lines |
| `ImportQuery.lua` | yes | «Import a folder without the dialog...»: the read-only `SELECT` (the record of the previous import and the mark) and parsing its output |
| `ImportPlan.lua` | yes | «Import a folder without the dialog...»: judging the record of the previous import, whether the automatic send can send, the dialog, notice and log texts |
| `Json.lua` | yes | JSON, [rxi/json.lua](https://github.com/rxi/json.lua) unmodified (see [THIRD-PARTY.md](THIRD-PARTY.md)) |
| `Log.lua` | no | `LrLogger` wrapper |
| `ServerClient.lua` | no | `LrHttp` calls to the server |
| `SqliteRunner.lua` | no | Finding and running sqlite3 with `LrTasks.execute` |
| `PhotoAccess.lua` | no | Reading photos, finding them by path, the selection, the file operations for `Delivery` |
| `Pipeline.lua` | no | The steps the commands share: preparing a send and creating its jobs, lookups, the download queue, the fetch lock, the `clientId`, the temporary files of interrupted placings |
| `Fetcher.lua` | no | Fetching for a selection or for everything this catalog sent |
| `AutoFetch.lua` | no | Starting and stopping the automatic loop (fetch and send); the fetch of jobs sent by older versions |
| `AutoSend.lua` | no | One look of the automatic send: reading the catalog with sqlite3, sending the new photos into the job of their import |
| `FastFetch.lua` | no | The automatic fetch of jobs sent since 0.8.0: a waiting request per job, nothing downloaded during an import and a fetch in one go after it, placing without calls into the catalog, registration afterwards with one call |
| `FetchGo.lua` | yes | When the automatic fetch downloads: nothing during an import, everything ready in one go when it is over; the totals of that go |
| `PreviewWatch.lua` | yes | When an import counts as over: Lightroom's previews of its photos have stopped coming (the preview index, read with sqlite3) |
| `FetchProgress.lua` | yes | The automatic fetch's progress bar: when it is shown, its caption and portion, when it ends |
| `PluginInfoProvider.lua` | no | The Plug-in Manager section |
| `ImportFolder.lua`, `BuildSmartPreviews.lua`, `FetchSmartPreviews.lua`, `ServerStatus.lua`, `CheckServer.lua`, `Diagnostics*.lua` | no | The menu commands |
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
- Detecting an import as it happens: the SDK has no import event; the automatic send reads the catalog every 3
  seconds while photos come in, and takes an import as finished when no new photo has come for 2 minutes.
- Importing several folders in one go with **Import a folder without the dialog...** (one folder per run), or with
  settings other than those of the previous import.

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

Version 0.5.0, Lightroom Classic 15.6 on Windows, 2026-11-14: «Add a folder without previews...» ran once, on a test
catalog and a folder on a NAS reached over Wi-Fi with 1384 raw files and 1384 JPEGs, with «send afterwards». It was
removed in 0.6.0 (decision record 0007).

| What | Result |
|---|---|
| The menu item, `LrDialogs.runOpenPanel` with folders, the options dialog | worked |
| `LrFileUtils.files` and `LrFileUtils.directoryEntries` on the NAS folder | 68.7 s for 2768 entries each (about 12 ms per entry), processor idle, Lightroom's window not responding the whole time |
| `catalog:findPhotoByPath` for each of the 1384 raw files | 1.86 s in all |
| `catalog:addPhoto` inside `catalog:withWriteAccessDo` | about 37 s per photo (six photos in a bit over three minutes; 1384 would have taken about 14 hours), the window «Not responding» throughout; cancel only between batches of 50 |
| Where the time went | a stack of Lightroom's main thread, taken twice, was both times in Lightroom's own file-existence check (`FindFirstFileW` under `AgFileUtilsWin_fileExists`) called from the Lua runtime: plug-in tasks run on the main thread, and `addPhoto` checks the folder's files one by one on every call; `LrTasks.yield()` between files did not keep the window alive |
| A JPEG next to its raw file | recorded as the raw photo's sidecar (`sidecarExtensions` = `JPG`), as the import does |
| `LrDate.currentTime()` | has fractions of a second (the log's timings) |
| For comparison: Lightroom's import dialog on the same folder (Add, «Embedded & Sidecar») | 0.17 s per photo, window responsive |

Version 0.6.0, Lightroom Classic 15.6 on Windows, 2026-11-14: «Import a folder without the dialog...» ran once, on a
test catalog and a network folder with 1384 raw files and 1384 JPEGs (9 of the photos in the catalog already), with
«send afterwards». Its waiting and sending were removed in 0.7.0 (decision record 0007).

| What | Result |
|---|---|
| The menu item; `LrDialogs.runOpenPanel` with one folder; the dialog with the settings and the send checkbox | worked |
| Reading `Adobe_variablesTable` with sqlite3 while Lightroom has the catalog open | worked: the settings line in the log was right (`refInPlace`, `bthm`) |
| `catalog:triggerImportFromPathWithPreviousSettings` | returned after 0.16 s with `nil`; Lightroom then imported by itself, with its own two progress bars (import, initial previews) |
| How Lightroom imported | about 2 min 20 s before the first photo (its scan of the folder), then photos committed to the catalog in bursts of roughly a hundred every 22–26 s: 1375 photos in 288 s (0.21 s per photo). One `AgLibraryImport` row was created at the trigger and filled as it went |
| The JPEGs; the photos already in the catalog | the JPEGs were recorded as sidecars; the 9 photos were left alone |
| «Settled after 20 s without a new photo» | failed: it fired between two bursts, so the wait ended at 425 of 1384 photos and only those were sent |
| The send afterwards while Lightroom imported | `findPhotoByPath` for the 425 photos took 45.8 s and the whole preparation of the send 226 s |
| The plug-in's own progress bar | it moved weakly, it was unclear what it showed, and it looked useless next to Lightroom's two bars |
| Sub-folders of the chosen folder; whether the import uses exactly the settings the catalog records | not seen |

Version 0.7.0, Lightroom Classic 15.6 on Windows, 2026-11-14: one run end to end, a NAS folder with 1384 raw files,
started with «Import a folder without the dialog...» with the automatic send on.

| What | Result |
|---|---|
| The Help menu (`LrHelpMenuItems`); the settings upgrade that switched the automatic fetch on | worked |
| «Nothing pending for this catalog; the server is not asked» before anything was sent | worked |
| `catalog:triggerImportFromPathWithPreviousSettings` | returned after 0.17 s |
| The automatic send | three jobs; every photo sent |
| The automatic fetch | 1384 of 1384 smart previews placed and registered; no warning or error |
| How long | trigger at 15:15:55, everything done at 15:32:24: 16.5 minutes |
| Where the time went | at 15:19:06 the send saw the first 125 new photos and kept them for its next round (sent at 15:20:52); from 15:20:52 to 15:26:10 the one background loop sat in a fetch, 4.7 minutes before its `POST /lookup` (plug-in calls into the catalog are very slow while Lightroom imports), and no send round ran meanwhile; at 15:27:10 it saw the remaining 976 photos, kept them again, and sent 449 at 15:28:11 and 440 at 15:29:18 (500 per round, one round a minute) |

Version 0.8.0, Lightroom Classic 15.6 on Windows, 2026-11-14: an import of 1384 raw files from the NAS with «Import a
folder without the dialog...», the automatic send on, server 0.6.0.

| What | Result |
|---|---|
| The trigger; the first photos | the trigger returned in 0.04 s; the first photos were seen 2.5 minutes later |
| First seen in the catalog -> sent | median 0.1 s, max 0.3 s |
| Ready -> placed (waiting requests, placing without calls into the catalog) | median 2.5 s, max 7.7 s |
| Registration after the import | began 120 s after the last new photo; 3 minutes for 650 photos; no warning or error in the log |
| How often it looked while Lightroom imported | every 20-26 s, in step with Lightroom's bursts, not every 3 s |
| Photos sent | **650 of 1384; 737 were never looked at.** All 1384 are linked to the import (id 160795) and have one contiguous block of image ids, 163566-164949, but their rows became visible out of order (several places of the block at once). In id order, sent and missed runs alternate: sent 163566-163573, missed 163574-163665, sent 163666-163677, missed 163678-163765, … sent 164916-164949. The mark moved to the largest id seen and skipped everything that became visible below it later. 647 of the photos have a smart preview |
| Jobs | job 18 for the import, added to look by look, and ten small jobs «Lightroom import (automatic)» (2 to 13 photos): photos seen before their link to the import was there |
| A sqlite3 run that never came back | seen once that evening while Lightroom was busy removing 1384 photos: the `.sql` file was written, nothing more came from the plug-in until Lightroom was closed |

Version 0.8.1: nothing has been tried in Lightroom yet. It fixes the two faults above: the low-water mark with a set
of the photos dealt with, and photos waiting for their import link. In the stand-in run with an import that gives out
all ids at once and makes its rows visible out of order, eight places of the block at a time, with the links a burst
later, 0.8.0 sent 159 of 600 photos, partly into jobs of their own, and 0.8.1 sent all 600 once, into the one job of
the import. What to look at in Lightroom:

| What | Result |
|---|---|
| Every photo of an import sent, once, into one job; the log line when the mark moves (5 minutes after the last new photo) | not tried |
| The time between looks while Lightroom imports (in the look lines and at the end of the fast period) | not tried |
| The totals per job | not tried |
| The watchdog (a loop that took no step for 10 minutes) | not tried |
| Against a server before 0.6.0: new jobs per look, asking at the interval | not tried |

Version 0.8.2, Lightroom Classic 15.6 on Windows: an import of 1384 raw files from the NAS with «Import a folder
without the dialog...», the automatic send on, server 0.6.0.

| What | Result |
|---|---|
| Photos sent | all 1384, in one job |
| First seen in the catalog -> sent | median 0.1 s, max 17 s (photos waiting for their import link) |
| How often it looked while Lightroom imported | every 4 s on average, the longest gap 9 s |
| Downloads during the import | none; no warning in the log |
| Timeline | trigger 21:41:47; photos added 21:44:11-21:48:27; Lightroom's «Fetching Initial Previews» (quality `embedded` in the preview index) wrote from 21:44:15 to 21:51:52, 0.34 s per photo, 3.5 minutes longer than the adding; the plug-in judged the import over at 21:50:30 and began the fetch in one go; 836 of 1384 files placed by 21:52:24 (about 7 per second) |
| **The user closed Lightroom at 21:52:30, in the middle of the fetch** | nothing on the screen said that anything was still going on; he watched Lightroom's bar finish and took the import for done. So the registration call and the continuation at the next start were not reached in this run |
| The import confirmation and **Server status...** at a normal width | not tried |

Version 0.8.3, Lightroom Classic 15.6 on Windows: Lightroom started on the catalog whose fetch 0.8.2 had left
unfinished (job 29: 1384 photos, 836 files in place, none registered), the NAS asleep.

| What | Result |
|---|---|
| The server asleep at the start | `job 29: Cannot reach the server ... (cannotFindHost). (next try at 22:26)` at 22:25:08; the retry at 22:26:13 woke the NAS (`the server answers again`) |
| The mark | moved at the first look (`no new photo for 300 s and nothing waits; every photo up to catalog id 219546 is dealt with`), but that look had read the old import record above the old mark |
| **The fetch** | **nothing fetched**: the old record was taken for a new import (`looking every 3 s while photos come in`, `an import is in progress`), and the bar said `Waiting for Lightroom's import to end: 1384 ready on the server, 0 being built` for three minutes, although no import was running, until the user closed Lightroom at 22:29:07. The cause: WatchMode armed the five minutes of «waiting for the first photo» for every import record its run had not seen, and a new run had seen none |

Version 0.8.4: nothing has been tried in Lightroom yet. In the stand-in run of that session (1384 photos, 836 placed,
the import's record above the mark, the server away for the first minute): no import in progress, the 548 missing
downloads began within a few seconds of the server's first answer, the 836 in place were not downloaded again, one
registration call for all 1384, the bar `N of M fetched` from the start. What to look at in Lightroom: the same as for
0.8.3 below, and that a restart with files left over fetches at once.

Version 0.8.3, beyond the session above: in the stand-in run of an import of 600 photos whose stand-in preview task
ended 3 minutes after the last photo, the fetch began 0 to 10 s after that task ended, the bar showed a waiting
caption from the first photos on, then `N of 600 fetched`, and ended when all were in; a cancel of the bar paused the
fetch until the next start (which showed the bar again) or until **Fetch ready smart previews**. What to look at in
Lightroom:

| What | Result |
|---|---|
| The bar `LRRP: smart previews` in the activity area, its captions, its cancel button; that a bar without a function context shows and ends | not tried |
| The preview index read while Lightroom writes it: the log lines `the photos stopped coming` and `the previews stopped coming`, and the fetch beginning after «Fetching Initial Previews» ends | not tried |
| `catalog:buildSmartPreviews` for 1384 photos (exists, answers `existed`, one progress bar, how long it takes) | not tried |
| Quitting Lightroom during the fetch: at the next start the bar shows again, nothing placed is downloaded again, all registered | not tried |
