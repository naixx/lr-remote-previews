"""The database: migration from older schemas, deleting expired jobs, the daily clean-up."""

import sqlite3
import sys
import time
from collections.abc import Iterator
from pathlib import Path

import pytest

from conftest import Harness, items_by_path, post_job, wait_job
from lrrp import converter, sources
from lrrp.cache import Cache, CacheEntry
from lrrp.display import NoDisplay
from lrrp.runner import Runner, RunnerConfig
from lrrp.scheduler import DAY, Scheduler
from lrrp.store import SCHEMA_VERSION, NewItem, Store, StoreError

# The schema of server 0.2.0 (schema version 1), as it created its database.
SCHEMA_0_2_0 = """
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

T0 = 1_800_000_000.0
KEY_A = "a" * 64
KEY_B = "b" * 64


def create_0_2_0_database(path: Path, rows: list[tuple[str, tuple[object, ...]]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path)
    db.executescript(f"BEGIN; {SCHEMA_0_2_0} PRAGMA user_version = 1; COMMIT;")
    with db:
        for sql, params in rows:
            db.execute(sql, params)
    db.close()


OLD_ROWS: list[tuple[str, tuple[object, ...]]] = [
    (
        "INSERT INTO jobs (id, client, label, state, created, finished, seq)"
        " VALUES (1, 'lr-plugin/0.2.0', 'Selection', 'done', ?, ?, 3)",
        (T0, T0 + 5),
    ),
    (
        "INSERT INTO items (job_id, ref, root, path, state, seq, cache_key, size, mtime_ns,"
        " updated) VALUES (1, '17', 'archive', 'IMG_0001.ARW', 'ready', 3, ?, 10, 20, ?)",
        (KEY_A, T0 + 5),
    ),
    (
        "INSERT INTO items (job_id, ref, root, path, state, seq, error_code, error_message,"
        " updated) VALUES (1, '18', 'archive', 'photo.jpg', 'rejected', 2,"
        " 'unsupported_format', 'not raw', ?)",
        (T0,),
    ),
    (
        "INSERT INTO cache (key, size, sha256, original_name, original_width, original_height,"
        " created) VALUES (?, 1234, ?, 'IMG_0001.ARW', 6000, 4000, ?)",
        (KEY_A, "c" * 64, T0 + 5),
    ),
    ("INSERT INTO builds (finished, ok) VALUES (?, 1)", (T0 + 5,)),
]


def columns(path: Path, table: str) -> set[str]:
    db = sqlite3.connect(path)
    try:
        return {row[1] for row in db.execute(f"PRAGMA table_info({table})")}
    finally:
        db.close()


def user_version(path: Path) -> int:
    db = sqlite3.connect(path)
    try:
        return db.execute("PRAGMA user_version").fetchone()[0]
    finally:
        db.close()


def test_a_0_2_0_database_is_migrated_in_place(tmp_path: Path) -> None:
    path = tmp_path / "lrrp.sqlite3"
    create_0_2_0_database(path, OLD_ROWS)
    assert "client_id" not in columns(path, "jobs")

    store = Store(path)
    try:
        job = store.get_job(1)
        assert job is not None
        assert (job.client, job.label, job.client_id) == ("lr-plugin/0.2.0", "Selection", None)
        assert (job.state, job.created, job.finished, job.seq) == ("done", T0, T0 + 5, 3)
        assert job.counts == {"ready": 1, "rejected": 1}
        ready, rejected = store.items_of_job(1)
        assert ready.result is not None and ready.result.key == KEY_A
        assert ready.result.original_width == 6000
        assert (rejected.error_code, rejected.error_message) == ("unsupported_format", "not raw")
        assert store.status(0, 0).built_today == 1

        new, _ = store.create_job(None, None, [], T0 + 10, client_id="mine")
        assert new.id == 2
        assert new.client_id == "mine"
        assert [j.id for j in store.list_jobs(10, client_id="mine")] == [2]
        assert [j.id for j in store.list_jobs(10)] == [2, 1]
    finally:
        store.close()
    assert user_version(path) == SCHEMA_VERSION == 4
    assert "client_id" in columns(path, "jobs")

    # Opening it again changes nothing.
    store = Store(path)
    try:
        assert [(j.id, j.client_id) for j in store.list_jobs(10)] == [(2, "mine"), (1, None)]
    finally:
        store.close()


# The schema of server 0.3.0 (schema version 2), as it created a new database.
SCHEMA_0_3_0 = (
    SCHEMA_0_2_0.replace(
        "    seq INTEGER NOT NULL DEFAULT 0\n);",
        "    seq INTEGER NOT NULL DEFAULT 0,\n    client_id TEXT\n);",
        1,
    )
    + """
