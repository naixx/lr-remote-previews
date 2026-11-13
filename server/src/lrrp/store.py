"""The server's state in SQLite (WAL): jobs, their items, the cache index and a log of builds.

One connection, used from the API threads and the scheduler thread, serialised by a lock. Every
change runs in one ``BEGIN IMMEDIATE`` transaction.

The change counter (``seq``, ``docs/protocol.md``): every state change of an item, including its
creation, adds one to its job's ``seq`` and gives the item the new value. So the items of a job
have distinct ``seq`` values, and a client that asks for ``seq > since`` sees every change once.
"""

import sqlite3
import threading
from collections.abc import Iterable, Iterator, Sequence
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path

from lrrp.cache import CacheEntry

DATABASE_NAME = "lrrp.sqlite3"
SCHEMA_VERSION = 1

ITEM_STATES = ("queued", "building", "ready", "failed", "rejected", "cancelled")
JOB_STATES = ("active", "done", "cancelled")
PENDING_STATES = ("queued", "building")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    client TEXT,
    label TEXT,
    state TEXT NOT NULL,
    created REAL NOT NULL,
    finished REAL,
    seq INTEGER NOT NULL DEFAULT 0
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
CREATE INDEX IF NOT EXISTS items_by_job ON items (job_id, seq);
CREATE INDEX IF NOT EXISTS items_by_state ON items (state, cache_key);
CREATE INDEX IF NOT EXISTS items_by_key ON items (cache_key, state);
CREATE TABLE IF NOT EXISTS cache (
    key TEXT PRIMARY KEY,
    size INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    original_name TEXT,
    original_width INTEGER,
    original_height INTEGER,
    created REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS builds (
    id INTEGER PRIMARY KEY,
    finished REAL NOT NULL,
    ok INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS builds_by_time ON builds (finished);
"""

_ITEM_COLUMNS = """
    i.id, i.job_id, i.ref, i.root, i.path, i.state, i.seq, i.error_code, i.error_message,
    i.cache_key, c.key AS c_key, c.size AS c_size, c.sha256 AS c_sha256,
    c.original_name AS c_name, c.original_width AS c_width, c.original_height AS c_height,
    c.created AS c_created
FROM items i LEFT JOIN cache c ON c.key = i.cache_key AND i.state = 'ready'
"""

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
class Status:
    queued: int
    building: int
    built_recently: int
    built_today: int
    failed_today: int
    cache_entries: int
    cache_bytes: int
    active_jobs: int


class StoreError(RuntimeError):
    pass


class Store:
    def __init__(self, path: Path) -> None:
        self._lock = threading.RLock()
        self._db = sqlite3.connect(path, check_same_thread=False, isolation_level=None, timeout=30)
        self._db.row_factory = sqlite3.Row
        self._db.execute("PRAGMA journal_mode = WAL")
        self._db.execute("PRAGMA synchronous = NORMAL")
        self._db.execute("PRAGMA foreign_keys = ON")
        (version,) = self._db.execute("PRAGMA user_version").fetchone()
        if version > SCHEMA_VERSION:
            self._db.close()
            raise StoreError(
                f"{path} was written by a newer server (schema {version}, this one knows "
                f"{SCHEMA_VERSION})"
            )
        if version < SCHEMA_VERSION:
            self._db.executescript(
                f"BEGIN; {_SCHEMA} PRAGMA user_version = {SCHEMA_VERSION}; COMMIT;"
            )

    def close(self) -> None:
        with self._lock:
            self._db.close()

    @contextmanager
    def _transaction(self) -> Iterator[sqlite3.Connection]:
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                yield self._db
            except BaseException:
                self._db.execute("ROLLBACK")
                raise
            self._db.execute("COMMIT")

    def _query(self, sql: str, params: Sequence[object] = ()) -> list[sqlite3.Row]:
        with self._lock:
            return self._db.execute(sql, params).fetchall()

    # --- Jobs and items, for the API ------------------------------------------------------------

    def create_job(
        self, client: str | None, label: str | None, items: Sequence[NewItem], now: float
    ) -> tuple[Job, list[Item]]:
        """Add a job; return it and its items as created, before the scheduler can touch them."""
        with self._lock:
            job_id = self._insert_job(client, label, items, now)
            job = self.get_job(job_id)
            assert job is not None
            return job, self.items_of_job(job_id)

    def _insert_job(
        self, client: str | None, label: str | None, items: Sequence[NewItem], now: float
    ) -> int:
        with self._transaction() as db:
            cursor = db.execute(
                "INSERT INTO jobs (client, label, state, created, seq)"
                " VALUES (?, ?, 'active', ?, 0)",
                (client, label, now),
            )
            job_id = cursor.lastrowid or 0
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
                        seq,
                        item.error_code,
                        item.error_message,
                        item.cache_key,
                        item.size,
                        item.mtime_ns,
                        now,
                    )
                    for seq, item in enumerate(items, start=1)
                ],
            )
            db.execute("UPDATE jobs SET seq = ? WHERE id = ?", (len(items), job_id))
            _settle(db, [job_id], now)
        return job_id

    def get_job(self, job_id: int) -> Job | None:
        with self._lock:
            rows = self._query("SELECT * FROM jobs WHERE id = ?", (job_id,))
            return self._jobs_with_counts(rows)[0] if rows else None

    def list_jobs(self, limit: int, state: str | None = None) -> list[Job]:
        with self._lock:
            if state is None:
                rows = self._query("SELECT * FROM jobs ORDER BY id DESC LIMIT ?", (limit,))
            else:
                rows = self._query(
                    "SELECT * FROM jobs WHERE state = ? ORDER BY id DESC LIMIT ?", (state, limit)
                )
            return self._jobs_with_counts(rows)

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
            )
            for row in rows
        ]

    def items_of_job(self, job_id: int) -> list[Item]:
        """All items of a job in the order they were requested."""
        rows = self._query(f"SELECT {_ITEM_COLUMNS} WHERE i.job_id = ? ORDER BY i.id", (job_id,))
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
            _change(db, rows, "cancelled", now)
        return True

    # --- The queue, for the scheduler -----------------------------------------------------------

    def recover(self, now: float) -> int:
        """Put items a stopped server left ``building`` back into the queue; return how many."""
        with self._transaction() as db:
            rows = db.execute("SELECT id, job_id FROM items WHERE state = 'building'").fetchall()
            _change(db, rows, "queued", now)
        return len(rows)

    def queued_candidates(self, limit: int) -> list[Candidate]:
        """Up to ``limit`` distinct files waiting to be built, oldest request first."""
        rows = self._query(
            "SELECT i.cache_key, i.root, i.path, i.size, i.mtime_ns FROM ("
            " SELECT cache_key, MIN(id) AS first FROM items WHERE state = 'queued'"
            " GROUP BY cache_key ORDER BY first LIMIT ?"
            ") q JOIN items i ON i.id = q.first ORDER BY q.first",
            (limit,),
        )
        return [Candidate(*row) for row in rows]

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
                _change(db, rows, "building", now)

    def complete(self, key: str, entry: CacheEntry | None, now: float) -> None:
        """The DNG for ``key`` is in the cache: its pending items become ``ready``.

        ``entry`` is a new build to add to the index (and to the build log); None when the cache
        already had it.
        """
        with self._transaction() as db:
            if entry is not None:
                db.execute(
                    "INSERT OR REPLACE INTO cache (key, size, sha256, original_name,"
                    " original_width, original_height, created) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    (
                        entry.key,
                        entry.size,
                        entry.sha256,
                        entry.original_name,
                        entry.original_width,
                        entry.original_height,
                        entry.created,
                    ),
                )
                db.execute("INSERT INTO builds (finished, ok) VALUES (?, 1)", (now,))
            rows = db.execute(
                "SELECT id, job_id FROM items"
                " WHERE cache_key = ? AND state IN ('queued', 'building')",
                (key,),
            ).fetchall()
            _change(db, rows, "ready", now)

    def fail(self, key: str, code: str, message: str, now: float) -> None:
        """Building the DNG for ``key`` failed: its ``building`` items become ``failed``."""
        with self._transaction() as db:
            db.execute("INSERT INTO builds (finished, ok) VALUES (?, 0)", (now,))
            rows = db.execute(
                "SELECT id, job_id FROM items WHERE cache_key = ? AND state = 'building'", (key,)
            ).fetchall()
            _change(db, rows, "failed", now, code, message)

    # --- The cache index and the status ---------------------------------------------------------

    def cache_entries(self, keys: Iterable[str]) -> dict[str, CacheEntry]:
        found: dict[str, CacheEntry] = {}
        for chunk in _chunks(list(set(keys))):
            marks = ",".join("?" * len(chunk))
            for row in self._query(f"SELECT * FROM cache WHERE key IN ({marks})", chunk):
                found[row["key"]] = CacheEntry(*row)
        return found

    def cache_entry(self, key: str) -> CacheEntry | None:
        return self.cache_entries([key]).get(key)

    def status(self, recent_since: float, today_since: float) -> Status:
        with self._lock:
            pending = dict(
                self._query(
                    "SELECT state, COUNT(*) FROM items WHERE state IN ('queued', 'building')"
                    " GROUP BY state"
                )
            )
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
            queued=pending.get("queued", 0),
            building=pending.get("building", 0),
            built_recently=recent,
            built_today=built,
            failed_today=failed,
            cache_entries=entries,
            cache_bytes=size,
            active_jobs=active,
        )


def _change(
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
            "UPDATE items SET state = ?, seq = ?, error_code = ?, error_message = ?, updated = ?"
            " WHERE id = ?",
            updates,
        )
        db.execute("UPDATE jobs SET seq = ? WHERE id = ?", (seq, job_id))
    _settle(db, list(by_job), now)


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
