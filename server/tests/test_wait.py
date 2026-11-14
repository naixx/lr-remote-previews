"""Waiting for a change: ``wait`` of ``GET /api/v1/jobs/{id}/items``.

Most tests use the in-process test client, with each waiting request in a thread of its own. The
tests at the end serve the application with uvicorn on a local port, as ``python -m lrrp`` does,
for what only a real server shows: many clients at once, a client that goes away, a stop.
"""

import asyncio
import contextlib
import socket
import threading
import time
from collections.abc import Awaitable, Callable, Iterator
from typing import Any

import httpx2
import pytest
import uvicorn
from fastapi import FastAPI
from fastapi.testclient import TestClient

import lrrp.app as app_module
from conftest import Harness, add_items, post_job, wait_for, wait_job
from lrrp.__main__ import Server
from lrrp.app import MAX_WAIT_SECONDS
from lrrp.store import Changes, NewItem
from lrrp.waits import LOOK_THREADS, Waits


def waits_of(client: TestClient) -> Waits:
    return client.app.state.services.waits


def items_url(job_id: int) -> str:
    return f"/api/v1/jobs/{job_id}/items"


class Waiter:
    """A request that may wait, sent in a thread of its own."""

    def __init__(self, client: TestClient, job_id: int, **params: Any) -> None:
        self.response: Any = None
        self.elapsed = 0.0

        def send() -> None:
            started = time.monotonic()
            self.response = client.get(items_url(job_id), params=params)
            self.elapsed = time.monotonic() - started

        self.thread = threading.Thread(target=send, daemon=True)
        self.thread.start()

    def result(self, timeout: float = 70.0) -> Any:
        self.thread.join(timeout)
        assert not self.thread.is_alive(), "the request did not end"
        return self.response


def test_info_says_how_long_a_request_may_wait(harness: Harness) -> None:
    with harness.client() as client:
        capabilities = client.get("/api/v1/info").json()["capabilities"]
        assert capabilities["maxWaitSeconds"] == MAX_WAIT_SECONDS == 55
        assert capabilities["appendItems"] is True


def test_a_wait_answers_at_once_when_there_is_something(harness: Harness) -> None:
    with harness.client() as client:
        job = post_job(client, ["photo.jpg", "other.jpg"])["job"]
        started = time.monotonic()
        page = client.get(items_url(job["id"]), params={"since": 1, "wait": 30}).json()
        assert time.monotonic() - started < 5
        assert [item["seq"] for item in page["items"]] == [2]
        assert page["job"]["seq"] == 2
        assert waits_of(client).watching() == 0


@pytest.mark.parametrize("wait", ["-1", "-0.5", "55.001", "56", "abc", "nan", "inf", "-inf", ""])
def test_a_bad_wait_is_refused(harness: Harness, wait: str) -> None:
    with harness.client() as client:
        job = post_job(client, ["photo.jpg"])["job"]
        response = client.get(items_url(job["id"]), params={"wait": wait})
        assert response.status_code == 422, response.text
        detail = response.json()["detail"]
        assert isinstance(detail, str)
        assert detail.startswith("wait"), detail


def test_waits_from_0_to_55_seconds_are_accepted(harness: Harness) -> None:
    with harness.client() as client:
        job = post_job(client, ["photo.jpg"])["job"]
        for wait in ("0", "0.0", "1e1", "55", "55.0"):
            started = time.monotonic()
            response = client.get(items_url(job["id"]), params={"since": 0, "wait": wait})
            assert response.status_code == 200, (wait, response.text)
            assert len(response.json()["items"]) == 1
            assert time.monotonic() - started < 5
        # An unknown job does not wait either.
        started = time.monotonic()
        response = client.get(items_url(999), params={"wait": 30})
        assert response.status_code == 404
        assert response.json() == {"detail": "No such job"}
        assert time.monotonic() - started < 5


