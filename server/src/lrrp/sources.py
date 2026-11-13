"""The files a client asks for: checking a root id and a relative path, and the cache key.

A client names a file by a root id and a path relative to that root (``docs/protocol.md``,
«Paths»). ``resolve`` turns that into a regular file under the root or a rejection with one of
the protocol's codes. Nothing here opens an original; ``stat`` is all it does.

The cache key is the source's identity (decision record 0003): root id, relative path, size and
modification time, plus the recipe (how the DNG is made), so new converter options rebuild.
"""

import hashlib
import json
import os
import stat
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

from lrrp.converter import RAW_EXTENSIONS
from lrrp.settings import Root

MAX_PATH_LENGTH = 4096
"""Longest relative path accepted, in characters."""

CACHE_KEY_VERSION = "lrrp-cache-key/1"


@dataclass(frozen=True)
class Source:
    """A file a client may have built: a regular file under a root, with its identity."""

    root: str
    path: str
    file: Path
    size: int
    mtime_ns: int

    @property
    def name(self) -> str:
        """The file's base name with its extension, such as ``IMG_0001.ARW``."""
        return self.path.rsplit("/", 1)[-1]


@dataclass(frozen=True)
class Rejection:
    """Why a requested file is not acceptable; ``code`` is one of the protocol's codes."""

    code: str
    message: str


def path_problem(path: str) -> str | None:
    """What is wrong with a relative path from a client, or None when its form is acceptable."""
    if path == "":
        return "The path is empty"
    if len(path) > MAX_PATH_LENGTH:
        return f"The path is longer than {MAX_PATH_LENGTH} characters"
    if "\x00" in path:
        return "The path contains a NUL character"
    if "\\" in path:
        return "The path contains a backslash; separate folders with forward slashes"
    if path.startswith("/"):
        return "The path is absolute; send it relative to its root, without a leading slash"
    try:
        path.encode("utf-8")
    except UnicodeEncodeError:
        return "The path is not valid Unicode"
    for segment in path.split("/"):
        if segment in ("", ".", ".."):
            return "The path has an empty, '.' or '..' segment"
    return None


def resolve(
    roots: Mapping[str, Root],
    root_id: str,
    path: str,
    *,
    extensions: Sequence[str] = RAW_EXTENSIONS,
) -> Source | Rejection:
    """Check a requested file and return it with its identity, or the reason it is rejected."""
    return Resolver(roots, extensions=extensions).resolve(root_id, path)


