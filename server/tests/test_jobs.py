"""End to end through the HTTP API, with the fake converter in place of Wine."""

import hashlib
import json
import os
import re
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from conftest import Harness, items_by_path, post_job, wait_for, wait_job
from fake_converter import ORIGINAL_HEIGHT, ORIGINAL_WIDTH, dng_bytes
from lrrp.app import MAX_ITEMS_PER_JOB


def check_download(client: TestClient, item: dict[str, Any], name: str, content: bytes) -> None:
    """The item's file is the DNG the fake converter made from ``content``, with its headers."""
    response = client.get(f"/api/v1/items/{item['id']}/file")
    assert response.status_code == 200, response.text
    body = response.content
    assert body == dng_bytes(name, content)
    assert response.headers["content-type"] == "image/x-adobe-dng"
    assert response.headers["content-length"] == str(len(body))
    digest = hashlib.sha256(body).hexdigest()
    assert response.headers["x-lrrp-sha256"] == digest
    assert item["result"] == {
        "size": len(body),
        "sha256": digest,
        "originalName": name,
        "originalWidth": ORIGINAL_WIDTH,
        "originalHeight": ORIGINAL_HEIGHT,
    }


def building(client: TestClient, job_id: int) -> int:
    return client.get(f"/api/v1/jobs/{job_id}").json()["job"]["counts"]["building"]


def test_happy_path(harness: Harness) -> None:
    paths = ["2026/2026.06.20 - shoot/IMG_0001.ARW", "2026/IMG_0002.arw", "scans/Día 3/DSC_7.NEF"]
    for path in paths:
        harness.raw(path)
    with harness.client(workers=3, batch_size=8) as client:
        created = post_job(client, paths, label="Selection")
        job = created["job"]
        assert job["state"] == "active"
        assert job["label"] == "Selection"
        assert job["client"] is None
        assert job["finished"] is None
        assert job["seq"] == 3
        assert job["counts"]["total"] == 3
        assert job["counts"]["queued"] == 3
        assert [item["ref"] for item in created["items"]] == ["0", "1", "2"]
        assert [item["seq"] for item in created["items"]] == [1, 2, 3]
        assert all(item["state"] == "queued" for item in created["items"])
        assert all(item["error"] is None and item["result"] is None for item in created["items"])

        # Poll with since, as a client does, and collect every state change.
        seen: dict[str, list[str]] = {path: [] for path in paths}
        since = 0

        def poll() -> bool:
            nonlocal since
            page = client.get(f"/api/v1/jobs/{job['id']}/items", params={"since": since}).json()
            for item in page["items"]:
                assert item["seq"] > since
                since = item["seq"]
                seen[item["path"]].append(item["state"])
            return page["job"]["state"] != "active"

        wait_for(poll, what="the job")
        poll()
        assert all(states[-1] == "ready" for states in seen.values()), seen

        done = client.get(f"/api/v1/jobs/{job['id']}").json()["job"]
        assert done["state"] == "done"
        assert done["finished"] is not None
        assert done["created"].endswith("Z")
        assert done["seq"] == since == 9, "created, building, ready: three changes per item"
        assert done["counts"] == {
            "total": 3,
            "queued": 0,
            "building": 0,
            "ready": 3,
            "failed": 0,
            "rejected": 0,
            "cancelled": 0,
        }
        items = items_by_path(client, job["id"])
        for path in paths:
            check_download(client, items[path], path.rsplit("/", 1)[-1], path.encode())
    # One batch with all three files: no retries.
    assert [sorted(run) for run in harness.runs()] == [
        sorted(path.rsplit("/", 1)[-1] for path in paths)
    ]


def test_a_second_job_is_served_from_the_cache(harness: Harness) -> None:
    harness.raw("a/IMG_0001.ARW")
    harness.raw("a/IMG_0002.ARW")
    with harness.client() as client:
        first = post_job(client, ["a/IMG_0001.ARW"])
        wait_job(client, first["job"]["id"])
        runs = len(harness.runs())
        second = post_job(client, ["a/IMG_0001.ARW", "a/IMG_0002.ARW"])
        hit, miss = second["items"]
        assert hit["state"] == "ready"
        assert hit["result"]["originalName"] == "IMG_0001.ARW"
        assert miss["state"] == "queued"
        wait_job(client, second["job"]["id"])
        check_download(client, hit, "IMG_0001.ARW", b"a/IMG_0001.ARW")
    assert harness.runs()[runs:] == [["IMG_0002.ARW"]]
    assert harness.runs_with("IMG_0001.ARW") == 1


