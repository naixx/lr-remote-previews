"""The automatic scan (``docs/protocol.md``, «The automatic scan»).

Off unless ``autoScan.enabled`` is set (``lrrp.runtime``). One thread scans the roots of the
setting ``intervalMinutes`` after the last scan finished (at once when none has run yet), and
the roots ``POST /api/v1/autoscan/run`` names whenever it asks. A scan queues every camera raw
file that

- has no entry in the cache index (the DNG files are not looked at; the daily clean-up drops
  index entries whose file is missing, ``lrrp.cleanup``),
- is not queued or building in any job,
- was last modified at least ``settleMinutes`` ago, so that a file still being copied is left
  alone,
- did not fail in an earlier automatic job as it is now (``Store.fail`` remembers such a file by
  its cache key, which changes when the file changes).

At most ``maxFilesPerRun`` files per run, oldest folders first: the age of a folder is the
modification time of its oldest raw file, so a folder that gets a sidecar file or a late addition
keeps its place. The rest wait for the next run. The files go into jobs of at most
``maxItemsPerJob`` items, per root, with client ``auto-scan``, priority ``background``, no
``clientId`` and the label ``Automatic scan: <root id>``.

What it costs, for roots with hundreds of thousands of files: the walk is ``lrrp.folders.walk``
(symbolic links are not followed, names that start with a dot are skipped), one listing per
folder and one ``stat`` per raw file; the database is asked about ``BATCH_FILES`` files at a time
in chunks (never once per file), and its lock is held only for those short queries and for the
creation of each job. Only the files chosen so far are kept: at most ``maxFilesPerRun`` plus the
files of one folder, whatever the size of the root. The thread looks between folders whether the
server is stopping.

Scanning does not depend on ``paused`` or the working hours; building what it queued does. A root
that is unavailable is skipped with a log line. While the converter is not installed no
periodic scan runs (nothing could be built); it is tried again an interval later.
"""

import heapq
import logging
import threading
import time
from collections.abc import Callable, Iterator, Sequence
from dataclasses import dataclass, field
from typing import Any

from lrrp import converter, folders, sources
from lrrp.runtime import AutoScan, Controls
from lrrp.settings import Root
from lrrp.store import AUTO_SCAN_CLIENT, NewItem, NewJob, Store

log = logging.getLogger(__name__)

POLL = 10.0
"""Seconds between two looks at the clock while no scan is due, unless woken earlier."""

BATCH_FILES = 5000
"""Raw files taken from the walk before the database is asked about them."""

STATE_NAME = "autoScan"
"""The record of the last scan in the database (``Store.state``)."""

LABEL = "Automatic scan: {root}"


class ScanBusy(Exception):
    """A scan is running."""


class _Stopping(Exception):
    """The server is stopping; the scan ends without queueing anything."""


@dataclass(frozen=True)
class ScanStatus:
    running: bool
    last_run: float | None
    """When the last scan finished; None before the first."""
    last_queued: int
    next_run: float | None
    """When the next periodic scan is due; None while the automatic scan is off."""


@dataclass
class _Counts:
    """What a scan found in one root, for the log."""

    raw: int = 0
    built: int = 0
    pending: int = 0
    failed: int = 0
    unsettled: int = 0
    wanted: int = 0


@dataclass(frozen=True)
class _Folder:
    """The files of one folder that the scan would queue, with their cache keys."""

    order: tuple[int, int, str, str]
    """Age (ns), position of the root in the scan, the path folded and as it is."""
    root: str
    files: list[tuple[folders.RawFile, str]] = field(compare=False)

    def __lt__(self, other: "_Folder") -> bool:
        # Reversed, so that the top of a heap is the folder that comes last.
        return self.order > other.order


class _Selection:
    """The first ``limit`` files in folder order out of folders offered in any order, keeping no
    more than ``limit`` files plus those of one folder."""

    def __init__(self, limit: int) -> None:
        self._limit = limit
        self._heap: list[_Folder] = []
        self._kept = 0
        self.offered = 0
        """Files offered in all."""

    def offer(self, folder: _Folder) -> None:
        self.offered += len(folder.files)
        heapq.heappush(self._heap, folder)
        self._kept += len(folder.files)
        # The last folder is not needed while the others reach the limit without it.
        while self._kept - len(self._heap[0].files) >= self._limit:
            self._kept -= len(heapq.heappop(self._heap).files)

    def chosen(self) -> list[tuple[str, folders.RawFile, str]]:
        """(root, file, cache key), oldest folder first."""
        files: list[tuple[str, folders.RawFile, str]] = []
        for folder in sorted(self._heap, key=lambda folder: folder.order):
            for file, key in folder.files:
                if len(files) == self._limit:
                    return files
                files.append((folder.root, file, key))
        return files