class Resolver:
    """Checks the files of one request (``resolve`` for many files).

    What the files share is looked at once per request: whether a root is available, the real
    path of the root and the real path of every folder. So a file that is not a symbolic link
    costs one ``lstat``, which matters for a request with thousands of files. The answers are the
    same as ``locate`` and a ``stat`` per file would give.
    """

    def __init__(
        self, roots: Mapping[str, Root], *, extensions: Sequence[str] = RAW_EXTENSIONS
    ) -> None:
        self._roots = roots
        self._extensions = extensions
        self._available: dict[str, bool] = {}
        self._real_roots: dict[str, Path | None] = {}
        self._folders_inside: dict[tuple[str, str], bool] = {}

    def resolve(self, root_id: str, path: str) -> Source | Rejection:
        root = self._roots.get(root_id)
        if root is None:
            return Rejection("unknown_root", f"The server has no root {_quote(root_id)}")
        problem = path_problem(path)
        if problem is not None:
            return Rejection("bad_path", problem)
        suffix = PurePosixPath(path).suffix.lower()
        if suffix not in self._extensions:
            kind = f"'{suffix}' files" if suffix else "Files without an extension"
            return Rejection(
                "unsupported_format", f"{kind} are not camera raw files this server builds"
            )
        available = self._available.get(root_id)
        if available is None:
            available = self._available[root_id] = _is_dir(root.path)
        if not available:
            return Rejection("root_unavailable", f"The root {_quote(root_id)} is not available")

        folder, _, name = path.rpartition("/")
        file = root.path.joinpath(*path.split("/"))
        missing = unreadable = False
        info: os.stat_result | None = None
        try:
            info = os.lstat(file)
        except (FileNotFoundError, NotADirectoryError):
            missing = True
        except (OSError, ValueError):
            unreadable = True
        if info is not None and stat.S_ISLNK(info.st_mode):
            inside = self._inside(root, _realpath(file))
        else:
            # Not a link: the file's real path is its folder's real path plus its name. A name
            # that is not a plain last component (on Windows, "C:x.ARW" names another folder)
            # does not count as inside.
            inside = file.name == name and self._folder_inside(root, folder)
        if not inside:
            return Rejection("bad_path", "The path leads outside its root")
        if missing:
            return Rejection("not_found", "No such file")
        if unreadable:
            return Rejection("not_found", "The file cannot be read")
        assert info is not None
        if stat.S_ISLNK(info.st_mode):
            try:
                info = os.stat(file)
            except (FileNotFoundError, NotADirectoryError):
                return Rejection("not_found", "No such file")
            except (OSError, ValueError):
                return Rejection("not_found", "The file cannot be read")
        if not stat.S_ISREG(info.st_mode):
            return Rejection("not_a_file", "Not a regular file")
        return Source(
            root=root_id, path=path, file=file, size=info.st_size, mtime_ns=info.st_mtime_ns
        )

    def _folder_inside(self, root: Root, folder: str) -> bool:
        """Whether a folder under a root ("" is the root itself) really lies inside it."""
        known = (root.id, folder)
        inside = self._folders_inside.get(known)
        if inside is None:
            target = root.path.joinpath(*folder.split("/")) if folder else root.path
            inside = self._folders_inside[known] = self._inside(root, _realpath(target))
        return inside

    def _inside(self, root: Root, real: Path | None) -> bool:
        if root.id not in self._real_roots:
            self._real_roots[root.id] = _realpath(root.path)
        real_root = self._real_roots[root.id]
        return real is not None and real_root is not None and real.is_relative_to(real_root)


def locate(root: Root, path: str) -> Path | None:
    """The file ``path`` names under ``root``, or None if it resolves outside the root.

    The comparison is on real paths, so a symbolic link that leads out of the root is caught.
    The path returned is the one under the root (not the link target), so the converter sees the
    requested name. ``path`` must have passed ``path_problem``.
    """
    file = root.path.joinpath(*path.split("/"))
    try:
        real_root = Path(os.path.realpath(root.path))
        real_file = Path(os.path.realpath(file))
    except (OSError, ValueError):
        return None
    if not real_file.is_relative_to(real_root):
        return None
    return file


def identity(file: Path) -> tuple[int, int] | None:
    """Size and modification time (ns) of a regular file, or None if it is gone or not one."""
    try:
        info = os.stat(file)
    except (OSError, ValueError):
        return None
    if not stat.S_ISREG(info.st_mode):
        return None
    return info.st_size, info.st_mtime_ns


def cache_key(root_id: str, path: str, size: int, mtime_ns: int, recipe: str) -> str:
    """SHA-256 (lower-case hex) over the source's identity and the recipe."""
    material = json.dumps(
        [CACHE_KEY_VERSION, root_id, path, size, mtime_ns, recipe],
        ensure_ascii=False,
        separators=(",", ":"),
    )
    return hashlib.sha256(material.encode("utf-8")).hexdigest()


def _realpath(path: Path) -> Path | None:
    try:
        return Path(os.path.realpath(path))
    except (OSError, ValueError):
        return None


def _is_dir(path: Path) -> bool:
    try:
        return path.is_dir()
    except OSError:
        return False


def _quote(value: str) -> str:
    shown = value if len(value) <= 40 else value[:40] + "..."
    return repr(shown)
