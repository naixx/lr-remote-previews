"""The server's state in SQLite (WAL): jobs, their items, the cache index, a log of builds, the
settings changed through the API, the files the automatic scan leaves alone because they failed,
and a few records of the background work (``state``).

One connection, used from the API threads and the background threads, serialised by a lock.
Every change runs in one ``BEGIN IMMEDIATE`` transaction. After a transaction that changed items
or deleted jobs has been committed, the store says which (``Changes``) to ``on_change``, for the
requests that wait for a change (``lrrp.waits``).

The change counter (``seq``, ``docs/protocol.md``): every state change of an item, including its
creation (also when it is added to a job that exists), adds one to its job's ``seq`` and gives the
item the new value. So the items of a job have distinct ``seq`` values, and a client that asks for
``seq > since`` sees every change once. The counter lives in the database, so a restart of the
server never sets it back.

A cache entry records the original it was built from (root, path, size, modification time), for
the clean-up, and when it was last used (built, found by a job or a lookup, downloaded), at most
once per ``USE_RESOLUTION``, so that reading it costs no write most of the time.

Schema versions (``PRAGMA user_version``): 1 is server 0.2.0; 2 (server 0.3.0) adds
``jobs.client_id``; 3 (server 0.4.0) adds the ``settings`` table; 4 (server 0.5.0) adds
``jobs.priority``, the original and the last use of each cache entry, and the ``scan_failures``
and ``state`` tables. An older database is brought up to date in place when it is opened;
nothing is dropped. Cache entries of an older database get their original from an item that
points to them (unknown when their jobs have expired) and count as used at the upgrade.
"""

import json
import logging
import sqlite3
import threading
import time
from collections.abc import Callable, Iterable, Iterator, Mapping, Sequence
from contextlib import contextmanager
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any, Literal

from lrrp.cache import CacheEntry

log = logging.getLogger(__name__)

DATABASE_NAME = "lrrp.sqlite3"
SCHEMA_VERSION = 4

ITEM_STATES = ("queued", "building", "ready", "failed", "rejected", "cancelled")
JOB_STATES = ("active", "done", "cancelled")
PENDING_STATES = ("queued", "building")

AUTO_SCAN_CLIENT = "auto-scan"
"""The ``client`` of the jobs the automatic scan makes. A file that fails in such a job is
remembered (``scan_failures``) so that the scan does not queue it again until it changes."""

USE_RESOLUTION = 24 * 3600.0
"""The last use of a cache entry is written again only when it is at least this old."""

RetryOutcome = Literal["unknown", "cancelled", "unchanged", "retried"]
AppendRefusal = Literal["unknown", "cancelled", "duplicate_ref", "too_many"]

_TABLES = """
CREATE TABLE IF NOT EXISTS jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    client TEXT,
    label TEXT,
    state TEXT NOT NULL,
    created REAL NOT NULL,
    finished REAL,
    seq INTEGER NOT NULL DEFAULT 0,
    client_id TEXT,
    priority TEXT NOT NULL DEFAULT 'normal'
);
CREATE TABLE IF NOT EXISTS items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id INTEGER NOT NULL REFERENCES jobs (id),
    ref TEXT NOT NULL,
    root TEXT NOT NULL,
    path TEXT NOT NULL,
    state TEXT NOT NULL,
    seq INTEGER NOT NULL,
    error_code TEXT,
    error_message TEXT,
    cache_key TEXT,
    size INTEGER,
    mtime_ns INTEGER,
    updated REAL NOT NULL,
    UNIQUE (job_id, ref)
);
CREATE TABLE IF NOT EXISTS cache (
    key TEXT PRIMARY KEY,
    size INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    original_name TEXT,
    original_width INTEGER,
    original_height INTEGER,
    created REAL NOT NULL,
    root TEXT,
    path TEXT,
    source_size INTEGER,
    source_mtime_ns INTEGER,
    used REAL NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS builds (
    id INTEGER PRIMARY KEY,
    finished REAL NOT NULL,
    ok INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS settings (
    name TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS scan_failures (
    root TEXT NOT NULL,
    path TEXT NOT NULL,
    key TEXT NOT NULL,
    failed REAL NOT NULL,
    PRIMARY KEY (root, path)
);
CREATE TABLE IF NOT EXISTS state (
    name TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""

_ADDED_COLUMNS = (
    ("jobs", "client_id", "TEXT"),
    ("jobs", "priority", "TEXT NOT NULL DEFAULT 'normal'"),
    ("cache", "root", "TEXT"),
    ("cache", "path", "TEXT"),
    ("cache", "source_size", "INTEGER"),
    ("cache", "source_mtime_ns", "INTEGER"),
    ("cache", "used", "REAL NOT NULL DEFAULT 0"),
)
"""Columns added after schema 1: (table, column, type). Added to an older database in place."""

_INDEXES = """
CREATE INDEX IF NOT EXISTS items_by_job ON items (job_id, seq);
CREATE INDEX IF NOT EXISTS items_by_state ON items (state, cache_key);
CREATE INDEX IF NOT EXISTS items_by_key ON items (cache_key, state);
CREATE INDEX IF NOT EXISTS builds_by_time ON builds (finished);
CREATE INDEX IF NOT EXISTS jobs_by_client ON jobs (client_id, id);
CREATE INDEX IF NOT EXISTS jobs_by_finished ON jobs (finished);
CREATE INDEX IF NOT EXISTS items_by_job_state ON items (job_id, state);
CREATE INDEX IF NOT EXISTS cache_by_use ON cache (used, key);
CREATE INDEX IF NOT EXISTS scan_failures_by_key ON scan_failures (key);
"""

_ITEM_COLUMNS = """
    i.id, i.job_id, i.ref, i.root, i.path, i.state, i.seq, i.error_code, i.error_message,
    i.cache_key, c.key AS c_key, c.size AS c_size, c.sha256 AS c_sha256,
    c.original_name AS c_name, c.original_width AS c_width, c.original_height AS c_height,
    c.created AS c_created, c.used AS c_used