def test_a_job_where_everything_is_cached_is_done_at_once(harness: Harness) -> None:
    harness.raw("IMG_0001.ARW")
    with harness.client() as client:
        wait_job(client, post_job(client, ["IMG_0001.ARW"])["job"]["id"])
        job = post_job(client, ["IMG_0001.ARW"])["job"]
        assert job["state"] == "done"
        assert job["finished"] == job["created"]
        assert job["counts"]["ready"] == 1


def test_a_changed_original_gets_a_new_build(harness: Harness) -> None:
    original = harness.raw("IMG_0001.ARW", b"first version")
    with harness.client() as client:
        wait_job(client, post_job(client, ["IMG_0001.ARW"])["job"]["id"])
        original.write_bytes(b"second version, longer")
        body = post_job(client, ["IMG_0001.ARW"])
        assert body["items"][0]["state"] == "queued"
        wait_job(client, body["job"]["id"])
        item = items_by_path(client, body["job"]["id"])["IMG_0001.ARW"]
        check_download(client, item, "IMG_0001.ARW", b"second version, longer")
    assert harness.runs_with("IMG_0001.ARW") == 2


def test_a_cache_entry_whose_file_is_gone_is_built_again(harness: Harness) -> None:
    harness.raw("IMG_0001.ARW")
    with harness.client() as client:
        first = post_job(client, ["IMG_0001.ARW"])
        wait_job(client, first["job"]["id"])
        old = items_by_path(client, first["job"]["id"])["IMG_0001.ARW"]
        for dng in (harness.tmp / "cache").glob("*/*.dng"):
            dng.unlink()
        response = client.get(f"/api/v1/items/{old['id']}/file")
        assert response.status_code == 404
        assert response.json()["code"] == "not_in_cache"
        second = post_job(client, ["IMG_0001.ARW"])
        assert second["items"][0]["state"] == "queued"
        wait_job(client, second["job"]["id"])
        item = items_by_path(client, second["job"]["id"])["IMG_0001.ARW"]
        check_download(client, item, "IMG_0001.ARW", b"IMG_0001.ARW")
        check_download(client, old, "IMG_0001.ARW", b"IMG_0001.ARW")
    assert harness.runs_with("IMG_0001.ARW") == 2


def test_rejections(harness: Harness) -> None:
    harness.raw("ok/IMG_0001.ARW")
    harness.raw("ok/photo.jpg")
    (harness.originals / "folder.ARW").mkdir()
    cases = [
        ("archive", "", "bad_path"),
        ("archive", "/ok/IMG_0001.ARW", "bad_path"),
        ("archive", "ok\\IMG_0001.ARW", "bad_path"),
        ("archive", "ok/../ok/IMG_0001.ARW", "bad_path"),
        ("archive", "./ok/IMG_0001.ARW", "bad_path"),
        ("archive", "ok//IMG_0001.ARW", "bad_path"),
        ("archive", "ok/IMG_0001.ARW/", "bad_path"),
        ("archive", "ok/IMG\x000001.ARW", "bad_path"),
        ("archive", "ok/" + "x" * 5000 + ".ARW", "bad_path"),
        ("archive", "ok/photo.jpg", "unsupported_format"),
        ("archive", "ok/README", "unsupported_format"),
        ("archive", "ok/IMG_0009.ARW", "not_found"),
        ("archive", "missing/IMG_0001.ARW", "not_found"),
        ("archive", "ok/IMG_0001.ARW/x.ARW", "not_found"),
        ("archive", "folder.ARW", "not_a_file"),
        ("nowhere", "ok/IMG_0001.ARW", "unknown_root"),
        ("offline", "ok/IMG_0001.ARW", "root_unavailable"),
    ]
    items = [
        {"ref": str(index), "root": root, "path": path}
        for index, (root, path, _) in enumerate(cases)
    ]
    with harness.client() as client:
        response = client.post("/api/v1/jobs", json={"items": items})
        assert response.status_code == 201, response.text
        body = response.json()
        assert body["job"]["state"] == "done"
        assert body["job"]["finished"] is not None
        assert body["job"]["counts"]["rejected"] == len(cases)
        for item, (root, path, code) in zip(body["items"], cases, strict=True):
            assert item["state"] == "rejected", (root, path)
            assert item["error"]["code"] == code, (root, path, item["error"])
            assert item["error"]["message"]
            assert item["result"] is None
            assert item["root"] == root
            assert item["path"] == path
        assert str(harness.tmp) not in response.text
        assert str(harness.tmp).replace("\\", "\\\\") not in response.text
    assert harness.runs() == []


