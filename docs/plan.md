# LR Remote Previews: plan from the minimum to an end-to-end product

What the plan stands on: [research/smart-previews.md](research/smart-previews.md). Why things are built this way: [adr/](adr/).
Written 2026-11-13; stage 0 started 2026-11-14.

## Goal

In Lightroom Classic the user selects photos and gives one command. A server next to the originals (a TrueNAS app)
builds their smart previews in the background and shows its state on a dashboard. On request Lightroom receives the
finished files. The catalog stays on the user's computer and is never written by us.

## What is already proven (Lightroom Classic 15.6, Adobe DNG Converter 17.2)

- A smart preview is a DNG 1.7 with lossy JPEG XL, 2560 px, stored as
  `<catalog> Smart Previews.lrdata\<U[0]>\<U[0..3]>\<U>.dng`, U = the file UUID from the catalog.
- Adobe DNG Converter makes that file (`-lossy -side 2560 -p0`); under Wine 8.0 in a container its image data is
  byte-identical to Lightroom's own, at 0.26–0.35 s per 24 MP photo on a 14-core desktop CPU.
- Lightroom takes a DNG that appears in the store, at catalog open and while running; `photo:buildSmartPreview()`
  then answers `'existed'`. No catalog write from outside is needed.
- Lightroom does not check the content: whatever lies under the UUID is used.
- The SDK does not give the file UUID; `sqlite3` read-only on the open catalog does.

## Decisions

| Topic | Decision |
|---|---|
| Kind of project | Open source, AGPL-3.0-or-later. The repository is public from the start |
| Names | Repository `lr-remote-previews`; the product is called «LR Remote Previews» |
| Parts | A Lightroom Classic plug-in, a server packaged for TrueNAS, a dashboard |
| Server stack | Python (FastAPI), dashboard in React + TypeScript + Vite |
| Adobe DNG Converter | Not stored, not downloaded, not distributed by the project. Users install it into the app themselves; we describe what the app expects and what we verified |
| Catalog | The plug-in reads the catalog in place, read-only, and never writes it itself. Lightroom changes it through its own plug-in interface on the user's command: registering a placed smart preview, and its own import of a folder started by «Import a folder without the dialog...» after the plug-in checked that the previous import was «Add» ([adr/0007](adr/0007-photos-added-through-lightroom-on-the-users-command.md)) |
| How a build starts | Selection in Lightroom; a folder picked on the dashboard; after an import in Lightroom; by itself for new files, only when a setting turns that on |
| Standard previews | Not built by the project. Measured (stage 6): an import with «Embedded & Sidecar» previews removes the wait for them, and nothing the server could render would look like Lightroom's own |

## Architecture

```
 Lightroom Classic (the user's computer)       Server (one container next to the originals)
 ┌────────────────────────────┐   HTTP + token   ┌──────────────────────────────────────┐
 │ plug-in (Lua)              │ ───────────────► │ API (Python, FastAPI)                │
 │  selection → eligible list │   jobs, status   │  queue + cache index (SQLite)        │
 │  file UUIDs ← sqlite3 (ro) │ ◄─────────────── │  workers → Adobe DNG Converter/Wine  │
 │  fetch DNG → check → store │   DNG files      │  cache of DNGs                       │
 │  buildSmartPreview()       │                  │  dashboard (static front end)        │
 └────────────────────────────┘                  │  originals mounted READ-ONLY         │
                                                 └──────────────────────────────────────┘
```

Rules the design keeps everywhere (see the decision records):

1. **The catalog is never written by us.** Registration is: file into the store, then `buildSmartPreview()`. Photos
   enter the catalog only through Lightroom's own import, on the user's command (0007).
2. **The originals are mounted read-only** in the container.
3. **The server knows nothing about catalogs.** It turns «file at this path» into a DNG and caches it under a key made
   of the source's identity (root, path, size, modification time). The same cache serves any catalog, any client, and
   builds started without Lightroom.
4. **A wrong file must not be possible.** Lightroom shows whatever is under the UUID, so the plug-in checks every DNG
   before placing it (original file name and original pixel size inside the DNG against the photo), writes under a
   temporary name and renames, and never overwrites an existing smart preview.
5. **Adobe's converter is not part of the repository or the image.**

## Stages

Each stage ends with something that works and can be used; later stages do not rework earlier ones.

### Stage 0. Foundations

- Repository with the layout below, licence, README, contribution notes, CI. Everything in it is in English.
- Decision records: registration by placing the file; read-only catalog access; cache key; converter not bundled;
  safety rules; stack and platforms.
