#!/usr/bin/env python3
"""Submit a job to an LR Remote Previews server, follow it, and optionally download the DNGs.

A small client of the protocol in docs/protocol.md for development and for checking a server without Lightroom.

    python tools/submit_job.py --server http://nas.local:8787 --token T --root archive \\
        "2026/shoot/IMG_0001.ARW" "2026/shoot/IMG_0002.ARW" --download out/

    # every raw file of a local folder, as paths relative to the root:
    python tools/submit_job.py --server … --root archive --prefix "2026/shoot" --from-folder "Z:\\2026\\shoot"

Paths are relative to the root, with forward slashes. `--from-folder` only reads the file names of a local folder
(it does not upload anything): each name is joined to `--prefix`. The token can also come from the environment
variable LRRP_TOKEN. Standard library only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


class Client:
    def __init__(self, server: str, token: str | None) -> None:
        self.base = server.rstrip("/") + "/api/v1/"
        self.headers = {"Authorization": f"Bearer {token}"} if token else {}
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(self, method: str, path: str, body: object | None = None) -> tuple[bytes, dict[str, str]]:
        data = None if body is None else json.dumps(body).encode("utf-8")
        headers = dict(self.headers)
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
        # A GET is repeated for a while when the server cannot be reached, so that following a job
        # survives a restart of the server. Other methods are tried once.
        deadline = time.monotonic() + (120 if method == "GET" else 0)
        while True:
            try:
                with self.opener.open(request, timeout=60) as response:
                    return response.read(), {k.lower(): v for k, v in response.headers.items()}
            except urllib.error.HTTPError as exc:
                detail = exc.read().decode("utf-8", "replace")
                raise SystemExit(f"error: {method} {path}: HTTP {exc.code}: {detail}") from None
            except (urllib.error.URLError, ConnectionError, TimeoutError) as exc:
                if time.monotonic() >= deadline:
                    raise SystemExit(f"error: {method} {path}: {exc}") from None
                print(f"  server not reachable ({exc}); trying again")
                time.sleep(2)

    def json(self, method: str, path: str, body: object | None = None) -> dict:
        return json.loads(self.request(method, path, body)[0])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--server", required=True)
    parser.add_argument("--token", default=os.environ.get("LRRP_TOKEN"))
    parser.add_argument("--root", required=True, help="root id on the server")
    parser.add_argument("--prefix", default="", help="path under the root that --from-folder names are joined to")
    parser.add_argument("--from-folder", help="take the raw file names of this local folder")
    parser.add_argument("--limit", type=int, help="send at most this many files")
    parser.add_argument("--download", help="folder to download the DNGs into")
    parser.add_argument("--label", default="tools/submit_job.py")
    parser.add_argument("paths", nargs="*", help="paths relative to the root")
    args = parser.parse_args()

    client = Client(args.server, args.token)
    info = client.json("GET", "info")
    print(f"server {info['name']} {info['version']}, converter installed: {info['converter']['installed']}")

    paths = list(args.paths)
    if args.from_folder:
        extensions = set(info["capabilities"]["extensions"])
        names = sorted(p.name for p in Path(args.from_folder).iterdir() if p.suffix.lower() in extensions)
        prefix = args.prefix.strip("/")
        paths += [f"{prefix}/{name}" if prefix else name for name in names]
    if args.limit:
        paths = paths[: args.limit]
    if not paths:
        parser.error("no files given")

    started = time.monotonic()
    created = client.json(
        "POST",
        "jobs",
        {
            "client": "submit_job.py",
            "label": args.label,
            "items": [{"ref": str(i), "root": args.root, "path": p} for i, p in enumerate(paths)],
        },
    )
    job = created["job"]
    items = {item["id"]: item for item in created["items"]}
    seq = job["seq"]
    print(f"job {job['id']}: {job['counts']}")

    last_print = 0.0
    while job["state"] == "active":
        time.sleep(1.0)
        while True:
            page = client.json("GET", f"jobs/{job['id']}/items?since={seq}&limit=1000")
            job = page["job"]
            for item in page["items"]:
                items[item["id"]] = item
                seq = max(seq, item["seq"])
            if not page["more"]:
                break
        now = time.monotonic()
        if now - last_print >= 5 or job["state"] != "active":
            counts = job["counts"]
            print(f"  {now - started:6.1f} s  ready {counts['ready']:4}  building {counts['building']:3}  "
                  f"queued {counts['queued']:4}  failed {counts['failed']}  rejected {counts['rejected']}")
            last_print = now
    elapsed = time.monotonic() - started

    counts = job["counts"]
    built = counts["ready"]
    print(f"job {job['id']} {job['state']} in {elapsed:.1f} s: {counts}")
    if built:
        print(f"  {elapsed / built:.2f} s per ready file, {built / elapsed * 60:.0f} per minute (cached files included)")
    for item in sorted(items.values(), key=lambda i: i["id"]):
        if item["state"] not in ("ready",):
            error = item.get("error") or {}
            print(f"  {item['state']:9} {item['path']}: {error.get('code')} {error.get('message')}")

    if args.download:
        out = Path(args.download)
        out.mkdir(parents=True, exist_ok=True)
        total = 0
        started = time.monotonic()
        for item in sorted(items.values(), key=lambda i: i["id"]):
            if item["state"] != "ready":
                continue
            data, headers = client.request("GET", f"items/{item['id']}/file")
            digest = hashlib.sha256(data).hexdigest()
            result = item["result"]
            if len(data) != result["size"] or digest != result["sha256"] or headers.get("x-lrrp-sha256") != digest:
                raise SystemExit(f"error: {item['path']}: the download does not match the item's size or SHA-256")
            (out / (Path(item["path"]).stem + ".dng")).write_bytes(data)
            total += len(data)
        elapsed = time.monotonic() - started
        print(f"downloaded {built} files, {total / 1e6:.1f} MB in {elapsed:.1f} s into {out}")

    status = client.json("GET", "status")
    print(f"status: {json.dumps(status)}")
    return 0 if counts["failed"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
