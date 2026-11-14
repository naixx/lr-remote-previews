# LR Remote Previews server

The server part of LR Remote Previews: a FastAPI application (Python package `lrrp`) that runs next to the photo
originals, answers the plug-in and the dashboard, and serves the built dashboard. It takes jobs (lists of raw files),
builds their smart preview DNGs with Adobe DNG Converter under Wine in the background, keeps them in a cache and
serves them, by job or by a lookup that needs no job (stages 1 and 2 of the [plan](../docs/plan.md)). For the
dashboard (stage 3) it also reports its state, takes settings that change while it runs (processes, batch size, pause,
working hours), browses the roots and queues whole folders, tests the converter step by step and keeps its recent log.
For automation (stage 4) jobs have a priority (`normal` jobs are built before `background` ones), an optional
automatic scan queues new raw files by itself, and a clean-up keeps the cache within limits of age and size and drops
the DNGs of originals that are gone or changed. Since 0.6.0 a job can grow (items are added to a job that exists, so
that one Lightroom import is one job), and a client can wait for a change of a job instead of asking again and again.

In production it runs in the container built from [`deploy/`](../deploy/). This page is about running it from source.

## Run locally

Python 3.11 or newer.

```sh
cd server
python -m venv .venv
. .venv/bin/activate            # Windows: .venv\Scripts\activate
pip install -e ".[dev]"
LRRP_DATA_DIR=/tmp/lrrp/data LRRP_CACHE_DIR=/tmp/lrrp/cache LRRP_WEB_DIR=../web/dist python -m lrrp
```

The server listens on `0.0.0.0:8787`; open `http://localhost:8787/`. Without a built dashboard, `/` answers with a
short text. Outside the container there is no Wine prefix, so `converter.installed` is `false` and a job whose files
would have to be built is refused with `409 converter_not_installed`; jobs whose items are all rejected or cached
still work.

On Windows, set the variables with `set NAME=value` (cmd) or `$env:NAME = "value"` (PowerShell) before
`python -m lrrp`.

## Test

The same commands CI runs, from `server/`:

```sh
ruff check .
ruff format --check .
pytest
```

The tests need neither Wine nor Xvfb. `tests/fake_converter.py` stands in for Adobe DNG Converter: it takes the same
command line (`-lossy -side 2560 -p0 -d Z:\out Z:\in\x.ARW ...`), writes a small DNG with the identity tags for each
input, exits with code 1 when an input is missing, and can be told through environment variables to fail a file,
skip an output, hang, record a wrong original name, behave like a fresh Wine prefix, or record how many copies of
itself run at the same time. Through files in a switches folder a test can change that behaviour while the server
runs, and hold the runs of chosen files until it lets them go (`Harness.switch`, `Harness.hold`). The end-to-end
tests drive the HTTP API with it, including restarts of the server in the middle of a job. The tests of waiting
requests also serve the application with uvicorn on a local port (`tests/test_wait.py`), for what only a real server
shows: a hundred clients waiting at once, a client that goes away, a stop; they wait for evidence that a request is
asleep (`Waits.waiting`) before they change anything. The server's wall clock is
injectable (`create_app(clock=...)`, `conftest.FakeClock`), so the tests of the automatic scan, the last uses of
cached DNGs and the daily clean-up move time by hours and days without waiting; the background threads' polling
interval is shortened for them (`autoscan.POLL`, `cleanup.POLL`), and they wait for evidence that a thread has looked
at the clock (`AutoScanner.checks`, `CacheCleaner.checks`) rather than for a fixed time.

## Settings

Environment variables. An empty variable counts as unset.

