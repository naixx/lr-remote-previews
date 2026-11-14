"""Adding items to a job that exists: ``POST /api/v1/jobs/{id}/items``."""

import sqlite3
import threading
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import pytest

import lrrp.app as app_module
from conftest import DAY, FakeClock, Harness, Poller, add_items, post_job, wait_for, wait_job
from lrrp import scheduler as scheduler_module
from lrrp.cache import CacheEntry
from lrrp.scheduler import Scheduler
from lrrp.store import Appended, AppendRefused, Changes, NewItem, NewJob, Store


def iso(timestamp: float) -> str:
    return datetime.fromtimestamp(timestamp, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def item_count(database: Path, job_id: int) -> int:
    db = sqlite3.connect(database)
    try:
        (count,) = db.execute("SELECT COUNT(*) FROM items WHERE job_id = ?", (job_id,)).fetchone()
    finally:
        db.close()
    return count


def test_added_items_are_checked_like_new_ones_and_get_the_next_seqs(harness: Harness) -> None:
    harness.raw("cached/IMG_0001.ARW")
    harness.raw("new/IMG_0002.ARW")
    with harness.client() as client:
        wait_job(client, post_job(client, ["cached/IMG_0001.ARW"])["job"]["id"])
        created = post_job(
            client, ["photo.jpg"], label="Import", clientId="catalog-1", priority="background"
        )
        job = created["job"]
        assert (job["state"], job["seq"]) == ("done", 1)

        paths = ["cached/IMG_0001.ARW", "new/IMG_0002.ARW", "other.jpg", "gone/IMG_0009.ARW"]
        body = add_items(client, job["id"], paths, prefix="b")
        items = body["items"]
        assert [item["ref"] for item in items] == ["b0", "b1", "b2", "b3"]
        assert [item["path"] for item in items] == paths
        assert [item["state"] for item in items] == ["ready", "queued", "rejected", "rejected"]
        assert [item["seq"] for item in items] == [2, 3, 4, 5]
        assert items[0]["result"]["originalName"] == "IMG_0001.ARW"
        assert [item["error"] and item["error"]["code"] for item in items] == [
            None,
            None,
            "unsupported_format",
            "not_found",
        ]
        added = body["job"]
        assert added["id"] == job["id"]
        assert added["seq"] == 5
        assert (added["state"], added["finished"]) == ("active", None)
        assert added["counts"]["total"] == 5
        assert added["counts"]["queued"] + added["counts"]["building"] == 1
        # The job keeps what it was created with.
        assert (added["label"], added["clientId"], added["priority"]) == (
            "Import",
            "catalog-1",
            "background",
        )
        assert added["created"] == job["created"]

        # A client polling with the seq of the creation answer sees the added items as changes.
        poller = Poller(job["id"], job["seq"])
        final = poller.until_finished(client)
        assert final["state"] == "done"
        assert final["finished"] is not None
        assert poller.last_states() == {
            "cached/IMG_0001.ARW": "ready",
            "new/IMG_0002.ARW": "ready",
            "other.jpg": "rejected",
            "gone/IMG_0009.ARW": "rejected",
        }
        everything = client.get(f"/api/v1/jobs/{job['id']}/items").json()["items"]
        assert len({item["seq"] for item in everything}) == 5
        assert final["seq"] == max(item["seq"] for item in everything) == poller.since
    assert harness.runs_with("IMG_0001.ARW") == 1, "the cached file was not built again"


def test_a_done_job_becomes_active_again_and_done_again(harness: Harness) -> None:
    clock = FakeClock()
    for name in ("IMG_0001.ARW", "IMG_0002.ARW"):
        harness.raw(name)
    with harness.client(clock=clock) as client:
        job_id = post_job(client, ["IMG_0001.ARW"])["job"]["id"]
        first = wait_job(client, job_id)
        assert first["finished"] == iso(clock.now)

        clock.advance(3600)
        harness.hold()
        body = add_items(client, job_id, ["IMG_0002.ARW"], prefix="b")
        assert (body["job"]["state"], body["job"]["finished"]) == ("active", None)
        active = client.get("/api/v1/jobs", params={"state": "active"}).json()["jobs"]
        assert [job["id"] for job in active] == [job_id]
        assert client.get("/api/v1/status").json()["jobs"]["active"] == 1

        clock.advance(60)
        harness.release()
        done = wait_job(client, job_id)
        assert done["finished"] == iso(clock.now), "finished: when it was done the second time"
        assert done["counts"]["ready"] == 2

        # Items that need no build leave a done job done, and its time as it was.
        clock.advance(60)
        body = add_items(client, job_id, ["IMG_0001.ARW", "photo.jpg"], prefix="c")
        assert [item["state"] for item in body["items"]] == ["ready", "rejected"]
        assert (body["job"]["state"], body["job"]["finished"]) == ("done", done["finished"])
    assert harness.runs_with("IMG_0001.ARW") == 1


def test_the_retention_counts_from_when_the_job_was_last_done(harness: Harness) -> None:
    clock = FakeClock()
    for name in ("IMG_0001.ARW", "IMG_0002.ARW"):
        harness.raw(name)
    with harness.client(clock=clock, LRRP_JOB_RETENTION_DAYS="2") as client:
        store = client.app.state.services.store
        job_id = post_job(client, ["IMG_0001.ARW"])["job"]["id"]
        wait_job(client, job_id)
        clock.advance(1.5 * DAY)
        add_items(client, job_id, ["IMG_0002.ARW"], prefix="b")
        wait_job(client, job_id)
        # 2.5 days after it was done the first time, 1 day after the second: kept.
        clock.advance(DAY)
        store.delete_expired_jobs(clock.now - 2 * DAY)
        assert client.get(f"/api/v1/jobs/{job_id}").status_code == 200
        # More than 2 days after the second time: deleted, with every item.
        clock.advance(1.5 * DAY)
        store.delete_expired_jobs(clock.now - 2 * DAY)
        assert client.get(f"/api/v1/jobs/{job_id}").status_code == 404
    assert item_count(harness.database, job_id) == 0


def test_added_items_are_built_without_waiting_for_anything_else(
    harness: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Unless something wakes it, the idle scheduler would sleep for an hour.
    monkeypatch.setattr(scheduler_module, "IDLE_WAIT", 3600.0)
    results: list[bool] = []
    run_wave = Scheduler.run_wave

    def recorded(self: Scheduler) -> bool:
        worked = run_wave(self)
        results.append(worked)
        return worked

    monkeypatch.setattr(Scheduler, "run_wave", recorded)
    for name in ("IMG_0001.ARW", "IMG_0002.ARW"):
        harness.raw(name)
    with harness.client() as client:
        job_id = post_job(client, ["IMG_0001.ARW"])["job"]["id"]
        wait_job(client, job_id)
        # Evidence that the scheduler has found the queue empty after the job: it sleeps now.
        wait_for(lambda: True in results and results[-1] is False, what="an empty look")
        body = add_items(client, job_id, ["IMG_0002.ARW"], prefix="b")
        assert body["items"][0]["state"] == "queued"
        assert wait_job(client, job_id)["counts"]["ready"] == 2


def test_an_older_jobs_added_items_go_before_a_newer_jobs(harness: Harness) -> None:
    names = ["A_0001.ARW", "A_0002.ARW", "B_0001.ARW", "B_0002.ARW"]
    for name in names:
        harness.raw(name)
    harness.hold("A_0001.ARW")
    with harness.client(workers=1, batch_size=1) as client:
        older = post_job(client, ["A_0001.ARW"])["job"]["id"]
        wait_for(lambda: harness.runs_with("A_0001.ARW") == 1, what="the first wave")
        newer = post_job(client, ["B_0001.ARW", "B_0002.ARW"])["job"]["id"]
        add_items(client, older, ["A_0002.ARW"], prefix="b")
        harness.release()
        wait_job(client, older)
        wait_job(client, newer)
    assert harness.runs() == [["A_0001.ARW"], ["A_0002.ARW"], ["B_0001.ARW"], ["B_0002.ARW"]]


def test_a_file_that_is_building_is_built_once_for_the_items_added_meanwhile(
    harness: Harness,
) -> None:
    for name in ("IMG_0001.ARW", "IMG_0002.ARW"):
        harness.raw(name)
    harness.hold()
    with harness.client(workers=1, batch_size=8) as client:
        first = post_job(client, ["IMG_0001.ARW"])["job"]["id"]
        wait_for(lambda: harness.runs_with("IMG_0001.ARW") == 1, what="its build")
        second = post_job(client, ["IMG_0002.ARW"])["job"]["id"]
        # The same file again, in the job that builds it and in another job, while it builds.
        same = add_items(client, first, ["IMG_0001.ARW"], prefix="again")["items"][0]
        other = add_items(client, second, ["IMG_0001.ARW"], prefix="b")["items"][0]
        assert same["state"] == other["state"] == "queued"
        harness.release()
        wait_job(client, first)
        wait_job(client, second)
        results = {
            (job_id, item["ref"]): item
            for job_id in (first, second)
            for item in client.get(f"/api/v1/jobs/{job_id}/items").json()["items"]
            if item["path"] == "IMG_0001.ARW"
        }
        assert len(results) == 3
        assert {item["state"] for item in results.values()} == {"ready"}
        assert len({item["result"]["key"] for item in results.values()}) == 1
    assert harness.runs_with("IMG_0001.ARW") == 1


def test_items_added_while_a_wave_runs_survive_a_restart(harness: Harness) -> None:
    names = [f"IMG_000{index}.ARW" for index in range(1, 5)]
    for name in names:
        harness.raw(name)
    harness.hold()
    with harness.client(workers=1, batch_size=2) as client:
        job_id = post_job(client, names[:2])["job"]["id"]
        poller = Poller(job_id)
        # "building" is set before the converter starts; wait for the converter itself.
        wait_for(lambda: harness.runs_with("IMG_0001.ARW") == 1, what="the held wave")
        added = add_items(client, job_id, names[2:], prefix="b")
        assert [item["state"] for item in added["items"]] == ["queued", "queued"]
        assert added["job"]["counts"]["building"] == 2
        before = poller.poll(client)["seq"]
    # The server stopped with two items building (their converter killed) and two added ones
    # queued.
    harness.release()
    with harness.client(workers=1, batch_size=2) as client:
        final = poller.until_finished(client)
        assert final["state"] == "done"
        assert final["seq"] > before
        assert final["counts"]["total"] == final["counts"]["ready"] == 4
        assert poller.last_states() == dict.fromkeys(names, "ready")
        everything = client.get(f"/api/v1/jobs/{job_id}/items").json()["items"]
        assert sorted(item["ref"] for item in everything) == ["0", "1", "b0", "b1"]
        assert len({item["seq"] for item in everything}) == 4
    for name in names[:2]:
        assert harness.runs_with(name) == 2, f"{name}: the interrupted run and one after it"
    for name in names[2:]:
        assert harness.runs_with(name) == 1, name


# --- Refusals --------------------------------------------------------------------------------


def test_an_unknown_job(harness: Harness) -> None:
    with harness.client() as client:
        body = add_items(client, 999, ["photo.jpg"], prefix="b", expect=404)
        assert body == {"detail": "No such job"}


def test_a_cancelled_job(harness: Harness) -> None:
    harness.raw("IMG_0001.ARW")
    harness.hold()
    with harness.client() as client:
        job_id = post_job(client, ["IMG_0001.ARW", "IMG_0002.ARW"])["job"]["id"]
        cancelled = client.delete(f"/api/v1/jobs/{job_id}").json()["job"]
        assert cancelled["state"] == "cancelled"
        body = add_items(client, job_id, ["photo.jpg"], prefix="b", expect=409)
        assert body["code"] == "job_cancelled"
        assert isinstance(body["detail"], str)
        assert client.get(f"/api/v1/jobs/{job_id}").json()["job"]["seq"] == cancelled["seq"]
        harness.release()


@pytest.mark.parametrize(
    ("body", "fragment"),
    [
        ({}, "items: Field required"),
        ({"items": []}, "items"),
        ({"items": [{"ref": "x" * 65, "root": "archive", "path": "a.ARW"}]}, "items[0].ref"),
        ({"items": [{"ref": "1", "root": "archive"}]}, "items[0].path"),
        ({"items": "a.ARW"}, "items"),
    ],
)
def test_a_malformed_body(harness: Harness, body: dict[str, Any], fragment: str) -> None:
    with harness.client() as client:
        job = post_job(client, ["photo.jpg"])["job"]
        response = client.post(f"/api/v1/jobs/{job['id']}/items", json=body)
        assert response.status_code == 422, response.text
        assert fragment in response.json()["detail"]
        assert client.get(f"/api/v1/jobs/{job['id']}").json()["job"] == job


def test_duplicate_refs(harness: Harness) -> None:
    with harness.client() as client:
        job = post_job(client, ["photo.jpg"])["job"]
        url = f"/api/v1/jobs/{job['id']}/items"
        twice = [{"ref": "b", "root": "archive", "path": f"{n}.jpg"} for n in range(2)]
        response = client.post(url, json={"items": twice})
        assert response.status_code == 422
        assert response.json()["code"] == "duplicate_ref"
        # The job's own refs: from its creation, and from an earlier addition.
        add_items(client, job["id"], ["x.jpg"], prefix="b")
        for ref in ("0", "b0"):
            items = [
                {"ref": "new", "root": "archive", "path": "y.jpg"},
                {"ref": ref, "root": "archive", "path": "z.jpg"},
            ]
            response = client.post(url, json={"items": items})
            assert response.status_code == 422, ref
            assert response.json()["code"] == "duplicate_ref"
            assert repr(ref) in response.json()["detail"]
        assert client.get(f"/api/v1/jobs/{job['id']}").json()["job"]["counts"]["total"] == 2


def test_too_many_items(harness: Harness, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(app_module, "MAX_ITEMS_PER_JOB", 3)
    with harness.client() as client:
        job_id = post_job(client, ["0.jpg", "1.jpg"])["job"]["id"]
        for paths in (["a.jpg", "b.jpg"], ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]):
            body = add_items(client, job_id, paths, prefix="b", expect=413)
            assert body["code"] == "too_many_items"
        add_items(client, job_id, ["a.jpg"], prefix="c")
        body = add_items(client, job_id, ["b.jpg"], prefix="d", expect=413)
        assert "another job" in body["detail"]
        assert client.get(f"/api/v1/jobs/{job_id}").json()["job"]["counts"]["total"] == 3


def test_the_real_limit_of_items(harness: Harness) -> None:
    limit = app_module.MAX_ITEMS_PER_JOB
    with harness.client() as client:
        job_id = post_job(client, [f"{n}.jpg" for n in range(limit - 1)])["job"]["id"]
        add_items(client, job_id, ["a.jpg", "b.jpg"], prefix="b", expect=413)
        body = add_items(client, job_id, ["a.jpg"], prefix="b")
        assert body["job"]["counts"]["total"] == limit
        assert body["items"][0]["seq"] == limit


def test_converter_not_installed(harness: Harness) -> None:
    harness.raw("IMG_0001.ARW")
    (harness.prefix / "drive_c" / "Program Files").rename(harness.prefix / "drive_c" / "Gone")
    with harness.client() as client:
        job = post_job(client, ["photo.jpg"])["job"]
        body = add_items(client, job["id"], ["IMG_0001.ARW"], prefix="b", expect=409)
        assert body["code"] == "converter_not_installed"
        assert client.get(f"/api/v1/jobs/{job['id']}").json()["job"] == job
        # With nothing to build the items are added.
        body = add_items(client, job["id"], ["other.jpg"], prefix="b")
        assert body["items"][0]["state"] == "rejected"


def test_adding_items_needs_the_token(harness: Harness, token: str, auth: dict[str, str]) -> None:
    with harness.client(LRRP_TOKEN=token) as client:
        response = client.post("/api/v1/jobs/1/items")
        assert response.status_code == 401
        assert response.json() == {"detail": "Missing bearer token"}
        items = [{"ref": "1", "root": "archive", "path": "a.jpg"}]
        created = client.post("/api/v1/jobs", json={"items": items}, headers=auth).json()
        url = f"/api/v1/jobs/{created['job']['id']}/items"
        items = [{"ref": "2", "root": "archive", "path": "b.jpg"}]
        assert client.post(url, json={"items": items}, headers=auth).status_code == 200
    paths = client.app.openapi()["paths"]
    assert "post" in paths["/api/v1/jobs/{job_id}/items"]


# --- Races -----------------------------------------------------------------------------------


def meddle(monkeypatch: pytest.MonkeyPatch, action: Callable[[], None]) -> None:
    """Run ``action`` once in the request, after its own checks and before it adds the items
    (while it looks at the files)."""
    identify = app_module._identify
    done = threading.Event()

    def meddling(*args: Any) -> Any:
        if not done.is_set():
            done.set()
            action()
        return identify(*args)

    monkeypatch.setattr(app_module, "_identify", meddling)


def rejected(ref: str) -> NewItem:
    return NewItem(ref=ref, root="archive", path="x.jpg", state="rejected", error_code="x")


def test_a_job_deleted_meanwhile_gets_no_items(
    harness: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    clock = FakeClock()
    with harness.client(clock=clock) as client:
        store: Store = client.app.state.services.store
        job_id = post_job(client, ["photo.jpg"])["job"]["id"]
        meddle(monkeypatch, lambda: store.delete_expired_jobs(clock.now + 1))
        assert add_items(client, job_id, ["a.jpg"], prefix="b", expect=404) == {
            "detail": "No such job"
        }
    assert item_count(harness.database, job_id) == 0, "nothing left behind"


def test_a_job_cancelled_meanwhile_gets_no_items(
    harness: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    harness.raw("IMG_0001.ARW")
    harness.hold()
    with harness.client() as client:
        store: Store = client.app.state.services.store
        job_id = post_job(client, ["IMG_0001.ARW", "IMG_0002.ARW"])["job"]["id"]
        meddle(monkeypatch, lambda: store.cancel_job(job_id, 0))
        body = add_items(client, job_id, ["a.jpg"], prefix="b", expect=409)
        assert body["code"] == "job_cancelled"
        assert client.get(f"/api/v1/jobs/{job_id}").json()["job"]["counts"]["total"] == 2
        harness.release()


def test_a_ref_taken_meanwhile_is_a_duplicate(
    harness: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    with harness.client() as client:
        store: Store = client.app.state.services.store
        job_id = post_job(client, ["photo.jpg"])["job"]["id"]
        meddle(monkeypatch, lambda: store.append_items(job_id, [rejected("b1")], 0, 5000))
        body = add_items(client, job_id, ["a.jpg", "b.jpg"], prefix="b", expect=422)
        assert body["code"] == "duplicate_ref"
        assert "'b1'" in body["detail"]
        refs = [item["ref"] for item in client.get(f"/api/v1/jobs/{job_id}/items").json()["items"]]
        assert refs == ["0", "b1"]


def test_items_added_meanwhile_count_against_the_limit(
    harness: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(app_module, "MAX_ITEMS_PER_JOB", 3)
    with harness.client() as client:
        store: Store = client.app.state.services.store
        job_id = post_job(client, ["photo.jpg"])["job"]["id"]
        meddle(monkeypatch, lambda: store.append_items(job_id, [rejected("other")], 0, 3))
        body = add_items(client, job_id, ["a.jpg", "b.jpg"], prefix="b", expect=413)
        assert body["code"] == "too_many_items"
        assert client.get(f"/api/v1/jobs/{job_id}").json()["job"]["counts"]["total"] == 2


def test_additions_at_the_same_time_get_distinct_seqs(harness: Harness) -> None:
    harness.raw("IMG_0001.ARW")
    senders, per_sender = 8, 25
    with harness.client() as client:
        job_id = post_job(client, ["photo.jpg"])["job"]["id"]
        start = threading.Barrier(senders + 2)
        answers: dict[str, Any] = {}

        def send(name: str, paths: list[str], refs: list[str]) -> None:
            items = [
                {"ref": ref, "root": "archive", "path": path}
                for ref, path in zip(refs, paths, strict=True)
            ]
            start.wait()
            answers[name] = client.post(f"/api/v1/jobs/{job_id}/items", json={"items": items})

        threads = [
            threading.Thread(
                target=send,
                args=(
                    f"s{n}",
                    [f"s{n}/{i}.jpg" for i in range(per_sender)],
                    [f"s{n}-{i}" for i in range(per_sender)],
                ),
            )
            for n in range(senders)
        ]
        # Two more that want the same ref: one of them gets it.
        threads += [
            threading.Thread(target=send, args=(name, ["IMG_0001.ARW"], ["same"]))
            for name in ("x", "y")
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(60)
        statuses = sorted(answers[name].status_code for name in ("x", "y"))
        assert statuses == [200, 422]
        for n in range(senders):
            response = answers[f"s{n}"]
            assert response.status_code == 200, response.text
            seqs = [item["seq"] for item in response.json()["items"]]
            assert seqs == list(range(seqs[0], seqs[0] + per_sender)), "one block per addition"
        wait_job(client, job_id)
        everything = client.get(f"/api/v1/jobs/{job_id}/items", params={"limit": 1000}).json()
        total = 1 + senders * per_sender + 1
        assert len(everything["items"]) == total
        assert len({item["seq"] for item in everything["items"]}) == total
        assert everything["job"]["seq"] == max(item["seq"] for item in everything["items"])
    assert harness.runs_with("IMG_0001.ARW") == 1


# --- The store -------------------------------------------------------------------------------

KEY = "a" * 64


def queued(ref: str, key: str = KEY) -> NewItem:
    return NewItem(
        ref=ref, root="archive", path="IMG.ARW", state="queued", cache_key=key, size=1, mtime_ns=1
    )


def test_store_append_and_its_refusals(tmp_path: Path) -> None:
    store = Store(tmp_path / "lrrp.sqlite3")
    try:
        job, _ = store.create_job(None, None, [rejected("0")], 100.0)
        assert (job.state, job.seq, job.finished) == ("done", 1, 100.0)
        outcome = store.append_items(job.id, [rejected("1"), queued("2")], 200.0, 10)
        assert isinstance(outcome, Appended)
        assert [(item.ref, item.state, item.seq) for item in outcome.items] == [
            ("1", "rejected", 2),
            ("2", "queued", 3),
        ]
        assert (outcome.job.state, outcome.job.seq, outcome.job.finished) == ("active", 3, None)
        assert store.append_items(job.id, [rejected("2")], 0, 10) == AppendRefused(
            "duplicate_ref", ref="2"
        )
        assert store.append_items(job.id, [rejected("a"), rejected("b")], 0, 4) == AppendRefused(
            "too_many", total=3
        )
        assert store.append_items(999, [rejected("a")], 0, 10) == AppendRefused("unknown")
        store.cancel_job(job.id, 300.0)
        assert store.append_items(job.id, [rejected("a")], 0, 10) == AppendRefused("cancelled")
        cancelled = store.get_job(job.id)
        assert cancelled is not None and cancelled.seq == 4, "nothing changed but the cancel"
    finally:
        store.close()


def test_store_a_job_made_active_by_an_addition_does_not_expire(tmp_path: Path) -> None:
    store = Store(tmp_path / "lrrp.sqlite3")
    try:
        old, _ = store.create_job(None, None, [rejected("0")], 100.0)
        kept, _ = store.create_job(None, None, [rejected("0")], 100.0)
        store.append_items(kept.id, [queued("1")], 1000.0, 10)
        assert store.delete_expired_jobs(1000.0) == 1
        assert store.get_job(old.id) is None
        job = store.get_job(kept.id)
        assert job is not None and job.state == "active" and job.counts["queued"] == 1
    finally:
        store.close()


def test_store_an_item_added_before_its_wave_marks_it_building_is_built_with_it(
    tmp_path: Path,
) -> None:
    store = Store(tmp_path / "lrrp.sqlite3")
    try:
        first, _ = store.create_job(None, None, [queued("0")], 100.0)
        second, _ = store.create_job(None, None, [rejected("0")], 100.0)
        # The wave has chosen the file; the same file is added to another job before the wave
        # marks it building.
        assert [candidate.key for candidate in store.queued_candidates(10)] == [KEY]
        store.append_items(second.id, [queued("1")], 101.0, 10)
        store.mark_building([KEY], 102.0)
        assert {item.state for item in store.items_of_job(second.id) if item.ref == "1"} == {
            "building"
        }
        store.complete(KEY, CacheEntry(KEY, 10, "d" * 64, "IMG.ARW", 1, 1, 103.0), 103.0)
        for job_id in (first.id, second.id):
            job = store.get_job(job_id)
            assert job is not None and job.state == "done"
        assert store.queued_candidates(10) == []
    finally:
        store.close()


def test_store_reports_committed_changes(tmp_path: Path) -> None:
    path = tmp_path / "lrrp.sqlite3"
    reports: list[Changes] = []
    seen_by_another_connection: list[str] = []

    def on_change(changes: Changes) -> None:
        # Reported after the commit: another connection already sees the change.
        reader = sqlite3.connect(path)
        try:
            rows = reader.execute("SELECT state FROM items ORDER BY id DESC LIMIT 1").fetchall()
        finally:
            reader.close()
        seen_by_another_connection.append(rows[0][0] if rows else "")
        reports.append(changes)

    store = Store(path, on_change=on_change)
    try:
        job, _ = store.create_job(None, None, [queued("0")], 100.0)
        store.mark_building([KEY], 101.0)
        store.complete(KEY, CacheEntry(KEY, 10, "d" * 64, "IMG.ARW", 1, 1, 102.0), 102.0)
        assert [dict(report.items) for report in reports] == [
            {job.id: frozenset({"queued"})},
            {job.id: frozenset({"building"})},
            {job.id: frozenset({"ready"})},
        ]
        assert seen_by_another_connection == ["queued", "building", "ready"]
        reports.clear()
        store.append_items(job.id, [rejected("1"), queued("2", "b" * 64)], 103.0, 10)
        assert dict(reports[-1].items) == {job.id: frozenset({"rejected", "queued"})}
        reports.clear()
        # Refused, or nothing to change: nothing to report.
        store.append_items(job.id, [rejected("1")], 104.0, 10)
        store.mark_building(["c" * 64], 104.0)
        assert reports == []
        store.cancel_job(job.id, 105.0)
        assert dict(reports[-1].items) == {job.id: frozenset({"cancelled"})}
        store.delete_expired_jobs(200.0)
        assert reports[-1].deleted == frozenset({job.id})
        assert dict(reports[-1].items) == {}
        reports.clear()

        # A transaction that fails reports nothing, and what it noted is not reported later.
        with pytest.raises(sqlite3.IntegrityError):
            store.create_jobs(
                [
                    NewJob(client=None, label=None, items=[queued("0", "d" * 64)]),
                    NewJob(client=None, label=None, items=[rejected("dup"), rejected("dup")]),
                ],
                300.0,
            )
        assert reports == []
        store.mark_building(["d" * 64], 301.0)
        assert reports == [], "the failed job's item was never there"
    finally:
        store.close()


def test_store_a_failing_report_does_not_undo_the_change(tmp_path: Path) -> None:
    def failing(_changes: Changes) -> None:
        raise RuntimeError("the listener is broken")

    store = Store(tmp_path / "lrrp.sqlite3", on_change=failing)
    try:
        job, items = store.create_job(None, None, [queued("0")], 100.0)
        assert items[0].state == "queued"
        assert store.get_job(job.id) is not None
    finally:
        store.close()
