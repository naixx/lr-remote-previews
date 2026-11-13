# Protocol between the plug-in, the dashboard and the server

HTTP and JSON. Everything under `/api/v1`. The server also publishes an OpenAPI description at `/docs` (generated;
the text here is the contract that the three parts are written against).

This file grows with the stages of the [plan](plan.md). Stage 0 defines only the two calls below.

## Authentication

When the server has a token configured, every request under `/api/` needs the header
`Authorization: Bearer <token>`. A missing or wrong token gives `401` with a body `{"detail": "<reason>"}`.
`/healthz` never needs a token. A server without a configured token reports `"auth": "none"` and accepts every
request; that is meant for development only.

## `GET /healthz`

`200` `{"status": "ok"}`. For container health checks.

## `GET /api/v1/info`

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
  "roots": [
    {"id": "archive", "label": "Archive", "available": true}
  ],
  "capabilities": {
    "extensions": [".arw", ".cr2"],
    "previewLongEdge": 2560
  }
}
```

| Field | Meaning |
|---|---|
| `version` | Version of the server |
| `api` | Major version of this protocol |
| `auth` | `"token"` or `"none"` |
| `converter.installed` | Whether the server finds Adobe DNG Converter at `converter.path` inside its Wine prefix |
| `converter.version` | Not determined yet (`null`) |
| `roots[]` | The folders with originals the server can read. `id` is what a client uses to name a root; server-side paths are never exposed. `available` is false when the folder is missing, for example an unmounted volume |
| `capabilities.extensions` | Lower-case file extensions the server accepts as camera raw files |
| `capabilities.previewLongEdge` | Long edge of the smart previews it builds, in pixels |

## Paths

A client never sends a server-side path. It sends a root `id` and a path relative to that root, with forward
slashes. The plug-in derives both from the local path of the original with a mapping the user configures (for
example local prefix `Z:\` → root `archive`). The server rejects relative paths that would leave the root.
