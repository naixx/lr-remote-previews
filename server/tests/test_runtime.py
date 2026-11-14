"""Runtime settings: working hours, the checks of each value, keeping changes, the wave gate."""

from collections.abc import Iterator
from datetime import datetime
from pathlib import Path
from typing import Any

import pytest

from lrrp.runtime import (
    Controls,
    RuntimeSettings,
    WorkingHours,
    parse_batch_size,
    parse_paused,
    parse_workers,
    parse_working_hours,
)
from lrrp.settings import Settings, auto_workers
from lrrp.store import Store


def at(hour: int, minute: int = 0, second: int = 0, microsecond: int = 0) -> datetime:
    return datetime(2026, 11, 14, hour, minute, second, microsecond)


@pytest.mark.parametrize(
    ("moment", "inside"),
    [
        (at(21, 59, 59, 999999), False),
        (at(22, 0), True),
        (at(23, 59, 59), True),
        (at(0, 0), True),
        (at(6, 59, 59, 999999), True),
        (at(7, 0), False),
        (at(12, 0), False),
    ],
)
def test_a_window_across_midnight(moment: datetime, inside: bool) -> None:
    assert WorkingHours(enabled=True, start="22:00", end="07:00").allows(moment) is inside


@pytest.mark.parametrize(
    ("moment", "inside"),
    [
        (at(8, 59, 59), False),
        (at(9, 0), True),
        (at(16, 59, 59), True),
        (at(17, 0), False),
        (at(0, 0), False),
        (at(23, 59), False),
    ],
)
def test_a_window_within_a_day(moment: datetime, inside: bool) -> None:
    assert WorkingHours(enabled=True, start="09:00", end="17:00").allows(moment) is inside


def test_minute_windows_and_disabled_hours() -> None:
    hours = WorkingHours(enabled=True, start="23:59", end="00:00")
    assert hours.allows(at(23, 59)) and hours.allows(at(23, 59, 59))
    assert not hours.allows(at(0, 0)) and not hours.allows(at(23, 58, 59))
    assert WorkingHours(enabled=False, start="09:00", end="10:00").allows(at(3, 0))


@pytest.mark.parametrize(("value", "expected"), [("auto", None), (1, 1), (3, 3), (32, 32)])
def test_workers_values(value: object, expected: int | None) -> None:
    assert parse_workers(value) == expected


@pytest.mark.parametrize(
    ("value", "message"),
    [
        (2, "2 is not allowed"),
        (0, "from 1 to 32"),
        (33, "from 1 to 32"),
        (-1, "from 1 to 32"),
        (True, "from 1 to 32"),
        (3.0, "from 1 to 32"),
        ("3", "from 1 to 32"),
        ("AUTO", "from 1 to 32"),
        (None, "from 1 to 32"),
    ],
)
def test_bad_workers(value: object, message: str) -> None:
    with pytest.raises(ValueError, match=message):
        parse_workers(value)


def test_batch_size_and_paused() -> None:
    assert parse_batch_size(1) == 1 and parse_batch_size(64) == 64
    for bad in (0, 65, True, 8.0, "8", None):
        with pytest.raises(ValueError, match="from 1 to 64"):
            parse_batch_size(bad)
    assert parse_paused(True) is True and parse_paused(False) is False
    for bad in (1, 0, "true", None):
        with pytest.raises(ValueError, match="true or false"):
            parse_paused(bad)


def test_working_hours_values() -> None:
    value = {"enabled": True, "from": "22:00", "to": "07:00", "unknown": 1}
    assert parse_working_hours(value) == WorkingHours(True, "22:00", "07:00")
    assert parse_working_hours({"enabled": False, "from": "00:00", "to": "23:59"}) == WorkingHours(
        False, "00:00", "23:59"
    )