- A skeleton of each part that builds, lints and tests: the server answers `GET /api/v1/info`, the dashboard shows it,
  the plug-in has its settings and a «Server status» command; the container image builds.
- The document about the converter: what the app expects, what was verified, the licence pointers.
- Test data: freely licensed raw samples only; no photographs of contributors or users in the repository.
- Done when: CI builds the image and the plug-in package and runs the tests of all three parts; this plan, the
  decision records and the research are in the repository.

### Stage 1. The minimum that works end to end

The thinnest path through every part, usable for real work.

- **Server:** the converter runner (4–6 processes, never `-mp`, never exactly 2, each batch in its own output folder,
  a failed batch retried file by file); a queue in SQLite; the cache; API to create a job from a list of files, read
  its state and download one DNG.
- **Plug-in:** the command «Build smart previews on the server» for the selection: keep raw photos without a smart
  preview whose path maps to a root, get the file UUIDs with `sqlite3` (read-only), send, show progress, download,
  check, place, `buildSmartPreview()`, show a summary; a log file.
- **State:** the dashboard's overview page shows the queue and the rate.
- **Deploy:** `docker compose` by hand.
- Done when, on the reference setup: 500 selected photos get smart previews with Lightroom usable meanwhile;
  Lightroom's own report confirms all of them; five files compared with Lightroom-built ones have identical image
  data; the server does at least 2 photos per second; the originals are mounted read-only.

### Stage 2. Background work and delivery on request

- **Server:** jobs survive a restart; states per file with reasons (unsupported format, file missing, converter
  failed); cancel and retry; a second request for a file already built costs nothing; a lookup that tells which of
  a list of files are already built, without building; jobs a client can find again by its own identifier; old jobs
  expire.
- **Plug-in:** «Send to the server» returns at once (Lightroom may be closed afterwards); «Fetch ready smart
  previews» for the selection or for everything this catalog sent, resumable, several downloads at once; the
  send-and-wait command stays; optional automatic fetch while Lightroom runs; a status dialog with retry and a link
  to the dashboard. (A download of many files in one stream was planned here; several downloads at once do the job
  without a new format. It comes back only if measurements ask for it.)
- Done when: 2000 photos are sent, Lightroom is closed, and the next day one command delivers all; an interrupted
  fetch continues; a server restart in the middle loses nothing.

### Stage 3. The TrueNAS application and the dashboard

- **Application:** a versioned image in a public registry; a compose file for TrueNAS «Install via YAML» with the
  Web UI button and an icon; volumes for the originals (read-only), the cache and the data; a non-root user with a
  configurable id; a health check.
- **Converter:** the dashboard shows whether the converter is found, its version, and runs a self-test; the guide
  explains how to place it.
- **Dashboard:** overview (converter state, queue, photos per minute, time left, cache size, CPU temperature if
  readable); jobs with progress, errors, cancel, retry; **folder browser that puts a folder into the queue**;
  settings (roots, number of processes, pause, working hours); log. Live updates.
- **Operations:** a «busy» signal other software can read, so that a NAS that sleeps when idle stays awake while the
  queue runs.
- Done when: on a clean TrueNAS the app is installed from the README alone, the converter is placed by the guide, a
  folder is queued on the dashboard, the progress is visible, and Lightroom fetches the result.

### Stage 4. Automation

- **New files by themselves, off by default:** per root, a periodic scan with a settle time (so half-copied files
  are left alone), limits and working hours.
- **After an import in Lightroom, optional:** the plug-in sends new photos that have no smart preview. The SDK has no
  import event; the way to detect new photos has to be found (**not known yet**).
- Jobs started from Lightroom go ahead of background ones. Cache clean-up by age, size and vanished originals.
- Done when: a shoot copied to the NAS has its DNGs in the cache within minutes with nobody asking, and after the
  import one «Fetch» delivers hundreds of smart previews in seconds.

### Stage 5. Ready for other people

- **Compatibility guard:** a self-test that compares the server's output with a smart preview Lightroom builds
  itself, run after an update of either side; the plug-in refuses to deliver when the check fails.
- **Tests:** unit tests of the server; integration tests with the real converter on sample raw files (run where a
  converter is available, never in public CI); tests of the plug-in's pure logic; a written end-to-end checklist.
- **Security:** token, path checks against escaping a root, notes on running it only inside the home network.
- **Documentation:** user guide, troubleshooting, limits; architecture and protocol.
- **Releases:** versions, change log, plug-in package and image published together; minimum-version check between
  plug-in and server.
