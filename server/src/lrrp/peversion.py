"""The product version recorded in a Windows executable, read without running it.

Pure Python, standard library only. It follows the PE file's own structure with a few small
reads: the DOS and PE headers, the section table, the resource directory down to the version
resource (type ``RT_VERSION``) and that resource itself (``VS_VERSIONINFO``, a few kilobytes).
It never reads the whole file, which matters for Adobe DNG Converter (about 227 MB).

The answer is the ``ProductVersion`` string of the version resource (Adobe DNG Converter 17.2
records ``17.2`` there; checked with Windows' own reading of the same file), or, when the
resource has no such string, the fixed product version (``17.2.0.2155``). Anything unexpected
(not a PE file, no version resource, offsets that point outside the file, a structure that does
not parse) gives None. Every read is bounded by the file size and by the limits below.

``VersionCache`` keeps the answer for one file until its size or modification time changes.
"""

import logging
import os
import struct
import threading
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO

log = logging.getLogger(__name__)

RT_VERSION = 16
FIXED_INFO_SIGNATURE = 0xFEEF04BD
PE32 = 0x10B
PE32_PLUS = 0x20B
RESOURCE_DIRECTORY = 2
"""Index of the resource table among the optional header's data directories."""

MAX_SECTIONS = 96
MAX_DIRECTORY_ENTRIES = 4096
MAX_VERSION_RESOURCE = 64 * 1024
MAX_BLOCKS = 4096
"""Most blocks (strings, tables) looked at inside one version resource."""
MAX_VERSION_LENGTH = 64


class PeError(ValueError):
    """The file is not a PE file this reader understands, or its structure is broken."""


@dataclass(frozen=True)
class _Section:
    """The fields of a section header after its name, in their order in the file."""

    virtual_size: int
    address: int
    raw_size: int
    raw_offset: int


class _File:
    def __init__(self, file: BinaryIO, size: int) -> None:
        self._file = file
        self._size = size

    def read(self, offset: int, length: int, what: str) -> bytes:
        if offset < 0 or length < 0 or offset + length > self._size:
            raise PeError(f"{what} lies outside the file")
        self._file.seek(offset)
        data = self._file.read(length)
        if len(data) != length:
            raise PeError(f"{what} lies outside the file")
        return data


def read_product_version(path: Path) -> str | None:
    """The product version recorded in the executable at ``path``, or None."""
    try:
        with path.open("rb") as file:
            resource = _version_resource(_File(file, os.fstat(file.fileno()).st_size))
        return None if resource is None else parse_version_resource(resource)
    except Exception as exc:  # whatever the file holds, the answer is "unknown"
        log.debug("no product version in %s: %s", path.name, exc)
        return None


def parse_version_resource(data: bytes) -> str | None:
    """The product version in a ``VS_VERSIONINFO`` resource. Raises ``PeError`` when broken."""
    root = _block(data, 0, len(data))
    if root.key != "VS_VERSION_INFO":
        raise PeError(f"the version resource starts with {root.key!r}")
    text = _product_version_string(data, root)
    if text is not None:
        return text
    return _fixed_product_version(root.value)


def _version_resource(file: _File) -> bytes | None:
    dos = file.read(0, 64, "the DOS header")
    if dos[:2] != b"MZ":
        raise PeError("not an executable (no MZ header)")
    (pe_offset,) = struct.unpack_from("<I", dos, 0x3C)
    header = file.read(pe_offset, 24, "the PE header")
    if header[:4] != b"PE\0\0":
        raise PeError("not a PE file")
    sections_count, optional_size = struct.unpack_from("<H12xH", header, 6)
    if sections_count > MAX_SECTIONS:
        raise PeError(f"{sections_count} sections")
    optional = file.read(pe_offset + 24, optional_size, "the optional header")
    (magic,) = struct.unpack_from("<H", optional, 0)
    if magic == PE32:
        count_at, directories_at = 92, 96
    elif magic == PE32_PLUS:
        count_at, directories_at = 108, 112
    else:
        raise PeError(f"unknown optional header magic {magic:#x}")
    (directories,) = struct.unpack_from("<I", optional, count_at)
    if directories <= RESOURCE_DIRECTORY:
        return None
    rva, size = struct.unpack_from("<II", optional, directories_at + 8 * RESOURCE_DIRECTORY)
    if rva == 0 or size == 0:
        return None
    table = file.read(pe_offset + 24 + optional_size, 40 * sections_count, "the section table")
    sections = [
        _Section(*struct.unpack_from("<IIII", table, 40 * index + 8))
        for index in range(sections_count)
    ]
    base = _file_offset(sections, rva)

    def entries(offset: int) -> list[tuple[int, bool, int]]:
        named, numbered = struct.unpack_from(
            "<HH", file.read(base + offset, 16, "a resource directory"), 12
        )
        count = named + numbered
        if count > MAX_DIRECTORY_ENTRIES:
            raise PeError(f"a resource directory with {count} entries")
        raw = file.read(base + offset + 16, 8 * count, "resource directory entries")
        found = []
        for index in range(count):
            name, target = struct.unpack_from("<II", raw, 8 * index)
            found.append((name, bool(target & 0x80000000), target & 0x7FFFFFFF))
        return found

    # Three levels: type, then name (the version resource is number 1), then language.
    types = [t for name, is_dir, t in entries(0) if name == RT_VERSION and is_dir]
    if not types:
        return None
    names = [t for _, is_dir, t in entries(types[0]) if is_dir]
    if not names:
        return None
    languages = [t for _, is_dir, t in entries(names[0]) if not is_dir]
    if not languages:
        return None
    data_rva, data_size = struct.unpack_from(
        "<II", file.read(base + languages[0], 16, "the version resource entry")
    )
    if data_size > MAX_VERSION_RESOURCE:
        raise PeError(f"a version resource of {data_size} bytes")
    return file.read(_file_offset(sections, data_rva), data_size, "the version resource")


