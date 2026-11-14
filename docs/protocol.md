# Protocol between the plug-in, the dashboard and the server

HTTP and JSON. Everything under `/api/v1`. The server also publishes an OpenAPI description at `/docs` (generated;
the text here is the contract that the three parts are written against). This file grows with the stages of the
[plan](plan.md); it now covers stage 4.

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

`200` `{"status": "ok", "busy": false}`. For container health checks, and for software that must know whether
the server is working: `busy` is true while `status.state` (below) is `running`. A NAS that sleeps when idle can
poll this to stay awake while the queue runs. An automatic scan or a cache clean-up alone does not make it busy.
Never needs a token.

## `GET /api/v1/info`

```json
{
  "name": "LR Remote Previews",
  "version": "0.5.0",
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
    "maxItemsPerJob": 5000,
    "jobRetentionDays": 30,
    "appendItems": true,
    "maxWaitSeconds": 55
  }
}
```

| Field | Meaning |
|---|---|
| `version` | Version of the server |
| `api` | Major version of this protocol |
| `auth` | `"token"` or `"none"` |
| `converter.installed` | Whether the server finds Adobe DNG Converter at `converter.path` inside its Wine prefix |
| `converter.version` | The converter's product version as recorded in its executable (for example `"17.2"`), or `null` when it is not installed or the version cannot be read |
| `roots[]` | The folders with originals the server can read. `id` is what a client uses to name a root; server-side paths are never exposed. `available` is false when the folder is missing, for example an unmounted volume |
| `capabilities.extensions` | Lower-case file extensions the server accepts as camera raw files |
| `capabilities.previewLongEdge` | Long edge of the smart previews it builds, in pixels |
| `capabilities.maxItemsPerJob` | The most items one job, or one lookup, may have |
| `capabilities.jobRetentionDays` | A job is deleted this many days after it left `active`. Its DNGs stay in the cache |
| `capabilities.appendItems` | `true` when items can be added to a job that exists (`POST /api/v1/jobs/{id}/items`). Absent on servers before 0.6.0 |
| `capabilities.maxWaitSeconds` | The longest time the server holds a request that asks to wait for a change (`wait` of `GET /api/v1/jobs/{id}/items`). Absent on servers before 0.6.0, which answer at once |

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
    "key": "5d41…",
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
| `result` | `null` until `ready`, and `null` again on a `ready` item whose DNG the cache clean-up has removed since (its download answers `404` `not_in_cache`). `key` names the DNG in the server's cache (64 lower-case hex characters; see `GET /api/v1/files/{key}`); `size` and `sha256` (lower-case hex) of the DNG; `originalName` and the original pixel size as the DNG records them (`OriginalRawFileName`, `OriginalDefaultFinalSize`), `null` where the DNG has no such tag |

### The job object

```json
{
  "id": 7,
  "label": "Lightroom selection",
  "client": "lr-plugin/0.3.0",
  "clientId": "c1f0a6e2-7d0b-4c55-9d0e-3f6a1b2c4d5e",
  "priority": "normal",
  "state": "active",
  "created": "2026-11-14T09:30:00Z",
  "finished": null,
  "seq": 692,
  "counts": {"total": 500, "queued": 300, "building": 8, "ready": 190, "failed": 2, "rejected": 0, "cancelled": 0}
}
```

