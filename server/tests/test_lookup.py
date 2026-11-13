"""Lookups (``POST /api/v1/lookup``) and downloads by cache key, through the HTTP API."""

import hashlib
import math
import os
import sqlite3
import threading
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from conftest import Harness, items_by_path, lookup, post_job, wait_for, wait_job
from fake_converter import dng_bytes
from lrrp.app import MAX_ITEMS_PER_JOB
from lrrp.store import Store


def building(client: TestClient, job_id: int) -> int:
    return client.get(f"/api/v1/jobs/{job_id}").json()["job"]["counts"]["building"]


def state_of(answers: list[dict[str, Any]]) -> list[str]:
    return [answer["state"] for answer in answers]


def test_lookup_answers_ready_pending_absent_and_rejected(harness: Harness) -> None:
    for name in ("cached.ARW", "held.ARW", "waiting.ARW", "never.ARW"):
        harness.raw(name)
    with harness.client(workers=1, batch_size=1) as client:
        first = post_job(client, ["cached.ARW"])["job"]["id"]
        wait_job(client, first)
        cached = items_by_path(client, first)["cached.ARW"]
        harness.hold()
        job_id = post_job(client, ["held.ARW", "waiting.ARW"])["job"]["id"]
        wait_for(lambda: building(client, job_id), what="the held build")
        jobs = client.get("/api/v1/jobs").json()["jobs"]

        items = [
            {"ref": "a", "root": "archive", "path": "cached.ARW"},
            {"ref": "b", "root": "archive", "path": "held.ARW"},
            {"ref": "c", "root": "archive", "path": "waiting.ARW"},
            {"ref": "d", "root": "archive", "path": "never.ARW"},
            {"ref": "e", "root": "archive", "path": "photo.jpg"},
            {"ref": "f", "root": "archive", "path": "missing.ARW"},
            {"ref": "g", "root": "nowhere", "path": "cached.ARW"},
            {"ref": "h", "root": "offline", "path": "cached.ARW"},
            {"ref": "i", "root": "archive", "path": "../cached.ARW"},
        ]
        response = client.post("/api/v1/lookup", json={"items": items})
        assert response.status_code == 200, response.text
        answers = response.json()["items"]
        assert [answer["ref"] for answer in answers] == [item["ref"] for item in items]
        assert state_of(answers) == ["ready", "pending", "pending", "absent"] + ["rejected"] * 5
        ready = answers[0]
        assert ready["error"] is None
        assert ready["result"] == cached["result"], "the same key, size, digest and tags"
        for answer in answers[1:4]:
            assert answer["error"] is None and answer["result"] is None
        codes = [answer["error"]["code"] for answer in answers[4:]]
        assert codes == [
            "unsupported_format",
            "not_found",
            "unknown_root",
            "root_unavailable",
            "bad_path",
        ]
        assert all(answer["error"]["message"] for answer in answers[4:])
        assert all(answer["result"] is None for answer in answers[4:])
        assert str(harness.tmp) not in response.text

        # A lookup stores nothing and queues nothing.
        assert client.get("/api/v1/jobs").json()["jobs"] == jobs
        assert client.get("/api/v1/status").json()["queue"] == {"queued": 1, "building": 1}

        harness.release()
        wait_job(client, job_id)
        built = items_by_path(client, job_id)
        answers = lookup(client, ["held.ARW", "waiting.ARW", "never.ARW"])
        assert state_of(answers) == ["ready", "ready", "absent"]
        assert answers[0]["result"] == built["held.ARW"]["result"]
        assert answers[1]["result"]["key"] == built["waiting.ARW"]["result"]["key"]
    assert harness.runs() == [["cached.ARW"], ["held.ARW"], ["waiting.ARW"]]