| Variable | Default | Meaning |
|---|---|---|
| `LRRP_HOST` | `0.0.0.0` | Address to listen on |
| `LRRP_PORT` | `8787` | Port to listen on |
| `LRRP_TOKEN` | unset | When set, every request under `/api/` needs `Authorization: Bearer <token>`. When unset, the API is open (`"auth": "none"`); use that for development only |
| `LRRP_CONFIG` | unset | YAML file with the roots (below) |
| `LRRP_DATA_DIR` | `/data` | The server's state: the database `lrrp.sqlite3` (jobs, items, cache index) and, by default, the Wine prefix |
| `LRRP_CACHE_DIR` | `/cache` | Built smart previews, and the converter's temporary batch folders in `work/` |
| `LRRP_WEB_DIR` | `/app/web` | The built dashboard (`web/dist`) |
| `LRRP_WINEPREFIX` | `<LRRP_DATA_DIR>/wine` | The Wine prefix the converter is installed into |
| `LRRP_CONVERTER_EXE` | `C:\Program Files\Adobe\Adobe DNG Converter\Adobe DNG Converter.exe` | The converter, as a Windows path inside the Wine prefix |
| `LRRP_WORKERS` | `auto` | First value of the `workers` setting (below): converter processes run side by side, `auto` or 1 to 32. `auto` is 6 with 16 or more CPU threads, 4 with 8 or more, 3 with 6 or more, else 1. **2 is refused**: two converter processes side by side take twice the CPU time per photo (measured; the cause is unknown) |
| `LRRP_BATCH_SIZE` | `8` | First value of the `batchSize` setting: files given to one converter process at a time, 1 to 64 |
| `LRRP_JOB_RETENTION_DAYS` | `30` | Days a job is kept after it finished (or was cancelled), a whole number of at least 1. Its DNGs stay in the cache |

The converter is found when that Windows path exists in the prefix: `C:\x\y` is looked up as
`<LRRP_WINEPREFIX>/drive_c/x/y`. Adobe DNG Converter is not part of this project; see
[docs/converter.md](../docs/converter.md).

`LRRP_DATA_DIR` and `LRRP_CACHE_DIR` must not lie inside a root: the server writes there, and it never writes under a
root of originals.

### Settings that change while the server runs