`label`, `client` and `clientId` are always present: the text the client sent, or `null` when it sent none.
`clientId` is a string of at most 64 characters that a client makes up once and sends with every job, so that it
can find its own jobs again later (for example a random UUID kept in the plug-in's settings per catalog). The
server does not interpret it.
`priority` is `normal` or `background`: the server builds every queued item of `normal` jobs before any item of a
`background` job, and within a priority the oldest job first. A file two jobs want is built with the higher of
their priorities.
`state`: `active` while any item is `queued` or `building`; `done` when none is; `cancelled` after a cancel.
`finished` is the time the job left `active`, or `null`. `seq` is the job's change counter: it grows by one with
every state change of any of its items.

### `POST /api/v1/jobs`

```json
{
  "client": "lr-plugin/0.3.0",
  "clientId": "c1f0a6e2-7d0b-4c55-9d0e-3f6a1b2c4d5e",
  "label": "Lightroom selection",
  "items": [
    {"ref": "17", "root": "archive", "path": "2026/2026.06.20 - shoot/IMG_0001.ARW"}
  ]
}
```

`client` and `label` are optional free text (at most 100 characters each); `clientId` is optional (at most 64);
`priority` is optional (`normal` by default). `items` has 1 to
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

### `POST /api/v1/jobs/{id}/items`

Adds items to a job that exists, so that one job can stand for a piece of work that grows: an import in
Lightroom, whose photos appear over several minutes, is one job. Only on servers with
`capabilities.appendItems`.

```json
{"items": [{"ref": "18", "root": "archive", "path": "2026/2026.06.20 - shoot/IMG_0002.ARW"}]}
```

`items` has 1 to `capabilities.maxItemsPerJob` entries; their `ref`s are unique in the request and not used by
an item the job already has.

`200`:

```json
{"job": { …job object… }, "items": [ …one item object per added item, in request order… ]}
```

Each added item is checked exactly as when a job is created (`rejected`, `ready` or `queued`) and gets the next
values of the job's `seq`, so a client that polls with `since` sees the added items like any other change. A
`done` job becomes `active` again when an added item has to be built, and `done` again when it is built; `finished`
follows (`null` while active). The job keeps its priority, label and `clientId`.

`404` for an unknown job. `409` with `"code": "job_cancelled"` for a cancelled job (start a new one). `409`
`converter_not_installed` and `422` `duplicate_ref` as for a new job; a `ref` the job already has is a
`duplicate_ref` too. `413` with `"code": "too_many_items"` when the job would then hold more than
`capabilities.maxItemsPerJob` items: start another job for the rest.

### `GET /api/v1/jobs`

Query: `limit` (1–200, default 50), `state` (`active`, `done`, `cancelled`; default all), `clientId` (only the
jobs created with exactly this `clientId`; an empty value matches nothing). `200`
`{"jobs": [ …job objects, newest first… ]}`.

### `GET /api/v1/jobs/{id}`

`200` `{"job": { … }}`. `404` for an unknown job.

### `GET /api/v1/jobs/{id}/items`

Query: `since` (default 0), `limit` (1–1000, default 500), `state` (optional; one state), `wait` (seconds, 0 to
`capabilities.maxWaitSeconds`, default 0).

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

**Waiting for a change:** with `wait` greater than 0 and nothing to return, the server holds the request until an
item of the job that the request would return appears (a state change, or an added item; with `state`, one in
that state), until the job is deleted (`404`), or until `wait` seconds have passed, and then answers as usual;
after the time has passed that is an answer with no items. A client that waits for smart previews asks with
`since=<its largest seq>&state=ready&wait=<seconds>` and gets each one within a moment of its being built,
without asking again and again. Each waiting request holds one connection, so a client keeps at most one per
job. A server without `capabilities.maxWaitSeconds` ignores `wait` and answers at once: against such a server a
client must fall back to asking at intervals, not loop.

### `GET /api/v1/items/{id}/file`

`200` with the DNG as the body, `Content-Type: image/x-adobe-dng`, `Content-Length`, `X-LRRP-SHA256` with the same
value as `result.sha256`, and `Content-Disposition: attachment` with the original's base name and `.dng`. `404` for
an unknown item, `409` with `"code": "not_ready"` when the item is not `ready`, `404` with
`"code": "not_in_cache"` when the item is `ready` but its DNG is gone from the cache (ask for the file in a new job;
it is built again).

### `POST /api/v1/jobs/{id}/retry`

Gives every `failed` item of the job another attempt: they become `queued` (each with a new `seq`), and the job
becomes `active` again. Items in other states are untouched. `200` `{"job": { … }}`. A job without failed items is
returned unchanged. `409` with `"code": "job_cancelled"` for a cancelled job. Each retried file is checked again
as it is now, so an item that failed with `source_changed` is built from the changed file; a file that is gone
fails again. The answer may already show a retried item as `building`.

### `DELETE /api/v1/jobs/{id}`

Cancels the job: `queued` items become `cancelled`; items already `building` finish and their results stay in the
cache. `200` `{"job": { … }}`. Cancelling a job that is not `active` changes nothing and returns it.

## Asking for files without a job

A job makes the server build. A lookup only asks what the server already has, so a client can collect finished
smart previews for files it (or anything else: the dashboard, an automatic scan) asked for earlier, without knowing
which job built them.

### `POST /api/v1/lookup`

```json
{"items": [{"ref": "17", "root": "archive", "path": "2026/2026.06.20 - shoot/IMG_0001.ARW"}]}
```

1 to `capabilities.maxItemsPerJob` items with unique `ref`s. Nothing is queued and nothing is stored.

`200`:

```json
{
  "items": [
    {"ref": "17", "state": "ready", "error": null,
     "result": {"key": "5d41…", "size": 359310, "sha256": "9f2c…",
                "originalName": "IMG_0001.ARW", "originalWidth": 6000, "originalHeight": 4000}}
  ]
}
```

One entry per requested item, in request order. `state` is one of:

| State | Meaning |
|---|---|
| `ready` | The DNG for this file, as it is now (same size and modification time), is in the cache; `result` as in an item object |
| `pending` | Not in the cache, but an item of some job for this file is `queued` or `building` |
| `absent` | Not in the cache and nothing is on its way |
| `rejected` | The request for this file is not acceptable; `error` as for a rejected item |

`result` is `null` unless `ready`; `error` is `null` unless `rejected`. Errors: `413` `too_many_items`, `422` for a
malformed body, `422` `duplicate_ref`.

### `GET /api/v1/files/{key}`

The DNG with this cache key, with the same headers as `GET /api/v1/items/{id}/file`. `404` with
`"code": "not_in_cache"` when there is no such DNG (a `key` is only valid as long as the original has not changed and
the cache still holds the file; look the file up again). `422` for a key that is not 64 lower-case hex characters.

## `GET /api/v1/status`

For the dashboard.

```json
{
  "state": "running",
  "queue": {"queued": 300, "building": 8},
  "workers": {"configured": 4, "busy": 4},
  "rate": {"perMinute": 172.5, "windowSeconds": 60},
  "etaSeconds": 104,
  "today": {"built": 1234, "failed": 2},
  "cache": {"entries": 5321, "bytes": 2890000000},
  "jobs": {"active": 1},
  "cpuTemperature": 67.5,
  "autoScan": {"running": false, "lastRun": "2026-11-14T09:00:00Z", "lastQueued": 120, "nextRun": "2026-11-14T10:00:00Z"}
}
```

`state`: `running` (building, or about to), `idle` (nothing queued), `paused` (the `paused` setting is on),
`waiting` (work is queued but the working hours have not begun). While a wave or a self-test is in progress the
state is `running` whatever the settings say; otherwise `paused` wins over `idle`, and `idle` over `waiting`. `queue`: items over all jobs.
`workers.configured`: the number of converter processes the server may run side by side; `busy`: how many run now.
`rate.perMinute`: items built in the last `windowSeconds`, scaled to a minute; 0 when idle. `etaSeconds`: an
estimate of the time until the queue is empty from the current rate (counting files, like `rate`), or `null` when there is nothing to estimate
(idle, paused, waiting, or no rate yet). `today`: since local midnight of the server. `rate` and `today` count
conversions, not items: a file two jobs asked for counts once, and `rate` counts successful conversions only.
`cache`: the DNGs kept. `cpuTemperature`: degrees Celsius of the hottest CPU sensor the server can read, or `null`.
`autoScan`: whether a scan is going on (true from the moment one is asked for), when the last one finished and how
many files it queued (`null` and 0 before the first ever; both are kept across restarts), and when the next is due
(`null` while the automatic scan is off; while a scan runs, its start plus the interval).

## Settings

Settings that can be changed while the server runs. They are kept in the server's database; the environment
variables only give their first values.

### `GET /api/v1/settings`

```json
{
  "workers": "auto",
  "effectiveWorkers": 4,
  "batchSize": 8,
  "paused": false,
  "workingHours": {"enabled": false, "from": "22:00", "to": "07:00"},
  "autoScan": {"enabled": false, "roots": [], "intervalMinutes": 60, "settleMinutes": 15, "maxFilesPerRun": 2000},
  "cache": {"maxBytes": null, "maxAgeDays": null}
}
```

| Field | Meaning |
|---|---|
| `workers` | `"auto"` or a whole number from 1 to 32, never 2 (two converter processes side by side waste CPU time) |
| `effectiveWorkers` | What `workers` comes to on this machine. Read-only |
| `batchSize` | Files per converter process in one wave, 1 to 64 |
| `paused` | When true no new wave starts; a wave that is running finishes |
| `workingHours` | When `enabled`, waves start only between `from` and `to`, local time of the server, `HH:MM` in 24-hour form. `from` later than `to` means a window across midnight. `from` equal to `to` is refused |
| `autoScan` | The automatic scan (below). `roots`: ids of the roots to scan, each must exist; `intervalMinutes` 5 to 1440; `settleMinutes` 0 to 1440; `maxFilesPerRun` 1 to 50000 |
| `cache` | Limits for the cache clean-up (below). `maxBytes`: `null` for no limit, or at least 104857600 (100 MiB); `maxAgeDays`: `null` for no limit, or 1 to 3650 |

### `PATCH /api/v1/settings`

A JSON object with any subset of `workers`, `batchSize`, `paused`, `workingHours`, `autoScan`, `cache` (each of the
last three as a whole object when it is given). `200` with the settings object after the change. `422` when a value is not acceptable
(including an explicit `null`, and `from` equal to `to` even when `enabled` is false); nothing is changed then.
Fields the server does not know, and the read-only `effectiveWorkers`, are ignored, so a client may send back
what it read. A change takes effect with the next wave. A value that was never changed this way keeps following
the server's environment variables.

## Browsing the roots and queueing a folder

### `GET /api/v1/browse`

Query: `root` (a root id), `path` (a folder relative to the root; empty or absent for the root itself).

```json
{
  "root": "archive",
  "path": "2026",
  "parent": "",
  "dirs": [{"name": "2026.06.20 - shoot", "path": "2026/2026.06.20 - shoot"}],
  "rawFiles": 0,
  "builtFiles": 0,
  "otherFiles": 12,
  "truncated": false
}
```

`parent` is the path of the folder above, `""` for a folder directly under the root, `null` for the root itself.
`dirs`: the sub-folders, sorted by name without regard to case. Names that start with a dot and symbolic links are
left out, here and in every count, and so are names a client could not send back as a path.
`rawFiles`: the files directly in this folder that the server accepts as camera raw files; `builtFiles`: how many
of those have their DNG in the cache now; `otherFiles`: the other files directly in this folder. Nothing is counted
in sub-folders. `truncated` is true when the folder has more than 5000 sub-folders and the list was cut. Errors:
`404` with `"code"` `unknown_root`, `root_unavailable` or `not_found`; `422` `bad_path`; `422` `not_a_folder`.

### `POST /api/v1/folders`

Queues the raw files of a folder.

```json
{"root": "archive", "path": "2026/2026.06.20 - shoot", "recursive": false, "label": null, "priority": "normal"}
```

`recursive` (default false) also takes the files of all sub-folders (not following symbolic links, skipping names
that start with a dot). `priority` is optional (`normal` by default). `label` is optional; without it the jobs are labelled with the folder's path (the root's
id for the root itself). `path` may be absent or empty for the root.

