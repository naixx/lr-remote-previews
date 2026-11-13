# Container image and compose example

| File | What |
|---|---|
| `Dockerfile` | The image: the server, the built dashboard, Wine and Xvfb |
| `Dockerfile.dockerignore` | What the build leaves out of the context (local `node_modules`, virtualenvs, build output) |
| `entrypoint.sh` | Prepares the data folders and the Wine prefix at start, then runs the server |
| `compose.yaml` | A generic example deployment |
| `.env.example` | Template for the `.env` file with the token |

**Adobe DNG Converter is not included** in the image, and nothing in it downloads the converter. You obtain it from
Adobe and install it into the app's Wine prefix yourself; [docs/converter.md](../docs/converter.md) describes how.
Until then the server runs and reports `"converter": {"installed": false, ...}` in `GET /api/v1/info`.

## What is in the image

- Debian 12 (`debian:bookworm-slim`) with its Wine 8.0, 64-bit only: the version the converter was proven on.
- Xvfb, because the converter needs an X display.
- Python 3.11 with the server in a virtualenv at `/opt/venv`.
- The dashboard, built from `web/` in a Node 20 stage, at `/app/web`.
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
| `/data` | The server's state; the Wine prefix with the converter (`/data/wine`) and the home folder (`/data/home`) | read-write |
| `/cache` | Built smart previews (used from stage 1) | read-write |
| `/sources` | The originals, one mount per root, for example `/sources/archive` | **read-only** |

Mount the originals read-only (`:ro`). The server never writes to them, and a read-only mount makes sure of it.

## First start

On the first start the entrypoint creates the Wine prefix in `/data/wine` (`wineboot` on a virtual display), which
can take a minute; the health check allows three minutes for the start. At every start it also makes sure the marker
file exists that switches the converter's GPU path off, without which the converter aborts in a container without a
Vulkan device.

## Running as another user

The container can run as any uid:gid, for example with `user: "568:568"` in compose. Then:

- `/data` and `/cache` must be writable by that uid (bind mounts: set the owner of the host folders).
- The Wine prefix belongs to the uid that created it, and Wine refuses a prefix owned by someone else. If you change
  the uid later, the entrypoint stops with a message; run as the old uid again, or remove `/data/wine` and install the
  converter again.

## Other commands in the container

The entrypoint runs any command given to the container after preparing the same environment (`WINEPREFIX`, `HOME`,
the marker file), and runs the server when none is given. For example:

```sh
docker compose run --rm lrrp wine --version
```