@pytest.mark.parametrize(
    ("value", "message"),
    [
        (None, "must be an object"),
        ([], "must be an object"),
        ({"enabled": True, "from": "22:00"}, "'to' missing"),
        ({}, "'enabled', 'from', 'to' missing"),
        ({"enabled": "yes", "from": "22:00", "to": "07:00"}, '"enabled" must be true or false'),
        ({"enabled": True, "from": "24:00", "to": "07:00"}, '"from" must be a time of day'),
        ({"enabled": True, "from": "7:00", "to": "08:00"}, '"from" must be a time of day'),
        ({"enabled": True, "from": "22:00", "to": "07:60"}, '"to" must be a time of day'),
        ({"enabled": True, "from": "22:00", "to": 700}, '"to" must be a time of day'),
        ({"enabled": True, "from": "22:00:00", "to": "07:00"}, '"from" must be a time of day'),
        ({"enabled": True, "from": "08:00", "to": "08:00"}, "must differ"),
        ({"enabled": False, "from": "08:00", "to": "08:00"}, "must differ"),
    ],
)
def test_bad_working_hours(value: Any, message: str) -> None:
    with pytest.raises(ValueError, match=message):
        parse_working_hours(value)


@pytest.fixture
def store(tmp_path: Path) -> Iterator[Store]:
    opened = Store(tmp_path / "lrrp.sqlite3")
    yield opened
    opened.close()


def test_changes_are_kept_and_unchanged_values_follow_the_environment(store: Store) -> None:
    first = Controls(RuntimeSettings(workers=4, batch_size=8), cpu_count=8, store=store)
    assert first.current() == RuntimeSettings(workers=4, batch_size=8)
    hours = WorkingHours(True, "22:00", "07:00")
    first.update({"batchSize": 16, "workingHours": hours})
    assert store.settings() == {
        "batchSize": 16,
        "workingHours": {"enabled": True, "from": "22:00", "to": "07:00"},
    }
    # The environment now says 6 workers and batches of 4: the batch size was changed through
    # the API and keeps its value, the number of workers follows the environment.
    again = Controls(RuntimeSettings(workers=6, batch_size=4), cpu_count=8, store=store)
    assert again.current() == RuntimeSettings(
        workers=6, batch_size=16, paused=False, working_hours=hours
    )
    again.update({"workers": None})
    assert again.effective_workers() == auto_workers(8)
    third = Controls(RuntimeSettings(workers=6, batch_size=4), cpu_count=16, store=store)
    assert third.current().workers is None
    assert third.effective_workers() == auto_workers(16)


def test_a_broken_saved_value_falls_back_to_the_default(store: Store) -> None:
    store.save_settings({"workers": 2, "batchSize": "many", "paused": True, "other": 1})
    controls = Controls(RuntimeSettings(workers=3, batch_size=8), cpu_count=4, store=store)
    assert controls.current() == RuntimeSettings(workers=3, batch_size=8, paused=True)


def test_defaults_from_the_environment() -> None:
    auto = Controls.from_settings(Settings.from_env({}, cpu_count=8), None)
    assert auto.current() == RuntimeSettings(workers=None, batch_size=8)
    assert auto.effective_workers() == 4
    fixed = Controls.from_settings(
        Settings.from_env({"LRRP_WORKERS": "3", "LRRP_BATCH_SIZE": "5"}, cpu_count=8), None
    )
    assert fixed.current() == RuntimeSettings(workers=3, batch_size=5)


def test_the_gate() -> None:
    now = [at(12, 0)]
    controls = Controls(RuntimeSettings(workers=1, batch_size=1), cpu_count=1, clock=lambda: now[0])
    assert controls.gate() == "open"
    controls.update({"workingHours": WorkingHours(True, "22:00", "07:00")})
    assert controls.gate() == "waiting"
    now[0] = at(22, 0)
    assert controls.gate() == "open"
    controls.update({"paused": True})
    assert controls.gate() == "paused"
    now[0] = at(12, 0)
    assert controls.gate() == "paused", "paused wins over the working hours"
