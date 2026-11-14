"""Browsing the roots (``GET /api/v1/browse``) and queueing folders (``POST /api/v1/folders``)."""

import math
import os
import threading
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from conftest import Harness, items_by_path, lookup, post_job, wait_job
from lrrp import app as app_module
from lrrp.store import Store

SHOOT = "2026/2026.06.20 - shoot"


def tree(harness: Harness) -> None:
    """A small library:

    archive/
      top.ARW
      2026/
        readme.txt
        2026.06.20 - shoot/  IMG_0001.ARW IMG_0002.ARW IMG_0003.CR2 notes.txt .hidden.ARW
                             ._IMG_0001.ARW  edits/IMG_0001.jpg  edits/IMG_0004.NEF
        A folder/  b-day/  Zeta/IMG_0005.ARW
        .thumbnails/IMG_0001.ARW
    """
    harness.raw("top.ARW")
    harness.raw("2026/readme.txt")
    for name in ("IMG_0001.ARW", "IMG_0002.ARW", "IMG_0003.CR2", "notes.txt", ".hidden.ARW"):
        harness.raw(f"{SHOOT}/{name}")
    harness.raw(f"{SHOOT}/._IMG_0001.ARW", b"AppleDouble")
    harness.raw(f"{SHOOT}/edits/IMG_0001.jpg")
    harness.raw(f"{SHOOT}/edits/IMG_0004.NEF")
    (harness.originals / "2026" / "A folder").mkdir()
    (harness.originals / "2026" / "b-day").mkdir()
    harness.raw("2026/Zeta/IMG_0005.ARW")
    harness.raw("2026/.thumbnails/IMG_0001.ARW")


def browse(client: TestClient, expect: int = 200, **params: str) -> dict[str, Any]:
    response = client.get("/api/v1/browse", params=params)
    assert response.status_code == expect, response.text
    return response.json()


def queue(client: TestClient, body: dict[str, Any], expect: int = 201) -> dict[str, Any]:
    response = client.post("/api/v1/folders", json=body)
    assert response.status_code == expect, response.text
    return response.json()


def symlink(link: Path, target: Path) -> None:
    try:
        link.symlink_to(target, target_is_directory=target.is_dir())
    except (OSError, NotImplementedError) as exc:
        pytest.skip(f"cannot create symbolic links here: {exc}")


# --- Browse ----------------------------------------------------------------------------------


def test_browse_the_root_and_its_folders(harness: Harness) -> None:
    tree(harness)
    with harness.client() as client:
        root = browse(client, root="archive")
        assert root == {
            "root": "archive",
            "path": "",
            "parent": None,
            "dirs": [{"name": "2026", "path": "2026"}],
            "rawFiles": 1,
            "builtFiles": 0,
            "otherFiles": 0,
            "truncated": False,
        }
        assert browse(client, root="archive", path="") == root
        year = browse(client, root="archive", path="2026")
        assert year["parent"] == ""
        assert year["dirs"] == [
            {"name": "2026.06.20 - shoot", "path": SHOOT},
            {"name": "A folder", "path": "2026/A folder"},
            {"name": "b-day", "path": "2026/b-day"},
            {"name": "Zeta", "path": "2026/Zeta"},
        ], "sorted without regard to case; names starting with a dot left out"
        assert (year["rawFiles"], year["builtFiles"], year["otherFiles"]) == (0, 0, 1)
        shoot = browse(client, root="archive", path=SHOOT)
        assert shoot["path"] == SHOOT
        assert shoot["parent"] == "2026"
        assert shoot["dirs"] == [{"name": "edits", "path": f"{SHOOT}/edits"}]
        # IMG_0001.ARW, IMG_0002.ARW and IMG_0003.CR2; notes.txt; the dot files not at all.
        assert (shoot["rawFiles"], shoot["otherFiles"]) == (3, 1)
        edits = browse(client, root="archive", path=f"{SHOOT}/edits")
        assert edits["parent"] == SHOOT
        assert (edits["dirs"], edits["rawFiles"], edits["otherFiles"]) == ([], 1, 1)
        assert browse(client, root="archive", path="2026/b-day")["dirs"] == []
        assert str(harness.tmp) not in client.get("/api/v1/browse?root=archive&path=2026").text


