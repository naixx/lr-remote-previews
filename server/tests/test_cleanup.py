"""The cache clean-up (``POST /api/v1/cache/clean``, the ``cache`` settings, the daily run), end
to end with a fake clock, and the store's removal of cache entries."""

import sqlite3
import threading
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from conftest import (
    DAY,
    FakeClock,
    Harness,
    items_by_path,
    lookup,
    post_job,
    wait_for,
    wait_job,
)
from fake_converter import dng_bytes
from lrrp import autoscan, cleanup, runtime
from lrrp.cache import Cache, CacheEntry
from lrrp.cleanup import CacheCleaner, CleanResult
from lrrp.runtime import Controls, RuntimeSettings
from lrrp.settings import Root
from lrrp.store import NewItem, Store


@pytest.fixture(autouse=True)
def threads(monkeypatch: pytest.MonkeyPatch) -> None:
    """The scan thread looks at the (fake) clock every 20 ms. The daily clean-up's thread looks
    only when it starts, so that moving the clock by days does not start a clean-up beside the
    one a test asks for (that one would get 409); the test of the daily run changes that."""
    monkeypatch.setattr(autoscan, "POLL", 0.02)
    monkeypatch.setattr(cleanup, "POLL", 3600.0)


def clean(client: TestClient, body: Any = None, expect: int = 200) -> dict[str, Any]:
    if body is None:
        response = client.post("/api/v1/cache/clean")
    else:
        response = client.post("/api/v1/cache/clean", json=body)
    assert response.status_code == expect, response.text
    return response.json()


def outcome(
    gone: int = 0, expired: int = 0, over: int = 0, freed: int = 0, dry: bool = False
) -> dict[str, Any]:
    return {
        "dryRun": dry,
        "removed": {"originalGone": gone, "expired": expired, "overLimit": over},
        "bytesFreed": freed,
    }


def limits(client: TestClient, max_bytes: int | None = None, max_age: int | None = None) -> None:
    body = {"cache": {"maxBytes": max_bytes, "maxAgeDays": max_age}}
    response = client.patch("/api/v1/settings", json=body)
    assert response.status_code == 200, response.text


def build(client: TestClient, paths: list[str]) -> dict[str, dict[str, Any]]:
    """Build these files in one job; return its items by path."""
    job_id = post_job(client, paths)["job"]["id"]
    assert wait_job(client, job_id)["counts"]["ready"] == len(paths)
    return items_by_path(client, job_id)


def size(name: str) -> int:
    """The size of the fake converter's DNG of a file at the top of the root."""
    return len(dng_bytes(name, name.encode()))


def cache_status(client: TestClient) -> dict[str, int]:
    return client.get("/api/v1/status").json()["cache"]


def used(database: Path, key: str) -> float:
    db = sqlite3.connect(database)
    try:
        return db.execute("SELECT used FROM cache WHERE key = ?", (key,)).fetchone()[0]
    finally:
        db.close()


def dng(harness: Harness, key: str) -> Path:
    return harness.tmp / "cache" / key[:2] / f"{key}.dng"


def log_messages(client: TestClient) -> list[str]:
    lines = client.get("/api/v1/log", params={"limit": 1000}).json()["lines"]
    return [line["message"] for line in lines]


def states(client: TestClient, names: list[str]) -> list[str]:
    return [answer["state"] for answer in lookup(client, names)]


def test_dngs_whose_original_is_gone_or_changed_are_removed(harness: Harness) -> None:
    names = ["KEEP.ARW", "GONE.ARW", "EDIT.ARW"]
    for name in names:
        harness.raw(name)
    with harness.client() as client:
        job_id = post_job(client, names)["job"]["id"]
        wait_job(client, job_id)
        items = items_by_path(client, job_id)
        keys = {name: items[name]["result"]["key"] for name in names}
        (harness.originals / "GONE.ARW").unlink()
        harness.raw("EDIT.ARW", b"edited, and longer than before")
        freed = size("GONE.ARW") + size("EDIT.ARW")

        assert clean(client, {"dryRun": True}) == outcome(gone=2, freed=freed, dry=True)
        assert cache_status(client)["entries"] == 3, "a dry run removes nothing"
        assert client.get(f"/api/v1/files/{keys['GONE.ARW']}").status_code == 200

        assert clean(client) == outcome(gone=2, freed=freed)
        assert cache_status(client) == {"entries": 1, "bytes": size("KEEP.ARW")}
        for name in ("GONE.ARW", "EDIT.ARW"):
            assert not dng(harness, keys[name]).exists()
            response = client.get(f"/api/v1/files/{keys[name]}")
            assert (response.status_code, response.json()["code"]) == (404, "not_in_cache")
            # The item of the finished job stays ready, without its DNG.
            gone = items_by_path(client, job_id)[name]
            assert (gone["state"], gone["result"]) == ("ready", None)
            response = client.get(f"/api/v1/items/{items[name]['id']}/file")
            assert (response.status_code, response.json()["code"]) == (404, "not_in_cache")
        assert client.get(f"/api/v1/items/{items['KEEP.ARW']['id']}/file").status_code == 200
        assert states(client, names) == ["ready", "rejected", "absent"]
        assert clean(client) == outcome()


