"""The cache clean-up (``docs/protocol.md``, «The cache clean-up»).

A clean-up removes, in this order:

1. DNGs whose original is gone or has changed (another size or modification time). The original
   is the file the entry was built from, as the cache index records it. An entry of a server
   before 0.5.0 whose jobs had expired does not know its original and is left to the other
   steps. An original is not treated as gone when its root is unavailable, no longer configured,
   or an empty folder (an unmounted volume often leaves an empty mount point), nor when the server
   cannot ``stat`` it for another reason than its absence;
2. DNGs not used for ``cache.maxAgeDays`` days (used: built, found by a job or a lookup,
   downloaded; recorded at most once a day, ``lrrp.store``);
3. the least recently used DNGs until the index adds up to no more than ``cache.maxBytes``.

Steps 2 and 3 are skipped while their limit is null. A DNG that an item of an active job points to
is never removed: ``Store.remove_cache_entries`` checks that in the transaction that deletes the
file and the index row. The pass of step 1 also drops index entries whose DNG file is missing;
they are not counted (no DNG is removed), and dropping them keeps the automatic scan, which trusts
the index, right.

``bytesFreed`` is the size the index recorded for the DNGs removed, which is what
``status.cache.bytes`` goes down by. The cost: one ``stat`` per entry that knows its original,
one listing per cache folder (256), the index read in pages, and the lock held for one page of
removals at a time.

The server runs a clean-up once a day: a day after the last one (one asked for through the API
counts), or, with no record of one, a day after it first started without one.
``POST /api/v1/cache/clean`` runs one in the request, so the answer waits for it; a dry run only
counts.
"""

import logging
import os
import stat
import threading
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from lrrp.cache import Cache
from lrrp.runtime import CacheLimits, Controls
from lrrp.settings import Root
from lrrp.store import CacheRow, Store

log = logging.getLogger(__name__)

DAY = 24 * 3600.0

POLL = 60.0
"""Seconds between two looks at the clock, unless woken earlier."""

PAGE = 500
"""Index entries read, and removed under the lock, at a time."""

STATE_NAME = "cacheCleanUp"
"""The record of when the next daily clean-up is due (``Store.state``)."""


class CleanBusy(Exception):
    """A clean-up is running."""


@dataclass(frozen=True)
class CleanResult:
    dry_run: bool
    original_gone: int = 0
    expired: int = 0
    over_limit: int = 0
    bytes_freed: int = 0