def test_a_wait_ends_after_its_time_with_no_items(harness: Harness) -> None:
    with harness.client() as client:
        job = post_job(client, ["photo.jpg"])["job"]
        for wait in (1.0, 0.3):
            waiter = Waiter(client, job["id"], since=job["seq"], wait=wait)
            response = waiter.result()
            assert response.status_code == 200
            page = response.json()
            assert page["items"] == []
            assert page["more"] is False
            assert page["job"] == job
            assert wait - 0.05 <= waiter.elapsed < wait + 10
        assert waits_of(client).watching() == 0


def test_a_waiting_request_gets_a_ready_item_as_soon_as_it_is_built(harness: Harness) -> None:
    harness.raw("IMG_0001.ARW")
    harness.hold()
    with harness.client() as client:
        waits = waits_of(client)
        client.patch("/api/v1/settings", json={"paused": True})
        created = post_job(client, ["IMG_0001.ARW", "photo.jpg"])
        job_id = created["job"]["id"]
        waiter = Waiter(client, job_id, since=created["job"]["seq"], state="ready", wait=30)
        wait_for(lambda: waits.waiting(job_id) == 1, what="the request to wait")
        client.patch("/api/v1/settings", json={"paused": False})
        wait_for(lambda: harness.runs_with("IMG_0001.ARW") == 1, what="the build to start")
        # The item is building now: not what the request asks for, so it still waits.
        assert waits.waiting(job_id) == 1
        assert waiter.thread.is_alive()
        harness.release()
        response = waiter.result()
        assert response.status_code == 200
        page = response.json()
        [item] = page["items"]
        assert (item["path"], item["state"]) == ("IMG_0001.ARW", "ready")
        assert item["result"]["originalName"] == "IMG_0001.ARW"
        assert page["job"]["seq"] >= item["seq"]
        assert waiter.elapsed < 25, "it answered when the item was ready, not at the end"
        assert waits.watching() == 0


def test_an_added_item_ends_a_wait_whose_filter_it_matches(harness: Harness) -> None:
    harness.raw("cached/IMG_0001.ARW")
    harness.raw("new/IMG_0002.ARW")
    with harness.client() as client:
        waits = waits_of(client)
        wait_job(client, post_job(client, ["cached/IMG_0001.ARW"])["job"]["id"])
        client.patch("/api/v1/settings", json={"paused": True})  # added raw files stay queued
        job = post_job(client, ["photo.jpg"])["job"]

        # Without a state: any added item, a rejected one too.
        waiter = Waiter(client, job["id"], since=job["seq"], wait=30)
        wait_for(lambda: waits.waiting(job["id"]) == 1, what="the request to wait")
        added = add_items(client, job["id"], ["other.jpg"], prefix="b")
        page = waiter.result().json()
        assert [(item["ref"], item["state"]) for item in page["items"]] == [("b0", "rejected")]
        assert waiter.elapsed < 25

        # With state=ready: a queued item does not end it, one found in the cache does.
        waiter = Waiter(client, job["id"], since=added["job"]["seq"], state="ready", wait=30)
        wait_for(lambda: waits.waiting(job["id"]) == 1, what="the request to wait")
        add_items(client, job["id"], ["new/IMG_0002.ARW"], prefix="c")
        assert waits.waiting(job["id"]) == 1
        add_items(client, job["id"], ["cached/IMG_0001.ARW"], prefix="d")
        page = waiter.result().json()
        assert [(item["ref"], item["state"]) for item in page["items"]] == [("d0", "ready")]
        assert waiter.elapsed < 25
        client.patch("/api/v1/settings", json={"paused": False})


def test_a_cancel_ends_a_wait_for_any_change(harness: Harness) -> None:
    harness.raw("IMG_0001.ARW")
    with harness.client() as client:
        waits = waits_of(client)
        client.patch("/api/v1/settings", json={"paused": True})
        job = post_job(client, ["IMG_0001.ARW"])["job"]
        waiter = Waiter(client, job["id"], since=job["seq"], wait=30)
        wait_for(lambda: waits.waiting(job["id"]) == 1, what="the request to wait")
        client.delete(f"/api/v1/jobs/{job['id']}")
        page = waiter.result().json()
        assert [item["state"] for item in page["items"]] == ["cancelled"]
        assert page["job"]["state"] == "cancelled"


