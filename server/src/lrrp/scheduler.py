"""The background scheduler: takes queued files in waves, runs the converter, publishes results.

One thread for the whole server, so the event loop never waits for the converter. A wave:

1. take up to ``workers * batch_size`` distinct files from the head of the queue (two jobs that
   ask for the same file share one build): first the files of ``normal`` jobs, then those of
   ``background`` jobs (``Store.queued_candidates``); a file already in the cache becomes ready
   at once. A wave that runs is never interrupted: a ``normal`` job that arrives meanwhile is
   at the head of the next one;
2. make sure the converter can run (``Runner.prepare``: display, warm-up of a fresh prefix);
3. check every source again (changed or gone: ``source_changed``), plan the batches, mark the
   items ``building`` and run the batches together;
4. publish what succeeded, retry once what failed as a batch, one file per process, publish that.

Items of a wave that a shutdown interrupts stay ``building``; the next start puts them back into
the queue (``Store.recover``).

Before every wave the scheduler reads the runtime settings (``lrrp.runtime.Controls``): paused,
or outside the working hours, it starts no wave (a wave that runs finishes); a changed number of
processes or batch size applies from the next wave on. A wave runs while holding a lock that the
converter self-test takes too (``hold``), so the two never run converters at the same time.

The same thread deletes expired jobs: at start and then once a day, between waves.
"""

import logging
import threading
import time
from collections.abc import Callable, Iterator, Mapping, Sequence
from contextlib import contextmanager

from lrrp import sources
from lrrp.cache import Cache
from lrrp.runner import BatchFile, FileResult, Runner, plan_wave
from lrrp.runtime import Controls, RuntimeSettings
from lrrp.settings import DEFAULT_JOB_RETENTION_DAYS, Root
from lrrp.store import Candidate, Store

log = logging.getLogger(__name__)

IDLE_WAIT = 10.0
"""Seconds the scheduler sleeps when the queue is empty, or no wave may start (paused, outside
the working hours, a self-test running), unless woken earlier."""

DAY = 24 * 3600.0

EXPIRY_INTERVAL = DAY
"""Seconds between two clean-ups of expired jobs."""