- **macOS client:** the plug-in on macOS is untested; verify with someone who has one. Windows comes first.
- Optional: submission to the TrueNAS apps catalog.
- Done when: a person who has never seen the project installs and uses it from the documentation alone.

### Stage 6. Research tracks, no commitment

- **Standard previews: answered, nothing to build.** Measured with Lightroom Classic 15.6 and originals on a NAS:
  - «Build Standard-Sized Previews» reads the original whenever it is reachable, smart preview or not. With the
    originals unreachable Lightroom renders from the smart preview, but making them unreachable on purpose is not a
    workflow worth building.
  - The converter can embed a rendered preview of its own (`-p2`), but its rendering differs visibly from
    Lightroom's (darker, no lens corrections), and delivering it would mean writing Lightroom's preview database.
  - **An import with Build Previews: «Embedded & Sidecar» removes the need.** Lightroom shows the camera's own
    JPEG (a paired JPEG next to the raw file, else the one inside it) without rendering: 0.17 s per photo to add,
    0.34 s per photo for the previews, about 4 MB read per photo, and it keeps these previews while browsing; an
    original is read only at a 1:1 zoom. The guide describes this as the workflow to use (section 6).
  - Still open: whether Lightroom's «Use Smart Previews instead of Originals for image editing» keeps the Develop
    module off the originals in this workflow (one run without a restart of Lightroom still read them).
  - Answered: adding photos with the SDK's `catalog:addPhoto` instead of the import (plug-in 0.5.0) took about 37 s
    per photo on a NAS folder of 2768 files, with Lightroom's window frozen (decision record 0007).
  - Still open: the plug-in's «Import a folder without the dialog...» (plug-in 0.6.0) starts Lightroom's own import
    with the previous settings, without the dialog. How it behaves (whether the call returns at once, sub-folders,
    files already in the catalog) has not been seen yet.
- GPU for the converter in the container. The two CPU-wasting modes (`-mp`, exactly two processes). A newer Wine.
- Adobe's installer under Wine. Converters newer than 17.4, whose GPU switch changed. Passing `-dng1.7` explicitly,
  as Adobe's command-line examples for lossy JPEG XL do (we rely on the default).

## Repository layout

```
plugin/LRRemotePreviews.lrplugin/   Lua plug-in (commands, settings, pure-Lua helpers); plugin/spec = its tests
server/                             Python package `lrrp`: api, queue, workers, converter runner, cache; tests
web/                                dashboard (React + TypeScript + Vite), built into static files the server serves
deploy/                             Dockerfile, compose files
tools/                              dng_compare, plug-in packaging, benchmarks
docs/                               plan, decision records (adr/), research, guides
```

## Risks and unknowns

| Risk | What we do about it |
|---|---|
| Everything rests on undocumented Lightroom behaviour (taking a file that appears in the store) | The stage 5 self-test; a list of Lightroom versions it was verified on; no catalog writes of our own, so the worst case is «does not work», not a damaged catalog |
| Adobe's terms for the converter: no licence text naming it was found; Adobe's general software terms restrict hosting and remote access by third parties | The converter is never shipped; [converter.md](converter.md) reports what Adobe publishes without interpreting it; each user is responsible for complying |
| The converter's GPU switch (`TempDisableGPU2`) is documented by Adobe for Camera Raw 17.4 and earlier only; a newer converter may ignore it and abort under Wine | Verified converter versions are listed (17.2 so far); a newer one is tested before it is recommended; other ways to keep it off the GPU are a research track |
| Lightroom does not check the content of a smart preview | Checks in the plug-in before placing; identity-based cache key; tests for mix-ups |
| Only camera raw files can be converted | Other formats are reported as unsupported; Lightroom builds those itself |
| New cameras need a newer converter and profiles | Version shown on the dashboard; documented update |
| The converter under Wine: `-mp` and exactly two processes waste CPU, one missing input fails a whole batch | Encoded in the worker; covered by tests |
| Heat and noise on a small NAS (87–92 °C seen on the reference machine) | Number of processes, pause, working hours |
| A NAS that sleeps when idle | The «busy» signal (stage 3) |
| macOS client untested | Stage 5 |

## Order of work

Stage 0 and stage 1 first, because stage 1 already replaces the slow build. Stages 2–4 follow in the order above
(background, dashboard, automation). Stage 5 is the price of an open project and comes when the tool has been in real
use. Stage 6 runs in parallel whenever a question becomes important.
