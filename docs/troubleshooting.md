# Troubleshooting

Symptom, likely causes, what to check. The examples are the ones of the [user guide](guide.md): the originals are
`/path/to/originals` on the NAS, `Z:\` on the Lightroom computer and `/sources/archive` in the container; root id
`archive`; path mapping `Z:\` → `archive`; the server at `http://nas.local:8787`. Run `docker compose` commands in the
`deploy` folder of the repository on the NAS.

This page describes server 0.3.0 and plug-in 0.3.0. The 0.3.0 commands have not been run in Lightroom yet (see the
guide), so some of the plug-in messages below have only been seen in tests.

## Where to look

| Where | What it tells you | How |
|---|---|---|
| The summary dialog | What happened to the photos of one command, counted per outcome and reason, with the server's codes | Shown when a command ends |
| The plug-in's log | One line per photo, the `sqlite3` commands, what the server said, the automatic fetch | `LRRemotePreviews.log` in Lightroom's log folder. With Lightroom Classic 15.6 on Windows: `%LOCALAPPDATA%\Adobe\Lightroom\Logs\LrClassicLogs`. Older versions used an `LrClassicLogs` folder in your Documents folder. The folder on macOS is not known. The token is never logged |
| The server's log | Start-up, configuration errors, every wave of conversions, converter failures with the converter's last output, the warm-up | `docker compose logs --tail 200 lrrp`; add `-f` to follow it. Refused items (`rejected`) are not logged; ask the API for them |
| The dashboard | Whether the converter is installed, whether each root is available, the queue, processes busy, the rate, today's failures | `http://nas.local:8787/` (only the Overview page in 0.3.0) |
| The API | The items of a job with their paths and error messages | See below |

The items of a job with their errors (the job id is in the plug-in's log, `send: job 7 created with 40 item(s)`, in
the dialog after a send when it shows one, and in **Server status...**):

```sh
curl -H "Authorization: Bearer <token>" "http://nas.local:8787/api/v1/jobs?limit=5"
curl -H "Authorization: Bearer <token>" "http://nas.local:8787/api/v1/jobs/7/items?state=rejected"
curl -H "Authorization: Bearer <token>" "http://nas.local:8787/api/v1/jobs/7/items?state=failed"
```

Every item shows its `root`, its `path` (relative to the root, as the plug-in sent it) and `error.code` with
`error.message`.

## The server's codes

An item that the server did not accept is `rejected`; one it tried and could not build is `failed`. The plug-in shows
the codes in its summary (`The server refused them: 3 (not_found: 3)`) and in its log
(`IMG_0001.ARW: rejected (job 7, not_found)`).

