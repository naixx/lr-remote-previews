"""Settings that can change while the server runs (``GET``/``PATCH /api/v1/settings``).

``workers``, ``batchSize``, ``paused`` and ``workingHours``. The environment gives their first
values (``LRRP_WORKERS``, ``LRRP_BATCH_SIZE``; not paused; no working hours). A value changed
through the API is saved in the database and wins over the environment from then on; a value
that was never changed follows the environment, also after the environment changes.

The scheduler asks ``Controls`` before every wave: whether a wave may start now (not paused, and
inside the working hours if they are on), and with how many processes and files per batch.
Working hours are the server's local time; the clock is injectable for tests.
"""

import logging
import re
import threading
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field, replace
from datetime import datetime
from typing import Any, Literal

from lrrp.settings import MAX_BATCH_SIZE, MAX_WORKERS, Settings, auto_workers
from lrrp.store import Store

log = logging.getLogger(__name__)

TIME_OF_DAY = re.compile(r"([01]\d|2[0-3]):([0-5]\d)")

Gate = Literal["open", "paused", "waiting"]
"""Whether a wave may start: ``open``, or not because of ``paused`` or the working hours."""


def local_now() -> datetime:
    return datetime.now().astimezone()


@dataclass(frozen=True)
class WorkingHours:
    """Waves start only from ``start`` up to (not including) ``end``, when ``enabled``.

    ``start`` later than ``end`` is a window across midnight.
    """

    enabled: bool = False
    start: str = "22:00"
    end: str = "07:00"

    def allows(self, moment: datetime) -> bool:
        if not self.enabled:
            return True
        start, end = _minutes(self.start), _minutes(self.end)
        now = moment.hour * 60 + moment.minute + (moment.second + moment.microsecond / 1e6) / 60
        if start < end:
            return start <= now < end
        return now >= start or now < end

    def to_json(self) -> dict[str, Any]:
        return {"enabled": self.enabled, "from": self.start, "to": self.end}


@dataclass(frozen=True)
class RuntimeSettings:
    workers: int | None
    """Converter processes side by side; None is ``auto``."""
    batch_size: int
    paused: bool = False
    working_hours: WorkingHours = field(default_factory=WorkingHours)

    def to_json(self) -> dict[str, Any]:
        """The values as the API and the database write them."""
        return {
            "workers": "auto" if self.workers is None else self.workers,
            "batchSize": self.batch_size,
            "paused": self.paused,
            "workingHours": self.working_hours.to_json(),
        }


# --- Checking values -------------------------------------------------------------------------
# Each takes a value as it comes from JSON and returns it for RuntimeSettings, or raises
# ValueError with a message for a person.


def parse_workers(value: object) -> int | None:
    if value == "auto":
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f'must be "auto" or a whole number from 1 to {MAX_WORKERS}')
    if value == 2:
        raise ValueError(
            "2 is not allowed: two converter processes side by side take twice the CPU time per "
            f'photo. Use 1, 3 to {MAX_WORKERS}, or "auto"'
        )
    if not 1 <= value <= MAX_WORKERS:
        raise ValueError(f'must be "auto" or a whole number from 1 to {MAX_WORKERS}')
    return value


def parse_batch_size(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= MAX_BATCH_SIZE:
        raise ValueError(f"must be a whole number from 1 to {MAX_BATCH_SIZE}")
    return value


def parse_paused(value: object) -> bool:
    if not isinstance(value, bool):
        raise ValueError("must be true or false")
    return value


def parse_working_hours(value: object) -> WorkingHours:
    if not isinstance(value, dict):
        raise ValueError('must be an object with "enabled", "from" and "to"')
    missing = [name for name in ("enabled", "from", "to") if name not in value]
    if missing:
        raise ValueError(f"{', '.join(repr(name) for name in missing)} missing")
    if not isinstance(value["enabled"], bool):
        raise ValueError('"enabled" must be true or false')
    for name in ("from", "to"):
        text = value[name]
        if not isinstance(text, str) or not TIME_OF_DAY.fullmatch(text):
            raise ValueError(f'"{name}" must be a time of day as HH:MM, 00:00 to 23:59')
    if value["from"] == value["to"]:
        raise ValueError('"from" and "to" must differ')
    return WorkingHours(enabled=value["enabled"], start=value["from"], end=value["to"])


PARSERS: dict[str, tuple[str, Callable[[object], Any]]] = {
    "workers": ("workers", parse_workers),
    "batchSize": ("batch_size", parse_batch_size),
    "paused": ("paused", parse_paused),
    "workingHours": ("working_hours", parse_working_hours),
}
"""The settings by their API name: the field of RuntimeSettings and the check of a value."""


# --- The current settings --------------------------------------------------------------------


class Controls:
    def __init__(
        self,
        defaults: RuntimeSettings,
        cpu_count: int,
        store: Store | None = None,
        clock: Callable[[], datetime] = local_now,
    ) -> None:
        """``defaults`` come from the environment; ``store`` keeps changes (None: memory only)."""
        self._defaults = defaults
        self._cpu_count = cpu_count
        self._store = store
        self._clock = clock
        self._lock = threading.Lock()
        self._current = self._load()

    @classmethod
    def from_settings(
        cls, settings: Settings, store: Store | None, clock: Callable[[], datetime] | None = None
    ) -> "Controls":
        defaults = RuntimeSettings(
            workers=None if settings.workers_auto else settings.workers,
            batch_size=settings.batch_size,
        )
        return cls(defaults, settings.cpu_count, store, clock or local_now)

    def _load(self) -> RuntimeSettings:
        current = self._defaults
        if self._store is None:
            return current
        for name, value in self._store.settings().items():
            if name not in PARSERS:
                continue
            attribute, parse = PARSERS[name]
            try:
                current = replace(current, **{attribute: parse(value)})
            except ValueError as exc:
                log.warning("ignoring the saved setting %s (%s); using %r", name, exc, value)
        return current

    def current(self) -> RuntimeSettings:
        with self._lock:
            return self._current

    def effective_workers(self, current: RuntimeSettings | None = None) -> int:
        """What ``workers`` comes to on this machine."""
        workers = (current or self.current()).workers
        return auto_workers(self._cpu_count) if workers is None else workers

    def update(self, changes: Mapping[str, Any]) -> RuntimeSettings:
        """Apply checked values (by API name, as the ``parse_*`` functions return them)."""
        with self._lock:
            before = self._current
            values = {PARSERS[name][0]: value for name, value in changes.items()}
            after = replace(before, **values)
            if self._store is not None and changes:
                saved = after.to_json()
                self._store.save_settings({name: saved[name] for name in changes})
            self._current = after
        old, new = before.to_json(), after.to_json()
        changed = [
            f"{name} {_shown(old[name])} -> {_shown(new[name])}"
            for name in changes
            if old[name] != new[name]
        ]
        if changed:
            log.info("settings changed: %s", "; ".join(changed))
        return after

    def gate(self, current: RuntimeSettings | None = None) -> Gate:
        """Whether a new wave may start now."""
        current = current or self.current()
        if current.paused:
            return "paused"
        if not current.working_hours.allows(self._clock()):
            return "waiting"
        return "open"


def _shown(value: object) -> str:
    if isinstance(value, dict):
        return f"{value['from']}-{value['to']} ({'on' if value['enabled'] else 'off'})"
    if isinstance(value, bool):
        return "on" if value else "off"
    return str(value)


def _minutes(text: str) -> int:
    match = TIME_OF_DAY.fullmatch(text)
    if match is None:
        raise ValueError(f"not a time of day: {text!r}")
    return int(match[1]) * 60 + int(match[2])