def test_a_symbolic_link_out_of_the_root_is_rejected(harness: Harness) -> None:
    outside = harness.tmp / "outside"
    outside.mkdir()
    (outside / "IMG_0001.ARW").write_bytes(b"not under the root")
    harness.raw("inside/IMG_0002.ARW")
    try:
        (harness.originals / "link.ARW").symlink_to(outside / "IMG_0001.ARW")
        (harness.originals / "linkdir").symlink_to(outside, target_is_directory=True)
        (harness.originals / "inner.ARW").symlink_to(harness.originals / "inside" / "IMG_0002.ARW")
    except (OSError, NotImplementedError) as exc:
        pytest.skip(f"cannot create symbolic links here: {exc}")
    with harness.client() as client:
        body = post_job(client, ["link.ARW", "linkdir/IMG_0001.ARW", "inner.ARW"])
        escaped, escaped_dir, inner = body["items"]
        assert escaped["error"]["code"] == "bad_path"
        assert escaped_dir["error"]["code"] == "bad_path"
        assert inner["state"] == "queued"
        wait_job(client, body["job"]["id"])
        inner = items_by_path(client, body["job"]["id"])["inner.ARW"]
        # The converter gets the link's own path, so the DNG names the requested file.
        check_download(client, inner, "inner.ARW", b"inside/IMG_0002.ARW")
    assert harness.runs() == [["inner.ARW"]]


def test_converter_not_installed(harness: Harness) -> None:
    harness.raw("IMG_0001.ARW")
    (harness.prefix / "drive_c" / "Program Files").rename(harness.prefix / "drive_c" / "Gone")
    item = {"ref": "1", "root": "archive", "path": "IMG_0001.ARW"}
    with harness.client() as client:
        response = client.post("/api/v1/jobs", json={"items": [item]})
        assert response.status_code == 409
        assert response.json()["code"] == "converter_not_installed"
        assert response.json()["detail"]
        assert client.get("/api/v1/jobs").json()["jobs"] == []
        # With nothing to build the job is created.
        body = post_job(client, ["IMG_0001.jpg"])
        assert body["items"][0]["error"]["code"] == "unsupported_format"


def test_a_failing_file_is_retried_once_and_the_others_succeed(harness: Harness) -> None:
    for name in ("IMG_0001.ARW", "BAD.ARW", "IMG_0003.ARW"):
        harness.raw(name)
    with harness.client(workers=1, fake={"FAKE_CONVERTER_FAIL": "bad.arw"}) as client:
        body = post_job(client, ["IMG_0001.ARW", "BAD.ARW", "IMG_0003.ARW"])
        job = wait_job(client, body["job"]["id"])
        assert job["counts"]["ready"] == 2
        assert job["counts"]["failed"] == 1
        items = items_by_path(client, job["id"])
        bad = items["BAD.ARW"]
        assert bad["state"] == "failed"
        assert bad["error"]["code"] == "converter_failed"
        assert "code 1" in bad["error"]["message"]
        assert bad["result"] is None
        check_download(client, items["IMG_0003.ARW"], "IMG_0003.ARW", b"IMG_0003.ARW")
        status = client.get("/api/v1/status").json()
        assert status["today"] == {"built": 2, "failed": 1}
    runs = harness.runs()
    assert sorted(runs[0]) == ["BAD.ARW", "IMG_0001.ARW", "IMG_0003.ARW"]
    assert sorted(runs[1:]) == [["BAD.ARW"], ["IMG_0001.ARW"], ["IMG_0003.ARW"]]
    assert harness.runs_with("BAD.ARW") == 2


def test_a_missing_output_is_retried_once(harness: Harness) -> None:
    for name in ("IMG_0001.ARW", "GONE.ARW"):
        harness.raw(name)
    with harness.client(workers=1, fake={"FAKE_CONVERTER_SKIP": "GONE.ARW"}) as client:
        body = post_job(client, ["IMG_0001.ARW", "GONE.ARW"])
        job = wait_job(client, body["job"]["id"])
        items = items_by_path(client, job["id"])
        assert items["IMG_0001.ARW"]["state"] == "ready"
        assert items["GONE.ARW"]["state"] == "failed"
        assert items["GONE.ARW"]["error"]["code"] == "output_missing"
    # The batch exited with 0, so only the file without an output ran again.
    assert harness.runs_with("GONE.ARW") == 2
    assert harness.runs_with("IMG_0001.ARW") == 1