def test_a_deleted_job_ends_a_wait_with_404(harness: Harness) -> None:
    with harness.client() as client:
        waits = waits_of(client)
        job = post_job(client, ["photo.jpg"])["job"]
        waiter = Waiter(client, job["id"], since=job["seq"], wait=30)
        wait_for(lambda: waits.waiting(job["id"]) == 1, what="the request to wait")
        client.app.state.services.store.delete_expired_jobs(time.time() + 3600)
        response = waiter.result()
        assert response.status_code == 404
        assert response.json() == {"detail": "No such job"}
        assert waiter.elapsed < 25
        assert waits.watching() == 0


def test_a_change_right_after_the_look_is_not_missed(
    harness: Harness, monkeypatch: pytest.MonkeyPatch
) -> None:
    with harness.client() as client:
        store = client.app.state.services.store
        job = post_job(client, ["photo.jpg"])["job"]
        late = NewItem(ref="late", root="archive", path="x.jpg", state="rejected", error_code="x")
        item_page = app_module._item_page
        changed = threading.Event()

        def look_then_change(*args: Any) -> Any:
            page = item_page(*args)
            if not changed.is_set():
                changed.set()
                # Committed after this look read the database, before the request sleeps.
                store.append_items(job["id"], [late], time.time(), 5000)
            return page

        monkeypatch.setattr(app_module, "_item_page", look_then_change)
        waiter = Waiter(client, job["id"], since=job["seq"], wait=30)
        response = waiter.result()
        assert changed.is_set()
        assert [item["ref"] for item in response.json()["items"]] == ["late"]
        # Missed, it would have found the item only at its last look, after 30 s.
        assert waiter.elapsed < 15


def test_waiting_requests_answer_when_the_application_stops(harness: Harness) -> None:
    with harness.client() as client:
        job = post_job(client, ["photo.jpg"])["job"]
        waiters = [Waiter(client, job["id"], since=job["seq"], wait=55) for _ in range(3)]
        wait_for(lambda: waits_of(client).waiting(job["id"]) == 3, what="the requests to wait")
        stopping = time.monotonic()
    assert time.monotonic() - stopping < 10
    for waiter in waiters:
        response = waiter.result(10)
        assert response.status_code == 200
        assert response.json()["items"] == []
        assert waiter.elapsed < 30


# --- Waits on its own ------------------------------------------------------------------------


def changes(items: dict[int, set[str]], deleted: set[int] | None = None) -> Changes:
    return Changes(
        items={job: frozenset(states) for job, states in items.items()},
        deleted=frozenset(deleted or ()),
    )


def run(scenario: Callable[[Waits], Awaitable[None]]) -> None:
    waits = Waits()
    try:
        asyncio.run(scenario(waits))
    finally:
        waits.stop()


def test_a_change_wakes_only_the_requests_it_concerns() -> None:
    async def scenario(waits: Waits) -> None:
        anything = waits.watch(1, None)
        ready = waits.watch(1, "ready")
        other = waits.watch(2, None)
        assert (waits.watching(), waits.watching(1)) == (3, 2)
        waits.changed(changes({1: {"building"}}))
        assert await anything.sleep(5) is True
        assert await ready.sleep(0.05) is False
        assert await other.sleep(0.05) is False
        anything.clear()
        waits.changed(changes({1: {"queued", "ready"}}))
        assert await ready.sleep(5) is True
        assert await anything.sleep(5) is True
        waits.changed(changes({}, deleted={2}))
        assert await other.sleep(5) is True
        for watch in (anything, ready, other):
            waits.forget(watch)
        assert waits.watching() == 0

    run(scenario)