def test_the_key_is_the_same_in_every_job_and_in_a_lookup(harness: Harness) -> None:
    harness.raw("a/IMG_0001.ARW")
    harness.raw("b/IMG_0001.ARW")
    with harness.client() as client:
        one = post_job(client, ["a/IMG_0001.ARW", "b/IMG_0001.ARW"])["job"]["id"]
        wait_job(client, one)
        two = post_job(client, ["b/IMG_0001.ARW", "a/IMG_0001.ARW"])
        assert {item["state"] for item in two["items"]} == {"ready"}
        first = items_by_path(client, one)
        second = {item["path"]: item for item in two["items"]}
        answers = lookup(client, ["a/IMG_0001.ARW", "b/IMG_0001.ARW"])
        found = dict(zip(["a", "b"], answers, strict=True))
        for folder in ("a", "b"):
            path = f"{folder}/IMG_0001.ARW"
            key = first[path]["result"]["key"]
            assert second[path]["result"]["key"] == key
            assert found[folder]["result"]["key"] == key
        assert first["a/IMG_0001.ARW"]["result"]["key"] != first["b/IMG_0001.ARW"]["result"]["key"]


@pytest.mark.parametrize("change", ["content", "mtime"])
def test_a_changed_original_is_no_longer_ready(harness: Harness, change: str) -> None:
    original = harness.raw("IMG_0001.ARW", b"first version")
    with harness.client() as client:
        wait_job(client, post_job(client, ["IMG_0001.ARW"])["job"]["id"])
        [before] = lookup(client, ["IMG_0001.ARW"])
        assert before["state"] == "ready"
        info = original.stat()
        if change == "content":
            original.write_bytes(b"second version, longer")
            os.utime(original, ns=(info.st_atime_ns, info.st_mtime_ns))
        else:
            os.utime(original, ns=(info.st_atime_ns, info.st_mtime_ns + 10**9))
        [after] = lookup(client, ["IMG_0001.ARW"])
        assert after == {"ref": "0", "state": "absent", "error": None, "result": None}
        # The DNG of the old version is still there under its key.
        response = client.get(f"/api/v1/files/{before['result']['key']}")
        assert response.status_code == 200


def test_ready_needs_the_dng_in_the_cache(harness: Harness) -> None:
    harness.raw("IMG_0001.ARW")
    with harness.client(workers=1, batch_size=1) as client:
        wait_job(client, post_job(client, ["IMG_0001.ARW"])["job"]["id"])
        [found] = lookup(client, ["IMG_0001.ARW"])
        dng = harness.tmp / "cache" / found["result"]["key"][:2] / f"{found['result']['key']}.dng"
        assert dng.is_file()
        dng.unlink()
        assert state_of(lookup(client, ["IMG_0001.ARW"])) == ["absent"]
        # Asked for again, it is built again; while that runs, the lookup says pending.
        harness.hold()
        job_id = post_job(client, ["IMG_0001.ARW"])["job"]["id"]
        assert state_of(lookup(client, ["IMG_0001.ARW"])) == ["pending"]
        harness.release()
        wait_job(client, job_id)
        assert state_of(lookup(client, ["IMG_0001.ARW"])) == ["ready"]


def test_lookup_rejects_like_job_creation(harness: Harness) -> None:
    harness.raw("ok/IMG_0001.ARW")
    harness.raw("ok/photo.jpg")
    (harness.originals / "folder.ARW").mkdir()
    cases = [
        ("archive", ""),
        ("archive", "/ok/IMG_0001.ARW"),
        ("archive", "ok\\IMG_0001.ARW"),
        ("archive", "ok/../ok/IMG_0001.ARW"),
        ("archive", "ok//IMG_0001.ARW"),
        ("archive", "ok/IMG\x000001.ARW"),
        ("archive", "ok/" + "x" * 5000 + ".ARW"),
        ("archive", "ok/photo.jpg"),
        ("archive", "ok/README"),
        ("archive", "ok/IMG_0009.ARW"),
        ("archive", "ok/IMG_0001.ARW/x.ARW"),
        ("archive", "folder.ARW"),
        ("nowhere", "ok/IMG_0001.ARW"),
        ("nowhere", "../x.jpg"),
        ("offline", "ok/IMG_0001.ARW"),
        ("offline", "../x.ARW"),
        ("offline", "x.jpg"),
    ]
    items = [{"ref": str(n), "root": root, "path": path} for n, (root, path) in enumerate(cases)]
    with harness.client() as client:
        job = client.post("/api/v1/jobs", json={"items": items})
        assert job.status_code == 201, job.text
        found = client.post("/api/v1/lookup", json={"items": items})
        assert found.status_code == 200, found.text
        for created, answer in zip(job.json()["items"], found.json()["items"], strict=True):
            assert created["state"] == answer["state"] == "rejected", answer
            assert answer["error"] == created["error"], answer
    assert harness.runs() == []