def test_a_dng_naming_another_original_is_not_used(harness: Harness) -> None:
    harness.raw("IMG_0001.ARW")
    with harness.client(fake={"FAKE_CONVERTER_WRONG_NAME": "IMG_0001.ARW"}) as client:
        body = post_job(client, ["IMG_0001.ARW"])
        wait_job(client, body["job"]["id"])
        item = items_by_path(client, body["job"]["id"])["IMG_0001.ARW"]
        assert item["state"] == "failed"
        assert item["error"]["code"] == "output_mismatch"
        assert "OTHER_IMG_0001.ARW" in item["error"]["message"]
        response = client.get(f"/api/v1/items/{item['id']}/file")
        assert response.status_code == 409
        assert response.json()["code"] == "not_ready"
        # Not cached: asking again builds again.
        again = post_job(client, ["IMG_0001.ARW"])
        assert again["items"][0]["state"] == "queued"
        wait_job(client, again["job"]["id"])
    assert list((harness.tmp / "cache").glob("*/*.dng")) == []
    assert harness.runs_with("IMG_0001.ARW") == 2, "a mismatch is not retried"


def test_a_hanging_converter_is_stopped(harness: Harness) -> None:
    for name in ("IMG_0001.ARW", "SLOW.ARW"):
        harness.raw(name)
    with harness.client(
        workers=1,
        timeout_base=1.0,
        timeout_per_file=0.0,
        fake={"FAKE_CONVERTER_HANG": "SLOW.ARW"},
    ) as client:
        body = post_job(client, ["IMG_0001.ARW", "SLOW.ARW"])
        job = wait_job(client, body["job"]["id"])
        items = items_by_path(client, job["id"])
        assert items["IMG_0001.ARW"]["state"] == "ready"
        slow = items["SLOW.ARW"]
        assert slow["error"]["code"] == "converter_timeout"
        assert "1 s" in slow["error"]["message"]
        assert client.get("/api/v1/status").json()["workers"]["busy"] == 0
    assert harness.runs_with("SLOW.ARW") == 2


def test_files_with_the_same_base_name_never_share_a_batch(harness: Harness) -> None:
    paths = [
        "a/IMG_0001.ARW",
        "b/IMG_0001.ARW",
        "c/img_0001.arw",
        "d/IMG_0001.CR2",
        "e/IMG_0002.ARW",
        "f/IMG_0002.NEF",
        "g/IMG_0003.ARW",
    ]
    for path in paths:
        harness.raw(path)
    with harness.client(workers=3, batch_size=2) as client:
        body = post_job(client, paths)
        job = wait_job(client, body["job"]["id"])
        assert job["counts"]["ready"] == len(paths)
        items = items_by_path(client, job["id"])
        for path in paths:
            check_download(client, items[path], path.rsplit("/", 1)[-1], path.encode())
    runs = harness.runs()
    for run in runs:
        stems = [Path(name).stem.casefold() for name in run]
        assert len(stems) == len(set(stems)), run
    assert sum(len(run) for run in runs) == len(paths), "no file ran twice"


def test_cancel(harness: Harness) -> None:
    paths = [f"IMG_000{index}.ARW" for index in range(1, 5)]
    for path in paths:
        harness.raw(path)
    with harness.client(workers=1, batch_size=1, fake={"FAKE_CONVERTER_DELAY": "1.0"}) as client:
        job_id = post_job(client, paths)["job"]["id"]
        wait_for(lambda: building(client, job_id), what="a building item")
        response = client.delete(f"/api/v1/jobs/{job_id}")
        assert response.status_code == 200
        cancelled = response.json()["job"]
        assert cancelled["state"] == "cancelled"
        assert cancelled["finished"] is not None
        assert cancelled["counts"]["queued"] == 0
        assert cancelled["counts"]["cancelled"] >= 1

        def settled() -> dict[str, Any] | None:
            job = client.get(f"/api/v1/jobs/{job_id}").json()["job"]
            return job if job["counts"]["building"] == 0 else None

        job = wait_for(settled, what="the building item")
        assert job["state"] == "cancelled"
        assert job["finished"] == cancelled["finished"]
        counts = job["counts"]
        assert counts["ready"] >= 1, "the item that was building finished"
        assert counts["ready"] + counts["cancelled"] == len(paths)
        cancelled_items = client.get(
            f"/api/v1/jobs/{job_id}/items", params={"state": "cancelled"}
        ).json()["items"]
        assert len(cancelled_items) == counts["cancelled"]
        assert all(item["error"] is None for item in cancelled_items)
        # Cancelling again changes nothing.
        assert client.delete(f"/api/v1/jobs/{job_id}").json()["job"] == job
        assert client.get("/api/v1/jobs", params={"state": "cancelled"}).json()["jobs"] == [job]
        time.sleep(0.3)
        assert client.get("/api/v1/status").json()["queue"] == {"queued": 0, "building": 0}
    assert len(harness.runs()) == counts["ready"]