def test_an_unavailable_or_empty_root_does_not_make_its_originals_gone(harness: Harness) -> None:
    for name in ("A.ARW", "B.ARW"):
        harness.raw(name)
    with harness.client() as client:
        build(client, ["A.ARW", "B.ARW"])
        away = harness.tmp / "away"
        harness.originals.rename(away)
        assert client.get("/api/v1/info").json()["roots"][0]["available"] is False
        assert clean(client) == outcome()
        # An unmounted volume often leaves an empty mount point behind.
        harness.originals.mkdir()
        assert client.get("/api/v1/info").json()["roots"][0]["available"] is True
        assert clean(client) == outcome()
        assert cache_status(client)["entries"] == 2
        harness.originals.rmdir()
        away.rename(harness.originals)
        (harness.originals / "A.ARW").unlink()
        assert clean(client) == outcome(gone=1, freed=size("A.ARW"))


def test_last_uses_are_recorded_and_unused_dngs_expire(harness: Harness) -> None:
    clock = FakeClock()
    names = ["LOOKED.ARW", "FETCHED.ARW", "BY_KEY.ARW", "ASKED.ARW", "IDLE.ARW"]
    for name in names:
        harness.raw(name)
    with harness.client(clock=clock) as client:
        items = build(client, names)
        keys = {name: items[name]["result"]["key"] for name in names}
        start = clock.now
        assert {used(harness.database, key) for key in keys.values()} == {start}, "built"
        limits(client, max_age=10)

        # Used again within a day: nothing is written.
        clock.advance(0.5 * DAY)
        assert states(client, ["LOOKED.ARW"]) == ["ready"]
        assert used(harness.database, keys["LOOKED.ARW"]) == start

        clock.advance(4.5 * DAY)
        assert states(client, ["LOOKED.ARW"]) == ["ready"]
        response = client.get(f"/api/v1/items/{items['FETCHED.ARW']['id']}/file")
        assert response.status_code == 200
        assert client.get(f"/api/v1/files/{keys['BY_KEY.ARW']}").status_code == 200
        assert post_job(client, ["ASKED.ARW"])["items"][0]["state"] == "ready"
        for name in ("LOOKED.ARW", "FETCHED.ARW", "BY_KEY.ARW", "ASKED.ARW"):
            assert used(harness.database, keys[name]) == start + 5 * DAY, name
        assert used(harness.database, keys["IDLE.ARW"]) == start

        clock.advance(6 * DAY)  # 11 days after the build, 6 after the last use of the others
        freed = size("IDLE.ARW")
        assert clean(client, {"dryRun": True}) == outcome(expired=1, freed=freed, dry=True)
        assert clean(client) == outcome(expired=1, freed=freed)
        assert states(client, names) == ["ready"] * 4 + ["absent"]
        assert clean(client) == outcome()