def test_a_change_from_another_thread_wakes_a_request() -> None:
    async def scenario(waits: Waits) -> None:
        watch = waits.watch(1, "ready")
        thread = threading.Thread(target=waits.changed, args=(changes({1: {"ready"}}),))
        sleeping = asyncio.create_task(watch.sleep(5))
        await asyncio.sleep(0)
        assert watch.asleep and waits.waiting(1) == 1
        thread.start()
        assert await sleeping is True
        assert not watch.asleep and waits.waiting(1) == 0
        thread.join()
        waits.forget(watch)

    run(scenario)


def test_a_wake_up_before_the_sleep_is_kept() -> None:
    async def scenario(waits: Waits) -> None:
        watch = waits.watch(1, None)
        watch.clear()
        waits.changed(changes({1: {"ready"}}))
        await asyncio.sleep(0)  # one turn of the loop delivers the wake-up; nobody sleeps yet
        assert await watch.sleep(5) is True
        watch.clear()
        assert await watch.sleep(0.05) is False, "clear forgets it"
        waits.forget(watch)

    run(scenario)


def test_closing_wakes_every_request_and_later_ones_do_not_wait() -> None:
    async def scenario(waits: Waits) -> None:
        first, second = waits.watch(1, None), waits.watch(2, "ready")
        assert not first.closing
        waits.close()
        assert await first.sleep(5) and await second.sleep(5)
        assert first.closing and second.closing
        late = waits.watch(3, None)
        assert late.closing
        assert await waits.drained(0.1) is False
        for watch in (first, second, late):
            waits.forget(watch)
        assert await waits.drained(0.1) is True

    run(scenario)


# --- With a real server ----------------------------------------------------------------------


@contextlib.contextmanager
def serving(app: FastAPI) -> Iterator[tuple[int, Server, threading.Thread]]:
    """Serve ``app`` with uvicorn on a free local port, as ``python -m lrrp`` does; stop it
    at the end. Yields the port, the server and its thread."""
    config = uvicorn.Config(app, host="127.0.0.1", port=0, log_config=None, access_log=False)
    server = Server(config, app)
    thread = threading.Thread(target=server.run, name="uvicorn", daemon=True)
    thread.start()
    try:
        wait_for(lambda: server.started or not thread.is_alive(), what="the server to start")
        assert server.started, "the server did not start"
        port = server.servers[0].sockets[0].getsockname()[1]
        yield port, server, thread
    finally:
        server.should_exit = True
        thread.join(30)


def http_client(port: int, **options: Any) -> httpx2.Client:
    return httpx2.Client(
        base_url=f"http://127.0.0.1:{port}", timeout=90, trust_env=False, **options
    )


def new_job(http: httpx2.Client | Any, name: str = "photo.jpg") -> dict[str, Any]:
    items = [{"ref": "0", "root": "archive", "path": name}]
    response = http.post("/api/v1/jobs", json={"items": items})
    assert response.status_code == 201, response.text
    return response.json()["job"]


async def until(check: Callable[[], bool], timeout: float = 30.0, what: str = "") -> None:
    deadline = time.monotonic() + timeout
    while not check():
        if time.monotonic() > deadline:
            raise AssertionError(f"timed out waiting for {what}")
        await asyncio.sleep(0.05)