`201`:

```json
{"files": 1384, "alreadyBuilt": 300, "jobs": [ …job objects… ]}
```

The files are put into one job, or several when there are more than `capabilities.maxItemsPerJob`; the jobs have
`client` `"dashboard"` and no `clientId`. `files` is the number of raw files found, `alreadyBuilt` how many of them
were in the cache already (their items are `ready` at once). A folder without raw files gives `201` with
`"files": 0` and no jobs. Errors: as for browse; `409` `converter_not_installed`; `422` with
`"code": "too_many_files"` when more than 50000 raw files are found (queue sub-folders instead).

## The automatic scan

Off unless `autoScan.enabled` is set. Every `intervalMinutes` the server walks the listed roots (all sub-folders;
not following symbolic links; skipping names that start with a dot), and queues every camera raw file that is not
in the cache, is not already queued or building, and was last modified at least `settleMinutes` ago (so that a file
still being copied is left alone). It queues at most `maxFilesPerRun` files per run, oldest folders first (a
folder is as old as its oldest raw file); the rest wait for the next run. The files go into jobs with `client`
`"auto-scan"`, `priority` `"background"`, no `clientId`, and the label `Automatic scan: <root id>`. A file that
failed in an earlier automatic job is not queued again until it changes. Scanning does not depend on `paused` or
the working hours; building what it queued does.