def test_lookup_limits(harness: Harness) -> None:
    item = {"root": "archive", "path": "a.jpg"}
    with harness.client() as client:
        response = client.post("/api/v1/lookup", json={"items": [{"ref": "1", **item}] * 2})
        assert response.status_code == 422
        assert response.json()["code"] == "duplicate_ref"
        too_many = [{"ref": str(n), **item} for n in range(MAX_ITEMS_PER_JOB + 1)]
        response = client.post("/api/v1/lookup", json={"items": too_many})
        assert response.status_code == 413
        assert response.json()["code"] == "too_many_items"
        assert isinstance(response.json()["detail"], str)
        response = client.post("/api/v1/lookup", json={"items": too_many[:MAX_ITEMS_PER_JOB]})
        assert response.status_code == 200
        assert len(response.json()["items"]) == MAX_ITEMS_PER_JOB
        for body in (
            {},
            {"items": []},
            {"items": [{"ref": "x" * 65, **item}]},
            {"items": [{"ref": "1", "root": "archive"}]},
            {"items": "IMG_0001.ARW"},
        ):
            response = client.post("/api/v1/lookup", json=body)
            assert response.status_code == 422, body
            assert isinstance(response.json()["detail"], str)
        assert client.get("/api/v1/jobs").json()["jobs"] == []


