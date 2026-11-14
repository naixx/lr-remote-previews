"""The contents of folders under a root: browsing (``GET /api/v1/browse``) and the raw files of a
folder to queue (``POST /api/v1/folders``).

The same rules everywhere:

- names that start with a dot are skipped (hidden folders, and files such as macOS's ``._x.ARW``
  that carry a raw extension without being raw files);
- symbolic links are neither followed nor counted: a link is not a folder or a file of the folder
  here (``Resolver.resolve_folder`` has made sure the folder itself lies inside its root);
- a name a client could not send back as a path (``sources.path_problem``: a backslash, text
  that is not Unicode, a path that would be too long) is never offered: such a folder is not
  listed or entered, such a file counts among the other files.

Each raw file costs one ``stat`` (for its size and modification time, which make its cache key);
everything else comes from the directory listing itself.
"""

import logging
import os
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

from lrrp.converter import RAW_EXTENSIONS
from lrrp.sources import Folder, path_problem

log = logging.getLogger(__name__)


@dataclass(frozen=True)
class RawFile:
    path: str
    """Relative to the root."""
    size: int
    mtime_ns: int


@dataclass(frozen=True)
class Listing:
    dirs: list[str]
    """The names of the sub-folders, sorted without regard to case."""
    raw: list[RawFile]
    """The raw files directly in the folder, sorted by name without regard to case."""
    other: int
    """How many other files are directly in the folder."""


class TooManyFiles(Exception):
    """A folder (with its sub-folders) holds more raw files than the limit."""


class FolderUnreadable(Exception):
    """The folder cannot be listed."""


def list_folder(folder: Folder, extensions: Sequence[str] = RAW_EXTENSIONS) -> Listing:
    """What is directly in a folder. Raises ``FolderUnreadable``."""
    try:
        return _scan(folder.folder, folder.path, extensions)
    except OSError as exc:
        raise FolderUnreadable(str(exc.strerror or exc)) from exc


def find_raw_files(
    folder: Folder,
    *,
    recursive: bool,
    limit: int,
    extensions: Sequence[str] = RAW_EXTENSIONS,
) -> list[RawFile]:
    """The raw files of a folder (and, when ``recursive``, of all its sub-folders): the files of a
    folder first, then those of each sub-folder in name order.

    Raises ``TooManyFiles`` as soon as more than ``limit`` are found, ``FolderUnreadable`` when
    the folder itself cannot be listed. A sub-folder that cannot be listed is skipped.
    """
    found: list[RawFile] = []
    pending: list[tuple[Path, str]] = [(folder.folder, folder.path)]
    first = True
    while pending:
        directory, path = pending.pop()
        try:
            listing = _scan(directory, path, extensions)
        except OSError as exc:
            if first:
                raise FolderUnreadable(str(exc.strerror or exc)) from exc
            log.warning("cannot list the folder %r under its root: %s", path, exc.strerror or exc)
            continue
        first = False
        found.extend(listing.raw)
        if len(found) > limit:
            raise TooManyFiles
        if recursive:
            for name in reversed(listing.dirs):
                pending.append((directory / name, f"{path}/{name}" if path else name))
    return found


def _scan(directory: Path, path: str, extensions: Sequence[str]) -> Listing:
    dirs: list[str] = []
    raw: list[RawFile] = []
    other = 0
    with os.scandir(directory) as entries:
        for entry in entries:
            name = entry.name
            if name.startswith("."):
                continue
            try:
                if entry.is_symlink() or getattr(entry, "is_junction", _no)():
                    continue
                is_dir = entry.is_dir(follow_symlinks=False)
                is_file = not is_dir and entry.is_file(follow_symlinks=False)
            except OSError:
                continue
            relative = f"{path}/{name}" if path else name
            acceptable = path_problem(relative) is None
            if is_dir:
                if acceptable:
                    dirs.append(name)
            elif is_file:
                if acceptable and PurePosixPath(name).suffix.lower() in extensions:
                    try:
                        info = entry.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    raw.append(RawFile(relative, info.st_size, info.st_mtime_ns))
                else:
                    other += 1
    dirs.sort(key=_by_name)
    raw.sort(key=lambda file: _by_name(file.path.rsplit("/", 1)[-1]))
    return Listing(dirs=dirs, raw=raw, other=other)


def _by_name(name: str) -> tuple[str, str]:
    return name.casefold(), name


def _no() -> bool:
    return False