def test_cancelling_a_finished_job_changes_nothing(harness: Harness) -> None:
    with harness.client() as client:
        job = post_job(client, ["photo.jpg"])["job"]
        assert job["state"] == "done"
        response = client.delete(f"/api/v1/jobs/{job['id']}")
        assert response.status_code == 200
        assert response.json()["job"] == job
        response = client.delete("/api/v1/jobs/999")
        assert response.status_code == 404
        assert response.json() == {"detail": "No such job"}


def test_items_left_by_a_stopped_server_are_built_after_a_restart(harness: Harness) -> None:
    paths = [f"IMG_000{index}.ARW" for index in range(1, 6)]
    for path in paths:
        harness.raw(path)
    with harness.client(workers=3, batch_size=1, fake={"FAKE_CONVERTER_DELAY": "60"}) as client:
        job_id = post_job(client, paths)["job"]["id"]

        def three_building() -> bool:
            counts = client.get(f"/api/v1/jobs/{job_id}").json()["job"]["counts"]
            return counts["building"] == 3 and counts["queued"] == 2

        wait_for(three_building, what="three building items")
        url = f"/api/v1/jobs/{job_id}/items"
        page = client.get(url, params={"state": "building"}).json()
        were_building = {item["id"] for item in page["items"]}
        before = page["job"]["seq"]
        stopping = time.monotonic()
    # The server stopped with three items building (their converters were killed) and two queued.
    assert time.monotonic() - stopping < 20
    with harness.client(workers=3, batch_size=1) as client:
        # Going back to the queue at the start is a state change, so pollers see those items.
        changed = client.get(url, params={"since": before}).json()["items"]
        assert were_building <= {item["id"] for item in changed}
        job = wait_job(client, job_id)
        assert job["state"] == "done"
        assert job["counts"]["ready"] == len(paths)
        items = items_by_path(client, job_id)
        for path in paths:
            check_download(client, items[path], path, path.encode())
    assert list((harness.tmp / "cache" / "work").iterdir()) == []


def test_two_jobs_asking_for_the_same_file_build_it_once(harness: Harness) -> None:
    harness.raw("IMG_0001.ARW")
    with harness.client(workers=1, batch_size=1, fake={"FAKE_CONVERTER_DELAY": "1.0"}) as client:
        first = post_job(client, ["IMG_0001.ARW"])["job"]["id"]
        wait_for(lambda: building(client, first), what="the first build")
        second = post_job(client, ["IMG_0001.ARW"])
        assert second["items"][0]["state"] == "queued"
        wait_job(client, first)
        wait_job(client, second["job"]["id"])
        one = items_by_path(client, first)["IMG_0001.ARW"]
        two = items_by_path(client, second["job"]["id"])["IMG_0001.ARW"]
        assert one["state"] == two["state"] == "ready"
        assert one["result"] == two["result"]
    assert harness.runs_with("IMG_0001.ARW") == 1


def test_a_source_that_changes_before_its_build_fails(harness: Harness) -> None:
    for name in ("IMG_0001.ARW", "IMG_0002.ARW", "IMG_0003.ARW"):
        harness.raw(name)
    with harness.client(workers=1, batch_size=1, fake={"FAKE_CONVERTER_DELAY": "1.0"}) as client:
        job_id = post_job(client, ["IMG_0001.ARW", "IMG_0002.ARW", "IMG_0003.ARW"])["job"]["id"]
        wait_for(lambda: building(client, job_id), what="the first build")
        changed = harness.raw("IMG_0002.ARW", b"edited in the meantime")
        info = changed.stat()
        os.utime(changed, ns=(info.st_atime_ns, info.st_mtime_ns + 10**9))
        (harness.originals / "IMG_0003.ARW").unlink()
        wait_job(client, job_id)
        items = items_by_path(client, job_id)
        assert items["IMG_0001.ARW"]["state"] == "ready"
        for name in ("IMG_0002.ARW", "IMG_0003.ARW"):
            assert items[name]["state"] == "failed"
            assert items[name]["error"]["code"] == "source_changed"
    assert harness.runs() == [["IMG_0001.ARW"]]