class CacheCleaner:
    def __init__(
        self,
        store: Store,
        cache: Cache,
        roots: Sequence[Root],
        controls: Controls,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._store = store
        self._cache = cache
        self._roots = {root.id: root for root in roots}
        self._controls = controls
        self._clock = clock
        self._lock = threading.Lock()
        self._wake = threading.Event()
        self._stopping = threading.Event()
        self._thread: threading.Thread | None = None
        self._next_run = float("inf")
        self.checks = 0
        """How many times the thread has looked whether the daily clean-up is due."""

    def start(self) -> None:
        """Read when the next daily clean-up is due (a day from now without a record), then start
        the thread."""
        saved = self._store.state(STATE_NAME)
        due = _number(saved.get("due")) if isinstance(saved, dict) else None
        if due is None:
            due = self._clock() + DAY
            self._store.save_state(STATE_NAME, {"due": due})
        self._next_run = due
        self._thread = threading.Thread(target=self._loop, name="lrrp-cleanup", daemon=True)
        self._thread.start()

    def stop(self, timeout: float = 30.0) -> None:
        """End the thread; a clean-up that runs stops after its current page."""
        self._stopping.set()
        self._wake.set()
        if self._thread is not None:
            self._thread.join(timeout)
            if self._thread.is_alive():
                log.error("the cache clean-up did not stop within %g s", timeout)

    def wake(self) -> None:
        self._wake.set()

    @property
    def next_run(self) -> float:
        """When the next daily clean-up is due."""
        return self._next_run

    def _loop(self) -> None:
        while not self._stopping.is_set():
            self._wake.clear()
            if self._clock() >= self._next_run:
                try:
                    self.clean()
                except CleanBusy:
                    pass  # One asked for through the API runs; it moves the next one.
                except Exception:
                    log.exception("the daily cache clean-up failed; trying again in a day")
            self.checks += 1
            self._wake.wait(POLL)

    def clean(self, dry_run: bool = False) -> CleanResult:
        """Run a clean-up now, in the calling thread. Raises ``CleanBusy``."""
        if not self._lock.acquire(blocking=False):
            raise CleanBusy
        try:
            if not dry_run:
                self._schedule(self._clock() + DAY)
            started = time.monotonic()
            limits = self._controls.current().cache
            result = _Run(
                self._store,
                self._cache,
                self._roots,
                limits,
                self._clock(),
                self._stopping,
                dry_run=dry_run,
            ).run()
        finally:
            self._lock.release()
        log.info(
            "cache clean-up%s: %s %d DNG(s), %d bytes: %d whose original is gone or changed, "
            "%d not used for %s day(s), %d over the limit of %s bytes; %.1f s",
            " (dry run)" if dry_run else "",
            "would remove" if dry_run else "removed",
            result.original_gone + result.expired + result.over_limit,
            result.bytes_freed,
            result.original_gone,
            result.expired,
            "(no limit)" if limits.max_age_days is None else limits.max_age_days,
            result.over_limit,
            "(no limit)" if limits.max_bytes is None else limits.max_bytes,
            time.monotonic() - started,
        )
        return result

    def _schedule(self, due: float) -> None:
        self._next_run = due
        try:
            self._store.save_state(STATE_NAME, {"due": due})
        except Exception:
            log.exception("cannot record the next cache clean-up in the database")


class _Run:
    """One clean-up."""

    def __init__(
        self,
        store: Store,
        cache: Cache,
        roots: Mapping[str, Root],
        limits: CacheLimits,
        now: float,
        stopping: threading.Event,
        *,
        dry_run: bool,
    ) -> None:
        self._store = store
        self._cache = cache
        self._roots = roots
        self._limits = limits
        self._now = now
        self._stopping = stopping
        self._dry_run = dry_run
        self._usable: dict[str, Root | None] = {}
        self._counted: set[str] = set()
        """Dry run: what an earlier step would remove (a real run removes it)."""

    def run(self) -> CleanResult:
        gone, gone_bytes, missing_bytes = self._originals()
        expired = expired_bytes = 0
        if self._limits.max_age_days is not None:
            cutoff = self._now - self._limits.max_age_days * DAY
            expired, expired_bytes = self._by_use(used_before=cutoff)
        over = over_bytes = 0
        if self._limits.max_bytes is not None:
            total = self._store.cache_bytes()
            if self._dry_run:
                total -= gone_bytes + expired_bytes + missing_bytes
            if total > self._limits.max_bytes:
                over, over_bytes = self._by_use(need=total - self._limits.max_bytes)
        return CleanResult(
            dry_run=self._dry_run,
            original_gone=gone,
            expired=expired,
            over_limit=over,
            bytes_freed=gone_bytes + expired_bytes + over_bytes,
        )

    def _originals(self) -> tuple[int, int, int]:
        """Step 1: the number and size of the entries removed, and the size of the index
        entries dropped because their DNG file is missing."""
        removed = freed = missing_bytes = 0
        dropped = 0
        for prefix in (f"{number:02x}" for number in range(256)):
            if self._stopping.is_set():
                break
            rows = self._store.cache_rows(prefix)
            if not rows:
                continue
            # Listed after the index was read: a DNG is renamed into place before its index
            # entry is written, so every entry read has its file in this listing.
            names = self._cache.names(prefix)
            missing: list[CacheRow] = []
            changed: list[str] = []
            for row in rows:
                if names is not None and f"{row.key}.dng" not in names:
                    missing.append(row)
                elif self._original_gone(row):
                    changed.append(row.key)
            if missing:
                missing_bytes += sum(row.size for row in missing)
                if self._dry_run:
                    self._counted.update(row.key for row in missing)
                else:
                    dropped += len(
                        self._store.remove_cache_entries(
                            [row.key for row in missing],
                            lambda key: not self._cache.path(key).exists(),
                        )
                    )
            for _key, size in self._remove(changed):
                removed += 1
                freed += size
        if dropped:
            log.warning(
                "cache clean-up: dropped %d index entr%s whose DNG file was missing",
                dropped,
                "y" if dropped == 1 else "ies",
            )
        return removed, freed, missing_bytes

    def _original_gone(self, row: CacheRow) -> bool:
        if row.root is None or row.path is None:
            return False
        if row.source_size is None or row.source_mtime_ns is None:
            return False
        root = self._usable_root(row.root)
        if root is None:
            return False
        try:
            info = os.stat(root.path.joinpath(*row.path.split("/")))
        except (FileNotFoundError, NotADirectoryError):
            return True
        except (OSError, ValueError):
            return False
        if not stat.S_ISREG(info.st_mode):
            return True
        return (info.st_size, info.st_mtime_ns) != (row.source_size, row.source_mtime_ns)

    def _usable_root(self, root_id: str) -> Root | None:
        """The root, if its originals can be judged now: configured, a folder, not empty."""
        if root_id not in self._usable:
            root = self._roots.get(root_id)
            if root is not None and not _has_entries(root.path):
                log.info(
                    "cache clean-up: the root %r is unavailable or empty; its originals are "
                    "not treated as gone",
                    root_id,
                )
                root = None
            self._usable[root_id] = root
        return self._usable[root_id]

    def _by_use(
        self, *, used_before: float | None = None, need: int | None = None
    ) -> tuple[int, int]:
        """Steps 2 and 3: remove least recently used entries first, those used before
        ``used_before``, or until ``need`` bytes are freed."""
        count = freed = 0
        after: tuple[float, str] | None = None
        while not self._stopping.is_set():
            rows = self._store.cache_rows_by_use(after, PAGE, used_before)
            if not rows:
                break
            after = (rows[-1].used, rows[-1].key)
            removed = self._remove(
                [row.key for row in rows], need=None if need is None else need - freed
            )
            for _key, size in removed:
                count += 1
                freed += size
            if need is not None and freed >= need:
                break
        return count, freed

    def _remove(self, keys: Sequence[str], need: int | None = None) -> list[tuple[str, int]]:
        if self._dry_run:
            keys = [key for key in keys if key not in self._counted]
        removed = self._store.remove_cache_entries(
            keys, self._cache.remove, dry_run=self._dry_run, need_bytes=need
        )
        if self._dry_run:
            self._counted.update(key for key, _ in removed)
        return removed


def _has_entries(folder: Path) -> bool:
    try:
        with os.scandir(folder) as entries:
            return next(entries, None) is not None
    except OSError:
        return False


def _number(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, int | float):
        return None
    return float(value)