A scan is due `intervalMinutes` after the previous one finished, and at once when none has ever run. A scan started
by hand counts as a scan. While the converter is not installed the periodic scan is skipped.

### `POST /api/v1/autoscan/run`

Starts a scan now, whether or not the automatic scan is enabled, over the roots in `autoScan.roots` (or, with a
body `{"roots": ["archive"]}`, over those; no body, `{}`, `"roots": null` and an empty list all mean the configured
roots). `202` `{"started": true}`. Errors, checked in this order: `422` when no root is given and none is
configured; `422` with `"code": "unknown_root"` for a root id the server does not have; `409`
`converter_not_installed`; `409` with `"code": "busy"` when a scan is running.

## The cache clean-up

The cache only grows unless it is cleaned. A clean-up removes, in this order:

1. DNGs whose original is gone or has changed (another size or modification time);
2. DNGs not used for `cache.maxAgeDays` days («used» = built, found by a job or a lookup, or downloaded);
3. the least recently used DNGs until the cache is no larger than `cache.maxBytes`.

Steps 2 and 3 are skipped while their limit is `null`. A DNG that an item of an active job points to (an item in
any state) is never removed. An original is not treated as gone while its root is unavailable, is no longer
configured, or is an empty folder (a volume that is not mounted often leaves one). The server runs a clean-up a
day after the previous one (not at start); removed files are simply built again if somebody asks for them. An item
that was `ready` stays `ready` when its DNG is removed; its `result` becomes `null`.