def test_lookup_costs_one_stat_per_file_and_few_queries(
    harness: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    folders, per_folder = 3, 400
    paths = [f"day{d}/IMG_{n:04d}.ARW" for d in range(folders) for n in range(per_folder)]
    for path in paths:
        harness.raw(path)
    with harness.client() as client:
        wait_job(client, post_job(client, paths[:3])["job"]["id"])
        originals = str(harness.originals)
        calls = {"stat": 0, "queries": 0}

        def counted(function: Callable[..., Any], what: str) -> Callable[..., Any]:
            def wrapper(*args: Any, **kwargs: Any) -> Any:
                # Only what the request does: not the idle scheduler thread.
                if threading.current_thread().name != "lrrp-scheduler" and (
                    what == "queries" or str(args[0]).startswith(originals)
                ):
                    calls[what] += 1
                return function(*args, **kwargs)

            return wrapper

        monkeypatch.setattr(os, "stat", counted(os.stat, "stat"))
        monkeypatch.setattr(os, "lstat", counted(os.lstat, "stat"))
        monkeypatch.setattr(Store, "_query", counted(Store._query, "queries"))
        answers = lookup(client, paths)
        monkeypatch.undo()
    assert state_of(answers) == ["ready"] * 3 + ["absent"] * (len(paths) - 3)
    # One stat per file, plus a few for the root and the folders (their real paths).
    assert len(paths) <= calls["stat"] <= len(paths) + 10 * (folders + 1), calls
    # The cache index and the queue are asked in chunks of 500 keys.
    assert calls["queries"] <= 2 * math.ceil(len(paths) / 500), calls


# --- Download by cache key -------------------------------------------------------------------


def test_download_by_key(harness: Harness) -> None:
    harness.raw("2026/IMG_0001.ARW")
    with harness.client() as client:
        job_id = post_job(client, ["2026/IMG_0001.ARW"])["job"]["id"]
        wait_job(client, job_id)
        item = items_by_path(client, job_id)["2026/IMG_0001.ARW"]
        by_item = client.get(f"/api/v1/items/{item['id']}/file")
        response = client.get(f"/api/v1/files/{item['result']['key']}")
        assert response.status_code == 200, response.text
        expected = dng_bytes("IMG_0001.ARW", b"2026/IMG_0001.ARW")
        assert response.content == by_item.content == expected
        digest = hashlib.sha256(response.content).hexdigest()
        for name in ("content-type", "content-length", "x-lrrp-sha256", "content-disposition"):
            assert response.headers[name] == by_item.headers[name], name
        assert response.headers["content-type"] == "image/x-adobe-dng"
        assert response.headers["content-length"] == str(item["result"]["size"])
        assert response.headers["x-lrrp-sha256"] == digest == item["result"]["sha256"]
        assert response.headers["content-disposition"].startswith("attachment")
        assert 'filename="IMG_0001.dng"' in response.headers["content-disposition"]


@pytest.mark.parametrize(
    "key",
    ["0" * 63, "0" * 65, "A" * 64, "g" * 64, "0" * 62 + "-0", "%20" + "0" * 61],
)
def test_download_by_a_malformed_key(harness: Harness, key: str) -> None:
    with harness.client() as client:
        response = client.get(f"/api/v1/files/{key}")
        assert response.status_code == 422, response.text
        assert isinstance(response.json()["detail"], str)
        assert "code" not in response.json()


def test_download_by_an_unknown_key_or_a_dng_gone_from_the_cache(harness: Harness) -> None:
    harness.raw("IMG_0001.ARW")
    with harness.client() as client:
        response = client.get("/api/v1/files/" + "0" * 64)
        assert response.status_code == 404
        assert response.json()["code"] == "not_in_cache"
        wait_job(client, post_job(client, ["IMG_0001.ARW"])["job"]["id"])
        [found] = lookup(client, ["IMG_0001.ARW"])
        key = found["result"]["key"]
        assert client.get(f"/api/v1/files/{key}").status_code == 200
        dngs = list((harness.tmp / "cache").glob(f"*/{key}.dng"))
        assert len(dngs) == 1
        dngs[0].write_bytes(b"truncated")
        response = client.get(f"/api/v1/files/{key}")
        assert response.status_code == 404, "a file of another size is not the DNG"
        assert response.json()["code"] == "not_in_cache"
        dngs[0].unlink()
        response = client.get(f"/api/v1/files/{key}")
        assert response.status_code == 404
        assert response.json()["code"] == "not_in_cache"


# --- Job retention ---------------------------------------------------------------------------


def backdate(database: Path, job_id: int, days: float) -> None:
    """Move a job's times into the past, as if it had run ``days`` earlier."""
    db = sqlite3.connect(database)
    with db:
        db.execute(
            "UPDATE jobs SET created = created - ?1, finished = finished - ?1 WHERE id = ?2",
            (days * 86400, job_id),
        )
    db.close()


def test_old_jobs_are_deleted_at_start_and_their_dngs_stay(harness: Harness) -> None:
    for name in ("IMG_0001.ARW", "IMG_0002.ARW", "IMG_0003.ARW"):
        harness.raw(name)
    # IMG_0003 never finishes, so its job stays active however old it is.
    harness.hold("IMG_0003.ARW")
    with harness.client(LRRP_JOB_RETENTION_DAYS="2") as client:
        old = post_job(client, ["IMG_0001.ARW", "photo.jpg"])["job"]["id"]
        wait_job(client, old)
        old_item = items_by_path(client, old)["IMG_0001.ARW"]
        recent = post_job(client, ["IMG_0002.ARW"])["job"]["id"]
        wait_job(client, recent)
        active = post_job(client, ["IMG_0003.ARW"])["job"]["id"]
    backdate(harness.database, old, 3)
    backdate(harness.database, recent, 1.5)
    backdate(harness.database, active, 30)
    with harness.client(LRRP_JOB_RETENTION_DAYS="2") as client:
        assert client.get("/api/v1/info").json()["capabilities"]["jobRetentionDays"] == 2
        assert client.get(f"/api/v1/jobs/{old}").status_code == 404
        assert client.get(f"/api/v1/jobs/{old}/items").status_code == 404
        assert client.get(f"/api/v1/items/{old_item['id']}/file").status_code == 404
        assert {job["id"] for job in client.get("/api/v1/jobs").json()["jobs"]} == {
            recent,
            active,
        }
        # The cache keeps the DNG: a lookup finds it and it downloads by its key.
        [found] = lookup(client, ["IMG_0001.ARW"])
        assert found["state"] == "ready"
        assert found["result"] == old_item["result"]
        assert client.get(f"/api/v1/files/{found['result']['key']}").status_code == 200
        assert client.get("/api/v1/status").json()["cache"]["entries"] == 2
        # A new job never gets the id of a deleted one.
        newest = post_job(client, ["photo.jpg"])["job"]["id"]
        assert newest > active
    with harness.client(LRRP_JOB_RETENTION_DAYS="1") as client:
        jobs = client.get("/api/v1/jobs").json()["jobs"]
        assert [job["id"] for job in jobs] == [newest, active]
        assert jobs[1]["state"] == "active"
    harness.release()