`GET`/`PATCH /api/v1/settings` (the dashboard's settings page):

| Setting | First value | Meaning |
|---|---|---|
| `workers` | `LRRP_WORKERS` | `"auto"` or 1 to 32, never 2; `effectiveWorkers` in the answer is what it comes to here |
| `batchSize` | `LRRP_BATCH_SIZE` | 1 to 64 |
| `paused` | `false` | No new wave starts; a wave that runs finishes |
| `workingHours` | off, 22:00 to 07:00 | `{"enabled", "from", "to"}`: waves start only from `from` up to `to` (`HH:MM`, the server's local time; `from` later than `to` crosses midnight; `from` equal to `to` is refused) |
| `autoScan` | off, no roots, 60, 15, 2000 | `{"enabled", "roots", "intervalMinutes", "settleMinutes", "maxFilesPerRun"}`: the automatic scan (below). `roots` are root ids the server has (an unknown one is refused; one named twice counts once); `intervalMinutes` 5 to 1440, `settleMinutes` 0 to 1440, `maxFilesPerRun` 1 to 50000 |
| `cache` | no limits | `{"maxBytes", "maxAgeDays"}`: limits of the cache clean-up (below). `maxBytes` `null` or at least 104857600 (100 MiB); `maxAgeDays` `null` or 1 to 3650 |

A value changed through the API is kept in the database and wins over the environment from then on, across
restarts; a value never changed follows the environment. A change applies from the next wave on. The scheduler looks
at the pause and the working hours before every wave, and at least every 10 seconds while it may not start one, so the
window opens within 10 seconds of its time. In a container the local time is the container's: set `TZ` (and have the
time zone data in the image) for working hours in local time; without it they are UTC. `workingHours`, `autoScan` and
`cache` are each given as a whole object. A root that has been taken out of `LRRP_CONFIG` since `autoScan.roots` was
saved is dropped from it at start, with a warning.

### Roots

The roots are the folders with originals, as the server (the container) sees them. They are listed in the YAML file
named by `LRRP_CONFIG`:

```yaml
roots:
  - id: archive            # how clients name the root
    path: /sources/archive # server-side path; never sent to clients
    label: Archive         # optional, defaults to the id
  - id: scans
    path: /sources/scans
```

An `id` is 1 to 32 lower-case letters, digits, `-` or `_`, starting with a letter or digit, and unique. A `path` is
absolute. Unknown keys, duplicate ids and bad values stop the server at start with a message that names the file and
the entry.

## How the queue works

- **A job** is checked item by item when it is created: a path that is malformed, leads outside its root (symbolic
  links included), is not a raw file, is missing or is not a regular file is `rejected`; a file whose DNG is in the
  cache is `ready` at once; the rest are `queued`. Originals are only ever `stat`ed and read by the converter.
- **The cache key** is a SHA-256 over the root id, the relative path, the file size, the modification time in
  nanoseconds and the converter options. A changed original gets a new key; so do new options. DNGs are stored as
  `<LRRP_CACHE_DIR>/<key[0:2]>/<key>.dng`, renamed into place from the batch folder (same file system), and indexed in
  the database with their size, SHA-256 and the original name and size the DNG records.
- **Priority.** A job is `normal` (the default) or `background`. Every queued file of `normal` jobs is taken before
  any of `background` jobs, and within a priority the oldest job first, each job's items in the order they were
  requested (items added to a job later come after its earlier ones, and before the items of newer jobs). A file that
  jobs of both priorities want is built once, as `normal`. A wave that runs is not interrupted when a `normal` job
  arrives; the next wave takes it first. The automatic scan makes `background` jobs. Choosing the files of a wave reads
  the queued items job by job, oldest job first, and stops when the wave is full, so it reads about as many items as
  the wave takes however long the queue is (0.4 ms with 120 000 queued items in a measurement; the single query of
  0.4.0 took about 90 ms).
- **Adding items to a job** (`POST /api/v1/jobs/{id}/items`) checks each file exactly as a new job does (rejected,
  ready from the cache, or queued); the added items get the next values of the job's `seq`, in request order, in one
  transaction. A `done` job with a queued item among them becomes `active` again (`finished` back to `null`) and is
  `done` again, with a new `finished`, when they are built, so the retention counts from then; items that need no
  build leave a `done` job as it was. The scheduler is woken at once, as for a new job. The refusals (no such job,
  `job_cancelled`, a `ref` the job has, more than `maxItemsPerJob` items in all) are checked first and once more in
  the transaction that adds the items, so a job deleted, cancelled or added to meanwhile cannot slip through. A file
  that another item is queued or building for is built once for all of them.
- **Waiting for a change** (`wait` of `GET /api/v1/jobs/{id}/items`, up to 55 s). A waiting request holds no thread:
  its handler is a coroutine on the event loop that sleeps until the store reports a committed change of its job
  (`src/lrrp/waits.py`). The store reports which jobs a transaction changed and the states their items went to; only
  the requests that care are woken (one that asks for `state=ready` is not woken when items become `building`), each
  looks at the database again and answers if the look finds something, else sleeps again. The looks of all waiting
  requests run in a pool of 4 threads of their own, so waiting requests never take the worker threads the other
  calls run in; a waiting request costs a connection, a small coroutine and a task that notices when the client goes
  away (the request then ends at once). A request registers before its first look and forgets earlier wake-ups
  before each look, and the store reports a change only after it is committed, so a change between a look and the
  sleep is never missed. When the server stops, every waiting request answers at once as if its time were up (`200`
  with what there is): `python -m lrrp` runs uvicorn with a server class that does this when the shutdown begins,
  because uvicorn by itself lets open requests finish first and a stop could take 55 s.
- **One scheduler thread** works in waves. Before each wave it reads the settings above: paused or outside the
  working hours, it starts none. It takes up to `workers × batchSize` distinct files from the head
  of the queue (two jobs that ask for the same file share one build), picks the number of converter processes for the
  wave (as many as needed, at most `workers`, and three instead of two, or one when there are only two files),
  splits the files evenly so that no batch holds two files with the same base name, checks every source again
  (changed or gone: `source_changed`), starts all processes together, each in its own output folder and process
  group, and waits for all of them before the next wave. So the number of converter processes running at the same
  time is 1 or at least 3, never 2.
- **Checks and retries.** A DNG is used only if its `OriginalRawFileName` is the requested file's name (else
  `output_mismatch`, not retried, not cached). A batch that exits with an error or runs too long (60 s + 30 s per
  file; only that converter's process group is killed), and every file a successful batch left without an output,
  run once more one file per process; what fails again is `converter_failed`, `converter_timeout` or
  `output_missing`.
- **Before the first wave** the server starts one Xvfb for the converter (displays from `:99` up), starts a persistent
  `wineserver` outside every batch's process group, and, if the converter has never run in the prefix (no
  `Camera Raw GPU Config.txt` next to the `TempDisableGPU2` marker), warms the prefix up with one run on an input that
  does not exist: the first run in a fresh prefix always aborts. If the file still does not appear, the wave's items
  fail with `converter_failed` and the converter's last output.
