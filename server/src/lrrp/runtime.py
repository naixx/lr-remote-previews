"""Settings that can change while the server runs (``GET``/``PATCH /api/v1/settings``).

``workers``, ``batchSize``, ``paused``, ``workingHours``, ``autoScan`` and ``cache``. The
environment gives the first values of the first two (``LRRP_WORKERS``, ``LRRP_BATCH_SIZE``); the
others start as: not paused, no working hours, no automatic scan, no cache limits. A value changed
through the API is saved in the database and wins over the environment from then on; a value
that was never changed follows the environment, also after the environment changes.

The scheduler asks ``Controls`` before every wave: whether a wave may start now (not paused, and
inside the working hours if they are on), and with how many processes and files per batch.
Working hours are the server's local time; the clock is injectable for tests. The automatic scan
(``lrrp.autoscan``) and the cache clean-up (``lrrp.cleanup``) read their settings here too.
"""

import json
import logging
import re
import threading
from collections.abc import Callable, Collection, Mapping, Sequence
from dataclasses import dataclass, field, replace
from datetime import datetime
from typing import Any, Literal

from lrrp.settings import MAX_BATCH_SIZE, MAX_WORKERS, Settings, auto_workers
from lrrp.store import Store

log = logging.getLogger(__name__)

TIME_OF_DAY = re.compile(r"([01]\d|2[0-3]):([0-5]\d)")

SCAN_INTERVAL_MINUTES = (5, 1440)
SCAN_SETTLE_MINUTES = (0, 1440)
SCAN_MAX_FILES = (1, 50000)
MIN_CACHE_BYTES = 100 * 1024 * 1024
"""The smallest ``cache.maxBytes`` accepted: 100 MiB."""
CACHE_MAX_AGE_DAYS = (1, 3650)

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
class AutoScan:
    """The automatic scan (``lrrp.autoscan``)."""

    enabled: bool = False
    roots: tuple[str, ...] = ()
    """Ids of the roots to scan."""
    interval_minutes: int = 60
    settle_minutes: int = 15
    """A file modified less than this long ago is left alone (it may still be being copied)."""
    max_files_per_run: int = 2000

    def to_json(self) -> dict[str, Any]:
        return {
            "enabled": self.enabled,
            "roots": list(self.roots),
            "intervalMinutes": self.interval_minutes,
            "settleMinutes": self.settle_minutes,
            "maxFilesPerRun": self.max_files_per_run,
        }


@dataclass(frozen=True)
class CacheLimits:
    """The limits of the cache clean-up (``lrrp.cleanup``); None is no limit."""

    max_bytes: int | None = None
    max_age_days: int | None = None

    def to_json(self) -> dict[str, Any]:
        return {"maxBytes": self.max_bytes, "maxAgeDays": self.max_age_days}