def test_built_files_are_those_in_the_cache_as_they_are_now(harness: Harness) -> None:
    tree(harness)
    with harness.client() as client:
        job_id = post_job(client, [f"{SHOOT}/IMG_0001.ARW", f"{SHOOT}/IMG_0002.ARW"])["job"]["id"]
        wait_job(client, job_id)
        assert browse(client, root="archive", path=SHOOT)["builtFiles"] == 2
        # A changed original is no longer built; a DNG gone from the cache neither.
        changed = harness.originals / "2026" / "2026.06.20 - shoot" / "IMG_0002.ARW"
        info = changed.stat()
        os.utime(changed, ns=(info.st_atime_ns, info.st_mtime_ns + 10**9))
        assert browse(client, root="archive", path=SHOOT)["builtFiles"] == 1
        key = items_by_path(client, job_id)[f"{SHOOT}/IMG_0001.ARW"]["result"]["key"]
        (harness.tmp / "cache" / key[:2] / f"{key}.dng").unlink()
        assert browse(client, root="archive", path=SHOOT)["builtFiles"] == 0


def test_a_long_list_of_folders_is_cut(harness: Harness, monkeypatch: pytest.MonkeyPatch) -> None:
    for name in ("d", "B", "a", "C"):
        (harness.originals / "many" / name).mkdir(parents=True)
    with harness.client() as client:
        monkeypatch.setattr(app_module, "MAX_LISTED_FOLDERS", 4)
        whole = browse(client, root="archive", path="many")
        assert [d["name"] for d in whole["dirs"]] == ["a", "B", "C", "d"]
        assert whole["truncated"] is False
        monkeypatch.setattr(app_module, "MAX_LISTED_FOLDERS", 3)
        cut = browse(client, root="archive", path="many")
        assert [d["name"] for d in cut["dirs"]] == ["a", "B", "C"]
        assert cut["truncated"] is True


@pytest.mark.parametrize(
    ("root", "path", "status", "code"),
    [
        ("nowhere", "", 404, "unknown_root"),
        ("nowhere", "../x", 404, "unknown_root"),
        ("offline", "", 404, "root_unavailable"),
        ("offline", "2026", 404, "root_unavailable"),
        ("offline", "../x", 422, "bad_path"),
        ("archive", "missing", 404, "not_found"),
        ("archive", "2026/missing/deeper", 404, "not_found"),
        ("archive", "top.ARW/x", 404, "not_found"),
        ("archive", "/2026", 422, "bad_path"),
        ("archive", "2026/", 422, "bad_path"),
        ("archive", "2026//x", 422, "bad_path"),
        ("archive", "2026/../2026", 422, "bad_path"),
        ("archive", "./2026", 422, "bad_path"),
        ("archive", "..", 422, "bad_path"),
        ("archive", "2026\\x", 422, "bad_path"),
        ("archive", "x" * 4097, 422, "bad_path"),
        ("archive", "top.ARW", 422, "not_a_folder"),
        ("archive", "2026/readme.txt", 422, "not_a_folder"),
    ],
)
def test_browse_errors(harness: Harness, root: str, path: str, status: int, code: str) -> None:
    tree(harness)
    with harness.client() as client:
        body = browse(client, expect=status, root=root, path=path)
        assert body["code"] == code, body
        assert isinstance(body["detail"], str) and body["detail"]
        assert str(harness.tmp) not in body["detail"]


def test_browse_needs_a_root(harness: Harness) -> None:
    with harness.client() as client:
        response = client.get("/api/v1/browse")
        assert response.status_code == 422
        assert response.json() == {"detail": "root: Field required"}