- **A restart** puts items that were `building` back into the queue (a state change, so pollers see it) and builds
  them again: only the files of the interrupted wave run twice. Jobs, items and the per-job `seq` live in the
  database, so a client that polls with the `since` it had before the restart still gets every change. Cancelling a
  job cancels its queued items; items already building finish and stay in the cache.
- **Retry** puts the failed items of a job back into the queue and makes the job active again. Each file is checked
  again as it is now, so an item that failed with `source_changed` is built from the changed file; a file that is
  gone or no longer acceptable fails again with `source_changed`.
- **A lookup** answers, for a list of files, whether the DNG of each file as it is now (same size and modification
  time) is in the cache, is on its way (an item of any job is queued or building for it), or neither. It stores and
  queues nothing. Each file costs one `stat` (the real paths of the root and of each folder are looked up once per
  request), the cache index and the queue are asked in batches, and a cached DNG is `stat`ed to make sure it is
  still there.
- **Job retention.** At start and then once a day the scheduler deletes the jobs (with their items) that finished
  or were cancelled more than `LRRP_JOB_RETENTION_DAYS` days ago; a cancelled job whose last items are still
  building waits for them. The cache and its index are not touched, so the DNGs stay available through a lookup or
  a new job, and their keys stay valid. Job ids are never reused.
- **The automatic scan** (off by default) runs in its own thread, `intervalMinutes` after the last scan finished (at
  once when there has been none, for example right after it is switched on), and whenever
  `POST /api/v1/autoscan/run` asks (also while it is off). It walks the roots of `autoScan.roots` (or those the
  call names) by the folder rules below, and queues every raw file that has no entry in the cache index, is not
  queued or building in any job, was modified at least `settleMinutes` ago, and did not fail in an earlier automatic
  job as it is now. A file that fails in an automatic job is remembered by its cache key, so it is queued again once
  it changes (its size or time); a failure that is not the file's (the converter cannot start, the DNG cannot be
  stored, the source changed during the build) is not remembered, and a later success (a retry, another job) clears
  the record. At most `maxFilesPerRun` files are queued per run, oldest folders first: a folder's age is the
  modification time of its oldest raw file, so a late addition or a sidecar file does not move it back. The rest wait
  for the next run. The files go into jobs of `maxItemsPerJob` items per root, client `auto-scan`, priority
  `background`, label `Automatic scan: <root id>`. A root that is unavailable is skipped with a log line. While the
  converter is not installed no periodic scan runs; it is tried again an interval later. The last scan's time and
  count are kept in the database, so a restart neither forgets them nor scans again before the interval is over.
  Scanning does not depend on `paused` or the working hours; building what it queued does. **Cost:** one directory
  listing per folder and one `stat` per raw file (the `stat` comes with the listing where the platform gives it);
  the cache index, the queue and the remembered failures are asked about 500 files per query, in batches of about
  5000 files, and the database lock is held only for those queries and for the creation of each job. Only the files
  chosen so far are kept in memory: at most `maxFilesPerRun` plus the files of one folder. The scan trusts the
  cache index (it does not look at the DNG files); the clean-up keeps the index right.