@dataclass(frozen=True)
class RuntimeSettings:
    workers: int | None
    """Converter processes side by side; None is ``auto``."""
    batch_size: int
    paused: bool = False
    working_hours: WorkingHours = field(default_factory=WorkingHours)
    auto_scan: AutoScan = field(default_factory=AutoScan)
    cache: CacheLimits = field(default_factory=CacheLimits)

    def to_json(self) -> dict[str, Any]:
        """The values as the API and the database write them."""
        return {
            "workers": "auto" if self.workers is None else self.workers,
            "batchSize": self.batch_size,
            "paused": self.paused,
            "workingHours": self.working_hours.to_json(),
            "autoScan": self.auto_scan.to_json(),
            "cache": self.cache.to_json(),
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


def parse_auto_scan(value: object) -> AutoScan:
    """The form of ``autoScan``. Whether its roots exist is ``Controls.unknown_roots``."""
    names = ("enabled", "roots", "intervalMinutes", "settleMinutes", "maxFilesPerRun")
    value = _object(value, names)
    if not isinstance(value["enabled"], bool):
        raise ValueError('"enabled" must be true or false')
    roots = value["roots"]
    if not isinstance(roots, list) or not all(isinstance(root, str) for root in roots):
        raise ValueError('"roots" must be a list of root ids')
    return AutoScan(
        enabled=value["enabled"],
        roots=tuple(dict.fromkeys(roots)),
        interval_minutes=_whole(value, "intervalMinutes", *SCAN_INTERVAL_MINUTES),
        settle_minutes=_whole(value, "settleMinutes", *SCAN_SETTLE_MINUTES),
        max_files_per_run=_whole(value, "maxFilesPerRun", *SCAN_MAX_FILES),
    )


def parse_cache_limits(value: object) -> CacheLimits:
    value = _object(value, ("maxBytes", "maxAgeDays"))
    max_bytes = value["maxBytes"]
    if max_bytes is not None and (
        isinstance(max_bytes, bool) or not isinstance(max_bytes, int) or max_bytes < MIN_CACHE_BYTES
    ):
        raise ValueError(
            f'"maxBytes" must be null or a whole number of at least {MIN_CACHE_BYTES} (100 MiB)'
        )
    max_age = value["maxAgeDays"]
    if max_age is not None:
        low, high = CACHE_MAX_AGE_DAYS
        if isinstance(max_age, bool) or not isinstance(max_age, int) or not low <= max_age <= high:
            raise ValueError(f'"maxAgeDays" must be null or a whole number from {low} to {high}')
    return CacheLimits(max_bytes=max_bytes, max_age_days=max_age)


def _object(value: object, names: Sequence[str]) -> dict[str, Any]:
    """``value`` as an object that has every one of ``names`` (others are ignored)."""
    if not isinstance(value, dict):
        listed = ", ".join(f'"{name}"' for name in names[:-1])
        raise ValueError(f'must be an object with {listed} and "{names[-1]}"')
    missing = [name for name in names if name not in value]
    if missing:
        raise ValueError(f"{', '.join(repr(name) for name in missing)} missing")
    return value


def _whole(value: Mapping[str, Any], name: str, low: int, high: int) -> int:
    number = value[name]
    if isinstance(number, bool) or not isinstance(number, int) or not low <= number <= high:
        raise ValueError(f'"{name}" must be a whole number from {low} to {high}')
    return number


PARSERS: dict[str, tuple[str, Callable[[object], Any]]] = {
    "workers": ("workers", parse_workers),
    "batchSize": ("batch_size", parse_batch_size),
    "paused": ("paused", parse_paused),
    "workingHours": ("working_hours", parse_working_hours),
    "autoScan": ("auto_scan", parse_auto_scan),
    "cache": ("cache", parse_cache_limits),
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
        root_ids: Collection[str] | None = None,
    ) -> None:
        """``defaults`` come from the environment; ``store`` keeps changes (None: memory only);
        ``root_ids`` are the roots the server has (None: any root id is accepted)."""
        self._defaults = defaults
        self._cpu_count = cpu_count
        self._store = store
        self._clock = clock
        self._root_ids = None if root_ids is None else frozenset(root_ids)
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
        return cls(
            defaults,
            settings.cpu_count,
            store,
            clock or local_now,
            root_ids=[root.id for root in settings.roots],
        )

    def _load(self) -> RuntimeSettings:
        current = self._defaults
        if self._store is None:
            return current
        for name, value in self._store.settings().items():
            if name not in PARSERS:
                continue
            attribute, parse = PARSERS[name]
            try:
                parsed = parse(value)
            except ValueError as exc:
                log.warning("ignoring the saved setting %s (%s); using %r", name, exc, value)
                continue
            if isinstance(parsed, AutoScan):
                unknown = self.unknown_roots(parsed.roots)
                if unknown:
                    # A root taken out of the configuration: scan the others.
                    log.warning(
                        "the automatic scan names root(s) the server no longer has: %s; "
                        "scanning the others",
                        ", ".join(unknown),
                    )
                    kept = tuple(root for root in parsed.roots if root not in unknown)
                    parsed = replace(parsed, roots=kept)
            current = replace(current, **{attribute: parsed})
        return current

    def unknown_roots(self, roots: Sequence[str]) -> list[str]:
        """The ids among ``roots`` that name no root of the server."""
        if self._root_ids is None:
            return []
        return [root for root in roots if root not in self._root_ids]

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
    if isinstance(value, dict) and set(value) == {"enabled", "from", "to"}:
        return f"{value['from']}-{value['to']} ({'on' if value['enabled'] else 'off'})"
    if isinstance(value, dict):
        return json.dumps(value)
    if isinstance(value, bool):
        return "on" if value else "off"
    return str(value)


def _minutes(text: str) -> int:
    match = TIME_OF_DAY.fullmatch(text)
    if match is None:
        raise ValueError(f"not a time of day: {text!r}")
    return int(match[1]) * 60 + int(match[2])