CREATE INDEX IF NOT EXISTS jobs_by_client ON jobs (client_id, id);
CREATE INDEX IF NOT EXISTS jobs_by_finished ON jobs (finished);
"""
)

ROWS_0_3_0: list[tuple[str, tuple[object, ...]]] = [
    (
        "INSERT INTO jobs (id, client, label, client_id, state, created, finished, seq)"
        " VALUES (1, 'lr-plugin/0.3.0', 'Selection', 'catalog-1', 'done', ?, ?, 3)",
        (T0, T0 + 5),
    ),
    *OLD_ROWS[1:],
]


def create_0_3_0_database(path: Path, rows: list[tuple[str, tuple[object, ...]]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path)
    db.executescript(f"BEGIN; {SCHEMA_0_3_0} PRAGMA user_version = 2; COMMIT;")
    with db:
        for sql, params in rows:
            db.execute(sql, params)
    db.close()


def tables(path: Path) -> set[str]:
    db = sqlite3.connect(path)
    try:
        return {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    finally:
        db.close()


def test_a_0_3_0_database_is_migrated_in_place(tmp_path: Path) -> None:
    path = tmp_path / "lrrp.sqlite3"
    create_0_3_0_database(path, ROWS_0_3_0)
    assert "settings" not in tables(path)
    assert "client_id" in columns(path, "jobs")

    store = Store(path)
    try:
        job = store.get_job(1)
        assert job is not None
        assert (job.client, job.label, job.client_id) == (
            "lr-plugin/0.3.0",
            "Selection",
            "catalog-1",
        )
        assert (job.state, job.seq, job.counts) == ("done", 3, {"ready": 1, "rejected": 1})
        assert store.cache_entry(KEY_A) is not None
        assert store.status(0, 0).built_today == 1
        assert store.settings() == {}
        store.save_settings({"paused": True, "workers": "auto"})
        assert store.settings() == {"paused": True, "workers": "auto"}
    finally:
        store.close()
    assert user_version(path) == SCHEMA_VERSION == 4
    assert "settings" in tables(path)

    store = Store(path)
    try:
        assert store.settings() == {"paused": True, "workers": "auto"}
        assert [j.client_id for j in store.list_jobs(10)] == ["catalog-1"]
    finally:
        store.close()


def test_the_server_starts_on_a_0_3_0_database(harness: Harness) -> None:
    create_0_3_0_database(harness.database, ROWS_0_3_0)
    with harness.client(workers=3, batch_size=8) as client:
        assert client.get("/api/v1/jobs/1").json()["job"]["clientId"] == "catalog-1"
        settings = client.get("/api/v1/settings").json()
        assert (settings["workers"], settings["batchSize"], settings["paused"]) == (3, 8, False)
        response = client.patch("/api/v1/settings", json={"paused": True, "batchSize": 2})
        assert response.status_code == 200
    with harness.client(workers=3, batch_size=8) as client:
        settings = client.get("/api/v1/settings").json()
        assert (settings["batchSize"], settings["paused"]) == (2, True)
        assert client.get("/api/v1/status").json()["state"] == "paused"
        assert [job["id"] for job in client.get("/api/v1/jobs").json()["jobs"]] == [1]
    assert user_version(harness.database) == SCHEMA_VERSION


def test_a_database_of_a_newer_server_is_refused(tmp_path: Path) -> None:
    path = tmp_path / "lrrp.sqlite3"
    db = sqlite3.connect(path)
    db.execute(f"PRAGMA user_version = {SCHEMA_VERSION + 1}")
    db.close()
    with pytest.raises(StoreError, match="newer server"):
        Store(path)


def test_the_server_starts_on_a_0_2_0_database(harness: Harness) -> None:
    raw = harness.raw("IMG_0002.ARW")
    info = raw.stat()
    key = sources.cache_key(
        "archive", "IMG_0002.ARW", info.st_size, info.st_mtime_ns, converter.recipe()
    )
    # The 0.2.0 server stopped with a finished job and one whose item was still queued.
    create_0_2_0_database(
        harness.database,
        [
            *OLD_ROWS,
            (
                "INSERT INTO jobs (id, client, label, state, created, seq)"
                " VALUES (2, NULL, NULL, 'active', ?, 1)",
                (T0 + 20,),
            ),
            (
                "INSERT INTO items (job_id, ref, root, path, state, seq, cache_key, size,"
                " mtime_ns, updated) VALUES (2, '0', 'archive', 'IMG_0002.ARW', 'queued', 1,"
                " ?, ?, ?, ?)",
                (key, info.st_size, info.st_mtime_ns, T0 + 20),
            ),
        ],
    )
    with harness.client() as client:
        job = wait_job(client, 2)
        assert job["clientId"] is None
        assert job["counts"]["ready"] == 1
        item = items_by_path(client, 2)["IMG_0002.ARW"]
        assert item["state"] == "ready"
        assert item["seq"] > 1
        assert item["result"]["key"] == key
        old = client.get("/api/v1/jobs/1").json()["job"]
        assert (old["client"], old["label"], old["clientId"]) == (
            "lr-plugin/0.2.0",
            "Selection",
            None,
        )
        new = post_job(client, ["photo.jpg"], clientId="mine")["job"]
        assert new["id"] == 3
        listed = client.get("/api/v1/jobs", params={"clientId": "mine"}).json()["jobs"]
        assert [job["id"] for job in listed] == [3]
    assert user_version(harness.database) == SCHEMA_VERSION


# The schema of server 0.4.0 (schema version 3), as it created a new database.
SCHEMA_0_4_0 = (
    SCHEMA_0_3_0
    + """
