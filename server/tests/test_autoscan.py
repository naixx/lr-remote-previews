"""The automatic scan (``POST /api/v1/autoscan/run``, ``autoScan`` settings and status), end to end
with a fake clock: no test sleeps for an interval."""

import math
import os
import threading
from collections.abc import Callable, Iterator
from datetime import UTC, datetime
from typing import Any

import pytest
from fastapi.testclient import TestClient

from conftest import DAY, FakeClock, Harness, items_by_path, post_job, wait_for, wait_job
from lrrp import app as app_module
from lrrp import autoscan, folders
from lrrp.store import Store

SCAN = {
    "enabled": True,
    "roots": ["archive"],
    "intervalMinutes": 60,
    "settleMinutes": 15,
    "maxFilesPerRun": 2000,
}
NOTHING_YET = {"running": False, "lastRun": None, "lastQueued": 0, "nextRun": None}


@pytest.fixture(autouse=True)
def fast(monkeypatch: pytest.MonkeyPatch) -> None:
    """The scan thread looks at the (fake) clock every 20 ms instead of every 10 s."""
    monkeypatch.setattr(autoscan, "POLL", 0.02)


def iso(moment: float) -> str:
    return datetime.fromtimestamp(moment, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def configure(client: TestClient, **values: Any) -> None:
    response = client.patch("/api/v1/settings", json={"autoScan": {**SCAN, **values}})
    assert response.status_code == 200, response.text


def pause(client: TestClient) -> None:
    """Nothing is built: queued files stay queued, so a later scan sees them as pending."""
    assert client.patch("/api/v1/settings", json={"paused": True}).status_code == 200


def scan_status(client: TestClient) -> dict[str, Any]:
    return client.get("/api/v1/status").json()["autoScan"]


def run(client: TestClient, body: Any = None, expect: int = 202) -> dict[str, Any]:
    if body is None:
        response = client.post("/api/v1/autoscan/run")
    else:
        response = client.post("/api/v1/autoscan/run", json=body)
    assert response.status_code == expect, response.text
    return response.json()


def wait_scanned(client: TestClient, clock: FakeClock) -> dict[str, Any]:
    """Wait for a scan that finished at the clock's time; return ``status.autoScan``. The scan
    records its time after its jobs exist, so they can be read at once."""

    def finished() -> dict[str, Any] | None:
        status = scan_status(client)
        return status if not status["running"] and status["lastRun"] == iso(clock.now) else None

    return wait_for(finished, what="the scan")


def scan_now(client: TestClient, clock: FakeClock, body: Any = None) -> dict[str, Any]:
    """Start a scan through the API and wait for it to finish."""
    clock.advance(1)  # so that this scan's time differs from the last one's
    assert run(client, body) == {"started": True}
    return wait_scanned(client, clock)


def look_at_the_clock(client: TestClient) -> None:
    """Wait until the scan thread has looked at the clock a few times since now."""
    scanner = client.app.state.services.autoscan
    looked = scanner.checks
    scanner.wake()
    wait_for(lambda: scanner.checks >= looked + 3, what="the scan thread to look at the clock")


def auto_jobs(client: TestClient) -> list[dict[str, Any]]:
    """The jobs of the automatic scan, oldest first."""
    jobs = client.get("/api/v1/jobs", params={"limit": 200}).json()["jobs"]
    return [job for job in reversed(jobs) if job["client"] == "auto-scan"]


def paths(client: TestClient, job: dict[str, Any]) -> list[str]:
    items = client.get(f"/api/v1/jobs/{job['id']}/items", params={"limit": 1000}).json()["items"]
    return [item["path"] for item in sorted(items, key=lambda item: item["id"])]


def log_messages(client: TestClient) -> list[str]:
    lines = client.get("/api/v1/log", params={"limit": 1000}).json()["lines"]
    return [line["message"] for line in lines]


def settled(harness: Harness, clock: FakeClock, path: str, age: float = DAY) -> None:
    """A raw file last modified ``age`` seconds before the clock's time."""
    harness.raw(path)
    harness.set_mtime(path, clock.now - age)


def test_with_the_scan_off_nothing_is_scanned(harness: Harness) -> None:
    clock = FakeClock()
    settled(harness, clock, "IMG_0001.ARW")
    with harness.client(clock=clock) as client:
        assert scan_status(client) == NOTHING_YET
        configure(client, enabled=False)
        clock.advance(30 * DAY)
        look_at_the_clock(client)
        assert auto_jobs(client) == []
        assert scan_status(client) == NOTHING_YET
    assert harness.runs() == []


def test_settled_files_are_queued_every_interval(harness: Harness) -> None:
    clock = FakeClock()
    settled(harness, clock, "2026/old/IMG_0001.ARW", age=20 * 60)
    settled(harness, clock, "2026/new/IMG_0002.ARW", age=5 * 60)
    with harness.client(clock=clock) as client:
        # Never scanned before: the first scan is due at once.
        configure(client)
        first = wait_scanned(client, clock)
        assert first == {
            "running": False,
            "lastRun": iso(clock.now),
            "lastQueued": 1,
            "nextRun": iso(clock.now + 3600),
        }
        [job] = auto_jobs(client)
        assert (job["client"], job["clientId"], job["priority"], job["label"]) == (
            "auto-scan",
            None,
            "background",
            "Automatic scan: archive",
        )
        assert paths(client, job) == ["2026/old/IMG_0001.ARW"], "the other is still being copied"
        assert wait_job(client, job["id"])["counts"]["ready"] == 1

        # Eleven minutes later the second file has settled, but no scan is due yet.
        clock.advance(11 * 60)
        look_at_the_clock(client)
        assert len(auto_jobs(client)) == 1
        assert scan_status(client) == first

        clock.advance(49 * 60)  # an interval after the first scan
        second = wait_scanned(client, clock)
        assert second["lastQueued"] == 1
        assert second["nextRun"] == iso(clock.now + 3600)
        newest = auto_jobs(client)[-1]
        assert paths(client, newest) == ["2026/new/IMG_0002.ARW"]
        wait_job(client, newest["id"])

        clock.advance(3600)
        third = wait_scanned(client, clock)
        assert third["lastQueued"] == 0, "everything is built"
        assert len(auto_jobs(client)) == 2
    # The last scan is remembered across a restart, and the schedule goes on from it.
    with harness.client(clock=clock) as client:
        assert scan_status(client) == third
        look_at_the_clock(client)
        assert scan_status(client) == third
    assert harness.runs_with("IMG_0001.ARW") == harness.runs_with("IMG_0002.ARW") == 1


def test_files_already_built_or_on_their_way_are_skipped(harness: Harness) -> None:
    clock = FakeClock()
    for name in ("BUILT.ARW", "HELD.ARW", "WAITING.ARW", "NEW.ARW", "photo.jpg"):
        settled(harness, clock, name)
    with harness.client(clock=clock, workers=1, batch_size=1) as client:
        wait_job(client, post_job(client, ["BUILT.ARW"])["job"]["id"])
        harness.hold("HELD.ARW")
        held = post_job(client, ["HELD.ARW", "WAITING.ARW"])["job"]["id"]
        wait_for(lambda: harness.runs_with("HELD.ARW") == 1, what="the held build")
        # The scan is off; a scan asked for runs anyway.
        status = scan_now(client, clock, {"roots": ["archive"]})
        assert status["lastQueued"] == 1
        assert status["nextRun"] is None, "the automatic scan is off"
        [job] = auto_jobs(client)
        assert paths(client, job) == ["NEW.ARW"]
        harness.release()
        wait_job(client, held)
        wait_job(client, job["id"])
    for name in ("BUILT.ARW", "HELD.ARW", "WAITING.ARW", "NEW.ARW"):
        assert harness.runs_with(name) == 1, name


def test_at_most_max_files_per_run_oldest_folders_first(harness: Harness) -> None:
    clock = FakeClock()
    for name in ("IMG_0001.ARW", "IMG_0002.ARW", "IMG_0003.ARW"):
        settled(harness, clock, f"2024/a/{name}", age=3 * DAY)
    for name in ("IMG_0001.ARW", "IMG_0002.ARW"):
        settled(harness, clock, f"2023/b/{name}", age=5 * DAY)
        settled(harness, clock, f"2025/c/{name}", age=1 * DAY)
    # A late addition does not make a folder younger: its oldest raw file counts.
    settled(harness, clock, "2023/b/IMG_0009.ARW", age=3600)
    with harness.client(clock=clock) as client:
        pause(client)
        configure(client, enabled=False, maxFilesPerRun=4)
        first = scan_now(client, clock)
        assert first["lastQueued"] == 4, "scanning does not wait for the pause"
        assert paths(client, auto_jobs(client)[-1]) == [
            "2023/b/IMG_0001.ARW",
            "2023/b/IMG_0002.ARW",
            "2023/b/IMG_0009.ARW",
            "2024/a/IMG_0001.ARW",
        ]
        assert any("4 left for the next run" in line for line in log_messages(client))
        second = scan_now(client, clock)
        assert second["lastQueued"] == 4
        assert paths(client, auto_jobs(client)[-1]) == [
            "2024/a/IMG_0002.ARW",
            "2024/a/IMG_0003.ARW",
            "2025/c/IMG_0001.ARW",
            "2025/c/IMG_0002.ARW",
        ]
        assert scan_now(client, clock)["lastQueued"] == 0
        assert len(auto_jobs(client)) == 2
        assert client.get("/api/v1/status").json()["queue"] == {"queued": 8, "building": 0}
    assert harness.runs() == []


def test_a_run_is_split_into_jobs_of_at_most_max_items(
    harness: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    clock = FakeClock()
    names = [f"day/IMG_{index:04d}.ARW" for index in range(5)]
    for name in names:
        settled(harness, clock, name)
    monkeypatch.setattr(app_module, "MAX_ITEMS_PER_JOB", 2)
    with harness.client(clock=clock) as client:
        pause(client)
        assert scan_now(client, clock, {"roots": ["archive"]})["lastQueued"] == 5
        jobs = auto_jobs(client)
        assert [job["counts"]["total"] for job in jobs] == [2, 2, 1]
        assert {(job["label"], job["priority"]) for job in jobs} == {
            ("Automatic scan: archive", "background")
        }
        assert [path for job in jobs for path in paths(client, job)] == names


def test_a_file_that_failed_in_an_automatic_job_waits_until_it_changes(harness: Harness) -> None:
    clock = FakeClock()
    for name in ("BAD.ARW", "GOOD.ARW", "OTHER.ARW"):
        settled(harness, clock, name)
    harness.switch("FAKE_CONVERTER_FAIL", "BAD.ARW,OTHER.ARW")
    with harness.client(clock=clock) as client:
        # A failure in a job of another client is not held against the file.
        other = wait_job(client, post_job(client, ["OTHER.ARW"])["job"]["id"])
        assert other["counts"]["failed"] == 1
        assert scan_now(client, clock, {"roots": ["archive"]})["lastQueued"] == 3
        [job] = auto_jobs(client)
        done = wait_job(client, job["id"])
        assert (done["counts"]["ready"], done["counts"]["failed"]) == (1, 2)

        assert scan_now(client, clock, {"roots": ["archive"]})["lastQueued"] == 0
        # Once the file changes it is queued again.
        harness.switch("FAKE_CONVERTER_FAIL", None)
        harness.raw("BAD.ARW", b"a repaired file")
        harness.set_mtime("BAD.ARW", clock.now - 3600)
        assert scan_now(client, clock, {"roots": ["archive"]})["lastQueued"] == 1
        newest = auto_jobs(client)[-1]
        assert paths(client, newest) == ["BAD.ARW"]
        assert wait_job(client, newest["id"])["counts"]["ready"] == 1
        # Retrying the automatic job builds the other file, after which nothing remembers it.
        client.post(f"/api/v1/jobs/{job['id']}/retry")
        retried = wait_job(client, job["id"])
        assert items_by_path(client, job["id"])["OTHER.ARW"]["state"] == "ready", retried
        assert scan_now(client, clock, {"roots": ["archive"]})["lastQueued"] == 0
    # Only by the first scan: in the batch that failed, then alone.
    assert harness.runs_with("GOOD.ARW") == 2


def test_a_failure_of_the_server_is_not_held_against_the_file(harness: Harness) -> None:
    clock = FakeClock()
    settled(harness, clock, "IMG_0001.ARW")
    harness.gpu_config.unlink()  # the warm-up fails, and with it every item of the wave
    with harness.client(clock=clock) as client:
        assert scan_now(client, clock, {"roots": ["archive"]})["lastQueued"] == 1
        [job] = auto_jobs(client)
        wait_job(client, job["id"])
        item = items_by_path(client, job["id"])["IMG_0001.ARW"]
        assert item["error"]["code"] == "converter_failed"
        assert "could not initialise" in item["error"]["message"]
        harness.gpu_config.write_text("config\n", encoding="utf-8")
        assert scan_now(client, clock, {"roots": ["archive"]})["lastQueued"] == 1
        assert wait_job(client, auto_jobs(client)[-1]["id"])["counts"]["ready"] == 1


def test_an_unavailable_root_is_skipped_with_a_log_line(harness: Harness) -> None:
    clock = FakeClock()
    settled(harness, clock, "IMG_0001.ARW")
    with harness.client(clock=clock) as client:
        pause(client)
        configure(client, enabled=False, roots=["offline", "archive"])
        assert scan_now(client, clock)["lastQueued"] == 1
        [job] = auto_jobs(client)
        assert job["label"] == "Automatic scan: archive"
        assert any("skipping the root 'offline'" in line for line in log_messages(client))


def test_the_run_call(harness: Harness, monkeypatch: pytest.MonkeyPatch) -> None:
    clock = FakeClock()
    settled(harness, clock, "IMG_0001.ARW")
    with harness.client(clock=clock) as client:
        for body in (None, {}, {"roots": []}, {"roots": None}):
            answer = run(client, body, expect=422)
            assert "No root to scan" in answer["detail"], body
        answer = run(client, {"roots": ["archive", "nowhere"]}, expect=422)
        assert answer["code"] == "unknown_root"
        assert "'nowhere'" in answer["detail"]
        for body in ({"roots": "archive"}, {"roots": [1]}):
            assert isinstance(run(client, body, expect=422)["detail"], str)
        assert scan_status(client) == NOTHING_YET

        # A second scan while one runs is refused.
        entered, release = threading.Event(), threading.Event()
        walk = folders.walk

        def held_walk(*args: Any, **kwargs: Any) -> Iterator[Any]:
            entered.set()
            release.wait(30)
            yield from walk(*args, **kwargs)

        monkeypatch.setattr(folders, "walk", held_walk)
        assert run(client, {"roots": ["archive"]}) == {"started": True}
        assert scan_status(client)["running"] is True
        wait_for(entered.is_set, what="the scan to start walking")
        busy = run(client, {"roots": ["archive"]}, expect=409)
        assert busy["code"] == "busy"
        assert run(client, {"roots": ["nowhere"]}, expect=422)["code"] == "unknown_root"
        release.set()
        wait_for(lambda: not scan_status(client)["running"], what="the scan to finish")
        assert scan_status(client)["lastQueued"] == 1


def test_without_a_converter_nothing_is_scanned(harness: Harness) -> None:
    clock = FakeClock()
    settled(harness, clock, "IMG_0001.ARW")
    (harness.prefix / "drive_c" / "Program Files").rename(harness.prefix / "drive_c" / "Gone")
    with harness.client(clock=clock) as client:
        answer = run(client, {"roots": ["archive"]}, expect=409)
        assert answer["code"] == "converter_not_installed"
        configure(client)
        # The periodic scan does not run either, and tries again an interval later.
        wait_for(
            lambda: scan_status(client)["nextRun"] == iso(clock.now + 3600),
            what="the scan to be put off",
        )
        assert scan_status(client)["lastRun"] is None
        assert auto_jobs(client) == []
        assert any("not installed" in line for line in log_messages(client))


def test_a_large_tree_costs_few_queries_and_no_stat_per_file(
    harness: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    clock = FakeClock()
    days, per_day = 30, 50
    moment = int((clock.now - DAY) * 1e9)
    for day in range(days):
        folder = harness.originals / "big" / f"day{day:02d}"
        folder.mkdir(parents=True)
        for number in range(per_day):
            file = folder / f"IMG_{number:04d}.ARW"
            file.write_bytes(b"x")
            os.utime(file, ns=(moment, moment))
    files = days * per_day
    with harness.client(clock=clock) as client:
        pause(client)
        originals = str(harness.originals)
        calls = {"stat": 0, "queries": 0}

        def counted(function: Callable[..., Any], what: str) -> Callable[..., Any]:
            def wrapper(*args: Any, **kwargs: Any) -> Any:
                # Only what the scan's thread does.
                if threading.current_thread().name == "lrrp-autoscan" and (
                    what == "queries" or str(args[0]).startswith(originals)
                ):
                    calls[what] += 1
                return function(*args, **kwargs)

            return wrapper

        monkeypatch.setattr(os, "stat", counted(os.stat, "stat"))
        monkeypatch.setattr(os, "lstat", counted(os.lstat, "stat"))
        monkeypatch.setattr(Store, "_query", counted(Store._query, "queries"))
        status = scan_now(client, clock, {"roots": ["archive"]})
    assert status["lastQueued"] == files
    # The index, the queue and the failures are asked in chunks of 500 keys; the jobs are read
    # back once each.
    assert calls["queries"] <= 3 * math.ceil(files / 500) + 6, calls
    # The files' own stat comes with the directory listing; os.stat only checks the root.
    assert calls["stat"] <= 10, calls