FROM items i LEFT JOIN cache c ON c.key = i.cache_key AND i.state = 'ready'
"""

_ENTRY_COLUMNS = "key, size, sha256, original_name, original_width, original_height, created, used"
"""The columns of the cache index that make a ``CacheEntry``, in its order."""

_ROW_COLUMNS = "key, size, used, root, path, source_size, source_mtime_ns"
"""The columns of the cache index that make a ``CacheRow``, in its order."""

_CHUNK = 500


@dataclass(frozen=True)
class NewItem:
    ref: str
    root: str
    path: str
    state: str
    error_code: str | None = None
    error_message: str | None = None
    cache_key: str | None = None
    size: int | None = None
    mtime_ns: int | None = None


@dataclass(frozen=True)
class Job:
    id: int
    client: str | None
    label: str | None
    state: str
    created: float
    finished: float | None
    seq: int
    counts: dict[str, int] = field(default_factory=dict)
    client_id: str | None = None
    priority: str = "normal"


@dataclass(frozen=True)
class Item:
    id: int
    job_id: int
    ref: str
    root: str
    path: str
    state: str
    seq: int
    error_code: str | None
    error_message: str | None
    cache_key: str | None
    result: CacheEntry | None


@dataclass(frozen=True)
class Candidate:
    """A file waiting to be built: the first queued item of one cache key."""

    key: str
    root: str
    path: str
    size: int
    mtime_ns: int


@dataclass(frozen=True)
class NewJob:
    client: str | None
    label: str | None
    items: Sequence[NewItem]
    client_id: str | None = None
    priority: str = "normal"


@dataclass(frozen=True)
class CacheRow:
    """A cache entry as the clean-up sees it: its DNG, its last use and its original."""

    key: str
    size: int
    used: float
    root: str | None
    """The original's root id, path, size and modification time; None when unknown (an entry of
    a server before 0.5.0 whose jobs had expired)."""
    path: str | None
    source_size: int | None
    source_mtime_ns: int | None


@dataclass(frozen=True)
class Changes:
    """What one committed transaction did to jobs, for those who wait for a change."""

    items: Mapping[int, frozenset[str]]
    """By job id: the states that items of the job were put in (created in or moved to)."""
    deleted: frozenset[int]
    """The jobs deleted with their items."""


@dataclass(frozen=True)
class Appended:
    """Items added to a job that exists: the job and the added items, as they were created."""

    job: Job
    items: list[Item]


@dataclass(frozen=True)
class AppendRefused:
    """Nothing was added. ``reason``: no such job, a cancelled job, a ``ref`` the job has
    already (``ref``), or more items in all than the limit (``total``: the job's items)."""

    reason: AppendRefusal
    ref: str | None = None
    total: int = 0


@dataclass(frozen=True)
class Status:
    queued: int
    building: int
    pending_files: int
    """Distinct files (cache keys) among the queued and building items."""
    built_recently: int
    built_today: int
    failed_today: int
    cache_entries: int
    cache_bytes: int
    active_jobs: int


class StoreError(RuntimeError):
    pass


class Store:
    def __init__(self, path: Path, on_change: Callable[[Changes], None] | None = None) -> None:
        """``on_change`` is told what each committed transaction did to items and jobs, from
        the thread that made the change, after the commit (so a reader sees the change)."""
        self._on_change = on_change
        self._changed_items: dict[int, set[str]] = {}
        self._deleted_jobs: set[int] = set()
        self._lock = threading.RLock()
        self._db = sqlite3.connect(path, check_same_thread=False, isolation_level=None, timeout=30)
        self._db.row_factory = sqlite3.Row
        self._db.execute("PRAGMA journal_mode = WAL")
        # FULL: a committed change survives a power cut. With NORMAL the last commits can be lost,
        # and a job's seq would then reuse values a client has already seen, so that client would
        # miss changes. The cost is one fsync per commit, a few per second at most here.
        self._db.execute("PRAGMA synchronous = FULL")
        self._db.execute("PRAGMA foreign_keys = ON")
        (version,) = self._db.execute("PRAGMA user_version").fetchone()
        if version > SCHEMA_VERSION:
            self._db.close()
            raise StoreError(
                f"{path} was written by a newer server (schema {version}, this one knows "
                f"{SCHEMA_VERSION})"
            )
        if version < SCHEMA_VERSION:
            self._migrate()

    def _migrate(self) -> None:
        """Create what is missing (tables, columns, indexes) in one transaction."""
        with self._transaction() as db:
            for statement in _statements(_TABLES):
                db.execute(statement)
            added: set[tuple[str, str]] = set()
            for table, column, kind in _ADDED_COLUMNS:
                present = {row["name"] for row in db.execute(f"PRAGMA table_info({table})")}
                if column not in present:
                    db.execute(f"ALTER TABLE {table} ADD COLUMN {column} {kind}")
                    added.add((table, column))
            if ("cache", "used") in added:
                # Entries of an older server: their original from an item that points to them,
                # and their use, which nobody recorded, counts from now.
                db.execute(
                    "UPDATE cache SET used = ?, (root, path, source_size, source_mtime_ns) = ("
                    " SELECT root, path, size, mtime_ns FROM items"
                    " WHERE items.cache_key = cache.key ORDER BY id DESC LIMIT 1)",
                    (time.time(),),
                )
            for statement in _statements(_INDEXES):
                db.execute(statement)
            db.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")

    def close(self) -> None:
        with self._lock:
            self._db.close()

    @contextmanager
    def _transaction(self) -> Iterator[sqlite3.Connection]:
        with self._lock:
            # Nothing noted by a transaction that did not commit is reported.
            self._changed_items.clear()
            self._deleted_jobs.clear()
            self._db.execute("BEGIN IMMEDIATE")
            try:
                yield self._db
            except BaseException:
                self._db.execute("ROLLBACK")
                raise
            self._db.execute("COMMIT")
            changes = None
            if self._changed_items or self._deleted_jobs:
                changes = Changes(
                    items={job: frozenset(states) for job, states in self._changed_items.items()},
                    deleted=frozenset(self._deleted_jobs),
                )
                self._changed_items.clear()
                self._deleted_jobs.clear()
        if changes is not None and self._on_change is not None:
            try:
                self._on_change(changes)
            except Exception:
                log.exception("cannot report a change of the jobs")

    def _note(self, job_id: int, states: Iterable[str]) -> None:
        """Items of this job were put in these states by the transaction that is open."""
        self._changed_items.setdefault(job_id, set()).update(states)

    @contextmanager
    def _reading(self) -> Iterator[sqlite3.Connection]:
        """The connection under the lock, for reads that need no transaction."""
        with self._lock:
            yield self._db

    def _query(self, sql: str, params: Sequence[object] = ()) -> list[sqlite3.Row]:
        with self._lock:
            return self._db.execute(sql, params).fetchall()

    # --- Jobs and items, for the API ------------------------------------------------------------

    def create_job(
        self,
        client: str | None,
        label: str | None,
        items: Sequence[NewItem],
        now: float,
        client_id: str | None = None,
        priority: str = "normal",
    ) -> tuple[Job, list[Item]]:
        """Add a job; return it and its items as created, before the scheduler can touch them.

        An item given as ``ready`` whose cache entry is gone by now (removed by the clean-up
        since the caller looked) is queued instead.
        """
        with self._lock:
            with self._transaction() as db:
                new = NewJob(client, label, items, client_id, priority)
                job_id = self._insert_job(db, new, now)
            job = self.get_job(job_id)
            assert job is not None
            return job, self.items_of_job(job_id)

    def create_jobs(self, jobs: Sequence[NewJob], now: float) -> list[Job]:
        """Add several jobs in one transaction; return them as created."""
        with self._lock:
            with self._transaction() as db:
                ids = [self._insert_job(db, job, now) for job in jobs]
            created = [self.get_job(job_id) for job_id in ids]
        return [job for job in created if job is not None]

    def append_items(
        self, job_id: int, items: Sequence[NewItem], now: float, max_items: int
    ) -> Appended | AppendRefused:
        """Add items to a job that exists; return the job and the added items as created (in
        the order given), before the scheduler can touch them.

        The items get the next values of the job's ``seq``. A ``done`` job becomes ``active``
        again when an added item is queued (``finished`` back to null); it is ``done`` again,
        with a new ``finished``, once nothing is queued or building. An item given as ``ready``
        whose cache entry is gone by now is queued instead, as in ``create_job``. Refused, with
        nothing changed: an unknown or cancelled job, a ``ref`` the job has already, or more
        than ``max_items`` items in all; checked in that order, in the same transaction as the
        insertion.
        """
        with self._lock:
            with self._transaction() as db:
                row = db.execute("SELECT state, seq FROM jobs WHERE id = ?", (job_id,)).fetchone()
                if row is None:
                    return AppendRefused("unknown")
                if row["state"] == "cancelled":
                    return AppendRefused("cancelled")
                used = self._used_refs(db, job_id, [item.ref for item in items])
                if used:
                    first = next(item.ref for item in items if item.ref in used)
                    return AppendRefused("duplicate_ref", ref=first)
                (total,) = db.execute(
                    "SELECT COUNT(*) FROM items WHERE job_id = ?", (job_id,)
                ).fetchone()
                if total + len(items) > max_items:
                    return AppendRefused("too_many", total=total)
                self._add_items(db, job_id, items, now)
            job = self.get_job(job_id)
            added, _ = self.items_since(job_id, row["seq"], len(items))
        assert job is not None
        return Appended(job, added)

    def used_refs(self, job_id: int, refs: Sequence[str]) -> set[str]:
        """The refs among ``refs`` that items of this job have."""
        with self._reading() as db:
            return self._used_refs(db, job_id, refs)

    @staticmethod
    def _used_refs(db: sqlite3.Connection, job_id: int, refs: Sequence[str]) -> set[str]:
        found: set[str] = set()
        for chunk in _chunks(list(set(refs))):
            marks = ",".join("?" * len(chunk))
            found.update(
                ref
                for (ref,) in db.execute(
                    f"SELECT ref FROM items WHERE job_id = ? AND ref IN ({marks})",
                    [job_id, *chunk],
                )
            )
        return found

    def get_job(self, job_id: int) -> Job | None:
        with self._lock:
            rows = self._query("SELECT * FROM jobs WHERE id = ?", (job_id,))
            return self._jobs_with_counts(rows)[0] if rows else None

    def list_jobs(
        self, limit: int, state: str | None = None, client_id: str | None = None
    ) -> list[Job]:
        """Jobs, newest first; only those in ``state`` and with ``client_id``, when given."""
        sql = "SELECT * FROM jobs"
        conditions: list[str] = []
        params: list[object] = []
        if state is not None:
            conditions.append("state = ?")
            params.append(state)
        if client_id is not None:
            conditions.append("client_id = ?")
            params.append(client_id)
        if conditions:
            sql += " WHERE " + " AND ".join(conditions)
        sql += " ORDER BY id DESC LIMIT ?"
        params.append(limit)
        with self._lock:
            return self._jobs_with_counts(self._query(sql, params))

    def _jobs_with_counts(self, rows: list[sqlite3.Row]) -> list[Job]:
        counts: dict[int, dict[str, int]] = {row["id"]: {} for row in rows}
        for chunk in _chunks(list(counts)):
            marks = ",".join("?" * len(chunk))
            for job_id, state, number in self._query(
                f"SELECT job_id, state, COUNT(*) FROM items WHERE job_id IN ({marks})"
                " GROUP BY job_id, state",
                chunk,
            ):
                counts[job_id][state] = number
        return [
            Job(
                id=row["id"],
                client=row["client"],
                label=row["label"],
                state=row["state"],
                created=row["created"],
                finished=row["finished"],
                seq=row["seq"],
                counts=counts[row["id"]],
                client_id=row["client_id"],
                priority=row["priority"],
            )
            for row in rows
        ]

    def items_of_job(self, job_id: int, state: str | None = None) -> list[Item]:
        """The items of a job (only those in ``state``, when given) in request order."""
        sql = f"SELECT {_ITEM_COLUMNS} WHERE i.job_id = ?"
        params: list[object] = [job_id]
        if state is not None:
            sql += " AND i.state = ?"
            params.append(state)
        rows = self._query(sql + " ORDER BY i.id", params)
        return [_item(row) for row in rows]

    def items_since(
        self, job_id: int, since: int, limit: int, state: str | None = None
    ) -> tuple[list[Item], bool]:
        """Items of a job with ``seq > since`` in ``seq`` order, and whether the limit cut them."""
        sql = f"SELECT {_ITEM_COLUMNS} WHERE i.job_id = ? AND i.seq > ?"
        params: list[object] = [job_id, since]
        if state is not None:
            sql += " AND i.state = ?"
            params.append(state)
        sql += " ORDER BY i.seq LIMIT ?"
        params.append(limit + 1)
        rows = self._query(sql, params)
        return [_item(row) for row in rows[:limit]], len(rows) > limit

    def get_item(self, item_id: int) -> Item | None:
        rows = self._query(f"SELECT {_ITEM_COLUMNS} WHERE i.id = ?", (item_id,))
        return _item(rows[0]) if rows else None

    def cancel_job(self, job_id: int, now: float) -> bool:
        """Cancel an active job: its queued items become cancelled. False for an unknown job."""
        with self._transaction() as db:
            row = db.execute("SELECT state FROM jobs WHERE id = ?", (job_id,)).fetchone()
            if row is None:
                return False
            if row["state"] != "active":
                return True
            db.execute(
                "UPDATE jobs SET state = 'cancelled', finished = ? WHERE id = ?", (now, job_id)
            )
            rows = db.execute(
                "SELECT id, job_id FROM items WHERE job_id = ? AND state = 'queued'", (job_id,)
            ).fetchall()
            self._change(db, rows, "cancelled", now)
        return True

    def retry_job(
        self, job_id: int, identities: Mapping[int, tuple[str, int, int]], now: float
    ) -> RetryOutcome:
        """Put the failed items of a job back into the queue and make the job active again.

        ``identities`` maps item ids to the file as it is now: (cache key, size, mtime in ns).
        A failed item missing from it keeps the identity it was requested with (its file is
        gone or no longer acceptable, so the build fails again with ``source_changed``).
        """
        with self._transaction() as db:
            row = db.execute("SELECT state FROM jobs WHERE id = ?", (job_id,)).fetchone()
            if row is None:
                return "unknown"
            if row["state"] == "cancelled":
                return "cancelled"
            rows = db.execute(
                "SELECT id, job_id FROM items WHERE job_id = ? AND state = 'failed'", (job_id,)
            ).fetchall()
            if not rows:
                return "unchanged"
            db.executemany(
                "UPDATE items SET cache_key = ?, size = ?, mtime_ns = ? WHERE id = ?",
                [(*identities[item_id], item_id) for item_id, _ in rows if item_id in identities],
            )
            db.execute("UPDATE jobs SET state = 'active', finished = NULL WHERE id = ?", (job_id,))
            self._change(db, rows, "queued", now)
        return "retried"

    def delete_expired_jobs(self, finished_before: float) -> int:
        """Delete the jobs that left ``active`` before this time, with their items.

        A cancelled job whose last items are still building is kept until they finish. The cache
        index is not touched. Returns the number of jobs deleted.
        """
        with self._transaction() as db:
            ids = [
                job_id
                for (job_id,) in db.execute(
                    "SELECT id FROM jobs WHERE state != 'active' AND finished < ?"
                    " AND NOT EXISTS (SELECT 1 FROM items WHERE items.job_id = jobs.id"
                    " AND items.state IN ('queued', 'building'))",
                    (finished_before,),
                )
            ]
            for chunk in _chunks(ids):
                marks = ",".join("?" * len(chunk))
                db.execute(f"DELETE FROM items WHERE job_id IN ({marks})", chunk)
                db.execute(f"DELETE FROM jobs WHERE id IN ({marks})", chunk)
            self._deleted_jobs.update(ids)
        return len(ids)

    # --- Writing items (inside a transaction) ---------------------------------------------------

    def _insert_job(self, db: sqlite3.Connection, job: NewJob, now: float) -> int:
        cursor = db.execute(
            "INSERT INTO jobs (client, label, client_id, priority, state, created, seq)"
            " VALUES (?, ?, ?, ?, 'active', ?, 0)",
            (job.client, job.label, job.client_id, job.priority, now),
        )
        job_id = cursor.lastrowid or 0
        self._add_items(db, job_id, job.items, now)
        return job_id

    def _add_items(
        self, db: sqlite3.Connection, job_id: int, items: Sequence[NewItem], now: float
    ) -> None:
        """Insert items into a job with the next values of its ``seq``; a ``done`` job with a
        queued item among them becomes ``active``, an ``active`` one with nothing queued or
        building ``done``."""
        cached = {item.cache_key for item in items if item.state == "ready" and item.cache_key}
        present: set[str] = set()
        for chunk in _chunks(list(cached)):
            marks = ",".join("?" * len(chunk))
            present.update(
                key for (key,) in db.execute(f"SELECT key FROM cache WHERE key IN ({marks})", chunk)
            )
        items = [
            replace(item, state="queued")
            if item.state == "ready" and item.cache_key not in present
            else item
            for item in items
        ]
        (seq,) = db.execute("SELECT seq FROM jobs WHERE id = ?", (job_id,)).fetchone()
        db.executemany(
            "INSERT INTO items (job_id, ref, root, path, state, seq, error_code, error_message,"
            " cache_key, size, mtime_ns, updated) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                (
                    job_id,
                    item.ref,
                    item.root,
                    item.path,
                    item.state,
                    item_seq,
                    item.error_code,
                    item.error_message,
                    item.cache_key,
                    item.size,
                    item.mtime_ns,
                    now,
                )
                for item_seq, item in enumerate(items, start=seq + 1)
            ],
        )
        db.execute("UPDATE jobs SET seq = ? WHERE id = ?", (seq + len(items), job_id))
        if any(item.state == "queued" for item in items):
            db.execute(
                "UPDATE jobs SET state = 'active', finished = NULL WHERE id = ? AND state = 'done'",
                (job_id,),
            )
        self._note(job_id, {item.state for item in items})
        _settle(db, [job_id], now)

    def _change(
        self,
        db: sqlite3.Connection,
        rows: Iterable[Sequence[int]],
        state: str,
        now: float,
        code: str | None = None,
        message: str | None = None,
    ) -> None:
        """Move items to ``state``, one ``seq`` step each, and settle their jobs."""
        by_job: dict[int, list[int]] = {}
        for item_id, job_id in rows:
            by_job.setdefault(job_id, []).append(item_id)
        for job_id, item_ids in by_job.items():
            (seq,) = db.execute("SELECT seq FROM jobs WHERE id = ?", (job_id,)).fetchone()
            updates = []
            for item_id in sorted(item_ids):
                seq += 1
                updates.append((state, seq, code, message, now, item_id))
            db.executemany(
                "UPDATE items SET state = ?, seq = ?, error_code = ?, error_message = ?,"
                " updated = ? WHERE id = ?",
                updates,
            )
            db.execute("UPDATE jobs SET seq = ? WHERE id = ?", (seq, job_id))
            self._note(job_id, (state,))
        _settle(db, list(by_job), now)

    # --- The queue, for the scheduler -----------------------------------------------------------

    def recover(self, now: float) -> int:
        """Put items a stopped server left ``building`` back into the queue; return how many."""
        with self._transaction() as db:
            rows = db.execute("SELECT id, job_id FROM items WHERE state = 'building'").fetchall()
            self._change(db, rows, "queued", now)
        return len(rows)

    def queued_candidates(self, limit: int) -> list[Candidate]:
        """Up to ``limit`` distinct files waiting to be built: first those a ``normal`` job wants,
        then the others; within a priority, oldest request first.

        A file is placed by its first request in a ``normal`` job if it has one, so a file wanted
        by a ``background`` and a ``normal`` job is built as ``normal``.

        Items are numbered in the order they were requested, so reading the queued items of the
        active jobs one job after the other, oldest job first and each job's items in order,
        gives the requests in order; items added to a job later (``append_items``) are read with
        their job, so an older job's added items come before a newer job's. The reading stops
        once ``limit`` files are found, so a wave reads about as many items as it takes, however
        long the queue (index ``items_by_job_state``).
        """
        found: dict[str, Candidate] = {}
        with self._lock:
            jobs = self._db.execute(
                "SELECT id, priority FROM jobs WHERE state = 'active' ORDER BY id"
            ).fetchall()
            for normal in (True, False):
                for job_id, priority in jobs:
                    if (priority == "normal") != normal:
                        continue
                    cursor = self._db.execute(
                        "SELECT cache_key, root, path, size, mtime_ns FROM items"
                        " WHERE job_id = ? AND state = 'queued' ORDER BY id",
                        (job_id,),
                    )
                    try:
                        for row in cursor:
                            if row[0] not in found:
                                found[row[0]] = Candidate(*row)
                                if len(found) == limit:
                                    return list(found.values())
                    finally:
                        cursor.close()
        return list(found.values())

    def mark_building(self, keys: Iterable[str], now: float) -> None:
        """Every queued item of these cache keys becomes ``building``."""
        with self._transaction() as db:
            for chunk in _chunks(list(keys)):
                marks = ",".join("?" * len(chunk))
                rows = db.execute(
                    "SELECT id, job_id FROM items"
                    f" WHERE state = 'queued' AND cache_key IN ({marks})",
                    chunk,
                ).fetchall()
                self._change(db, rows, "building", now)

    def complete(self, key: str, entry: CacheEntry | None, now: float) -> None:
        """The DNG for ``key`` is in the cache: its pending items become ``ready``.

        ``entry`` is a new build to add to the index (and to the build log), with the original
        its items name; None when the cache already had it, which counts as a use of it. Either
        way the automatic scan forgets an earlier failure of the file.
        """
        with self._transaction() as db:
            source = db.execute(
                "SELECT root, path, size, mtime_ns FROM items"
                " WHERE cache_key = ? AND state IN ('queued', 'building') ORDER BY id LIMIT 1",
                (key,),
            ).fetchone()
            if entry is not None:
                db.execute(
                    "INSERT OR REPLACE INTO cache (key, size, sha256, original_name,"
                    " original_width, original_height, created, root, path, source_size,"
                    " source_mtime_ns, used) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        entry.key,
                        entry.size,
                        entry.sha256,
                        entry.original_name,
                        entry.original_width,
                        entry.original_height,
                        entry.created,
                        *(tuple(source) if source is not None else (None,) * 4),
                        now,
                    ),
                )
                db.execute("INSERT INTO builds (finished, ok) VALUES (?, 1)", (now,))
            else:
                db.execute(
                    "UPDATE cache SET used = ? WHERE key = ? AND used <= ?",
                    (now, key, now - USE_RESOLUTION),
                )
            if source is not None:
                db.execute(
                    "DELETE FROM scan_failures WHERE key = ? OR (root = ? AND path = ?)",
                    (key, source["root"], source["path"]),
                )
            rows = db.execute(
                "SELECT id, job_id FROM items"
                " WHERE cache_key = ? AND state IN ('queued', 'building')",
                (key,),
            ).fetchall()
            self._change(db, rows, "ready", now)

    def fail(self, key: str, code: str, message: str, now: float, *, remember: bool = True) -> None:
        """Building the DNG for ``key`` failed: its ``building`` items become ``failed``.

        ``remember``: the failure is the file's (not the server's, such as a converter that
        cannot start, or a source that changed), so if an automatic job wanted it, the automatic
        scan leaves the file alone until it changes.
        """
        with self._transaction() as db:
            db.execute("INSERT INTO builds (finished, ok) VALUES (?, 0)", (now,))
            if remember:
                db.execute(
                    "INSERT OR REPLACE INTO scan_failures (root, path, key, failed)"
                    " SELECT i.root, i.path, i.cache_key, ? FROM items i"
                    " JOIN jobs j ON j.id = i.job_id"
                    " WHERE i.cache_key = ? AND i.state = 'building' AND j.client = ? LIMIT 1",
                    (now, key, AUTO_SCAN_CLIENT),
                )
            rows = db.execute(
                "SELECT id, job_id FROM items WHERE cache_key = ? AND state = 'building'", (key,)
            ).fetchall()
            self._change(db, rows, "failed", now, code, message)

    # --- Settings --------------------------------------------------------------------------------

    def settings(self) -> dict[str, Any]:
        """The settings changed through the API, by name, as they were saved."""
        found: dict[str, Any] = {}
        for name, value in self._query("SELECT name, value FROM settings"):
            try:
                found[name] = json.loads(value)
            except ValueError:
                continue
        return found

    def save_settings(self, values: Mapping[str, Any]) -> None:
        """Save these settings (JSON values), replacing what was saved under their names."""
        with self._transaction() as db:
            db.executemany(
                "INSERT OR REPLACE INTO settings (name, value) VALUES (?, ?)",
                [(name, json.dumps(value)) for name, value in values.items()],
            )

    def state(self, name: str) -> Any:
        """A record the background work keeps (a JSON value), or None."""
        rows = self._query("SELECT value FROM state WHERE name = ?", (name,))
        if not rows:
            return None
        try:
            return json.loads(rows[0]["value"])
        except ValueError:
            return None

    def save_state(self, name: str, value: Any) -> None:
        with self._transaction() as db:
            db.execute(
                "INSERT OR REPLACE INTO state (name, value) VALUES (?, ?)",
                (name, json.dumps(value)),
            )

    # --- The cache index and the status ---------------------------------------------------------

    def cache_entries(self, keys: Iterable[str]) -> dict[str, CacheEntry]:
        found: dict[str, CacheEntry] = {}
        for chunk in _chunks(list(set(keys))):
            marks = ",".join("?" * len(chunk))
            for row in self._query(
                f"SELECT {_ENTRY_COLUMNS} FROM cache WHERE key IN ({marks})", chunk
            ):
                found[row["key"]] = CacheEntry(*row)
        return found

    def cache_entry(self, key: str) -> CacheEntry | None:
        return self.cache_entries([key]).get(key)

    def cached_keys(self, keys: Iterable[str]) -> set[str]:
        """The keys among ``keys`` that the cache index has (the DNG files are not looked at)."""
        found: set[str] = set()
        for chunk in _chunks(list(set(keys))):
            marks = ",".join("?" * len(chunk))
            for (key,) in self._query(f"SELECT key FROM cache WHERE key IN ({marks})", chunk):
                found.add(key)
        return found

    def failed_scan_keys(self, keys: Iterable[str]) -> set[str]:
        """The keys among ``keys`` of files that failed in an automatic job, as they are now."""
        found: set[str] = set()
        for chunk in _chunks(list(set(keys))):
            marks = ",".join("?" * len(chunk))
            for (key,) in self._query(
                f"SELECT key FROM scan_failures WHERE key IN ({marks})", chunk
            ):
                found.add(key)
        return found

    def touch(self, keys: Iterable[str], now: float) -> None:
        """These cache entries were used now."""
        with self._transaction() as db:
            for chunk in _chunks(list(set(keys))):
                marks = ",".join("?" * len(chunk))
                db.execute(f"UPDATE cache SET used = ? WHERE key IN ({marks})", [now, *chunk])

    def cache_rows(self, prefix: str) -> list[CacheRow]:
        """The cache entries whose key starts with ``prefix``, by key."""
        rows = self._query(
            f"SELECT {_ROW_COLUMNS} FROM cache WHERE key >= ? AND key < ? ORDER BY key",
            (prefix, prefix + "￿"),
        )
        return [CacheRow(*row) for row in rows]

    def cache_rows_by_use(
        self, after: tuple[float, str] | None, limit: int, used_before: float | None = None
    ) -> list[CacheRow]:
        """Up to ``limit`` cache entries, least recently used first, after ``(used, key)``;
        only those last used before ``used_before``, when given."""
        conditions: list[str] = []
        params: list[object] = []
        if after is not None:
            conditions.append("(used, key) > (?, ?)")
            params.extend(after)
        if used_before is not None:
            conditions.append("used < ?")
            params.append(used_before)
        where = f" WHERE {' AND '.join(conditions)}" if conditions else ""
        rows = self._query(
            f"SELECT {_ROW_COLUMNS} FROM cache{where} ORDER BY used, key LIMIT ?",
            [*params, limit],
        )
        return [CacheRow(*row) for row in rows]

    def cache_bytes(self) -> int:
        """The size of every DNG the cache index has."""
        (size,) = self._query("SELECT COALESCE(SUM(size), 0) FROM cache")[0]
        return size

    def remove_cache_entries(
        self,
        keys: Sequence[str],
        remove_file: Callable[[str], bool],
        *,
        dry_run: bool = False,
        need_bytes: int | None = None,
    ) -> list[tuple[str, int]]:
        """Remove these cache entries in this order; return the (key, size) of those removed.

        An entry that an item of an active job points to is kept, and so is one whose file
        ``remove_file`` could not delete (it returns False; a file that was gone already is
        True). The check, the file and the index row go together, under the lock, so a job
        created meanwhile never points to a removed entry. ``need_bytes``: stop once that much
        is freed. ``dry_run``: only say what would be removed.
        """
        removed: list[tuple[str, int]] = []
        if not keys:
            return removed
        freed = 0
        with self._reading() if dry_run else self._transaction() as db:
            for chunk in _chunks(list(keys)):
                marks = ",".join("?" * len(chunk))
                protected = {
                    key
                    for (key,) in db.execute(
                        "SELECT DISTINCT i.cache_key FROM items i JOIN jobs j ON j.id = i.job_id"
                        f" WHERE j.state = 'active' AND i.cache_key IN ({marks})",
                        chunk,
                    )
                }
                sizes = dict(
                    db.execute(f"SELECT key, size FROM cache WHERE key IN ({marks})", chunk)
                )
                gone: list[tuple[str]] = []
                for key in chunk:
                    if need_bytes is not None and freed >= need_bytes:
                        break
                    if key in protected or key not in sizes:
                        continue
                    if not dry_run and not remove_file(key):
                        continue
                    removed.append((key, sizes[key]))
                    gone.append((key,))
                    freed += sizes[key]
                if not dry_run:
                    db.executemany("DELETE FROM cache WHERE key = ?", gone)
                if need_bytes is not None and freed >= need_bytes:
                    break
        return removed

    def pending_keys(self, keys: Iterable[str]) -> set[str]:
        """The cache keys among ``keys`` that an item of any job is queued or building for."""
        found: set[str] = set()
        for chunk in _chunks(list(set(keys))):
            marks = ",".join("?" * len(chunk))
            for (key,) in self._query(
                "SELECT DISTINCT cache_key FROM items"
                f" WHERE cache_key IN ({marks}) AND state IN ('queued', 'building')",
                chunk,
            ):
                found.add(key)
        return found

    def pending(self) -> tuple[int, int]:
        """The numbers of queued and of building items over all jobs."""
        counts = dict(
            self._query(
                "SELECT state, COUNT(*) FROM items WHERE state IN ('queued', 'building')"
                " GROUP BY state"
            )
        )
        return counts.get("queued", 0), counts.get("building", 0)

    def status(self, recent_since: float, today_since: float) -> Status:
        with self._lock:
            queued, building = self.pending()
            (files,) = self._query(
                "SELECT COUNT(DISTINCT cache_key) FROM items WHERE state IN ('queued', 'building')"
            )[0]
            (recent,) = self._query(
                "SELECT COUNT(*) FROM builds WHERE ok = 1 AND finished >= ?", (recent_since,)
            )[0]
            built, failed = self._query(
                "SELECT COALESCE(SUM(ok), 0), COALESCE(SUM(1 - ok), 0) FROM builds"
                " WHERE finished >= ?",
                (today_since,),
            )[0]
            entries, size = self._query("SELECT COUNT(*), COALESCE(SUM(size), 0) FROM cache")[0]
            (active,) = self._query("SELECT COUNT(*) FROM jobs WHERE state = 'active'")[0]
        return Status(
            queued=queued,
            building=building,
            pending_files=files,
            built_recently=recent,
            built_today=built,
            failed_today=failed,
            cache_entries=entries,
            cache_bytes=size,
            active_jobs=active,
        )