def test_symbolic_links_are_not_listed_and_do_not_lead_out(harness: Harness) -> None:
    tree(harness)
    outside = harness.tmp / "outside"
    (outside / "deeper").mkdir(parents=True)
    (outside / "IMG_9999.ARW").write_bytes(b"outside")
    shoot = harness.originals / "2026" / "2026.06.20 - shoot"
    symlink(shoot / "escape", outside)
    symlink(shoot / "alias", harness.originals / "2026" / "Zeta")
    symlink(shoot / "linked.ARW", shoot / "IMG_0001.ARW")
    symlink(shoot / "outside.ARW", outside / "IMG_9999.ARW")
    with harness.client() as client:
        listing = browse(client, root="archive", path=SHOOT)
        assert listing["dirs"] == [{"name": "edits", "path": f"{SHOOT}/edits"}]
        assert (listing["rawFiles"], listing["otherFiles"]) == (3, 1)
        # A link that leads out of the root is a bad path; one that stays inside can be opened.
        for path in (f"{SHOOT}/escape", f"{SHOOT}/escape/deeper"):
            body = browse(client, expect=422, root="archive", path=path)
            assert body["code"] == "bad_path"
        inside = browse(client, root="archive", path=f"{SHOOT}/alias")
        assert inside["rawFiles"] == 1


