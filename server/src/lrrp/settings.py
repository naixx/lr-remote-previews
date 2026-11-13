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

    @classmethod
    def from_env(cls, environ: Mapping[str, str] | None = None) -> Self:
        """Read the settings from ``environ`` (default: the process environment).

        An empty variable counts as unset. Raises ``SettingsError`` for invalid values.
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
        return cls(
            host=get("LRRP_HOST") or DEFAULT_HOST,
            port=_parse_port(get("LRRP_PORT")),
            token=get("LRRP_TOKEN"),
            data_dir=data_dir,
            cache_dir=Path(get("LRRP_CACHE_DIR") or DEFAULT_CACHE_DIR),
            web_dir=Path(get("LRRP_WEB_DIR") or DEFAULT_WEB_DIR),
            wineprefix=Path(wineprefix) if wineprefix else data_dir / "wine",
            converter_exe=converter_exe,
            roots=load_roots(Path(config)) if config else (),
        )


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
