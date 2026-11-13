# Protocol between the plug-in, the dashboard and the server

HTTP and JSON. Everything under `/api/v1`. The server also publishes an OpenAPI description at `/docs` (generated;
the text here is the contract that the three parts are written against). This file grows with the stages of the
[plan](plan.md); it now covers stage 1.

Conventions: JSON bodies are UTF-8. Times are UTC, written exactly as `YYYY-MM-DDTHH:MM:SSZ`
(`2026-11-14T09:30:00Z`): a literal `Z`, no numeric offset, no fractions of a second. Identifiers of
jobs and items are positive integers. A field described as «or null» is always present. Clients ignore fields they
do not know.

## Authentication

When the server has a token configured, every request under `/api/` needs the header
`Authorization: Bearer <token>`. A missing or wrong token gives `401` with a body `{"detail": "<reason>"}`.
`/healthz` never needs a token. A server without a configured token reports `"auth": "none"` and accepts every
request; that is meant for development only.

## Errors

Every error response has a JSON body `{"detail": "<text for a person>"}`; where a program has to tell cases apart it
also has `"code": "<identifier>"`. Status codes: `400` malformed request, `401` token, `404` unknown job, item or
path, `409` the request cannot be served in the current state, `413` too many items, `422` a field has the wrong
type or value. `detail` is always one string, also for `422`.

## `GET /healthz`

`200` `{"status": "ok"}`. For container health checks.

## `GET /api/v1/info`

```json
{
  "name": "LR Remote Previews",
  "version": "0.2.0",
  "api": 1,
  "auth": "token",
  "converter": {
    "installed": true,
    "path": "C:\\Program Files\\Adobe\\Adobe DNG Converter\\Adobe DNG Converter.exe",
    "version": null
  },
  "roots": [
    {"id": "archive", "label": "Archive", "available": true}
  ],
  "capabilities": {
    "extensions": [".arw", ".cr2"],
    "previewLongEdge": 2560,
    "maxItemsPerJob": 5000
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
| `capabilities.maxItemsPerJob` | The most items one job may have |

## Paths

A client never sends a server-side path. It sends a root `id` and a path relative to that root, with forward
slashes and no leading slash (`2026/2026.06.20 - shoot/IMG_0001.ARW`). The plug-in derives both from the local path
of the original with a mapping the user configures (for example local prefix `Z:\` → root `archive`). The server
rejects a relative path that is empty, absolute, longer than 4096 characters, contains a backslash, a NUL, an empty
segment (`a//b`, a trailing slash) or a `.` or `..` segment, or that resolves outside the root (symbolic links
included).

## Jobs and items

A **job** is a list of files a client wants as smart preview DNGs. Each file is an **item**. The server builds items
in the background, keeps every result in its cache, and serves the results until the job is deleted or expires.

### Item states

| State | Meaning | Final |
|---|---|---|
| `queued` | Waiting for a converter process | no |
| `building` | Given to a converter process | no |
| `ready` | The DNG is in the cache and can be downloaded | yes |
| `failed` | The server tried and could not build it | yes |
| `rejected` | The request for this file was not acceptable; nothing was tried | yes |
| `cancelled` | The job was cancelled before this item was built | yes |

A request for a file whose DNG is already in the cache becomes `ready` at once.

`error.code` of a `rejected` item: `unknown_root`, `root_unavailable`, `bad_path`, `unsupported_format`,
`not_found`, `not_a_file`. Of a `failed` item: `converter_failed`, `converter_timeout`, `output_missing`,
`output_mismatch` (the DNG does not name this file as its original), `source_changed` (the file changed or vanished
between the request and the build).

When several reasons to reject apply, the first of these wins: `unknown_root`, `bad_path` (the form of the path),
`unsupported_format`, `root_unavailable`, `bad_path` (the path leads outside the root), `not_found`, `not_a_file`. A
file the server is not permitted to read is `not_found`.

### The item object

```json
{
  "id": 4211,
  "ref": "17",
  "root": "archive",
  "path": "2026/2026.06.20 - shoot/IMG_0001.ARW",
  "state": "ready",
  "seq": 687,
  "error": null,
  "result": {
    "size": 359310,
    "sha256": "9f2c…",
    "originalName": "IMG_0001.ARW",
    "originalWidth": 6000,
    "originalHeight": 4000
  }
}
```

| Field | Meaning |
|---|---|
| `ref` | A string of at most 64 characters chosen by the client and echoed back unchanged. The server does not interpret it. Unique within a job |
| `seq` | The job's change counter at the item's last state change (see polling) |
| `error` | `null`, or `{"code": "...", "message": "..."}` for `failed` and `rejected` |
| `result` | `null` until `ready`. `size` and `sha256` (lower-case hex) of the DNG; `originalName` and the original pixel size as the DNG records them (`OriginalRawFileName`, `OriginalDefaultFinalSize`), `null` where the DNG has no such tag |

