# LR Remote Previews server

The server part of LR Remote Previews: a FastAPI application (Python package `lrrp`) that runs next to the photo
originals, answers the plug-in and the dashboard, and serves the built dashboard. It takes jobs (lists of raw files),
builds their smart preview DNGs with Adobe DNG Converter under Wine in the background, keeps them in a cache and
serves them (stage 1 of the [plan](../docs/plan.md)).

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
itself run at the same time. The end-to-end tests drive the HTTP API with it.

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
| `LRRP_WORKERS` | `auto` | Converter processes run side by side: `auto` or a number. `auto` is 6 with 16 or more CPU threads, 4 with 8 or more, 3 with 6 or more, else 1. **2 is refused**: two converter processes side by side take twice the CPU time per photo (measured; the cause is unknown) |
| `LRRP_BATCH_SIZE` | `8` | Files given to one converter process at a time, 1 to 64 |

The converter is found when that Windows path exists in the prefix: `C:\x\y` is looked up as
`<LRRP_WINEPREFIX>/drive_c/x/y`. Adobe DNG Converter is not part of this project; see
[docs/converter.md](../docs/converter.md).

`LRRP_DATA_DIR` and `LRRP_CACHE_DIR` must not lie inside a root: the server writes there, and it never writes under a
root of originals.

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
- **One scheduler thread** works in waves. It takes up to `LRRP_WORKERS × LRRP_BATCH_SIZE` distinct files from the head
  of the queue (two jobs that ask for the same file share one build), picks the number of converter processes for the
  wave (as many as needed, at most `LRRP_WORKERS`, and three instead of two, or one when there are only two files),
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
- **A restart** puts items that were `building` back into the queue. Cancelling a job cancels its queued items; items
  already building finish and stay in the cache.

## API

The contract is [docs/protocol.md](../docs/protocol.md); every call in it is implemented.

| Call | Token | Answer |
|---|---|---|
| `GET /healthz` | never | `{"status": "ok"}` |
| `GET /api/v1/info` | when configured | Name, version, protocol version, auth mode, converter state, roots, capabilities |
| `POST /api/v1/jobs` | when configured | Create a job from a list of files |
| `GET /api/v1/jobs` | when configured | Jobs, newest first |
| `GET /api/v1/jobs/{id}` | when configured | One job |
| `GET /api/v1/jobs/{id}/items` | when configured | A job's items changed since `since` |
| `DELETE /api/v1/jobs/{id}` | when configured | Cancel a job |
| `GET /api/v1/items/{id}/file` | when configured | The DNG of a ready item |
| `GET /api/v1/status` | when configured | Queue, workers, rate, today's counts, cache, active jobs |
| `GET /docs`, `GET /openapi.json` | no | Generated OpenAPI description |

`GET /api/v1/info` looks like this:

```json
{
  "name": "LR Remote Previews",
  "version": "0.2.0",
  "api": 1,
  "auth": "token",
  "converter": {
    "installed": false,
    "path": "C:\\Program Files\\Adobe\\Adobe DNG Converter\\Adobe DNG Converter.exe",
    "version": null
  },
  "roots": [{"id": "archive", "label": "Archive", "available": true}],
  "capabilities": {"extensions": [".arw", ".cr2", "..."], "previewLongEdge": 2560, "maxItemsPerJob": 5000}
}
```

`roots[].available` is `true` when the root's folder exists. A missing or wrong token gives `401` with
`{"detail": "Missing bearer token"}` or `{"detail": "Invalid token"}`. Unknown paths under `/api/` give a JSON `404`.
Every error body has a `detail` text; validation errors (`422`) are described in one line, such as
`items[0].ref: String should have at most 64 characters`.

Every other `GET` path serves the dashboard from `LRRP_WEB_DIR`: an existing file is sent as it is, anything else gets
`index.html`, so the dashboard's own routes work on reload.

## Layout

| File | What |
|---|---|
| `src/lrrp/__main__.py` | `python -m lrrp`: reads the settings, sets up logging and starts uvicorn |
| `src/lrrp/settings.py` | Settings from the environment and the roots file |
| `src/lrrp/app.py` | The FastAPI application: the API, the dashboard, the background services' lifespan |
| `src/lrrp/sources.py` | Checking a requested root and path; the cache key |
| `src/lrrp/store.py` | The SQLite database: jobs, items, the cache index, the build log |
| `src/lrrp/cache.py` | The DNG files of the cache and the batch folders |
| `src/lrrp/dng.py` | Reading `OriginalRawFileName` and `OriginalDefaultFinalSize` from a DNG |
| `src/lrrp/converter.py` | Finding the converter in the Wine prefix, its command line, and the measured facts about running it |
| `src/lrrp/runner.py` | Running the converter: wave planning, processes, timeouts, the warm-up, checking outputs |
| `src/lrrp/display.py` | The one Xvfb the converter uses |
| `src/lrrp/scheduler.py` | The background thread that turns the queue into waves and publishes the results |
| `tests/` | pytest tests; `tests/fake_converter.py` stands in for the converter |