def test_the_number_of_converter_processes_is_never_two(harness: Harness) -> None:
    sizes = [1, 2, 3, 4, 5, 9]
    fake = {"FAKE_CONVERTER_SETTLE": "0.4"}
    with harness.client(workers=4, batch_size=2, fake=fake) as client:
        for size in sizes:
            paths = [f"n{size}/IMG_{index:04d}.ARW" for index in range(size)]
            for path in paths:
                harness.raw(path)
            job = wait_job(client, post_job(client, paths)["job"]["id"])
            assert job["counts"]["ready"] == size
    counts = harness.concurrency()
    assert len(counts) == len(harness.runs())
    assert 2 not in counts, counts
    # 1 and 2 files: one process; 3 to 6 files: three; 7 and 8: four (9 = 8 + 1).
    assert set(counts) == {1, 3, 4}, counts


def test_a_fresh_wine_prefix_is_warmed_up_first(harness: Harness) -> None:
    harness.gpu_config.unlink()
    paths = [f"IMG_000{index}.ARW" for index in range(1, 5)]
    for path in paths:
        harness.raw(path)
    fake = {"FAKE_CONVERTER_FRESH_PREFIX": "1"}
    with harness.client(workers=3, batch_size=2, fake=fake) as client:
        job = wait_job(client, post_job(client, paths)["job"]["id"])
        assert job["counts"]["ready"] == len(paths)
        assert job["counts"]["failed"] == 0
        assert client.get("/api/v1/status").json()["today"] == {"built": 4, "failed": 0}
    assert harness.gpu_config.is_file()
    warm_up, *builds = harness.runs()
    assert warm_up == ["no-such-input.arw"]
    assert sorted(name for run in builds for name in run) == paths, "no file ran twice"


def test_a_prefix_that_cannot_be_warmed_up_fails_the_items(harness: Harness) -> None:
    harness.gpu_config.unlink()
    harness.raw("IMG_0001.ARW")
    with harness.client() as client:
        job = wait_job(client, post_job(client, ["IMG_0001.ARW"])["job"]["id"])
        item = items_by_path(client, job["id"])["IMG_0001.ARW"]
        assert item["state"] == "failed"
        assert item["error"]["code"] == "converter_failed"
        message = item["error"]["message"]
        assert "could not initialise" in message
        assert "exited with code 1" in message
        assert "cannot open no-such-input.arw" in message, "the converter's last output"
    assert harness.runs() == [["no-such-input.arw"]]


def test_polling_with_since_and_limit(harness: Harness) -> None:
    with harness.client() as client:
        job = post_job(client, [f"photo{index}.jpg" for index in range(5)])["job"]
        url = f"/api/v1/jobs/{job['id']}/items"
        page = client.get(url, params={"limit": 2}).json()
        assert [item["seq"] for item in page["items"]] == [1, 2]
        assert page["more"] is True
        assert page["job"]["id"] == job["id"]
        page = client.get(url, params={"since": 2, "limit": 2}).json()
        assert [item["seq"] for item in page["items"]] == [3, 4]
        assert page["more"] is True
        page = client.get(url, params={"since": 4, "limit": 2}).json()
        assert [item["seq"] for item in page["items"]] == [5]
        assert page["more"] is False
        assert client.get(url, params={"since": 5}).json()["items"] == []
        assert len(client.get(url, params={"state": "rejected"}).json()["items"]) == 5
        assert client.get(url, params={"state": "ready"}).json()["items"] == []
        for params in ({"state": "done"}, {"limit": 0}, {"limit": 1001}, {"since": -1}):
            response = client.get(url, params=params)
            assert response.status_code == 422, params
            assert isinstance(response.json()["detail"], str)
        response = client.get("/api/v1/jobs/999/items")
        assert response.status_code == 404
        assert response.json() == {"detail": "No such job"}