def test_browse_costs_one_stat_per_raw_file_and_few_queries(
    harness: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    files = 1200
    folder = harness.originals / "big"
    folder.mkdir()
    for index in range(files):
        (folder / f"IMG_{index:04d}.ARW").write_bytes(b"x")
    (folder / "sub").mkdir()
    with harness.client() as client:
        originals = str(harness.originals)
        calls = {"stat": 0, "queries": 0}

        def counted(function: Callable[..., Any], what: str) -> Callable[..., Any]:
            def wrapper(*args: Any, **kwargs: Any) -> Any:
                if threading.current_thread().name != "lrrp-scheduler" and (
                    what == "queries" or str(args[0]).startswith(originals)
                ):
                    calls[what] += 1
                return function(*args, **kwargs)

            return wrapper

        monkeypatch.setattr(os, "stat", counted(os.stat, "stat"))
        monkeypatch.setattr(os, "lstat", counted(os.lstat, "stat"))
        monkeypatch.setattr(Store, "_query", counted(Store._query, "queries"))
        body = browse(client, root="archive", path="big")
        monkeypatch.undo()
    assert body["rawFiles"] == files
    # The files' own stat comes with the directory listing; os.stat only checks the folder.
    assert calls["stat"] <= 10, calls
    assert calls["queries"] <= math.ceil(files / 500), calls


# --- Queue a folder --------------------------------------------------------------------------


def test_queue_a_folder(harness: Harness) -> None:
    tree(harness)
    with harness.client() as client:
        answer = queue(client, {"root": "archive", "path": SHOOT})
        assert answer["files"] == 3
        assert answer["alreadyBuilt"] == 0
        [job] = answer["jobs"]
        assert job["client"] == "dashboard"
        assert job["clientId"] is None
        assert job["label"] == SHOOT
        assert job["counts"]["total"] == job["counts"]["queued"] == 3
        items = client.get(f"/api/v1/jobs/{job['id']}/items").json()["items"]
        assert [item["path"] for item in items] == [
            f"{SHOOT}/IMG_0001.ARW",
            f"{SHOOT}/IMG_0002.ARW",
            f"{SHOOT}/IMG_0003.CR2",
        ]
        assert len({item["ref"] for item in items}) == 3
        done = wait_job(client, job["id"])
        assert done["counts"]["ready"] == 3
        assert browse(client, root="archive", path=SHOOT)["builtFiles"] == 3
        # Queued again: everything is built already, the job is done at once.
        again = queue(client, {"root": "archive", "path": SHOOT, "label": "Again"})
        assert (again["files"], again["alreadyBuilt"]) == (3, 3)
        assert again["jobs"][0]["state"] == "done"
        assert again["jobs"][0]["label"] == "Again"
    assert sorted(name for run in harness.runs() for name in run) == [
        "IMG_0001.ARW",
        "IMG_0002.ARW",
        "IMG_0003.CR2",
    ]


def test_queue_a_folder_with_its_sub_folders(harness: Harness) -> None:
    tree(harness)
    with harness.client() as client:
        top = queue(client, {"root": "archive", "path": "", "recursive": False})
        assert top["files"] == 1
        assert top["jobs"][0]["label"] == "archive", "the root has no path: its id is the label"
        whole = queue(client, {"root": "archive", "recursive": True})
        assert whole["files"] == 6
        items = client.get(f"/api/v1/jobs/{whole['jobs'][0]['id']}/items").json()["items"]
        # The files of a folder first, then each sub-folder's in name order.
        assert [item["path"] for item in items] == [
            "top.ARW",
            f"{SHOOT}/IMG_0001.ARW",
            f"{SHOOT}/IMG_0002.ARW",
            f"{SHOOT}/IMG_0003.CR2",
            f"{SHOOT}/edits/IMG_0004.NEF",
            "2026/Zeta/IMG_0005.ARW",
        ]
        wait_job(client, whole["jobs"][0]["id"])
        assert harness.runs_with("IMG_0001.ARW") == 1, "not the one under .thumbnails"


def test_files_already_built_are_ready_at_once(harness: Harness) -> None:
    tree(harness)
    with harness.client() as client:
        wait_job(client, post_job(client, [f"{SHOOT}/IMG_0002.ARW"])["job"]["id"])
        answer = queue(client, {"root": "archive", "path": SHOOT})
        assert (answer["files"], answer["alreadyBuilt"]) == (3, 1)
        job = answer["jobs"][0]
        assert job["counts"]["ready"] == 1 and job["counts"]["queued"] == 2
        items = {
            item["path"]: item
            for item in client.get(f"/api/v1/jobs/{job['id']}/items").json()["items"]
        }
        assert items[f"{SHOOT}/IMG_0002.ARW"]["state"] == "ready"
        assert items[f"{SHOOT}/IMG_0002.ARW"]["result"]["originalName"] == "IMG_0002.ARW"
        wait_job(client, job["id"])
    assert harness.runs_with("IMG_0002.ARW") == 1


def test_a_large_folder_is_split_into_several_jobs(
    harness: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    for index in range(5):
        harness.raw(f"day/IMG_{index:04d}.ARW")
    monkeypatch.setattr(app_module, "MAX_ITEMS_PER_JOB", 2)
    with harness.client() as client:
        answer = queue(client, {"root": "archive", "path": "day", "label": "Day"})
        assert answer["files"] == 5
        jobs = answer["jobs"]
        assert [job["counts"]["total"] for job in jobs] == [2, 2, 1]
        assert {job["label"] for job in jobs} == {"Day"}
        assert [job["id"] for job in jobs] == sorted(job["id"] for job in jobs)
        paths = []
        for job in jobs:
            paths += [item["path"] for item in items_by_path(client, job["id"]).values()]
            wait_job(client, job["id"])
        assert sorted(paths) == [f"day/IMG_{index:04d}.ARW" for index in range(5)]


def test_too_many_files(harness: Harness, monkeypatch: pytest.MonkeyPatch) -> None:
    for index in range(4):
        harness.raw(f"a/IMG_{index:04d}.ARW")
    harness.raw("a/b/IMG_0009.ARW")
    monkeypatch.setattr(app_module, "MAX_FOLDER_FILES", 4)
    with harness.client() as client:
        body = queue(client, {"root": "archive", "path": "a", "recursive": True}, expect=422)
        assert body["code"] == "too_many_files"
        assert "4" in body["detail"]
        assert client.get("/api/v1/jobs").json()["jobs"] == []
        assert queue(client, {"root": "archive", "path": "a"})["files"] == 4


def test_a_folder_without_raw_files(harness: Harness) -> None:
    tree(harness)
    with harness.client() as client:
        answer = queue(client, {"root": "archive", "path": "2026/b-day", "recursive": True})
        assert answer == {"files": 0, "alreadyBuilt": 0, "jobs": []}
        assert client.get("/api/v1/jobs").json()["jobs"] == []


@pytest.mark.parametrize(
    ("root", "path", "status", "code"),
    [
        ("nowhere", "", 404, "unknown_root"),
        ("offline", "", 404, "root_unavailable"),
        ("archive", "missing", 404, "not_found"),
        ("archive", "../outside", 422, "bad_path"),
        ("archive", "top.ARW", 422, "not_a_folder"),
    ],
)
def test_queue_errors(harness: Harness, root: str, path: str, status: int, code: str) -> None:
    tree(harness)
    with harness.client() as client:
        body = queue(client, {"root": root, "path": path}, expect=status)
        assert body["code"] == code


@pytest.mark.parametrize(
    ("body", "fragment"),
    [
        ({}, "root: Field required"),
        ({"root": "archive", "label": "x" * 101}, "label"),
        ({"root": "archive", "recursive": "sometimes"}, "recursive"),
    ],
)
def test_malformed_folder_requests(harness: Harness, body: dict[str, Any], fragment: str) -> None:
    with harness.client() as client:
        response = client.post("/api/v1/folders", json=body)
        assert response.status_code == 422
        assert fragment in response.json()["detail"]


def test_queue_a_folder_without_a_converter(harness: Harness) -> None:
    tree(harness)
    with harness.client() as client:
        wait_job(client, post_job(client, [f"{SHOOT}/edits/IMG_0004.NEF"])["job"]["id"])
    (harness.prefix / "drive_c" / "Program Files").rename(harness.prefix / "drive_c" / "Gone")
    with harness.client() as client:
        body = queue(client, {"root": "archive", "path": SHOOT}, expect=409)
        assert body["code"] == "converter_not_installed"
        # Everything already built: nothing has to be built, so the job is made.
        answer = queue(client, {"root": "archive", "path": f"{SHOOT}/edits"})
        assert (answer["files"], answer["alreadyBuilt"]) == (1, 1)


def test_a_long_folder_path_makes_a_short_label(harness: Harness) -> None:
    deep = "/".join(f"folder{index:02d}" for index in range(15))
    harness.raw(f"{deep}/IMG_0001.ARW")
    with harness.client() as client:
        [job] = queue(client, {"root": "archive", "path": deep})["jobs"]
        assert len(job["label"]) == 100
        assert job["label"].startswith("…")
        assert job["label"].endswith("folder13/folder14")


def test_symbolic_links_are_not_followed_when_queueing(harness: Harness) -> None:
    harness.raw("shoot/IMG_0001.ARW")
    outside = harness.tmp / "outside"
    outside.mkdir()
    (outside / "IMG_9999.ARW").write_bytes(b"outside")
    symlink(harness.originals / "shoot" / "escape", outside)
    symlink(harness.originals / "shoot" / "out.ARW", outside / "IMG_9999.ARW")
    symlink(harness.originals / "shoot" / "again.ARW", harness.originals / "shoot" / "IMG_0001.ARW")
    with harness.client() as client:
        answer = queue(client, {"root": "archive", "path": "shoot", "recursive": True})
        assert answer["files"] == 1
        wait_job(client, answer["jobs"][0]["id"])
        [found] = lookup(client, ["shoot/IMG_0001.ARW"])
        assert found["state"] == "ready"
    assert harness.runs() == [["IMG_0001.ARW"]]