CREATE TABLE IF NOT EXISTS settings (
    name TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""
)

ROWS_0_4_0: list[tuple[str, tuple[object, ...]]] = [
    *ROWS_0_3_0,
    # A DNG whose job has expired: nothing says which original it was built from.
    (
        "INSERT INTO cache (key, size, sha256, original_name, original_width, original_height,"
        " created) VALUES (?, 2000, ?, 'IMG_0002.ARW', 6000, 4000, ?)",
        (KEY_B, "d" * 64, T0 + 1),
    ),
    ("INSERT INTO settings (name, value) VALUES ('paused', 'true')", ()),
]


def create_0_4_0_database(path: Path, rows: list[tuple[str, tuple[object, ...]]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path)
    db.executescript(f"BEGIN; {SCHEMA_0_4_0} PRAGMA user_version = 3; COMMIT;")
    with db:
        for sql, params in rows:
            db.execute(sql, params)
    db.close()


def test_a_0_4_0_database_is_migrated_in_place(tmp_path: Path) -> None:
    path = tmp_path / "lrrp.sqlite3"
    create_0_4_0_database(path, ROWS_0_4_0)
    assert "priority" not in columns(path, "jobs")
    assert {"used", "root", "path"}.isdisjoint(columns(path, "cache"))

    before = time.time()
    store = Store(path)
    after = time.time()
    try:
        job = store.get_job(1)
        assert job is not None
        assert (job.client_id, job.priority, job.state, job.seq) == (
            "catalog-1",
            "normal",
            "done",
            3,
        )
        # The original of an entry comes from an item that points to it; its use, which the
        # older server did not record, counts from the upgrade.
        [known] = store.cache_rows("a")
        assert (known.key, known.size) == (KEY_A, 1234)
        assert (known.root, known.path, known.source_size, known.source_mtime_ns) == (
            "archive",
            "IMG_0001.ARW",
            10,
            20,
        )
        assert before <= known.used <= after
        [unknown] = store.cache_rows("b")
        assert (unknown.root, unknown.path, unknown.source_size) == (None, None, None)
        assert before <= unknown.used <= after
        entry = store.cache_entry(KEY_A)
        assert entry is not None and entry.used == known.used
        assert store.settings() == {"paused": True}
        assert store.state("anything") is None
        assert store.failed_scan_keys([KEY_A, KEY_B]) == set()
        new, _ = store.create_job("x", None, [], T0 + 10, priority="background")
        assert (new.id, new.priority) == (2, "background")
        store.save_state("record", {"n": 1})
    finally:
        store.close()
    assert user_version(path) == SCHEMA_VERSION == 4
    assert {"priority"} <= columns(path, "jobs")
    assert {"root", "path", "source_size", "source_mtime_ns", "used"} <= columns(path, "cache")
    assert {"scan_failures", "state"} <= tables(path)

    # Opening it again changes nothing.
    store = Store(path)
    try:
        assert [(j.id, j.priority) for j in store.list_jobs(10)] == [
            (2, "background"),
            (1, "normal"),
        ]
        assert store.cache_rows("a") == [known]
        assert store.state("record") == {"n": 1}
    finally:
        store.close()


def test_the_server_starts_on_a_0_4_0_database(harness: Harness) -> None:
    create_0_4_0_database(harness.database, ROWS_0_4_0)
    with harness.client() as client:
        job = client.get("/api/v1/jobs/1").json()["job"]
        assert (job["priority"], job["clientId"]) == ("normal", "catalog-1")
        settings = client.get("/api/v1/settings").json()
        assert settings["paused"] is True
        assert settings["autoScan"]["enabled"] is False
        assert settings["cache"] == {"maxBytes": None, "maxAgeDays": None}
        status = client.get("/api/v1/status").json()
        assert status["cache"] == {"entries": 2, "bytes": 3234}
        assert status["autoScan"] == {
            "running": False,
            "lastRun": None,
            "lastQueued": 0,
            "nextRun": None,
        }
        new = post_job(client, ["photo.jpg"], priority="background")["job"]
        assert new["priority"] == "background"
    assert user_version(harness.database) == SCHEMA_VERSION


# --- Expired jobs ----------------------------------------------------------------------------


def rejected(ref: str = "0") -> NewItem:
    return NewItem(ref=ref, root="archive", path="photo.jpg", state="rejected", error_code="x")


def queued(key: str, ref: str = "0") -> NewItem:
    return NewItem(
        ref=ref,
        root="archive",
        path=f"{key[:4]}.ARW",
        state="queued",
        cache_key=key,
        size=1,
        mtime_ns=1,
    )


def entry(key: str) -> CacheEntry:
    return CacheEntry(key, 100, "d" * 64, "IMG.ARW", 6000, 4000, T0)


@pytest.fixture
def store(tmp_path: Path) -> Iterator[Store]:
    opened = Store(tmp_path / "lrrp.sqlite3")
    yield opened
    opened.close()


def state(store: Store, job_id: int) -> str | None:
    job = store.get_job(job_id)
    return None if job is None else job.state


def test_expired_jobs_are_deleted_with_their_items(store: Store) -> None:
    old = T0 - 40 * DAY
    done_old, done_items = store.create_job(None, None, [rejected()], old)
    done_recent, _ = store.create_job(None, None, [rejected()], T0 - 10 * DAY)
    built_old, built_items = store.create_job(None, None, [queued(KEY_A)], old)
    store.mark_building([KEY_A], old)
    store.complete(KEY_A, entry(KEY_A), old)
    active_old, _ = store.create_job(None, None, [queued("f" * 64)], old)
    cancelled_old, cancelled_items = store.create_job(None, None, [queued("e" * 64)], old)
    store.cancel_job(cancelled_old.id, old)
    building_old, _ = store.create_job(None, None, [queued(KEY_B)], old)
    store.mark_building([KEY_B], old)
    store.cancel_job(building_old.id, old)
    assert [state(store, job.id) for job in (built_old, active_old, building_old)] == [
        "done",
        "active",
        "cancelled",
    ]

    deleted = store.delete_expired_jobs(T0 - 30 * DAY)

    assert deleted == 3, "the old done, built and cancelled jobs"
    for job in (done_old, built_old, cancelled_old):
        assert store.get_job(job.id) is None
    for item in (done_items[0], built_items[0], cancelled_items[0]):
        assert store.get_item(item.id) is None
    assert state(store, done_recent.id) == "done"
    assert state(store, active_old.id) == "active", "an active job never expires"
    kept = store.get_job(building_old.id)
    assert kept is not None and kept.state == "cancelled", "its item is still building"
    # The cache index is not touched.
    assert store.cache_entry(KEY_A) == entry(KEY_A)

    store.complete(KEY_B, entry(KEY_B), T0)
    assert store.delete_expired_jobs(T0 - 30 * DAY) == 1
    assert store.get_job(building_old.id) is None
    assert store.delete_expired_jobs(T0 - 30 * DAY) == 0


def test_a_retried_job_does_not_expire_while_active(store: Store) -> None:
    old = T0 - 40 * DAY
    job, _ = store.create_job(None, None, [queued(KEY_A)], old)
    store.mark_building([KEY_A], old)
    store.fail(KEY_A, "converter_failed", "failed", old)
    failed = store.get_job(job.id)
    assert failed is not None and failed.state == "done" and failed.finished == old
    assert store.retry_job(job.id, {}, T0) == "retried"
    retried = store.get_job(job.id)
    assert retried is not None and retried.state == "active" and retried.finished is None
    assert store.delete_expired_jobs(T0) == 0


def test_expiry_runs_at_start_and_then_once_a_day(store: Store, tmp_path: Path) -> None:
    now = [T0]
    cache = Cache(tmp_path / "cache")
    runner = Runner(
        RunnerConfig(command_prefix=(sys.executable,), env={}), cache.new_work_dir, NoDisplay()
    )
    scheduler = Scheduler(
        store, cache, runner, (), 1, 1, clock=lambda: now[0], job_retention_days=30
    )
    expired, _ = store.create_job(None, None, [rejected()], T0 - 31 * DAY)
    soon, _ = store.create_job(None, None, [rejected()], T0 - 29.6 * DAY)

    assert scheduler.expire_jobs_if_due() == 1
    assert store.get_job(expired.id) is None
    now[0] += 0.5 * DAY  # "soon" is now older than 30 days, but the last clean-up was today
    assert scheduler.expire_jobs_if_due() == 0
    assert store.get_job(soon.id) is not None
    now[0] += 0.5 * DAY
    assert scheduler.expire_jobs_if_due() == 1
    assert store.get_job(soon.id) is None
    later, _ = store.create_job(None, None, [rejected()], now[0] - 31 * DAY)
    now[0] += DAY - 60
    assert scheduler.expire_jobs_if_due() == 0
    now[0] += 60
    assert scheduler.expire_jobs_if_due() == 1
    assert store.get_job(later.id) is None
