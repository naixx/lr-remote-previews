"""Requests that wait for a change of a job: ``wait`` of ``GET /api/v1/jobs/{id}/items``.

A waiting request holds no thread while it waits. Its handler is a coroutine on the event loop
that sleeps on an ``asyncio.Event`` of its own (``Watch``). Only its looks at the database run in
a thread, in a small pool of their own (``LOOK_THREADS``), so a hundred waiting requests neither
hold a hundred threads nor take the worker threads that the other endpoints run in.

The store reports every committed transaction that changed items or deleted jobs
(``Store(on_change=...)``), from the thread that made it: the scheduler's or an API worker's.
``Waits.changed`` sets the events of the requests that watch those jobs and care about the change
(a request that asks for ``state=ready`` is not woken when items become ``building``), through
``loop.call_soon_threadsafe``. A woken request looks again and answers when the look finds
something; otherwise it sleeps again. The look decides, so a needless wake-up costs one look and
nothing else.

No change is missed between a look and the sleep after it: a request registers before its first
look and clears its event before every look, and the store reports a change only after its
commit. So a change that a look did not see was committed after the look began, its report sets
the event after it was cleared, and the sleep that follows returns at once.

When the server stops, ``close`` wakes every waiting request; each answers at once with what
there is (an ordinary answer, as when its time is up), and a request that arrives later does not
wait. uvicorn lets open requests finish before it tells the application that it stops, so
``lrrp.__main__`` calls ``close`` when the shutdown begins (``app.end_waits``); the application's
lifespan calls it too, and gives the requests a moment to answer before the database is closed.
"""

import asyncio
import contextlib
import threading
import time
from collections.abc import Callable, Collection, Iterable
from concurrent.futures import ThreadPoolExecutor
from typing import TypeVar

from lrrp.store import Changes

LOOK_THREADS = 4
"""Threads for the looks of all waiting requests together. The looks are short and queue for the
store's lock anyway, so more threads would not make them faster."""

T = TypeVar("T")


class Watch:
    """One waiting request: it wants the items of ``job_id`` (only those in ``state``, when
    given). Used on the event loop's thread, except ``closing``, which ``Waits`` sets."""

    def __init__(
        self, job_id: int, state: str | None, loop: asyncio.AbstractEventLoop, closing: bool
    ) -> None:
        self.job_id = job_id
        self.state = state
        self.closing = closing
        """The server is stopping: answer now."""
        self.client_gone = False
        """The client closed its connection: nobody reads the answer."""
        self.asleep = False
        self.loop = loop
        self._event = asyncio.Event()

    def cares(self, states: Collection[str]) -> bool:
        """Whether items put in these states can be what the request asks for."""
        return self.state is None or self.state in states

    def clear(self) -> None:
        """Forget earlier wake-ups; called before each look."""
        self._event.clear()

    def wake(self) -> None:
        self._event.set()

    async def sleep(self, seconds: float) -> bool:
        """Until woken, or until ``seconds`` have passed; whether it was woken."""
        self.asleep = True
        try:
            async with asyncio.timeout(seconds):
                await self._event.wait()
        except TimeoutError:
            return False
        finally:
            self.asleep = False
        return True


class Waits:
    def __init__(self, look_threads: int = LOOK_THREADS) -> None:
        self._lock = threading.Lock()
        self._watches: dict[int, set[Watch]] = {}
        self._closed = False
        # Threads are started on the first look, not before.
        self._pool = ThreadPoolExecutor(look_threads, thread_name_prefix="lrrp-wait")

    def watch(self, job_id: int, state: str | None) -> Watch:
        """Register a request before its first look; on the event loop. Once the server is
        stopping, the watch is ``closing`` from the start."""
        loop = asyncio.get_running_loop()
        with self._lock:
            watch = Watch(job_id, state, loop, closing=self._closed)
            self._watches.setdefault(job_id, set()).add(watch)
        return watch

    def forget(self, watch: Watch) -> None:
        """The request has answered (or is gone)."""
        with self._lock:
            watches = self._watches.get(watch.job_id)
            if watches is not None:
                watches.discard(watch)
                if not watches:
                    del self._watches[watch.job_id]

    async def look(self, function: Callable[[], T]) -> T:
        """Run a look at the database in one of the pool's threads."""
        return await asyncio.get_running_loop().run_in_executor(self._pool, function)

    def changed(self, changes: Changes) -> None:
        """The store committed these changes (from any thread): wake the requests they concern.
        A deleted job wakes all of its requests (the look answers ``404``)."""
        with self._lock:
            woken = [
                watch
                for job_id, states in changes.items.items()
                for watch in self._watches.get(job_id, ())
                if watch.cares(states)
            ]
            woken.extend(
                watch for job_id in changes.deleted for watch in self._watches.get(job_id, ())
            )
        _wake(woken)

    def close(self) -> None:
        """The server is stopping: every waiting request answers now, later ones do not wait.
        From any thread; doing it again changes nothing."""
        with self._lock:
            self._closed = True
            woken = [watch for watches in self._watches.values() for watch in watches]
            for watch in woken:
                watch.closing = True
        _wake(woken)

    def watching(self, job_id: int | None = None) -> int:
        """How many requests (for this job) are registered: waiting, or looking."""
        with self._lock:
            if job_id is not None:
                return len(self._watches.get(job_id, ()))
            return sum(len(watches) for watches in self._watches.values())

    def waiting(self, job_id: int | None = None) -> int:
        """How many requests (for this job) are asleep until a change. For the tests, which
        must know that a request is past its look before they change something."""
        with self._lock:
            groups = (
                [self._watches.get(job_id, set())]
                if job_id is not None
                else list(self._watches.values())
            )
            return sum(watch.asleep for watches in groups for watch in watches)

    async def drained(self, timeout: float) -> bool:
        """Wait (on the event loop) until no request is registered, at most ``timeout`` seconds;
        whether none is left."""
        deadline = time.monotonic() + timeout
        while self.watching():
            if time.monotonic() >= deadline:
                return False
            await asyncio.sleep(0.02)
        return True

    def stop(self) -> None:
        """After the last request: close, and end the look threads."""
        self.close()
        self._pool.shutdown(wait=True, cancel_futures=True)


def _wake(watches: Iterable[Watch]) -> None:
    """Wake these watches on their event loops: one call into each loop."""
    by_loop: dict[asyncio.AbstractEventLoop, list[Watch]] = {}
    for watch in watches:
        by_loop.setdefault(watch.loop, []).append(watch)
    for loop, group in by_loop.items():
        # A loop that is closed has nobody waiting on it any more.
        with contextlib.suppress(RuntimeError):
            loop.call_soon_threadsafe(_wake_all, group)


def _wake_all(watches: Iterable[Watch]) -> None:
    for watch in watches:
        watch.wake()