- **Last use of a cached DNG.** Building it, finding it for a job (at creation or when its wave begins), finding it
  by a lookup and downloading it (by item or by key) count as uses. The time is written only when the recorded one is
  a day old or more, so a use usually costs no write. Browsing and the automatic scan do not count.
- **The cache clean-up** removes, in this order: DNGs whose original is gone or has changed (size or modification
  time); DNGs not used for `cache.maxAgeDays` days; the least recently used DNGs until the index adds up to no more
  than `cache.maxBytes`. The last two steps are skipped while their limit is `null`. A DNG that an item of an active
  job points to is never removed: that check, deleting the file and deleting the index row happen together under the
  database lock (a file or row that is already gone is fine), and a job created at the same moment with an item that
  was found in the cache gets it queued instead if the entry has just been removed. An original is not treated as
  gone when its root is unavailable, no longer configured, or an empty folder (an unmounted volume often leaves an
  empty mount point), or when it cannot be `stat`ed for another reason than its absence. Entries of a server before
  0.5.0 whose jobs had expired do not know their original and are only subject to the age and size limits. The same
  pass drops index rows whose DNG file is missing (logged, not counted). `bytesFreed` is the size the index recorded
  for the removed DNGs. A ready item of a finished job whose DNG was removed stays `ready` with `result: null`; its
  download answers `404 not_in_cache`, and a lookup of the file says `absent`. The server runs a clean-up a day after
  the last one (one through the API counts; a dry run does not), and a day after its first start without a record of
  one; the due time is kept in the database. `POST /api/v1/cache/clean` runs in the request, so the answer can take a
  while on a large cache: one `stat` per entry that knows its original, one listing per cache folder (256), the index
  read and changed 500 entries at a time.
- **A folder** queued from the dashboard becomes one job per `maxItemsPerJob` raw files (client `dashboard`), at most
  50000 files at once. The walk never follows a symbolic link and skips names that start with a dot (so macOS's
  `._IMG_0001.ARW` files are not taken for raw files); a name a client could not send back as a path (a backslash,
  bytes that are not UTF-8) is skipped too. Browsing counts by the same rules. Each raw file costs one `stat` (its
  size and time make its cache key) and the cache index is asked in batches, as for a lookup.
- **The converter self-test** waits for a running wave to finish and holds the scheduler until it is done, so its
  converter processes never run beside a wave's (it runs one at a time). It uses the runner's own preparation (display,
  wineserver, warm-up) and its own batch run and checks; the DNG it makes is thrown away, and nothing is written to the
  cache or the database.
