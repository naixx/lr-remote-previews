"""The cache of built DNGs: one file per cache key, ``<cache dir>/<key[0:2]>/<key>.dng``.

The converter writes into a batch folder under ``<cache dir>/work``, on the same file system, and
a finished DNG is renamed into place, so a reader never sees a partial file. The index (size,
SHA-256, the DNG's identity tags, its original, its last use) lives in the database
(``lrrp.store``); the clean-up (``lrrp.cleanup``) removes files and index rows together.
"""

import hashlib
import logging
import os
import re
import shutil
import stat
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from lrrp.dng import DngTags

log = logging.getLogger(__name__)

WORK_DIR_NAME = "work"
WORK_PREFIXES = ("batch-", "warm-up-")
"""Prefixes of the folders the runner makes under the work folder; only those are cleaned up."""

CACHE_KEY = re.compile(r"[0-9a-f]{64}")
"""A cache key: SHA-256 in lower-case hex (``lrrp.sources.cache_key``)."""


@dataclass(frozen=True)
class CacheEntry:
    key: str
    size: int
    sha256: str
    original_name: str | None
    original_width: int | None
    original_height: int | None
    created: float
    used: float | None = field(default=None, compare=False)
    """When the entry was last used, as the index records it (None: not read)."""


class Cache:
    def __init__(self, root: Path) -> None:
        # Absolute, because the converter gets the batch folders as Z:\ paths.
        self.root = Path(os.path.abspath(root))
        self.work = self.root / WORK_DIR_NAME

    def prepare(self) -> None:
        """Create the folders and remove batch folders a previous run left behind."""
        self.work.mkdir(parents=True, exist_ok=True)
        for entry in self.work.iterdir():
            if entry.is_dir() and entry.name.startswith(WORK_PREFIXES):
                shutil.rmtree(entry, ignore_errors=True)

    def path(self, key: str) -> Path:
        if not CACHE_KEY.fullmatch(key):
            raise ValueError(f"not a cache key: {key!r}")
        return self.root / key[:2] / f"{key}.dng"

    def has(self, key: str, size: int) -> bool:
        """Whether the DNG for ``key`` is on disk with the size the index recorded."""
        try:
            info = self.path(key).stat()
        except OSError:
            return False
        return stat.S_ISREG(info.st_mode) and info.st_size == size

    def store(self, key: str, produced: Path, tags: DngTags, now: float) -> CacheEntry:
        """Move a DNG the converter produced into the cache and describe it."""
        size, digest = file_digest(produced)
        target = self.path(key)
        target.parent.mkdir(exist_ok=True)
        os.replace(produced, target)
        return CacheEntry(
            key=key,
            size=size,
            sha256=digest,
            original_name=tags.original_name,
            original_width=tags.original_width,
            original_height=tags.original_height,
            created=now,
        )

    def remove(self, key: str) -> bool:
        """Delete the DNG for ``key``. True when it is gone, also when it was gone already."""
        try:
            self.path(key).unlink()
        except FileNotFoundError:
            return True
        except OSError as exc:
            log.warning("cannot delete the cached DNG %s: %s", self.path(key), exc)
            return False
        return True

    def names(self, prefix: str) -> set[str] | None:
        """The names in the folder of the keys that start with ``prefix`` (the first two
        characters of a key); None when that folder cannot be listed."""
        try:
            with os.scandir(self.root / prefix) as entries:
                return {entry.name for entry in entries}
        except FileNotFoundError:
            return set()
        except OSError as exc:
            log.warning("cannot list the cache folder %s: %s", self.root / prefix, exc)
            return None

    def new_work_dir(self, prefix: str) -> Path:
        if prefix not in WORK_PREFIXES:
            raise ValueError(f"unknown work folder prefix {prefix!r}")
        return Path(tempfile.mkdtemp(prefix=prefix, dir=self.work))


def file_digest(path: Path) -> tuple[int, str]:
    """Size and SHA-256 (lower-case hex) of a file."""
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as file:
        while chunk := file.read(1 << 20):
            digest.update(chunk)
            size += len(chunk)
    return size, digest.hexdigest()