### `POST /api/v1/cache/clean`

Body optional: `{"dryRun": true}` only counts (`dryRun` must be a JSON boolean, anything else is `422`). The
clean-up runs inside the request, so on a large cache the answer can take minutes. `200`:

```json
{"dryRun": false, "removed": {"originalGone": 12, "expired": 0, "overLimit": 0}, "bytesFreed": 6291456}
```

`bytesFreed`: the size of the removed DNGs (with `dryRun`, of those that would be removed). `409` with
`"code": "busy"` when a clean-up is running.

## The converter

### `POST /api/v1/converter/selftest`

Checks that the converter can run, step by step, and reports each step. The body is optional:
`{"root": "archive", "path": "2026/2026.06.20 - shoot/IMG_0001.ARW"}` names a raw file to convert as the last step;
without it only the first steps run. The result of the conversion is not kept.

`200`:

```json
{
  "ok": true,
  "steps": [
    {"name": "installed", "ok": true, "detail": "C:\\Program Files\\Adobe\\Adobe DNG Converter\\Adobe DNG Converter.exe, version 17.2"},
    {"name": "display", "ok": true, "detail": "Xvfb on :99"},
    {"name": "warm-up", "ok": true, "detail": "not needed"},
    {"name": "conversion", "ok": true, "detail": "IMG_0001.ARW → 359310 bytes in 2.1 s, original name and size recorded"}
  ]
}
```

Step names, in order: `installed`, `display`, `warm-up`, `conversion` (only with a file). A step that fails has
`"ok": false` and a `detail` that says why, with the last lines of the converter's output where there is any; the
steps after it are left out and `ok` at the top is false. The self-test waits for a running wave to finish and
keeps new waves from starting while it runs. `409` with `"code": "busy"` when another self-test is running. The
request for the file is checked like an item of a job (`422` with the item's rejection code as `code`).

## `GET /api/v1/log`

The server's recent log lines, for the dashboard. Query: `limit` (1–1000, default 200).

```json
{"lines": [{"time": "2026-11-14T09:30:00Z", "level": "INFO", "logger": "lrrp.scheduler", "message": "wave: 32 file(s) …"}]}
```

Oldest first, the newest `limit` lines of the last 1000 the server keeps in memory since it started. Request lines
of the HTTP server are not included. The token never appears in a line.

## What a client must do with a delivered file

This is the plug-in's side of the safety rules (decision record 0005), stated here because it is part of the
contract of using the API:

1. Download the file and check its length (and, where practical, its SHA-256) against `result`.
2. Read `OriginalRawFileName` and `OriginalDefaultFinalSize` from the DNG itself and compare them with the photo
   the file is meant for. The server's `result` values are a convenience, not the check.
3. Write under a temporary name in the destination folder, then rename. Never replace an existing file.