def test_items_get_their_first_seq_in_the_post_answer(harness: Harness) -> None:
    harness.raw("cached/IMG_0001.ARW")
    harness.raw("new/IMG_0002.ARW")
    paths = ["cached/IMG_0001.ARW", "new/IMG_0002.ARW", "photo.jpg"]
    with harness.client(fake={"FAKE_CONVERTER_DELAY": "0.3"}) as client:
        wait_job(client, post_job(client, ["cached/IMG_0001.ARW"])["job"]["id"])
        body = post_job(client, paths)
        job = body["job"]
        states = {item["path"]: item["state"] for item in body["items"]}
        assert states == {paths[0]: "ready", paths[1]: "queued", paths[2]: "rejected"}
        seqs = [item["seq"] for item in body["items"]]
        assert all(seq >= 1 for seq in seqs)
        assert len(set(seqs)) == len(seqs)
        assert job["seq"] == max(seqs)

        # Polling from the job's seq in the POST answer: only later changes, nothing missed.
        since = job["seq"]
        later: list[dict[str, Any]] = []

        def poll() -> bool:
            nonlocal since
            page = client.get(f"/api/v1/jobs/{job['id']}/items", params={"since": since}).json()
            later.extend(page["items"])
            if page["items"]:
                since = page["items"][-1]["seq"]
            return page["job"]["state"] != "active"

        wait_for(poll, what="the job")
        poll()
        assert {item["path"] for item in later} == {paths[1]}, "unchanged items are not repeated"
        assert all(item["seq"] > job["seq"] for item in later)
        assert later[-1]["state"] == "ready"
        everything = client.get(f"/api/v1/jobs/{job['id']}/items", params={"since": 0}).json()
        assert sorted(item["path"] for item in everything["items"]) == sorted(paths)
        assert everything["job"]["seq"] == since


def test_list_and_get_jobs(harness: Harness) -> None:
    with harness.client() as client:
        ids = [post_job(client, ["photo.jpg"], label=f"job {n}")["job"]["id"] for n in range(3)]
        assert [job["id"] for job in client.get("/api/v1/jobs").json()["jobs"]] == ids[::-1]
        limited = client.get("/api/v1/jobs", params={"limit": 2}).json()["jobs"]
        assert [job["id"] for job in limited] == [ids[2], ids[1]]
        assert client.get("/api/v1/jobs", params={"state": "active"}).json()["jobs"] == []
        assert len(client.get("/api/v1/jobs", params={"state": "done"}).json()["jobs"]) == 3
        assert client.get("/api/v1/jobs", params={"state": "nonsense"}).status_code == 422
        assert client.get("/api/v1/jobs", params={"limit": 201}).status_code == 422
        job = client.get(f"/api/v1/jobs/{ids[0]}").json()["job"]
        assert job["label"] == "job 0"
        assert client.get("/api/v1/jobs/999").status_code == 404


def test_client_and_label_are_kept(harness: Harness) -> None:
    with harness.client() as client:
        job = post_job(client, ["photo.jpg"], client="lr-plugin/0.2.0", label="Selection")["job"]
        assert job["client"] == "lr-plugin/0.2.0"
        assert job["label"] == "Selection"


@pytest.mark.parametrize("fields", [{}, {"client": "", "label": ""}, {"client": None}])
def test_a_missing_or_empty_client_and_label_are_null(
    harness: Harness, fields: dict[str, Any]
) -> None:
    with harness.client() as client:
        job = post_job(client, ["photo.jpg"], **fields)["job"]
        assert "client" in job and job["client"] is None
        assert "label" in job and job["label"] is None
        listed = client.get("/api/v1/jobs").json()["jobs"][0]
        assert listed["client"] is None
        assert listed["label"] is None


def test_times_are_utc_seconds_with_a_z(harness: Harness) -> None:
    pattern = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
    harness.raw("IMG_0001.ARW")
    with harness.client() as client:
        before = datetime.now(UTC).replace(microsecond=0)
        body = post_job(client, ["IMG_0001.ARW", "photo.jpg"])
        assert pattern.fullmatch(body["job"]["created"]), body["job"]["created"]
        assert body["job"]["finished"] is None
        job = wait_job(client, body["job"]["id"])
        after = datetime.now(UTC)
        for value in (job["created"], job["finished"]):
            assert pattern.fullmatch(value), value
            moment = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)
            assert before <= moment <= after
        listed = client.get("/api/v1/jobs").json()["jobs"][0]
        assert pattern.fullmatch(listed["created"]) and pattern.fullmatch(listed["finished"])


def test_item_file_errors(harness: Harness) -> None:
    with harness.client() as client:
        item = post_job(client, ["photo.jpg"])["items"][0]
        response = client.get(f"/api/v1/items/{item['id']}/file")
        assert response.status_code == 409
        assert response.json()["code"] == "not_ready"
        response = client.get("/api/v1/items/999/file")
        assert response.status_code == 404
        assert response.json() == {"detail": "No such item"}