| Code | Item | The server's message | Meaning |
|---|---|---|---|
| `unknown_root` | rejected | `The server has no root 'archive'` | The plug-in named a root id that is not in `roots.yaml` |
| `bad_path` | rejected | for example `The path leads outside its root` | The path is malformed, or it leads outside the root (also through a symbolic link) |
| `unsupported_format` | rejected | `'.jpg' files are not camera raw files this server builds` | Not one of the accepted raw extensions |
| `root_unavailable` | rejected | `The root 'archive' is not available` | The root's folder does not exist in the container |
| `not_found` | rejected | `No such file`, or `The file cannot be read` | Missing, or the server may not read it ([below](#every-item-or-many-items-are-not_found)) |
| `not_a_file` | rejected | `Not a regular file` | A folder or a special file |
| `converter_failed` | failed | for example `Adobe DNG Converter exited with code 3 when run with this file alone` | [below](#items-fail-with-converter_failed) |
| `converter_timeout` | failed | `Adobe DNG Converter did not finish within 90 s and was stopped when run with this file alone` | [below](#items-fail-with-converter_timeout) |
| `output_missing` | failed | `Adobe DNG Converter finished but wrote no DNG for this file` | [below](#items-fail-with-output_missing) |
| `output_mismatch` | failed | for example `The DNG names 'IMG_0002.ARW' as its original, not 'IMG_0001.ARW'` | [below](#items-fail-with-output_mismatch) |
| `source_changed` | failed | `The file changed or disappeared after it was requested` | [below](#items-fail-with-source_changed) |

Codes of whole requests, which the plug-in turns into its own messages:

| HTTP | Code | When |
|---|---|---|
| 401 | | No token (`Missing bearer token`) or a wrong one (`Invalid token`) |
| 404 | | Unknown job (`No such job`) or unknown path under `/api/` |
| 404 | `not_in_cache` | The DNG is no longer in the server's cache |
| 409 | `converter_not_installed` | A job needs builds, and the server has no converter |
| 409 | `not_ready` | A file was asked for before its item was ready |
| 409 | `job_cancelled` | A retry of a cancelled job |
| 413 | `too_many_items` | More than 5000 files in one job or lookup |
| 422 | `duplicate_ref`, or none | A malformed request |

## The plug-in cannot reach the server

Messages: `Cannot reach the server: <network error>.`, `The server did not answer.` Next to **Test connection**:
`Failed: server not reachable`. On the dashboard: «Server unreachable».

- **Is the server running?** `docker compose ps` should show the container as running and, after the start, healthy.
  If it is restarting, see [the server does not start](#the-server-does-not-start-or-restarts-again-and-again).
- **Does it answer?** Open `http://nas.local:8787/healthz` in a browser on the Lightroom computer. It should show
  `{"status":"ok"}`. If it does not, the name does not resolve (try the NAS's address instead of `nas.local`), the port
  is not 8787 (see `ports:` in `compose.yaml`), or a firewall is in the way.
- **Is the URL right?** The plug-in says so when it is not: `No server URL is set. Enter it in File > Plug-in Manager >
  LR Remote Previews.`, `The server URL must start with http:// or https:// and a host name, e.g.
  http://nas.local:8787 (got "…").`, or `The server URL must not contain spaces, "?" or "#" (got "…").` Next to
  **Test connection**: `Failed: no valid server URL`.
- **Is the NAS asleep?** The plug-in cannot wake it.

The plug-in waits 15 seconds for most answers, 60 seconds for a new job or a lookup, and 120 seconds for a download.

## The token is refused

| Message | Cause |
|---|---|
| `The server did not accept the access token (HTTP 401). Server says: Invalid token` | The token in the plug-in differs from `LRRP_TOKEN` on the server |
| `The server needs an access token (HTTP 401). Enter it in File > Plug-in Manager > LR Remote Previews. Server says: Missing bearer token` | The plug-in's **Access token:** field is empty |

Next to **Test connection**: `Failed: access token rejected`. The dashboard asks again: «The server did not accept the
saved token. Enter the current one.»

Compare the plug-in's field with `LRRP_TOKEN` in `deploy/.env`. After you change `.env`, run `docker compose up -d`:
it creates the container again with the new value (`docker compose restart` keeps the old environment). Spaces before
and after the token are ignored by the plug-in.

## The server answers, but not as expected

| Message in the plug-in | Likely cause |
|---|---|
| `The server answered HTTP 404. Check that the URL points to an LR Remote Previews server.` | Another program answers at that address, or the URL has a wrong path |
| `The server answer is not valid JSON (…).`, `The server answer is not an LR Remote Previews info document: ….` | Another web server or a proxy page answers at that address. **Test connection** says `Failed: not a valid answer` or `Failed: not an LR Remote Previews server` |
| `The server speaks API 2, this plug-in speaks API 1. Update the plug-in or the server.` | The plug-in and the server do not match; update both ([guide](guide.md#8-updating)) |
| `The server cannot look files up; it needs to be version 0.3.0 or newer.` | The server is older than the plug-in |

## The server does not start, or restarts again and again

`docker compose ps` shows the container restarting or unhealthy. `docker compose logs --tail 50 lrrp` tells why. The
messages:

| Message | What to do |
|---|---|
| `lrrp: configuration error: LRRP_CONFIG /config/roots.yaml: cannot read the file: …` | The roots file is not mounted, or it is not where `LRRP_CONFIG` says. Check the line `- ./roots.yaml:/config/roots.yaml:ro` and that `roots.yaml` exists next to `compose.yaml` |
| `… roots[0]: id 'Archive' is not valid; use 1 to 32 lower-case letters, digits, '-' or '_', starting with a letter or digit` | Fix the id in `roots.yaml`, and use the same id in the plug-in's mapping |
| `… roots[0] (archive): path 'sources/archive' must be absolute: …` | A root's `path` is the folder as the container sees it, starting with `/` |
| `… unknown key(s) …`, `… duplicate id …` | `roots.yaml` allows `id`, `path` and `label` per root, each id once |
| `LRRP_CACHE_DIR (/cache) is inside the root 'archive'; …` | A root contains the data or cache folder. Mount the originals elsewhere under `/sources` |
| `LRRP_WORKERS=2 is not allowed: …` | Use `auto`, 1, or 3 or more ([slow builds](#builds-are-slow)) |
| `LRRP_WORKERS must be 'auto' or a number, got …`, `LRRP_BATCH_SIZE must be between 1 and 64, got …` | Fix the value in `compose.yaml` |
| `entrypoint: /data is not writable by uid 1001:100; fix the owner of the volume` | The container runs as another uid than the owner of `/data` (or `/cache`). See «The user the server runs as» in the [guide](guide.md#34-the-user-the-server-runs-as) |
| `entrypoint: the Wine prefix /data/wine belongs to uid 1000, but the container runs as uid 1001; …` | The uid changed after the first start. Run as the old uid again, or remove `/data/wine` and put the converter in again |
| `entrypoint: creating the Wine prefix failed (exit code …)` | The first start could not create the Wine prefix. The lines before it are Wine's own output |
| `/data/lrrp.sqlite3 was written by a newer server (schema …, this one knows …)` | An older image was started on the data of a newer one. Start the newer image again |

The first start takes about a minute longer, because the Wine prefix is created; the health check allows three
minutes before it counts a failure.

## sqlite3 is not found or fails

**Check sqlite3** says `Not found`, or a command stops with:

```
No working sqlite3 tool was found. Tried:
next to the plug-in: <plug-in folder>\sqlite3.exe: no such file
sqlite3 on the PATH: exit code 1: …
```

followed by `Put sqlite3.exe (from sqlite.org, "sqlite-tools" for Windows) next to the plug-in's Info.lua, or set its
path in File > Plug-in Manager > LR Remote Previews.`

- Each line says where the plug-in looked and what happened. When **sqlite3 tool:** is filled in, only that path is
  tried, so a wrong path there hides a `sqlite3` on the PATH. Empty the field to let the plug-in look by itself.
- Use `sqlite3.exe` from the "sqlite-tools" archive for Windows at sqlite.org. Other programs bring their own
  `sqlite3`; one from Android's platform-tools (3.50.6) worked, but a very old one that does not know
  `.open --readonly` stops with an error, so that nothing is read.

A command stops with `Reading the file ids from the catalog failed: sqlite3 failed with exit code <n>: <first line of
its error output>`:

- The first line is `sqlite3`'s own message. The plug-in's log has the command line it ran (`sqlite3 command: …`).
- The plug-in opens the catalog read-only with a 5-second busy timeout. If Lightroom was busy writing the catalog for
  longer, try again.
- The plug-in writes a small script and the output to the system's temporary folder and deletes them afterwards. A
  message `cannot write the temporary file …` means that folder is not writable.

Photos left out with `Lightroom gave no catalog id`, `not found in the catalog database` or `the catalog database
names a different file`: the plug-in could not match the photo to a file id with certainty and left it out rather
than risk a wrong file. If that happens to every photo, the catalog tables may differ from what the plug-in expects:
see [after an update of Lightroom](#after-an-update-of-lightroom).

## No path mapping, or the root is not available

A command stops at once with one of these:

- `No path mapping is set up. Enter at least one local prefix and server root id in File > Plug-in Manager > LR Remote
  Previews.`
- `None of the server roots in the path mappings can be used: archive (not available).` or
  `… archive (not on this server).`

**Test connection** shows each mapping with the state of its root, for example
`Path mapping: Z:\ -> archive (on this server but not available)`, and names rows that are not usable:
`Path mapping 1: the server root id is empty.`, `… the local prefix is empty.`,
`… the server root id must not contain spaces or slashes.`,
`… the local prefix must be an absolute path, e.g. Z:\ or \\server\share\ or /Volumes/Photos.`

- **«not on this server»**: the server has no root with that id. Root ids are compared exactly; they are lower case.
  If the server lists no roots at all (`Roots: none` in **Test connection**, «No library roots are configured on the
  server» on the dashboard), `LRRP_CONFIG` is not set or the roots file has no entries.
- **«not available»**: the root's folder does not exist inside the container. The mount line in `compose.yaml` is
  missing, its target differs from the `path` in `roots.yaml`, or the folder on the NAS was not there when the
  container started. Check with `docker compose exec lrrp ls /sources/archive`.

Some photos left out with `not under any local prefix of the path mappings`: their paths start with none of your
prefixes. The plug-in's log names each path, for example
`IMG_0001.ARW: noMapping (no mapping covers \\nas.local\photos\2026\2026.06.20 - shoot\IMG_0001.ARW)`. If the catalog
knows some photos by a network path rather than by the drive letter, add that path as a second mapping to the same
root id.

## Every item, or many items, are `not_found`

The summary says, for example, `The server refused them: 40 (not_found: 40)`. The API shows each item's `path` and
the message `No such file` or `The file cannot be read`.

1. **The container's user cannot read the originals.** The server treats a file it may not read as missing. Check
   what the server's user sees:

   ```sh
   docker compose exec lrrp sh -c 'id; ls -ln "/sources/archive/2026/2026.06.20 - shoot" | head'
   ```

   `Permission denied`, or a folder that looks empty, means a wrong uid. Choose the user as in «The user the server
   runs as» in the [guide](guide.md#34-the-user-the-server-runs-as). When a job is created, the server only looks at
   each file's size and date; if it may enter the folders but not read the files, the job is accepted and the builds
   fail later instead (that follows from the code; not tried).
2. **The mapping and the mount name different folders.** The item's `path`, put after `/sources/archive/`, must be a
   file in the container. If `Z:\` on the Lightroom computer is, say, the folder `2026` on the NAS, but the container
   mounts its parent, every path lacks the `2026/` part. Make the local prefix and the mount name the same folder.
3. **The spelling differs in letter case.** The server's file system is case-sensitive; Windows is not. The plug-in
   sends the rest of the path exactly as the catalog spells it, so a catalog that says `img_0001.arw` for a file
   named `IMG_0001.ARW` works in Lightroom and fails on the server. Compare the item's `path` with
   `docker compose exec lrrp ls "/sources/archive/2026/2026.06.20 - shoot"`. Version 0.3.0 has no setting for this:
   the catalog's spelling must match the file system.
4. **The file is gone**: moved, renamed or deleted on the NAS after the import. Lightroom then shows it as missing
   too.
5. **Part of the originals lies on another file system** (on TrueNAS, a child dataset) that the container's mount
   does not include. See [truenas.md](truenas.md).

## `converter_not_installed`

**Build smart previews on the server** stops at once with `Adobe DNG Converter is not
installed on the server, so it cannot build smart previews. See the server documentation for how to install it.` If
the converter disappears between that check and the job, the job is refused: `The server cannot build smart previews:
Adobe DNG Converter is not installed there. The server answered HTTP 409. Server says: Adobe DNG Converter is not
installed on the server, so these files cannot be built`. The dashboard's DNG converter card says **Not installed**
and the Queue card «Converter missing». Fetching does not need the converter.

The server looks for `C:\Program Files\Adobe\Adobe DNG Converter\Adobe DNG Converter.exe` in its Wine prefix, which is
`/data/wine/drive_c/Program Files/Adobe/Adobe DNG Converter/Adobe DNG Converter.exe` in the container. Check:

```sh
docker compose exec lrrp ls -l "/data/wine/drive_c/Program Files/Adobe/Adobe DNG Converter/"
```

Common causes: one folder level too many (`…/Adobe DNG Converter/Adobe DNG Converter/…`); the files were copied into
another volume or folder than the one the container uses as `/data`; `LRRP_WINEPREFIX` or `LRRP_CONVERTER_EXE` set to
something else. The dashboard card shows the path the server expects. No restart is needed after a fix. The steps are
in [converter.md](converter.md).

## Items fail with `converter_failed`

The server's log has a line for every failed converter run, with the end of the converter's output:
`converter batch <name> (<files>) failed: Adobe DNG Converter exited with code <n>; last output: …`. A batch that
fails is run again one file at a time, so an item fails only when its file also failed alone.

**The first run in a fresh prefix.** The converter's first run in a new Wine prefix always fails with exit code 3,
and the server makes that run itself before its first build. It is normal to see this once:

```
Adobe DNG Converter has not run in this Wine prefix yet (no 'Camera Raw GPU Config.txt'); warming it up
warm-up done (the run exited with code 3)
```

It is a problem only when the file still does not appear. Then the log has
`Adobe DNG Converter could not initialise in its Wine prefix: the warm-up run exited with code <n>; <path>/Camera Raw
GPU Config.txt is still missing. Its last output: …`, and every item of that wave fails with `converter_failed` and
`Adobe DNG Converter could not initialise in its Wine prefix (…)`. The server tries the warm-up again before each
later wave while the file is missing. Look at the converter's output:

- `Special file 'TempDisableGPU2' found -- skipping GPU2` missing, and an assertion in `vkd3d`: the converter did not
  find the marker file. The container creates it at every start for its Wine user; restart the container
  (`docker compose restart lrrp`) and look again.
- The marker is found and it still aborts: a converter version that ignores the marker. Adobe documents the marker
  only for Camera Raw 17.4 and earlier; only 17.2 is verified. Go back to 17.2.
- Do not copy `Camera Raw GPU Config.txt` from another machine: it contains a digest of the machine it was written on.

**Other `converter_failed` messages:**

| Message | Likely cause |
|---|---|
| `Adobe DNG Converter exited with code 3 when run with this file alone`, output with a `vkd3d` assertion | The GPU marker, as above |
| `Adobe DNG Converter exited with code 1 when run with this file alone` | The converter answers 1 when an input file does not exist. A file it cannot read may look the same to it (not tried) |
| `Adobe DNG Converter exited with code <n> when run with this file alone`, other codes | Look at the converter's output in the server log, and convert the file by hand as in «How to check that the app sees it» in [converter.md](converter.md). A camera that is newer than the converter needs a newer converter |
| `Adobe DNG Converter could not be started: …` | Wine could not start the converter |
| `No X display could be started for Adobe DNG Converter (…)` | Xvfb did not start in the container |
| `The server could not store the DNG in its cache` | `/cache` is full or not writable; the log says `cannot store the DNG for … in the cache: …` |

After a fix, **Server status... > Retry** builds the failed items again.

## Items fail with `converter_timeout`

A converter run may take 60 seconds plus 30 seconds per file; a file run alone, 90 seconds. Longer, and only that
run's processes are stopped. The log says `converter batch <name> ran longer than <n> s; stopping its process group`.
Check whether the machine is overloaded or hot (fewer converter processes: [builds are slow](#builds-are-slow)), and
convert the file by hand as in [converter.md](converter.md) to see how long it takes alone.

## Items fail with `output_missing`

The converter finished without an error but wrote no DNG for the file, also when run with it alone. This was not seen
in our tests. Convert the file by hand as in [converter.md](converter.md) and look at its output; check that the
camera is supported by your converter version (Adobe's list of supported cameras is linked from converter.md).

## Items fail with `output_mismatch`

The converter wrote a DNG that does not name the requested file as its original, or one the server cannot read. The
DNG is thrown away, never cached and never delivered. This should not happen: the server never puts two files with the
same base name into one converter run. Report it with the server's log lines.

## Items fail with `source_changed`

`The file changed or disappeared after it was requested`: the file's size or modification time was different when
the server came to build it, or the file was gone. Causes: the file was still being copied to the NAS; it was renamed,
moved or deleted; a program rewrote it. For DNG originals, an application that saves metadata into the file changes
it; Lightroom does that for DNG files when it writes metadata to files (not tried with this project). Wait until the
file stays the same, then use **Server status... > Retry**: the server builds the file as it is now.

The same causes make a fetch of the selected photos say `Not on the server (never sent, or the original changed since;
send them again)`: the server keys every DNG by the file's size and modification time.

## Smart previews are placed but not shown

Go through these in order.

1. **What did the summary and the log say for the photo?**
   - `delivered (DNG 1.7.0.0, <path>)`: placed, and Lightroom answered «existed».
   - `deliveredOther (Lightroom answered '<answer>', <path>)` or `(buildSmartPreview raised an error: …)`: placed, but
     Lightroom did not confirm it. Note the answer; this was never seen with Lightroom Classic 15.6.
   - `destinationExists`: a file with that name was there already; see point 6.
   - `writeFailed (…)`: nothing was placed; the detail says why (for example a folder that cannot be created).
   - `checkFailed (…)`: nothing was placed; see [the next section](#discarded-the-file-did-not-pass-the-check).
2. **Is the file there?** The log line names it:
   `C:\Photos\Main\Main Smart Previews.lrdata\6\6282\62823DFE-E7D3-40FF-938C-518FDECC6CF6.dng`.
3. **What does Lightroom report?** Run **Help > Plug-in Extras > Diagnostics: smart preview report (all photos)**.
   It writes `smart-preview-report-<time>.txt` next to the catalog. An empty path for the photo means Lightroom sees
   no smart preview for it.
4. **Is it the right catalog?** The plug-in writes into `<catalog name> Smart Previews.lrdata` next to the catalog that
   is open. A copy of the catalog elsewhere has its own folder.
5. **Give Lightroom time, or restart it.** With Lightroom Classic 15.6, a file placed while Lightroom ran was listed
   94 seconds later without a restart, and every correctly named file was taken up when the catalog was opened.
6. **A file was already there, but Lightroom shows no smart preview**: the store has a file under that name that
   Lightroom does not count. The plug-in never replaces a file. What Lightroom does in that case was not tested;
   Lightroom's own **Library > Previews > Build Smart Previews** for that photo lets Lightroom deal with it (reading
   the original over the network).
7. **Another Lightroom version than 15.6?** See [after an update of Lightroom](#after-an-update-of-lightroom).

## Discarded: the file did not pass the check

Before it writes anything, the plug-in checks each downloaded DNG against the photo. A file that fails is thrown away
and never written; the log line says why:

| Reason in the log | Meaning |
|---|---|
| `the file has <n> bytes, the server announced <m>` | The download was cut short. Fetch again |
| `not a readable DNG (…)`, `the file has no DNGVersion tag`, `the DNG records no original file name` | The download is not the expected file. Fetch again; if it repeats, report it |
| `the DNG was made from "<name>", not from "<name>"` | The DNG belongs to another file. Report it with both names |
| `the DNG records an original size of <w>x<h>, the photo is <w>x<h>` | The original pixel size in the DNG differs from the size Lightroom gives for the photo. With Lightroom Classic 15.6 they matched for all 157 photos of the test catalog (Sony ARW); other cameras are not verified. If it happens to every photo of one camera, report it with the camera model |

## A fetch says nothing is ready

| Message | Cause, and what to do |
|---|---|
| `This catalog has not sent anything to the server yet (only jobs sent by plug-in 0.3.0 or newer are marked as this catalog's).` | Jobs sent by plug-in 0.2.0 or by `tools/submit_job.py` belong to no catalog. Fetch **Selected photos** instead |
| `Nothing new to fetch.` | Everything this catalog sent was fetched already, or nothing is ready yet. The note `On the server: <n> photo(s) of this catalog queued or being built, <m> failed (Server status can retry failed ones).` tells which |
| `Still being built on the server` | Wait, and fetch again |
| `Not on the server (never sent, or the original changed since; send them again)` | The server has no DNG for the file as it is now. It was never sent, it was sent under another root or path, or the file changed since ([source_changed](#items-fail-with-source_changed)). Send it again |
| `Left out` with `already have a smart preview` | Nothing to do: those photos have one |
| `Smart previews are already being fetched by the automatic fetch. Try again when it has finished.` | Only one fetch runs at a time. A lock left behind when Lightroom closed in the middle of a fetch frees itself within 3 minutes |

Also:

- A catalog that was moved or renamed gets a new identity and no longer finds its old jobs. Fetch **Selected photos**.
- The server deletes jobs 30 days after they finished. Their DNGs stay in the cache: **Selected photos** still finds
  them.
- Only the newest 200 jobs of a catalog are looked at.
- **Server status...** (Help > Plug-in Extras) says how many smart previews are ready and not fetched by this catalog
  yet.
- **The automatic fetch brings nothing**: it asks the server only for jobs it waits for (sent by plug-in 0.7.0 or
  newer from this catalog, at most 7 days ago, not yet done). The log says `automatic fetch: nothing pending for this
  catalog; the server is not asked` when there is none. Older jobs: **Fetch ready smart previews**.
- **Nothing arrives while Lightroom imports** (plug-in 0.8.2): on purpose. While an import is in progress the
  automatic fetch only sends; when no new photo has come for 2 minutes and (since 0.8.3) Lightroom's own previews of
  them have stopped coming (at most 15 minutes later), it fetches everything ready in one go (log: `the photos stopped
  coming`, `the previews stopped coming: ...`, `the import is taken as over`, then `the fetch in one go is done: ...`).
- **The automatic fetch stopped after its progress bar was cancelled** (0.8.3): on purpose; the log says `paused,
  because its progress bar was cancelled`. Run **Fetch ready smart previews**, or start Lightroom again.
- **Smart previews are placed but Lightroom does not show them yet**: the automatic fetch places the files first (log:
  `placed (...; not registered yet)`) and then asks Lightroom to register them, since 0.8.2 with one call for all (log:
  `one registration call (catalog:buildSmartPreviews) for ... photo(s) took ...`, then `registered (...)` per photo).
  Lightroom does not take such files by itself; **Server status...** says how many wait. When the progress bar of that
  call was cancelled, the rest is registered after the next fetch in one go or at the next start of Lightroom.
- **Lightroom was closed, or the NAS went to sleep, in the middle of a fetch**: nothing needs to be done. At the next
  start (or when the server answers again) the fetch goes on with what is missing, does not download again what is
  already placed, and registers what was placed.
- **The log says `a waiting request for job 12 ran out of time on this side`**: LrHttp gave up before the server
  answered (`timedOut`). The plug-in then asks the server to wait half as long, down to 5 seconds; it is not an error.

## Builds are slow

**Measure first.** The dashboard's Queue card shows «Processes busy» out of the configured number and the «Rate» over
the last 60 seconds. The server's log has one line per wave, for example
`wave: 32 file(s) in 4 converter process(es), 32 built, 0 to retry, 10.3 s`: here 0.32 s per file. For comparison,
the reference setup (24 MP raw files, a 14-core, 20-thread desktop CPU) did 0.26–0.35 s per photo with 4 to 6
processes and 0.41–0.42 s with one. A smaller CPU is slower; how much has not been measured.

- **The number of converter processes** is `LRRP_WORKERS`. `auto` takes 6 with 16 or more CPU threads, 4 with 8 or
  more, 3 with 6 or more, else 1, counting the threads the container may run on. A CPU limit set as a quota (for
  example Compose's `cpus:`) does not change that count; then set a number yourself.
- **Never 2.** Two converter processes side by side take twice the CPU time per photo (measured: 0.67–0.76 s per
  photo; the cause is unknown). The server refuses `LRRP_WORKERS=2` and never runs exactly two at a time: a wave of
  two files runs in one process.
- **Never `-mp`.** The converter's own option for parallel work made it take 1.3–1.5 s per photo. The server never
  passes it; do not add it when you try the converter by hand.
- **Heat.** The reference machine reached 87–92 °C. Fewer processes mean less heat and noise and slower builds.
  Pausing and working hours come with stage 3.
- **Failures cost time.** A batch that fails is run again one file at a time. Look at «failed» under «Today» on the
  dashboard and at the server's log.
- **The first build in a new installation** includes the converter's warm-up run.
- `LRRP_BATCH_SIZE` (files per converter run, default 8): the measurements used 8; other values are untested.
- **On the Lightroom side**, smart previews are checked, written and registered one at a time; plug-in 0.2.0 placed
  157 in 30 seconds. **Downloads at once:** sets how many are downloaded at the same time.

After you change `LRRP_WORKERS` or `LRRP_BATCH_SIZE` in `compose.yaml`, run `docker compose up -d`.

## The NAS goes to sleep in the middle of a queue

- **Nothing is lost by a restart.** Jobs and items are kept in the server's database; after a restart, the items that
  were being built go back into the queue and are built again (tested). What happens to a converter run during a
  sleep of the machine has not been tested.
- **The automatic fetch** logs `… (next try at 14:05)` and waits 1, 2, 5, 10, 30 minutes, then an hour between tries;
  it shows no dialog. With nothing pending it makes no request at all, so it neither wakes a sleeping NAS nor keeps
  it awake. While a job is pending (since plug-in 0.8.0 with server 0.6.0) one request per job stays open on the
  server, which keeps a NAS awake that sleeps only when no connection is open.
- **Keeping the NAS awake.** Server 0.3.0 has no signal for that. Stage 3 adds `"busy": true` to `GET /healthz` while
  the queue runs. Until then the dashboard's Queue card says «Working» or «Idle», and `GET /api/v1/status` (with the
  token) has the counts `queue.queued` and `queue.building`; keep the NAS awake by its own means while they are not 0.

## Import a folder without the dialog

The command ran in Lightroom with plug-ins 0.6.0 and 0.7.0. Its log lines start with `import folder:`; they record
the settings of the previous import, the automatic send's setting, when Lightroom's import was started and when the
call returned. The command does not wait for the import: Lightroom imports with its own progress bars, and the
automatic send, if it is on, reads the catalog every 3 seconds and sends each burst of new photos as it comes, all
into one job for the import (log: `automatic send: looking every 3 s while photos come in`).

- **It refuses to start: «The previous import in this catalog was not «Add»»** (or «… made a second copy», «… no
  record of a previous import», «… incomplete»). The command starts Lightroom's import with the settings of the
  previous one and refuses anything that could copy or move files. Import one folder through Lightroom's own dialog
  with **Add** (and without «Make a Second Copy To»), then use the command again. The log line `import folder: …;
  previous import: …` lists every setting it read.
- **It refuses: «cannot read how the previous import … was set up»**: sqlite3 was not found or the catalog could not
  be read; see «sqlite3 is not found or fails» above. Without that check the plug-in starts no import.
- **«The settings of the previous import changed since the dialog»**: an import ran between the dialog and the start.
  Run the command again.
- **Nothing seems to happen after the notice**: in the one run, Lightroom scanned a network folder of 2768 files for
  about 2 min 20 s before the first photo appeared, then added them in bursts of about a hundred every 22–26 s. Look
  at Lightroom's own progress at the top left.
- **Only part of an import was sent (plug-in 0.8.0)**: 0.8.0 moved its mark past photos whose rows Lightroom made
  visible later; in its run 737 of 1384 photos were never sent. 0.8.1 fixes this, but does not go back to them. To
  repair: select the photos of the import (the Catalog panel's **Previous Import**, or the folder) and run **Build
  smart previews on the server**. Photos that already have a smart preview are left out, the others are sent in one
  job, and the automatic fetch places them.
- **The log says `the loop has taken no step for 10 minutes …; starting a new one`**: a call into Lightroom, for
  example a sqlite3 run, did not come back (seen once while Lightroom was busy removing many photos). The new loop
  carries on; nothing needs to be done. sqlite3 runs that take 10 seconds or more are logged as such.
- **Imported, but not sent to the server**: the automatic send was off, or the line under the checkbox named a reason
  (no server set up, the folder under no path mapping). The automatic send's log lines start with `automatic send:`
  and say what it sent and what it left out, and why. Select the photos and use **Build smart previews on the server**.

## After an update of Lightroom

The project depends on behaviour Adobe does not document: where Lightroom keeps smart previews and how it names them,
that it takes a file placed there, and the catalog tables the plug-in reads. It is verified with Lightroom Classic 15.6
only. Signs that an update changed something:

- `Placed, but Lightroom did not answer "existed"` for every photo;
- the diagnostics report shows no smart preview for photos that got one;
- every photo left out with `not found in the catalog database` or `the catalog database names a different file`;
- `Reading the file ids from the catalog failed: sqlite3 failed with exit code …` where it worked before.

Stop fetching into catalogs you care about, run the checks of «After an update of Lightroom» in the
[guide](guide.md#8-updating) on a test catalog, and report the result with the Lightroom version. The plug-in never
writes to the catalog itself, so the expected worst case is smart previews that are not picked up; the files the
plug-in placed are named in its log.

## After an update of the converter

- **Every build fails with `converter_failed`**, exit code 3 and a `vkd3d` assertion in the output: the new version
  probably ignores the `TempDisableGPU2` marker. Put the copy of the old folders back. Only 17.2 is verified.
- **The output may differ** from what Lightroom builds. Compare one file as in [tools/README.md](../tools/README.md)
  before you rely on it.
- **DNGs already in the cache are not built again**: the cache key contains the converter's options, not its version.
  Version 0.3.0 has no command to rebuild them.
- The dashboard shows the converter's version as «Unknown» in 0.3.0.

## When you report a problem

Collect the versions (the server's from the dashboard, the plug-in's from the Plug-in Manager, Lightroom's, the
converter's), the text of the summary, the plug-in's log lines of that run and the server's log
(`docker compose logs --since 1h lrrp`). Both logs contain file names and paths, and the plug-in's log the server's
address; remove what you do not want to share. The plug-in never logs the token.