class AutoScanner:
    def __init__(
        self,
        store: Store,
        roots: Sequence[Root],
        controls: Controls,
        *,
        converter_installed: Callable[[], bool],
        on_queued: Callable[[], None],
        max_items_per_job: int,
        clock: Callable[[], float] = time.time,
    ) -> None:
        """``on_queued`` is called after a scan queued files (to wake the scheduler)."""
        self._store = store
        self._roots = {root.id: root for root in roots}
        self._controls = controls
        self._converter_installed = converter_installed
        self._on_queued = on_queued
        self._per_job = max_items_per_job
        self._clock = clock
        self._lock = threading.Lock()
        self._wake = threading.Event()
        self._stopping = threading.Event()
        self._thread: threading.Thread | None = None
        self._running = False
        self._requested: list[str] | None = None
        self._started: float | None = None
        self._retry_at: float | None = None
        saved = store.state(STATE_NAME)
        saved = saved if isinstance(saved, dict) else {}
        self._last_run = _number(saved.get("lastRun"))
        last_queued = saved.get("lastQueued")
        self._last_queued = last_queued if isinstance(last_queued, int) else 0
        self.checks = 0
        """How many times the thread has looked whether a scan is due."""

    def start(self) -> None:
        self._thread = threading.Thread(target=self._loop, name="lrrp-autoscan", daemon=True)
        self._thread.start()

    def stop(self, timeout: float = 30.0) -> None:
        """End the thread; a scan that runs stops at the next folder and queues nothing."""
        self._stopping.set()
        self._wake.set()
        if self._thread is not None:
            self._thread.join(timeout)
            if self._thread.is_alive():
                log.error("the automatic scan did not stop within %g s", timeout)

    def wake(self) -> None:
        """A setting changed: look whether a scan is due now."""
        self._wake.set()

    def request(self, roots: Sequence[str]) -> None:
        """Start a scan of these roots now, in the scan's thread. Raises ``ScanBusy``."""
        with self._lock:
            if self._running:
                raise ScanBusy
            self._running = True
            self._requested = list(roots)
            self._started = self._clock()
        self._wake.set()

    def status(self) -> ScanStatus:
        settings = self._controls.current().auto_scan
        with self._lock:
            next_run = None
            if settings.enabled:
                if self._running and self._started is not None:
                    # Counted from the end of this scan; the earliest that can be.
                    next_run = self._started + settings.interval_minutes * 60
                else:
                    next_run = self._due(settings)
            return ScanStatus(
                running=self._running,
                last_run=self._last_run,
                last_queued=self._last_queued,
                next_run=next_run,
            )

    def _due(self, settings: AutoScan) -> float:
        """When the next periodic scan is due. Call with the lock held."""
        if self._last_run is None:
            due = self._clock()
        else:
            due = self._last_run + settings.interval_minutes * 60
        if self._retry_at is not None:
            due = max(due, self._retry_at)
        return due

    # --- The thread -----------------------------------------------------------------------------

    def _loop(self) -> None:
        while not self._stopping.is_set():
            self._wake.clear()
            roots = self._take()
            self.checks += 1
            if roots is None:
                self._wake.wait(POLL)
                continue
            self._run(roots)

    def _take(self) -> list[str] | None:
        """The roots to scan now (a scan asked for, or a periodic one that is due), or None."""
        settings = self._controls.current().auto_scan
        with self._lock:
            if self._requested is not None:
                roots, self._requested = self._requested, None
                return roots
            if self._running or not settings.enabled:
                return None
            now = self._clock()
            if now < self._due(settings):
                return None
            if not self._converter_installed():
                log.warning(
                    "automatic scan: Adobe DNG Converter is not installed, so nothing could be "
                    "built; trying again in %d minute(s)",
                    settings.interval_minutes,
                )
                self._retry_at = now + settings.interval_minutes * 60
                return None
            self._running = True
            self._started = now
            return list(settings.roots)

    def _run(self, roots: list[str]) -> None:
        queued: int | None = None
        try:
            queued = self.scan(roots)
        except _Stopping:
            log.info("automatic scan: stopped because the server is stopping")
        except Exception:
            log.exception("the automatic scan failed; trying again in an interval")
        now = self._clock()
        if queued is not None:
            try:
                self._store.save_state(STATE_NAME, {"lastRun": now, "lastQueued": queued})
            except Exception:
                log.exception("cannot record the automatic scan in the database")
        with self._lock:
            self._running = False
            self._started = None
            if queued is not None:
                self._last_run, self._last_queued = now, queued
                self._retry_at = None
            else:
                interval = self._controls.current().auto_scan.interval_minutes
                self._retry_at = now + interval * 60

    # --- One scan -------------------------------------------------------------------------------

    def scan(self, roots: Sequence[str]) -> int:
        """Scan these roots now, in the calling thread; return the number of files queued."""
        settings = self._controls.current().auto_scan
        started = time.monotonic()
        settled_ns = int((self._clock() - settings.settle_minutes * 60) * 1e9)
        recipe = converter.recipe()
        resolver = sources.Resolver(self._roots)
        selection = _Selection(settings.max_files_per_run)
        for position, root_id in enumerate(roots):
            found = resolver.resolve_folder(root_id, "")
            if isinstance(found, sources.Rejection):
                log.warning("automatic scan: skipping the root %r: %s", root_id, found.message)
                continue
            counts = _Counts()
            try:
                for batch in self._batches(found):
                    self._choose(root_id, position, batch, settled_ns, recipe, selection, counts)
            except folders.FolderUnreadable as exc:
                log.warning(
                    "automatic scan: skipping the root %r: cannot list it (%s)", root_id, exc
                )
                continue
            log.info(
                "automatic scan of %r: %d raw file(s): %d built, %d queued or building, "
                "%d failed before and unchanged, %d modified less than %d minute(s) ago, "
                "%d to build",
                root_id,
                counts.raw,
                counts.built,
                counts.pending,
                counts.failed,
                counts.unsettled,
                settings.settle_minutes,
                counts.wanted,
            )
        chosen = selection.chosen()
        jobs = self._queue(chosen)
        left = selection.offered - len(chosen)
        log.info(
            "automatic scan: queued %d file(s) in %d job(s)%s, %.1f s",
            len(chosen),
            jobs,
            f"; {left} left for the next run" if left else "",
            time.monotonic() - started,
        )
        return len(chosen)

    def _batches(self, top: sources.Folder) -> Iterator[list[tuple[str, list[folders.RawFile]]]]:
        """The folders of a root that have raw files, about ``BATCH_FILES`` files at a time."""
        batch: list[tuple[str, list[folders.RawFile]]] = []
        size = 0
        for path, listing in folders.walk(top):
            if self._stopping.is_set():
                raise _Stopping
            if not listing.raw:
                continue
            batch.append((path, listing.raw))
            size += len(listing.raw)
            if size >= BATCH_FILES:
                yield batch
                batch, size = [], 0
        if batch:
            yield batch

    def _choose(
        self,
        root: str,
        position: int,
        batch: Sequence[tuple[str, list[folders.RawFile]]],
        settled_ns: int,
        recipe: str,
        selection: _Selection,
        counts: _Counts,
    ) -> None:
        """Offer the files of these folders that the scan would queue."""
        settled: list[tuple[int, folders.RawFile, str]] = []
        for index, (_path, files) in enumerate(batch):
            counts.raw += len(files)
            for file in files:
                if file.mtime_ns > settled_ns:
                    counts.unsettled += 1
                    continue
                key = sources.cache_key(root, file.path, file.size, file.mtime_ns, recipe)
                settled.append((index, file, key))
        built = self._store.cached_keys(key for _, _, key in settled)
        rest = [entry for entry in settled if entry[2] not in built]
        pending = self._store.pending_keys(key for _, _, key in rest)
        rest = [entry for entry in rest if entry[2] not in pending]
        failed = self._store.failed_scan_keys(key for _, _, key in rest)
        counts.built += len(built)
        counts.pending += len(pending)
        counts.failed += len(failed)
        wanted: dict[int, list[tuple[folders.RawFile, str]]] = {}
        for index, file, key in rest:
            if key not in failed:
                wanted.setdefault(index, []).append((file, key))
                counts.wanted += 1
        for index, files in wanted.items():
            path, everything = batch[index]
            age = min(file.mtime_ns for file in everything)
            selection.offer(_Folder((age, position, path.casefold(), path), root, files))

    def _queue(self, chosen: Sequence[tuple[str, folders.RawFile, str]]) -> int:
        """Put the chosen files into jobs; return how many jobs were made."""
        by_root: dict[str, list[tuple[folders.RawFile, str]]] = {}
        for root, file, key in chosen:
            by_root.setdefault(root, []).append((file, key))
        jobs = 0
        for root, files in by_root.items():
            items = [
                NewItem(
                    ref=str(index),
                    root=root,
                    path=file.path,
                    state="queued",
                    cache_key=key,
                    size=file.size,
                    mtime_ns=file.mtime_ns,
                )
                for index, (file, key) in enumerate(files, start=1)
            ]
            for start in range(0, len(items), self._per_job):
                # One transaction per job, so that the lock is never held for long.
                job = NewJob(
                    client=AUTO_SCAN_CLIENT,
                    label=LABEL.format(root=root),
                    items=items[start : start + self._per_job],
                    priority="background",
                )
                self._store.create_jobs([job], self._clock())
                jobs += 1
        if jobs:
            self._on_queued()
        return jobs


def _number(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, int | float):
        return None
    return float(value)
