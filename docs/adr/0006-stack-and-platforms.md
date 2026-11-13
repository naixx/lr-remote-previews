# 0006. Stack and platforms

Status: accepted (2026-11-13)

## Decision

- **Server:** Python 3.11+ with FastAPI, SQLite for the queue and the cache index, one container that also holds
  Wine, Xvfb and the built dashboard. The base image is Debian 12, because its Wine 8.0 is the version the converter
  was proven on.
- **Dashboard:** React + TypeScript + Vite, built to static files that the server serves. No UI framework to start
  with.
- **Plug-in:** Lua 5.1 for the Lightroom Classic SDK. Logic that does not need the SDK lives in pure-Lua modules with
  unit tests.
- **Protocol:** HTTP + JSON under `/api/v1`, a bearer token, versioned; the plug-in and the server check each
  other's version.
- **Packaging:** a container image and a compose file; TrueNAS SCALE is the first target («Install via YAML»).
- **Client platform:** Windows first. The plug-in is written to be portable (path handling, `sqlite3`), but macOS is
  unverified until someone tests it.
- **Lightroom versions:** verified on Lightroom Classic 15.6. Every other version is unverified until tested.

## Why

- The converter dictates Wine, and Wine is simplest in a Debian container; Python sits naturally next to it and keeps
  the image small. The work is I/O and process supervision, not computation.
- One container means one thing to install on a NAS.
- React has the largest pool of people able to contribute to an open project.

## Consequences

- Two languages on the server side (Python, TypeScript) and Lua in the plug-in: three toolchains in CI.
- The image carries Wine, about a gigabyte.