def test_the_least_recently_used_go_when_the_cache_is_over_its_limit(
    harness: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(runtime, "MIN_CACHE_BYTES", 1)  # the real minimum is 100 MiB
    clock = FakeClock()
    names = ["A.ARW", "B.ARW", "C.ARW"]
    for name in names:
        harness.raw(name)
    one = size("A.ARW")
    with harness.client(clock=clock) as client:
        for name in names:  # built a day apart
            build(client, [name])
            clock.advance(DAY)
        clock.advance(0.5 * DAY)
        assert states(client, ["A.ARW"]) == ["ready"]  # A is now the most recently used
        assert cache_status(client) == {"entries": 3, "bytes": 3 * one}
        limits(client, max_bytes=2 * one)
        assert clean(client, {"dryRun": True}) == outcome(over=1, freed=one, dry=True)
        assert clean(client) == outcome(over=1, freed=one)
        assert states(client, names) == ["ready", "absent", "ready"]
        assert clean(client) == outcome()
        limits(client, max_bytes=1)
        assert clean(client) == outcome(over=2, freed=2 * one)
        assert cache_status(client) == {"entries": 0, "bytes": 0}


def test_the_steps_run_in_order_and_each_dng_counts_once(
    harness: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(runtime, "MIN_CACHE_BYTES", 1)
    clock = FakeClock()
    names = ["A.ARW", "B.ARW", "C.ARW", "D.ARW"]
    for name in names:
        harness.raw(name)
    one = size("A.ARW")
    with harness.client(clock=clock) as client:
        build(client, names)
        clock.advance(2 * DAY)
        assert states(client, ["C.ARW", "D.ARW"]) == ["ready", "ready"]
        (harness.originals / "A.ARW").unlink()  # gone, and not used for two days either
        limits(client, max_bytes=2 * one, max_age=1)
        # A goes in step 1, B (unused) in step 2; then the cache is within its limit.
        expected = {"gone": 1, "expired": 1, "over": 0, "freed": 2 * one}
        assert clean(client, {"dryRun": True}) == outcome(**expected, dry=True)
        assert clean(client) == outcome(**expected)
        assert cache_status(client) == {"entries": 2, "bytes": 2 * one}


def test_a_dng_that_an_active_job_points_to_is_kept(harness: Harness) -> None:
    for name in ("A.ARW", "B.ARW", "HELD.ARW"):
        harness.raw(name)
    with harness.client(workers=1, batch_size=1) as client:
        build(client, ["A.ARW", "B.ARW"])
        harness.hold("HELD.ARW")
        active = post_job(client, ["A.ARW", "HELD.ARW"])
        assert active["job"]["state"] == "active"
        ready = active["items"][0]
        assert ready["state"] == "ready"
        wait_for(lambda: harness.runs_with("HELD.ARW") == 1, what="the held build")
        (harness.originals / "A.ARW").unlink()
        (harness.originals / "B.ARW").unlink()

        assert clean(client, {"dryRun": True}) == outcome(gone=1, freed=size("B.ARW"), dry=True)
        assert clean(client) == outcome(gone=1, freed=size("B.ARW"))
        response = client.get(f"/api/v1/items/{ready['id']}/file")
        assert response.status_code == 200, "the active job can still fetch it"

        harness.release()
        wait_job(client, active["job"]["id"])
        assert clean(client) == outcome(gone=1, freed=size("A.ARW"))
        response = client.get(f"/api/v1/items/{ready['id']}/file")
        assert (response.status_code, response.json()["code"]) == (404, "not_in_cache")


def test_a_second_clean_up_while_one_runs_is_refused(
    harness: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    harness.raw("A.ARW")
    with harness.client() as client:
        build(client, ["A.ARW"])
        entered, release = threading.Event(), threading.Event()
        judge = cleanup._Run._original_gone

        def held(run: Any, row: Any) -> bool:
            entered.set()
            release.wait(30)
            return judge(run, row)

        monkeypatch.setattr(cleanup._Run, "_original_gone", held)
        results: list[CleanResult] = []
        cleaner = client.app.state.services.cleaner
        running = threading.Thread(target=lambda: results.append(cleaner.clean()))
        running.start()
        try:
            wait_for(entered.is_set, what="the clean-up to start")
            for body in (None, {"dryRun": True}):
                answer = clean(client, body, expect=409)
                assert answer["code"] == "busy"
                assert isinstance(answer["detail"], str)
        finally:
            release.set()
            running.join(30)
        assert results == [CleanResult(dry_run=False)]
        assert clean(client) == outcome()


def test_the_daily_clean_up_runs_by_the_clock(
    harness: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(cleanup, "POLL", 0.02)
    clock = FakeClock()
    harness.raw("A.ARW")
    harness.raw("B.ARW")  # a root with no file at all would count as unavailable
    with harness.client(clock=clock) as client:
        cleaner = client.app.state.services.cleaner
        assert cleaner.next_run == clock.now + DAY, "a day after the first start"
        build(client, ["A.ARW"])
        (harness.originals / "A.ARW").unlink()

        clock.advance(DAY - 60)
        looked = cleaner.checks
        cleaner.wake()
        wait_for(lambda: cleaner.checks >= looked + 3, what="the thread to look at the clock")
        assert cache_status(client)["entries"] == 1

        clock.advance(60)
        wait_for(
            lambda: any("cache clean-up: removed 1 DNG" in line for line in log_messages(client)),
            what="the daily clean-up",
        )
        assert cache_status(client)["entries"] == 0
        assert cleaner.next_run == clock.now + DAY
        # One asked for counts as the day's; a dry run does not.
        clock.advance(3600)
        clean(client)
        assert cleaner.next_run == clock.now + DAY
        due = cleaner.next_run
        clock.advance(60)
        clean(client, {"dryRun": True})
        assert cleaner.next_run == due
    with harness.client(clock=clock) as client:
        assert client.app.state.services.cleaner.next_run == due, "kept across a restart"


def test_an_index_entry_whose_dng_is_missing_is_dropped(harness: Harness) -> None:
    clock = FakeClock()
    harness.raw("A.ARW")
    harness.set_mtime("A.ARW", clock.now - DAY)
    with harness.client(clock=clock) as client:
        key = build(client, ["A.ARW"])["A.ARW"]["result"]["key"]
        dng(harness, key).unlink()
        assert clean(client, {"dryRun": True}) == outcome(dry=True)
        assert cache_status(client)["entries"] == 1
        assert clean(client) == outcome(), "no DNG was removed"
        assert cache_status(client) == {"entries": 0, "bytes": 0}
        assert any("dropped 1 index entry" in line for line in log_messages(client))
        # The automatic scan, which trusts the index, sees the file as not built again.
        response = client.post("/api/v1/autoscan/run", json={"roots": ["archive"]})
        assert response.status_code == 202
        status = wait_for(
            lambda: (lambda s: s if not s["running"] else None)(
                client.get("/api/v1/status").json()["autoScan"]
            ),
            what="the scan",
        )
        assert status["lastQueued"] == 1


@pytest.mark.parametrize("body", [{"dryRun": "yes"}, {"dryRun": None}, {"dryRun": 1}, []])
def test_a_bad_body_is_refused(harness: Harness, body: Any) -> None:
    with harness.client() as client:
        answer = clean(client, body, expect=422)
        assert isinstance(answer["detail"], str)
        assert clean(client, {}) == outcome()


# --- The store and the cleaner without the API ------------------------------------------------

T0 = 1_800_000_000.0
KEY_A = "a" * 64
KEY_B = "b" * 64


def entry(key: str) -> CacheEntry:
    return CacheEntry(key, 100, "d" * 64, "IMG.ARW", 6000, 4000, T0)


def test_removal_tolerates_a_file_or_an_index_entry_already_gone(tmp_path: Path) -> None:
    store = Store(tmp_path / "lrrp.sqlite3")
    try:
        cache = Cache(tmp_path / "cache")
        store.complete(KEY_A, entry(KEY_A), T0)
        store.complete(KEY_B, entry(KEY_B), T0)
        assert cache.remove(KEY_A) is True, "no file: gone already"
        assert store.remove_cache_entries([KEY_A, "c" * 64], cache.remove) == [(KEY_A, 100)]
        assert store.cache_entry(KEY_A) is None
        assert store.remove_cache_entries([KEY_A], cache.remove) == []
        # A file that cannot be deleted keeps its index entry.
        assert store.remove_cache_entries([KEY_B], lambda key: False) == []
        assert store.cache_entry(KEY_B) is not None
    finally:
        store.close()


def test_an_item_found_in_the_cache_is_queued_if_its_entry_is_gone_by_then(tmp_path: Path) -> None:
    # The API looks at the cache, then creates the job; a clean-up may remove an entry between.
    store = Store(tmp_path / "lrrp.sqlite3")
    try:
        store.complete(KEY_A, entry(KEY_A), T0)

        def ready(key: str, ref: str) -> NewItem:
            return NewItem(ref, "archive", f"{ref}.ARW", "ready", cache_key=key, size=1, mtime_ns=1)

        job, items = store.create_job(None, None, [ready(KEY_A, "a"), ready(KEY_B, "b")], T0)
        assert [(item.ref, item.state) for item in items] == [("a", "ready"), ("b", "queued")]
        assert items[0].result == entry(KEY_A)
        assert job.state == "active"
    finally:
        store.close()


def test_an_original_under_a_root_no_longer_configured_is_not_gone(tmp_path: Path) -> None:
    store = Store(tmp_path / "lrrp.sqlite3")
    try:
        item = NewItem("1", "elsewhere", "IMG.ARW", "queued", cache_key=KEY_A, size=1, mtime_ns=1)
        store.create_job(None, None, [item], T0)
        store.mark_building([KEY_A], T0)
        store.complete(KEY_A, entry(KEY_A), T0)
        [row] = store.cache_rows("a")
        assert (row.root, row.path) == ("elsewhere", "IMG.ARW")
        cache = Cache(tmp_path / "cache")
        cache.path(KEY_A).parent.mkdir(parents=True)
        cache.path(KEY_A).write_bytes(b"x" * 100)
        archive = tmp_path / "archive"
        archive.mkdir()
        (archive / "other.ARW").write_bytes(b"x")
        controls = Controls(RuntimeSettings(workers=1, batch_size=1), cpu_count=1)
        cleaner = CacheCleaner(store, cache, [Root("archive", archive, "Archive")], controls)
        assert cleaner.clean(dry_run=True) == CleanResult(dry_run=True)
        assert cleaner.clean() == CleanResult(dry_run=False)
        assert store.cache_entry(KEY_A) is not None
    finally:
        store.close()
