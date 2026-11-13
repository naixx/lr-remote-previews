# LR Remote Previews server

The server part of LR Remote Previews: a FastAPI application (Python package `lrrp`) that runs next to the photo
originals, answers the plug-in and the dashboard, and serves the built dashboard. In stage 0 it reports its state
only; the job queue and the converter runner come in stage 1 (see the [plan](../docs/plan.md)).

In production it runs in the container built from [`deploy/`](../deploy/). This page is about running it from source.

## Run locally

Python 3.11 or newer.

```sh
cd server
python -m venv .venv
. .venv/bin/activate            # Windows: .venv\Scripts\activate
pip install -e ".[dev]"
LRRP_WEB_DIR=../web/dist python -m lrrp
```

The server listens on `0.0.0.0:8787`; open `http://localhost:8787/`. Without a built dashboard, `/` answers with a
short text. Outside the container there is no Wine prefix, so `converter.installed` is `false`.

On Windows, set the variables with `set NAME=value` (cmd) or `$env:NAME = "value"` (PowerShell) before
`python -m lrrp`.

## Test

The same commands CI runs, from `server/`:

```sh
ruff check .
ruff format --check .
pytest
```

## Settings

Environment variables. An empty variable counts as unset.

| Variable | Default | Meaning |
|---|---|---|
| `LRRP_HOST` | `0.0.0.0` | Address to listen on |
| `LRRP_PORT` | `8787` | Port to listen on |
| `LRRP_TOKEN` | unset | When set, every request under `/api/` needs `Authorization: Bearer <token>`. When unset, the API is open (`"auth": "none"`); use that for development only |
| `LRRP_CONFIG` | unset | YAML file with the roots (below) |
| `LRRP_DATA_DIR` | `/data` | The server's state; holds the Wine prefix by default |
| `LRRP_CACHE_DIR` | `/cache` | Built smart previews (used from stage 1) |
| `LRRP_WEB_DIR` | `/app/web` | The built dashboard (`web/dist`) |
| `LRRP_WINEPREFIX` | `<LRRP_DATA_DIR>/wine` | The Wine prefix the converter is installed into |
| `LRRP_CONVERTER_EXE` | `C:\Program Files\Adobe\Adobe DNG Converter\Adobe DNG Converter.exe` | The converter, as a Windows path inside the Wine prefix |

The converter is found when that Windows path exists in the prefix: `C:\x\y` is looked up as
`<LRRP_WINEPREFIX>/drive_c/x/y`. Adobe DNG Converter is not part of this project; see
[docs/converter.md](../docs/converter.md).

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

## API

The contract is [docs/protocol.md](../docs/protocol.md). Implemented so far:

| Call | Token | Answer |
|---|---|---|
| `GET /healthz` | never | `{"status": "ok"}` |
| `GET /api/v1/info` | when configured | Name, version, protocol version, auth mode, converter state, roots, capabilities |
| `GET /docs`, `GET /openapi.json` | no | Generated OpenAPI description |

`GET /api/v1/info` looks like this:

```json
{
  "name": "LR Remote Previews",
  "version": "0.1.0",
  "api": 1,
  "auth": "token",
  "converter": {
    "installed": false,
    "path": "C:\\Program Files\\Adobe\\Adobe DNG Converter\\Adobe DNG Converter.exe",
    "version": null
  },
  "roots": [{"id": "archive", "label": "Archive", "available": true}],
  "capabilities": {"extensions": [".arw", ".cr2", "..."], "previewLongEdge": 2560}
}
```

`roots[].available` is `true` when the root's folder exists. A missing or wrong token gives `401` with
`{"detail": "Missing bearer token"}` or `{"detail": "Invalid token"}`. Unknown paths under `/api/` give a JSON `404`.

Every other `GET` path serves the dashboard from `LRRP_WEB_DIR`: an existing file is sent as it is, anything else gets
`index.html`, so the dashboard's own routes work on reload.

## Layout

| File | What |
|---|---|
| `src/lrrp/__main__.py` | `python -m lrrp`: reads the settings and starts uvicorn |
| `src/lrrp/settings.py` | Settings from the environment and the roots file |
| `src/lrrp/app.py` | The FastAPI application |
| `src/lrrp/converter.py` | Finding the converter in the Wine prefix, the command line for a batch, and the measured facts about running it |
| `tests/` | pytest tests |