class Scheduler:
    def __init__(
        self,
        store: Store,
        cache: Cache,
        runner: Runner,
        roots: Sequence[Root],
        workers: int,
        batch_size: int,
        clock: Callable[[], float] = time.time,
        job_retention_days: int = DEFAULT_JOB_RETENTION_DAYS,
        controls: Controls | None = None,
    ) -> None:
        """``controls`` gives the settings of every wave; without it, ``workers`` and
        ``batch_size`` are used for all of them."""
        self._store = store
        self._cache = cache
        self._runner = runner
        self._roots: Mapping[str, Root] = {root.id: root for root in roots}
        self.controls = controls or Controls(
            RuntimeSettings(workers=workers, batch_size=batch_size), cpu_count=1
        )
        self._clock = clock
        self._job_retention = job_retention_days * DAY
        self._next_expiry = float("-inf")
        self._wake = threading.Event()
        self._stopping = threading.Event()
        self._wave_lock = threading.Lock()
        self._in_wave = False
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        """Delete expired jobs, then start the thread."""
        self.expire_jobs_if_due()
        self._thread = threading.Thread(target=self._loop, name="lrrp-scheduler", daemon=True)
        self._thread.start()

    def expire_jobs_if_due(self) -> int:
        """Delete the jobs that left ``active`` more than the retention time ago, if the last
        clean-up was ``EXPIRY_INTERVAL`` or longer ago. Returns the number of jobs deleted."""
        now = self._clock()
        if now < self._next_expiry:
            return 0
        self._next_expiry = now + EXPIRY_INTERVAL
        deleted = self._store.delete_expired_jobs(now - self._job_retention)
        if deleted:
            days = self._job_retention / DAY
            log.info("deleted %d job(s) that finished more than %g days ago", deleted, days)
        return deleted

    def wake(self) -> None:
        """Something was queued, or a setting changed: look at the queue now."""
        self._wake.set()

    @property
    def in_wave(self) -> bool:
        """Whether the scheduler is working on a wave now."""
        return self._in_wave

    @contextmanager
    def hold(self) -> Iterator[None]:
        """Wait for a running wave to finish, and start none until the block ends."""
        with self._wave_lock:
            yield
        self.wake()

    def stop(self, timeout: float = 30.0) -> None:
        """Kill running converters, finish the current step and end the thread."""
        self._stopping.set()
        self._wake.set()
        self._runner.abort()
        if self._thread is not None:
            self._thread.join(timeout)
            if self._thread.is_alive():
                log.error("the scheduler did not stop within %g s", timeout)

    def _loop(self) -> None:
        while not self._stopping.is_set():
            self._wake.clear()
            try:
                self.expire_jobs_if_due()
            except Exception:
                log.exception("cannot delete expired jobs; trying again in a day")
            if self.controls.gate() != "open" or not self._wave_lock.acquire(blocking=False):
                self._wake.wait(IDLE_WAIT)
                continue
            failed = False
            try:
                self._in_wave = True
                worked = self.run_wave()
            except Exception:
                log.exception("the scheduler failed; trying again shortly")
                failed = True
                # Only this thread makes items building, and it is between waves now.
                try:
                    self._store.recover(self._clock())
                except Exception:
                    log.exception("cannot put the building items back into the queue")
            finally:
                self._in_wave = False
                self._wave_lock.release()
            if failed:
                self._stopping.wait(5.0)
            elif not worked:
                self._wake.wait(IDLE_WAIT)

    def run_wave(self) -> bool:
        """Run one wave. Returns False when the queue was empty."""
        settings = self.controls.current()
        workers = self.controls.effective_workers(settings)
        batch_size = settings.batch_size
        candidates = self._store.queued_candidates(workers * batch_size)
        if not candidates:
            return False
        entries = self._store.cache_entries(c.key for c in candidates)
        waiting: list[Candidate] = []
        for candidate in candidates:
            entry = entries.get(candidate.key)
            if entry is not None and self._cache.has(candidate.key, entry.size):
                self._store.complete(candidate.key, None, self._clock())
            else:
                waiting.append(candidate)
        if not waiting:
            return True

        problem = self._runner.prepare()
        if self._stopping.is_set():
            return True
        if problem is not None:
            keys = [c.key for c in waiting]
            self._store.mark_building(keys, self._clock())
            for key in keys:
                # The server's failure, not the file's: the automatic scan may queue it again.
                self._store.fail(key, "converter_failed", problem, self._clock(), remember=False)
            return True

        files, changed = self._check_sources(waiting)
        batches, _later = plan_wave(files, workers, batch_size)
        planned = [file for batch in batches for file in batch]
        self._store.mark_building([f.key for f in planned] + changed, self._clock())
        for key in changed:
            self._fail_changed(key)
        if not batches:
            return True

        started = time.monotonic()
        results = self._runner.run(batches, final=False)
        if self._stopping.is_set():
            return True
        retry = self._publish(results)
        built = sum(result.ok for result in results)
        log.info(
            "wave: %d file(s) in %d converter process(es), %d built, %d to retry, %.1f s",
            len(planned),
            len(batches),
            built,
            len(retry),
            time.monotonic() - started,
        )
        while retry and not self._stopping.is_set():
            files, changed = self._check_files(retry)
            for key in changed:
                self._fail_changed(key)
            batches, retry = plan_wave(files, workers, 1)
            if not batches:
                break
            results = self._runner.run(batches, final=True)
            if self._stopping.is_set():
                return True
            self._publish(results)
        return True

    def _check_sources(self, candidates: Sequence[Candidate]) -> tuple[list[BatchFile], list[str]]:
        """The files whose source is unchanged since the request, and the keys of the others."""
        files: list[BatchFile] = []
        changed: list[str] = []
        for candidate in candidates:
            requested = (candidate.size, candidate.mtime_ns)
            root = self._roots.get(candidate.root)
            file = sources.locate(root, candidate.path) if root is not None else None
            if file is None or sources.identity(file) != requested:
                changed.append(candidate.key)
                continue
            name = candidate.path.rsplit("/", 1)[-1]
            files.append(BatchFile(key=candidate.key, file=file, name=name, identity=requested))
        return files, changed

    @staticmethod
    def _check_files(files: Sequence[BatchFile]) -> tuple[list[BatchFile], list[str]]:
        unchanged: list[BatchFile] = []
        changed: list[str] = []
        for file in files:
            if sources.identity(file.file) == file.identity:
                unchanged.append(file)
            else:
                changed.append(file.key)
        return unchanged, changed

    def _publish(self, results: Sequence[FileResult]) -> list[BatchFile]:
        """Store the results; return the files to run again on their own."""
        retry: list[BatchFile] = []
        try:
            for result in results:
                key = result.file.key
                if result.retry:
                    retry.append(result.file)
                elif result.ok and result.output is not None and result.tags is not None:
                    # The source must not have changed while the converter read it.
                    if sources.identity(result.file.file) != result.file.identity:
                        self._fail_changed(key)
                        continue
                    try:
                        entry = self._cache.store(key, result.output, result.tags, self._clock())
                    except OSError as exc:
                        log.error("cannot store the DNG for %s in the cache: %s", result.file, exc)
                        self._store.fail(
                            key,
                            "converter_failed",
                            "The server could not store the DNG in its cache",
                            self._clock(),
                            remember=False,
                        )
                        continue
                    self._store.complete(key, entry, self._clock())
                else:
                    self._store.fail(
                        key,
                        result.error or "converter_failed",
                        result.message or "Adobe DNG Converter failed",
                        self._clock(),
                    )
        finally:
            self._runner.discard(results)
        return retry

    def _fail_changed(self, key: str) -> None:
        # Not remembered for the automatic scan: the file as it is now has another key anyway.
        self._store.fail(
            key,
            "source_changed",
            "The file changed or disappeared after it was requested",
            self._clock(),
            remember=False,
        )
