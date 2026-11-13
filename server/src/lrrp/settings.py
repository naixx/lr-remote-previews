"""Server settings: environment variables, plus an optional YAML file that lists the roots.

The roots are the folders with originals, as the container sees them. The YAML file is named by
``LRRP_CONFIG``::

    roots:
      - id: archive
        path: /sources/archive
        label: Archive
"""

import os
import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Self

import yaml

from lrrp.converter import DEFAULT_CONVERTER_EXE, is_drive_c_path

DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 8787
DEFAULT_DATA_DIR = "/data"
DEFAULT_CACHE_DIR = "/cache"
DEFAULT_WEB_DIR = "/app/web"
DEFAULT_BATCH_SIZE = 8
MAX_BATCH_SIZE = 64
DEFAULT_JOB_RETENTION_DAYS = 30

ROOT_ID_PATTERN = re.compile(r"[a-z0-9][a-z0-9_-]{0,31}")
ROOT_ID_RULE = "1 to 32 lower-case letters, digits, '-' or '_', starting with a letter or digit"


class SettingsError(ValueError):
    """The configuration is invalid. The message says what to fix."""


@dataclass(frozen=True)
class Root:
    """A folder with originals. ``path`` is server-side and never leaves the server."""

    id: str
    path: Path
    label: str


@dataclass(frozen=True)
class Settings:
    host: str
    port: int
    token: str | None
    data_dir: Path
    cache_dir: Path
    web_dir: Path
    wineprefix: Path
    converter_exe: str
    roots: tuple[Root, ...]
    workers: int = 1
    batch_size: int = DEFAULT_BATCH_SIZE
    job_retention_days: int = DEFAULT_JOB_RETENTION_DAYS

    @classmethod
    def from_env(
        cls, environ: Mapping[str, str] | None = None, *, cpu_count: int | None = None
    ) -> Self:
        """Read the settings from ``environ`` (default: the process environment).

        An empty variable counts as unset. ``cpu_count`` replaces the number of CPU threads the
        process may use (for ``LRRP_WORKERS=auto``). Raises ``SettingsError`` for invalid values.
        """
        env = os.environ if environ is None else environ

        def get(name: str) -> str | None:
            value = env.get(name, "").strip()
            return value or None

        data_dir = Path(get("LRRP_DATA_DIR") or DEFAULT_DATA_DIR)
        wineprefix = get("LRRP_WINEPREFIX")
        converter_exe = get("LRRP_CONVERTER_EXE") or DEFAULT_CONVERTER_EXE
        if not is_drive_c_path(converter_exe):
            raise SettingsError(
                "LRRP_CONVERTER_EXE must be an absolute Windows path on drive C: of the Wine "
                f"prefix, such as {DEFAULT_CONVERTER_EXE!r}; got {converter_exe!r}"
            )
        config = get("LRRP_CONFIG")
        cache_dir = Path(get("LRRP_CACHE_DIR") or DEFAULT_CACHE_DIR)
        roots = load_roots(Path(config)) if config else ()
        _reject_dirs_under_roots({"LRRP_DATA_DIR": data_dir, "LRRP_CACHE_DIR": cache_dir}, roots)
        return cls(
            host=get("LRRP_HOST") or DEFAULT_HOST,
            port=_parse_port(get("LRRP_PORT")),
            token=get("LRRP_TOKEN"),
            data_dir=data_dir,
            cache_dir=cache_dir,
            web_dir=Path(get("LRRP_WEB_DIR") or DEFAULT_WEB_DIR),
            wineprefix=Path(wineprefix) if wineprefix else data_dir / "wine",
            converter_exe=converter_exe,
            roots=roots,
            workers=_parse_workers(
                get("LRRP_WORKERS"), available_cpus() if cpu_count is None else cpu_count
            ),
            batch_size=_parse_batch_size(get("LRRP_BATCH_SIZE")),
            job_retention_days=_parse_job_retention_days(get("LRRP_JOB_RETENTION_DAYS")),
        )


def auto_workers(cpu_count: int) -> int:
    """The number of converter processes ``LRRP_WORKERS=auto`` chooses for ``cpu_count`` threads.

    Never 2: two converter processes side by side take twice the CPU time per photo.
    """
    if cpu_count >= 16:
        return 6
    if cpu_count >= 8:
        return 4
    if cpu_count >= 6:
        return 3
    return 1


def available_cpus() -> int:
    """CPU threads this process may run on (the container's CPU set, where the OS tells it)."""
    try:
        return len(os.sched_getaffinity(0))
    except AttributeError:  # not on Linux
        return os.cpu_count() or 1


def _parse_workers(value: str | None, cpu_count: int) -> int:
    if value is None or value.lower() == "auto":
        return auto_workers(cpu_count)
    try:
        workers = int(value)
    except ValueError:
        raise SettingsError(f"LRRP_WORKERS must be 'auto' or a number, got {value!r}") from None
    if workers < 1:
        raise SettingsError(f"LRRP_WORKERS must be at least 1, got {workers}")
    if workers == 2:
        raise SettingsError(
            "LRRP_WORKERS=2 is not allowed: two converter processes side by side take twice the "
            "CPU time per photo (measured with Adobe DNG Converter 17.2 under Wine 8.0; the cause "
            "is unknown). Use 1, or 3 or more, or 'auto'"
        )
    return workers