def test_a_hundred_waiting_requests_leave_the_other_calls_alone(harness: Harness) -> None:
    app = harness.app()
    count = 100
    with serving(app) as (port, _server, _thread):
        waits: Waits = app.state.services.waits
        with http_client(port) as http:
            jobs = [new_job(http, f"{n}.jpg") for n in range(count)]

        async def scenario() -> None:
            limits = httpx2.Limits(max_connections=count + 20, max_keepalive_connections=count)
            async with httpx2.AsyncClient(
                base_url=f"http://127.0.0.1:{port}", limits=limits, timeout=90, trust_env=False
            ) as http:
                started = time.monotonic()
                waiting = [
                    asyncio.create_task(
                        http.get(items_url(job["id"]), params={"since": job["seq"], "wait": 50})
                    )
                    for job in jobs
                ]
                await until(lambda: waits.waiting() == count, what="every request to wait")
                # Each waits without a thread: the calls that run in worker threads still answer.
                for path in (
                    "/healthz",
                    "/api/v1/info",
                    "/api/v1/status",
                    "/api/v1/jobs",
                    f"/api/v1/jobs/{jobs[0]['id']}",
                    items_url(jobs[0]["id"]),
                ):
                    sent = time.monotonic()
                    response = await http.get(path)
                    assert response.status_code == 200, (path, response.text)
                    assert time.monotonic() - sent < 5, path
                items = [{"ref": "0", "root": "archive", "path": "more.jpg"}]
                response = await http.post("/api/v1/jobs", json={"items": items})
                assert response.status_code == 201
                looking = [t for t in threading.enumerate() if t.name.startswith("lrrp-wait")]
                assert len(looking) <= LOOK_THREADS
                assert not any(task.done() for task in waiting)
                assert waits.waiting() == count

                # Then each job gets an item, and each request answers with it.
                for job in jobs:
                    items = [{"ref": "late", "root": "archive", "path": "late.jpg"}]
                    response = await http.post(f"{items_url(job['id'])}", json={"items": items})
                    assert response.status_code == 200, response.text
                answers = await asyncio.gather(*waiting)
                for answer in answers:
                    assert answer.status_code == 200, answer.text
                    assert [item["ref"] for item in answer.json()["items"]] == ["late"]
                assert time.monotonic() - started < 45, "they answered before their time was up"

        asyncio.run(scenario())
        assert waits.watching() == 0


def test_the_server_stops_at_once_with_waiting_requests(harness: Harness) -> None:
    app = harness.app()
    with serving(app) as (port, server, thread):
        waits: Waits = app.state.services.waits
        with http_client(port) as http:
            job = new_job(http)
        answers: list[Any] = []

        def send() -> None:
            with http_client(port) as http:
                params = {"since": job["seq"], "wait": 55}
                answers.append(http.get(items_url(job["id"]), params=params))

        waiters = [threading.Thread(target=send) for _ in range(5)]
        for waiter in waiters:
            waiter.start()
        wait_for(lambda: waits.waiting(job["id"]) == 5, what="the requests to wait")
        stopping = time.monotonic()
        server.should_exit = True  # what uvicorn's handler of SIGTERM and SIGINT does
        thread.join(30)
        assert not thread.is_alive()
        assert time.monotonic() - stopping < 10, "uvicorn alone would wait out the 55 s"
        for waiter in waiters:
            waiter.join(10)
        assert [answer.status_code for answer in answers] == [200] * 5
        assert all(answer.json()["items"] == [] for answer in answers)


def test_a_waiting_request_ends_when_its_client_goes_away(harness: Harness) -> None:
    app = harness.app()
    with serving(app) as (port, _server, _thread):
        waits: Waits = app.state.services.waits
        with http_client(port) as http:
            job = new_job(http)
            connection = socket.create_connection(("127.0.0.1", port))
            request = (
                f"GET {items_url(job['id'])}?since={job['seq']}&wait=55 HTTP/1.1\r\n"
                "Host: 127.0.0.1\r\n\r\n"
            )
            connection.sendall(request.encode("ascii"))
            wait_for(lambda: waits.waiting(job["id"]) == 1, what="the request to wait")
            connection.close()
            wait_for(lambda: waits.watching(job["id"]) == 0, timeout=10, what="it to end")
            # The server is fine: another request waits and answers as usual.
            started = time.monotonic()
            page = http.get(items_url(job["id"]), params={"since": job["seq"], "wait": 0.5})
            assert page.status_code == 200
            assert page.json()["items"] == []
            assert time.monotonic() - started >= 0.45