def _file_offset(sections: list[_Section], rva: int) -> int:
    for section in sections:
        span = max(section.virtual_size, section.raw_size)
        if section.address <= rva < section.address + span:
            inside = rva - section.address
            if inside >= section.raw_size:
                raise PeError(f"address {rva:#x} is not stored in the file")
            return section.raw_offset + inside
    raise PeError(f"address {rva:#x} is in no section")


@dataclass(frozen=True)
class _Block:
    """One block of a version resource (``VS_VERSIONINFO``, ``StringFileInfo``, a string...)."""

    key: str
    value_at: int
    value: bytes
    """The value as its declared length gives it."""
    children: int
    end: int


def _block(data: bytes, offset: int, limit: int) -> _Block:
    if offset + 6 > limit:
        raise PeError("a version block runs past its parent")
    length, value_length, value_type = struct.unpack_from("<HHH", data, offset)
    end = offset + length
    if length < 6 or end > limit:
        raise PeError("a version block runs past its parent")
    key_end = offset + 6
    while key_end + 1 < end and data[key_end : key_end + 2] != b"\0\0":
        key_end += 2
    if key_end + 1 >= end:
        raise PeError("a version block key is not terminated")
    value_at = _aligned(key_end + 2)
    value_bytes = value_length * 2 if value_type == 1 else value_length
    return _Block(
        key=data[offset + 6 : key_end].decode("utf-16-le"),
        value_at=value_at,
        value=data[value_at : min(value_at + value_bytes, end)],
        children=min(_aligned(value_at + value_bytes), end),
        end=end,
    )


def _children(data: bytes, parent: _Block) -> list[_Block]:
    found: list[_Block] = []
    offset = parent.children
    while offset + 6 <= parent.end and len(found) < MAX_BLOCKS:
        (length,) = struct.unpack_from("<H", data, offset)
        if length == 0:  # padding at the end of the parent
            break
        child = _block(data, offset, parent.end)
        found.append(child)
        offset = _aligned(child.end)
    return found


def _product_version_string(data: bytes, root: _Block) -> str | None:
    for info in _children(data, root):
        if info.key != "StringFileInfo":
            continue
        for table in _children(data, info):
            for string in _children(data, table):
                if string.key != "ProductVersion":
                    continue
                # The value runs from after the key to the end of the block. Its declared length
                # is not trusted: compilers disagree on whether it counts bytes or characters.
                raw = data[string.value_at : string.end]
                text = raw.decode("utf-16-le", errors="replace").split("\0", 1)[0].strip()
                if text and len(text) <= MAX_VERSION_LENGTH and text.isprintable():
                    return text
    return None


def _fixed_product_version(value: bytes) -> str | None:
    if len(value) < 52:
        return None
    signature, _structure, _file_ms, _file_ls, product_ms, product_ls = struct.unpack_from(
        "<6I", value, 0
    )
    if signature != FIXED_INFO_SIGNATURE:
        return None
    parts = (product_ms >> 16, product_ms & 0xFFFF, product_ls >> 16, product_ls & 0xFFFF)
    return ".".join(str(part) for part in parts)


def _aligned(offset: int) -> int:
    return (offset + 3) & ~3


class VersionCache:
    """The product version of one executable, read again only when its size or time changes."""

    def __init__(self, reader: Callable[[Path], str | None] = read_product_version) -> None:
        self._reader = reader
        self._lock = threading.Lock()
        self._key: tuple[str, int, int] | None = None
        self._value: str | None = None

    def get(self, path: Path) -> str | None:
        try:
            info = os.stat(path)
        except (OSError, ValueError):
            return None
        key = (str(path), info.st_size, info.st_mtime_ns)
        with self._lock:
            if key != self._key:
                self._value = self._reader(path)
                self._key = key
            return self._value