- **The log** keeps the last 1000 records of the `lrrp` loggers in memory (not uvicorn's request lines). The token is
  never logged; as a guard, it is replaced by `[token]` in every record that reaches the console or the log endpoint,
  and the converter's environment does not get `LRRP_TOKEN`.
- **The database** carries a schema version. A database of an older server is brought up to date in place at start
  (0.3.0 adds a column for `clientId` to a 0.2.0 database, 0.4.0 a table for the settings, 0.5.0 the jobs'
  priority, the original and last use of each cache entry, the failures the automatic scan remembers and the records
  of the background work); nothing is dropped. Cache entries from before 0.5.0 take their original from an item that
  points to them, and count as used at the upgrade. A database of a newer server stops the start with a message.

## API

The contract is [docs/protocol.md](../docs/protocol.md); every call in it is implemented.

| Call | Token | Answer |
|---|---|---|
| `GET /healthz` | never | `{"status": "ok", "busy": false}`; `busy` while `status.state` is `running` |
| `GET /api/v1/info` | when configured | Name, version, protocol version, auth mode, converter state and version, roots, capabilities |
| `POST /api/v1/jobs` | when configured | Create a job from a list of files, optionally with the client's `clientId` and a `priority` |
| `POST /api/v1/jobs/{id}/items` | when configured | Add files to a job that exists |
| `GET /api/v1/jobs` | when configured | Jobs, newest first; `state` and `clientId` filter them |
| `GET /api/v1/jobs/{id}` | when configured | One job |
| `GET /api/v1/jobs/{id}/items` | when configured | A job's items changed since `since`; with `wait`, held until there is one (at most `wait` seconds) |
| `POST /api/v1/jobs/{id}/retry` | when configured | Queue a job's failed items again |
| `DELETE /api/v1/jobs/{id}` | when configured | Cancel a job |
| `GET /api/v1/items/{id}/file` | when configured | The DNG of a ready item |
| `POST /api/v1/lookup` | when configured | For a list of files: `ready` (with the result), `pending`, `absent` or `rejected`, without a job |
| `GET /api/v1/files/{key}` | when configured | The DNG with this cache key (`result.key` of an item or a lookup) |
| `GET /api/v1/status` | when configured | State, queue, workers, rate, time left, today's counts, cache, active jobs, CPU temperature, the automatic scan |
| `GET /api/v1/settings` | when configured | The settings that change while the server runs |
| `PATCH /api/v1/settings` | when configured | Change any of them; `422` and no change for a bad value |
| `GET /api/v1/browse` | when configured | A folder of a root: its sub-folders, and how many raw files (and built ones) and other files it has |
| `POST /api/v1/folders` | when configured | Queue the raw files of a folder, optionally with its sub-folders and a `priority` |
| `POST /api/v1/autoscan/run` | when configured | Start a scan now over the configured roots or those named; `202`, `409 busy` while one runs |
| `POST /api/v1/cache/clean` | when configured | Run the cache clean-up now (or only count, with `{"dryRun": true}`); `409 busy` while one runs |
| `POST /api/v1/converter/selftest` | when configured | Check the converter step by step, optionally converting one file |
| `GET /api/v1/log` | when configured | The newest of the last 1000 log lines, oldest first |
| `GET /docs`, `GET /openapi.json` | no | Generated OpenAPI description |

`GET /api/v1/info` looks like this:

```json
{
  "name": "LR Remote Previews",
  "version": "0.6.0",
  "api": 1,
  "auth": "token",
  "converter": {
    "installed": true,
    "path": "C:\\Program Files\\Adobe\\Adobe DNG Converter\\Adobe DNG Converter.exe",
    "version": "17.2"
  },
  "roots": [{"id": "archive", "label": "Archive", "available": true}],
  "capabilities": {
    "extensions": [".arw", ".cr2", "..."],
    "previewLongEdge": 2560,
    "maxItemsPerJob": 5000,
    "jobRetentionDays": 30,
    "appendItems": true,
    "maxWaitSeconds": 55
  }
}
```

`wait` in `GET /api/v1/jobs/{id}/items` is a number of seconds from 0 to 55 (fractions allowed; anything else is
`422`). A waiting request ends with the usual answer when an item it would return appears (with `state`, one in that
state), with `404` when the job is deleted, with no items when the time is up or the server stops; a client's own HTTP
timeout must be longer than its `wait`. In `POST /api/v1/jobs/{id}/items` the refusals are checked in this order:
`404`, `409 job_cancelled`, `413 too_many_items` for a request of more than 5000 items, `422 duplicate_ref` within
the request, then against the job's items, `413 too_many_items` for the job's total, `409 converter_not_installed`
(a malformed body is `422` before all of them).

`converter.version` is the `ProductVersion` recorded in the executable's version resource (`17.2` for Adobe DNG
Converter 17.2), read without running it and with a few small reads (the file is about 227 MB); it is read again only
when the file's size or modification time changes, and is `null` when it cannot be read.