def _parse_batch_size(value: str | None) -> int:
    if value is None:
        return DEFAULT_BATCH_SIZE
    try:
        size = int(value)
    except ValueError:
        raise SettingsError(f"LRRP_BATCH_SIZE must be a number, got {value!r}") from None
    if not 1 <= size <= MAX_BATCH_SIZE:
        raise SettingsError(f"LRRP_BATCH_SIZE must be between 1 and {MAX_BATCH_SIZE}, got {size}")
    return size


def _parse_job_retention_days(value: str | None) -> int:
    if value is None:
        return DEFAULT_JOB_RETENTION_DAYS
    try:
        days = int(value)
    except ValueError:
        raise SettingsError(
            f"LRRP_JOB_RETENTION_DAYS must be a whole number of days, got {value!r}"
        ) from None
    if days < 1:
        raise SettingsError(f"LRRP_JOB_RETENTION_DAYS must be at least 1, got {days}")
    return days


def _reject_dirs_under_roots(dirs: Mapping[str, Path], roots: tuple[Root, ...]) -> None:
    # The server writes into these folders; nothing may ever be written under a root.
    for name, folder in dirs.items():
        for root in roots:
            if _is_within(folder, root.path):
                raise SettingsError(
                    f"{name} ({folder}) is inside the root {root.id!r}; the server writes there, "
                    "and it never writes under a root of originals"
                )


def _is_within(path: Path, root: Path) -> bool:
    if path.is_relative_to(root):
        return True
    try:
        return Path(os.path.realpath(path)).is_relative_to(os.path.realpath(root))
    except (OSError, ValueError):
        return False


def _parse_port(value: str | None) -> int:
    if value is None:
        return DEFAULT_PORT
    try:
        port = int(value)
    except ValueError:
        raise SettingsError(f"LRRP_PORT must be a number, got {value!r}") from None
    if not 1 <= port <= 65535:
        raise SettingsError(f"LRRP_PORT must be between 1 and 65535, got {port}")
    return port


def load_roots(path: Path) -> tuple[Root, ...]:
    """Read the roots from the YAML file at ``path``. Raises ``SettingsError`` when invalid."""
    where = f"LRRP_CONFIG {path}"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise SettingsError(f"{where}: cannot read the file: {exc.strerror or exc}") from exc
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        raise SettingsError(f"{where}: not valid YAML: {exc}") from exc
    if data is None:
        return ()
    if not isinstance(data, dict):
        raise SettingsError(f"{where}: expected a mapping with a 'roots' list at the top level")
    _reject_unknown_keys(data, {"roots"}, where)
    entries = data.get("roots")
    if entries is None:
        return ()
    if not isinstance(entries, list):
        raise SettingsError(f"{where}: 'roots' must be a list")
    roots: list[Root] = []
    for index, entry in enumerate(entries):
        root = _parse_root(entry, f"{where}: roots[{index}]")
        if any(existing.id == root.id for existing in roots):
            raise SettingsError(f"{where}: roots[{index}]: duplicate id {root.id!r}")
        roots.append(root)
    return tuple(roots)


def _parse_root(entry: Any, where: str) -> Root:
    if not isinstance(entry, dict):
        raise SettingsError(f"{where}: expected a mapping with 'id' and 'path'")
    _reject_unknown_keys(entry, {"id", "path", "label"}, where)
    if "id" not in entry:
        raise SettingsError(f"{where}: 'id' is missing")
    root_id = entry["id"]
    if not isinstance(root_id, str) or not ROOT_ID_PATTERN.fullmatch(root_id):
        raise SettingsError(f"{where}: id {root_id!r} is not valid; use {ROOT_ID_RULE}")
    path = entry.get("path")
    if not isinstance(path, str) or not path.strip():
        raise SettingsError(f"{where} ({root_id}): 'path' must be a non-empty string")
    if not _is_absolute(path):
        raise SettingsError(
            f"{where} ({root_id}): path {path!r} must be absolute: the folder as the server "
            "sees it, such as /sources/archive"
        )
    label = entry.get("label")
    if label is None:
        label = root_id
    if not isinstance(label, str) or not label.strip():
        raise SettingsError(f"{where} ({root_id}): 'label' must be a non-empty string")
    return Root(id=root_id, path=Path(path), label=label.strip())


def _reject_unknown_keys(mapping: dict[Any, Any], allowed: set[str], where: str) -> None:
    unknown = sorted(str(key) for key in mapping if key not in allowed)
    if unknown:
        raise SettingsError(
            f"{where}: unknown key(s) {', '.join(unknown)}; allowed: {', '.join(sorted(allowed))}"
        )


def _is_absolute(path: str) -> bool:
    # Roots are container (POSIX) paths; also accept native absolute paths for local runs.
    return path.startswith("/") or Path(path).is_absolute()