@pytest.mark.parametrize(
    ("body", "fragment"),
    [
        ({}, "items: Field required"),
        ({"items": []}, "items"),
        ({"items": [{"ref": "x" * 65, "root": "archive", "path": "a.ARW"}]}, "items[0].ref"),
        ({"items": [{"ref": 1, "root": "archive", "path": "a.ARW"}]}, "items[0].ref"),
        ({"items": [{"ref": "1", "root": "archive"}]}, "items[0].path"),
        ({"label": "x" * 101, "items": [{"ref": "1", "root": "a", "path": "a.ARW"}]}, "label"),
        ({"items": [{"ref": "\ud800", "root": "archive", "path": "a.ARW"}]}, "Unicode"),
        ({"items": [{"ref": "1", "root": "archive", "path": "\udcff.ARW"}]}, "Unicode"),
    ],
)
def test_malformed_bodies(harness: Harness, body: dict[str, Any], fragment: str) -> None:
    with harness.client() as client:
        # Sent as JSON text with escapes: httpx cannot encode a lone surrogate itself.
        response = client.post(
            "/api/v1/jobs",
            content=json.dumps(body).encode("ascii"),
            headers={"Content-Type": "application/json"},
        )
        assert response.status_code == 422, response.text
        detail = response.json()["detail"]
        assert isinstance(detail, str)
        assert fragment in detail


def test_a_body_that_is_not_json(harness: Harness) -> None:
    with harness.client() as client:
        response = client.post(
            "/api/v1/jobs", content=b"{not json", headers={"Content-Type": "application/json"}
        )
        assert response.status_code == 422
        assert response.json() == {"detail": "The request body is not valid JSON"}


def test_duplicate_refs(harness: Harness) -> None:
    items = [{"ref": "1", "root": "archive", "path": f"{n}.jpg"} for n in range(2)]
    with harness.client() as client:
        response = client.post("/api/v1/jobs", json={"items": items})
        assert response.status_code == 422
        assert response.json()["code"] == "duplicate_ref"
        assert client.get("/api/v1/jobs").json()["jobs"] == []


def test_too_many_items(harness: Harness) -> None:
    items = [
        {"ref": str(n), "root": "archive", "path": f"{n}.jpg"} for n in range(MAX_ITEMS_PER_JOB + 1)
    ]
    with harness.client() as client:
        response = client.post("/api/v1/jobs", json={"items": items})
        assert response.status_code == 413
        assert response.json()["code"] == "too_many_items"
        response = client.post("/api/v1/jobs", json={"items": items[:MAX_ITEMS_PER_JOB]})
        assert response.status_code == 201
        assert len(response.json()["items"]) == MAX_ITEMS_PER_JOB


def test_status(harness: Harness) -> None:
    harness.raw("IMG_0001.ARW")
    with harness.client(workers=4) as client:
        assert client.get("/api/v1/status").json() == {
            "queue": {"queued": 0, "building": 0},
            "workers": {"configured": 4, "busy": 0},
            "rate": {"perMinute": 0.0, "windowSeconds": 60},
            "today": {"built": 0, "failed": 0},
            "cache": {"entries": 0, "bytes": 0},
            "jobs": {"active": 0},
        }
        job = post_job(client, ["IMG_0001.ARW"])["job"]
        assert client.get("/api/v1/status").json()["jobs"]["active"] in (0, 1)
        wait_job(client, job["id"])
        status = client.get("/api/v1/status").json()
        size = len(dng_bytes("IMG_0001.ARW", b"IMG_0001.ARW"))
        assert status["rate"]["perMinute"] == 1.0
        assert status["today"] == {"built": 1, "failed": 0}
        assert status["cache"] == {"entries": 1, "bytes": size}
        assert status["jobs"] == {"active": 0}
        assert status["queue"] == {"queued": 0, "building": 0}


def test_new_endpoints_need_the_token(harness: Harness, token: str, auth: dict[str, str]) -> None:
    with harness.client(LRRP_TOKEN=token) as client:
        for method, path in [
            ("GET", "/api/v1/jobs"),
            ("POST", "/api/v1/jobs"),
            ("GET", "/api/v1/jobs/1"),
            ("DELETE", "/api/v1/jobs/1"),
            ("GET", "/api/v1/jobs/1/items"),
            ("GET", "/api/v1/items/1/file"),
            ("GET", "/api/v1/status"),
        ]:
            response = client.request(method, path)
            assert response.status_code == 401, (method, path)
            assert response.json() == {"detail": "Missing bearer token"}
        assert client.get("/api/v1/status", headers=auth).status_code == 200