def _settle(db: sqlite3.Connection, job_ids: Sequence[int], now: float) -> None:
    """An active job with nothing queued or building is done."""
    db.executemany(
        "UPDATE jobs SET state = 'done', finished = ? WHERE id = ? AND state = 'active'"
        " AND NOT EXISTS (SELECT 1 FROM items WHERE items.job_id = jobs.id"
        " AND items.state IN ('queued', 'building'))",
        [(now, job_id) for job_id in job_ids],
    )


def _item(row: sqlite3.Row) -> Item:
    result = None
    if row["c_key"] is not None:
        result = CacheEntry(
            key=row["c_key"],
            size=row["c_size"],
            sha256=row["c_sha256"],
            original_name=row["c_name"],
            original_width=row["c_width"],
            original_height=row["c_height"],
            created=row["c_created"],
            used=row["c_used"],
        )
    return Item(
        id=row["id"],
        job_id=row["job_id"],
        ref=row["ref"],
        root=row["root"],
        path=row["path"],
        state=row["state"],
        seq=row["seq"],
        error_code=row["error_code"],
        error_message=row["error_message"],
        cache_key=row["cache_key"],
        result=result,
    )


def _chunks(values: list[str] | list[int]) -> Iterator[list]:
    for start in range(0, len(values), _CHUNK):
        yield values[start : start + _CHUNK]


def _statements(script: str) -> list[str]:
    """The statements of a script of plain DDL (no ``;`` inside a statement)."""
    return [statement.strip() for statement in script.split(";") if statement.strip()]
