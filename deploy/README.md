# Container image and compose example

| File | What |
|---|---|
| `Dockerfile` | The image: the server, the built dashboard, Wine and Xvfb |
| `entrypoint.sh` | Prepares the data folders and the Wine prefix at start, then runs the server |
| `compose.yaml` | A generic example deployment |
| `.env.example` | Template for the `.env` file with the token |

What the build leaves out of the context (local `node_modules`, virtualenvs, build output) is in the repository
root's `.dockerignore`, because the build context is the root.

**Adobe DNG Converter is not included** in the image, and nothing in it downloads the converter. You obtain it from
Adobe and install it into the app's Wine prefix yourself; [docs/converter.md](../docs/converter.md) describes how.
Until then the server runs and reports `"converter": {"installed": false, ...}` in `GET /api/v1/info`.

## What is in the image

- Debian 12 (`debian:bookworm-slim`) with its Wine 8.0, 64-bit only: the version the converter was proven on.
- Xvfb, because the converter needs an X display.
- Python 3.11 with the server in a virtualenv at `/opt/venv`.
- The dashboard, built from `web/` in a Node 22 stage, at `/app/web`.
- `tini` as the init process.

It runs as a non-root user, uid and gid 1000 by default.

## Build

From the repository root (the build context must be the root, because the image needs `server/` and `web/`):

```sh
docker build -f deploy/Dockerfile -t lr-remote-previews .
```

Build arguments: `LRRP_UID` and `LRRP_GID` (default `1000`) set the user the image runs as.

## Run with compose

```sh
cd deploy
cp .env.example .env     # then set LRRP_TOKEN in .env to a long random string
# edit compose.yaml: replace /path/to/originals with the folder of your originals
docker compose up -d --build
```

The server is then at `http://<host>:8787/`. Check it with `curl http://<host>:8787/healthz`.

To tell the server about your roots (the folders with originals), write a `roots.yaml` as shown at the end of
`compose.yaml`, mount it, and set `LRRP_CONFIG`. The settings are described in [server/README.md](../server/README.md).

## Run with docker

```sh
docker run -d --name lr-remote-previews \
  -p 8787:8787 \
  -e LRRP_TOKEN=<long random string> \
  -v lrrp-data:/data \
  -v lrrp-cache:/cache \
  -v /path/to/originals:/sources/archive:ro \
  lr-remote-previews
```

## Volumes

| Path | What | Access |
|---|---|---|
| `/data` | The server's state: the database `lrrp.sqlite3` (jobs, items, cache index), the Wine prefix with the converter (`/data/wine`) and the home folder (`/data/home`) | read-write |
| `/cache` | Built smart previews (`<key[0:2]>/<key>.dng`) and the converter's temporary batch folders (`work/`, emptied at every start) | read-write |
| `/sources` | The originals, one mount per root, for example `/sources/archive` | **read-only** |

Mount the originals read-only (`:ro`). The server never writes to them, and a read-only mount makes sure of it.

## First start

On the first start the entrypoint creates the Wine prefix in `/data/wine` (`wineboot` on a virtual display), which
can take a minute; the health check allows three minutes for the start. At every start it also makes sure the marker
file exists that switches the converter's GPU path off, without which the converter aborts in a container without a
Vulkan device.

The first time the server builds anything in a new prefix it runs the converter once on an input that does not
exist, because the converter's first run in a fresh prefix always aborts (exit code 3) while it writes
`Camera Raw GPU Config.txt` next to the marker. If that file does not appear, the items fail with
`converter_failed` and the converter's last output, and the log says so.

## What runs in the container

- The server (`python -m lrrp`), as the main process under `tini`.
- One Xvfb, started by the server when it first builds something, on the first free display from `:99` up; started
  again if it dies, stopped with the server.
- One persistent `wineserver` for the prefix, started by the server before its first converter run.
- Adobe DNG Converter processes: `LRRP_WORKERS` at most at a time (never exactly two), each on a batch of up to
  `LRRP_BATCH_SIZE` files and in its own process group. A batch that runs longer than 60 s + 30 s per file is killed,
  that process group only.

The number of processes is the main knob for heat and noise on a small NAS: set `LRRP_WORKERS` (see
[server/README.md](../server/README.md); `auto` picks 6, 4, 3 or 1 from the number of CPU threads).

## Running as another user

The container can run as any uid:gid, for example with `user: "568:568"` in compose. Then:

- `/data` and `/cache` must be writable by that uid (bind mounts: set the owner of the host folders). The cache and
  the database written by one uid must stay writable for the next one.
- The Wine prefix belongs to the uid that created it, and Wine refuses a prefix owned by someone else. If you change
  the uid later, the entrypoint stops with a message; run as the old uid again, or remove `/data/wine` and install the
  converter again.

## Other commands in the container

The entrypoint runs any command given to the container after preparing the same environment (`WINEPREFIX`, `HOME`,
the marker file), and runs the server when none is given. For example:

```sh
docker compose run --rm lrrp wine --version
```