### The job object

```json
{
  "id": 7,
  "label": "Lightroom selection",
  "client": "lr-plugin/0.2.0",
  "state": "active",
  "created": "2026-11-14T09:30:00Z",
  "finished": null,
  "seq": 692,
  "counts": {"total": 500, "queued": 300, "building": 8, "ready": 190, "failed": 2, "rejected": 0, "cancelled": 0}
}
```

`label` and `client` are always present: the text the client sent, or `null` when it sent none.
`state`: `active` while any item is `queued` or `building`; `done` when none is; `cancelled` after a cancel.
`finished` is the time the job left `active`, or `null`. `seq` is the job's change counter: it grows by one with
every state change of any of its items.

### `POST /api/v1/jobs`

```json
{
  "client": "lr-plugin/0.2.0",
  "label": "Lightroom selection",
  "items": [
    {"ref": "17", "root": "archive", "path": "2026/2026.06.20 - shoot/IMG_0001.ARW"}
  ]
}
```

`client` and `label` are optional free text (at most 100 characters each). `items` has 1 to
`capabilities.maxItemsPerJob` entries with unique `ref`s.

`201`:

```json
{"job": { …job object… }, "items": [ …one item object per requested item, in request order… ]}
```

Each item is checked when the job is created: an unacceptable one is `rejected` with its reason, one already in the
cache is `ready`, the others are `queued`. A job is created even if every item is rejected.

`409` with `"code": "converter_not_installed"` when the server has no converter and at least one item would have to
be built. `413` with `"code": "too_many_items"`. `422` for a malformed body; duplicate `ref`s give `422` with
`"code": "duplicate_ref"`.

### `GET /api/v1/jobs`

Query: `limit` (1–200, default 50), `state` (`active`, `done`, `cancelled`; default all). `200`
`{"jobs": [ …job objects, newest first… ]}`.

### `GET /api/v1/jobs/{id}`

`200` `{"job": { … }}`. `404` for an unknown job.

### `GET /api/v1/jobs/{id}/items`

Query: `since` (default 0), `limit` (1–1000, default 500), `state` (optional; one state).

`200`:

```json
{"job": { … }, "items": [ …item objects with seq > since, ordered by seq… ], "more": false}
```

**Polling:** a client keeps the largest `seq` it has seen and asks for `since=<that>`. Because an item's `seq` only
changes when its state changes, every state change reaches the client exactly once. `more` is true when the limit
cut the list; ask again with the new largest `seq`.

Items get their first `seq` when the job is created: every item in the answer to `POST /api/v1/jobs` carries a
`seq` of at least 1, whatever its state, and the job's `seq` in that answer is the largest of them. A client that
has processed that answer polls with `since=<the job's seq from that answer>` and receives only later changes.
`since=0` returns every item of the job.

### `GET /api/v1/items/{id}/file`

`200` with the DNG as the body, `Content-Type: image/x-adobe-dng`, `Content-Length`, `X-LRRP-SHA256` with the same
value as `result.sha256`, and `Content-Disposition: attachment` with the original's base name and `.dng`. `404` for
an unknown item, `409` with `"code": "not_ready"` when the item is not `ready`, `404` with
`"code": "not_in_cache"` when the item is `ready` but its DNG is gone from the cache (ask for the file in a new job;
it is built again).

### `DELETE /api/v1/jobs/{id}`

Cancels the job: `queued` items become `cancelled`; items already `building` finish and their results stay in the
cache. `200` `{"job": { … }}`. Cancelling a job that is not `active` changes nothing and returns it.

## `GET /api/v1/status`

For the dashboard.

```json
{
  "queue": {"queued": 300, "building": 8},
  "workers": {"configured": 4, "busy": 4},
  "rate": {"perMinute": 172.5, "windowSeconds": 60},
  "today": {"built": 1234, "failed": 2},
  "cache": {"entries": 5321, "bytes": 2890000000},
  "jobs": {"active": 1}
}
```

`queue`: items over all jobs. `workers.configured`: the number of converter processes the server may run side by
side; `busy`: how many run now. `rate.perMinute`: items built in the last `windowSeconds`, scaled to a minute; 0
when idle. `today`: since local midnight of the server. `rate` and `today` count conversions, not items: a file two
jobs asked for counts once, and `rate` counts successful conversions only. `cache`: the DNGs kept.

## What a client must do with a delivered file

This is the plug-in's side of the safety rules (decision record 0005), stated here because it is part of the
contract of using the API:

1. Download the file and check its length (and, where practical, its SHA-256) against `result`.
2. Read `OriginalRawFileName` and `OriginalDefaultFinalSize` from the DNG itself and compare them with the photo
   the file is meant for. The server's `result` values are a convenience, not the check.
3. Write under a temporary name in the destination folder, then rename. Never replace an existing file.