`status.state` is `running` while a wave (or a self-test's converter) runs, also when `paused` was switched on
meanwhile, and when work is queued and a wave may start; then `paused`, `idle` (nothing queued) or `waiting` (queued,
outside the working hours). `etaSeconds` is the files still queued or building (a file two jobs want counts once)
divided by the rate of the last 60 seconds, only while `running`. `cpuTemperature` is the hottest reading of the CPU's
own sensors under `/sys/class/hwmon` (`coretemp`, `k10temp`, `zenpower`; on AMD `Tdie` rather than an offset `Tctl`),
else of the CPU thermal zones under `/sys/class/thermal`; `null` when there is none (always off Linux).

`status.autoScan` is `{"running", "lastRun", "lastQueued", "nextRun"}`: whether a scan runs (from the moment one is
asked for), when the last one finished and how many files it queued (`null` and 0 before the first), and when the
next periodic one is due (`null` while the automatic scan is off; while a scan runs, its start plus the interval, the
earliest the next can be). In `POST /api/v1/autoscan/run`, a body without roots (none, `{}`, `{"roots": []}`) means
the configured roots; `422` when there are none, `422` with `"code": "unknown_root"` for a root the server does not
have, `409 converter_not_installed`, `409 busy`. `dryRun` in `POST /api/v1/cache/clean` must be a JSON boolean.

`roots[].available` is `true` when the root's folder exists. A missing or wrong token gives `401` with
`{"detail": "Missing bearer token"}` or `{"detail": "Invalid token"}`. Unknown paths under `/api/` give a JSON `404`.
Every error body has a `detail` text; validation errors (`422`) are described in one line, such as
`items[0].path: Field required`.

Every other `GET` path serves the dashboard from `LRRP_WEB_DIR`: an existing file is sent as it is, anything else gets
`index.html`, so the dashboard's own routes work on reload.

## Layout

| File | What |
|---|---|
| `src/lrrp/__main__.py` | `python -m lrrp`: reads the settings, sets up logging and starts uvicorn, with a server class that ends the waiting requests when it stops |
| `src/lrrp/settings.py` | Settings from the environment and the roots file |
| `src/lrrp/runtime.py` | The settings that change while the server runs: checks, keeping them, working hours, whether a wave may start |
| `src/lrrp/app.py` | The FastAPI application: the API, the dashboard, the background services' lifespan |
| `src/lrrp/sources.py` | Checking a requested root and path (file or folder); the cache key |
| `src/lrrp/folders.py` | Listing a folder and finding the raw files of a folder tree |
| `src/lrrp/store.py` | The SQLite database: jobs, items, the cache index, the build log, the changed settings |
| `src/lrrp/cache.py` | The DNG files of the cache and the batch folders |
| `src/lrrp/dng.py` | Reading `OriginalRawFileName` and `OriginalDefaultFinalSize` from a DNG |
| `src/lrrp/converter.py` | Finding the converter in the Wine prefix, its command line, and the measured facts about running it |
| `src/lrrp/runner.py` | Running the converter: wave planning, processes, timeouts, the warm-up, checking outputs |
| `src/lrrp/display.py` | The one Xvfb the converter uses |
| `src/lrrp/scheduler.py` | The background thread that turns the queue into waves and publishes the results |
| `src/lrrp/waits.py` | The requests that wait for a change of a job: waking them when the store reports a change, their looks, the stop |
| `src/lrrp/autoscan.py` | The automatic scan: its thread, the walk of the roots and the choice of the files to queue |
| `src/lrrp/cleanup.py` | The cache clean-up and its daily run |
| `src/lrrp/selftest.py` | The converter self-test |
| `src/lrrp/peversion.py` | Reading the product version from a Windows executable |
| `src/lrrp/sensors.py` | The CPU temperature from Linux sysfs |
| `src/lrrp/logring.py` | The last log records in memory; keeping the token out of log lines |
| `tests/` | pytest tests; `tests/fake_converter.py` stands in for the converter, `tests/pe_builder.py` makes small executables with a version resource |
