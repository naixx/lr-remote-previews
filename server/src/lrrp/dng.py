"""Read the two identity tags of a DNG: the original's file name and its full pixel size.

Pure Python, standard library only. It reads the first image file directory (IFD0) of a classic
TIFF file in either byte order and nothing else: a smart preview DNG keeps both tags there.

- ``OriginalRawFileName`` (tag 0xC68B), ASCII or BYTE: the file name of the raw file the DNG was
  made from.
- ``OriginalDefaultFinalSize`` (tag 0xC791), two SHORT or LONG values: the original's default
  final size, horizontal first.

Either tag may be missing; the result then says ``None``. A file that is not a classic TIFF, or
whose structure points outside the file, raises ``DngError``. Every read is bounded by the file
size and by the limits below, so a malformed file cannot make the reader read without end.
"""

import io
import os
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO

TAG_ORIGINAL_RAW_FILE_NAME = 0xC68B
TAG_ORIGINAL_DEFAULT_FINAL_SIZE = 0xC791

TYPE_BYTE = 1
TYPE_ASCII = 2
TYPE_SHORT = 3
TYPE_LONG = 4

MAX_NAME_BYTES = 4096
"""Longest ``OriginalRawFileName`` accepted, in bytes; a longer one is treated as malformed."""

_TYPE_SIZES = {TYPE_BYTE: 1, TYPE_ASCII: 1, TYPE_SHORT: 2, TYPE_LONG: 4}
_ENTRY_SIZE = 12


class DngError(ValueError):
    """The file is not a DNG this reader understands, or its structure is broken."""


@dataclass(frozen=True)
class DngTags:
    original_name: str | None
    original_width: int | None
    original_height: int | None


def read_tags(path: Path) -> DngTags:
    """Read the identity tags from the file at ``path``. Raises ``DngError`` or ``OSError``."""
    with path.open("rb") as file:
        return _read(file, os.fstat(file.fileno()).st_size)


def parse_tags(data: bytes) -> DngTags:
    """Read the identity tags from the bytes of a whole file. Raises ``DngError``."""
    return _read(io.BytesIO(data), len(data))


def _read(file: BinaryIO, size: int) -> DngTags:
    header = _read_at(file, size, 0, 8, "the TIFF header")
    if header[:2] == b"II":
        order = "<"
    elif header[:2] == b"MM":
        order = ">"
    else:
        raise DngError("not a TIFF file (no byte order mark)")
    (magic,) = struct.unpack(order + "H", header[2:4])
    if magic == 43:
        raise DngError("BigTIFF is not supported")
    if magic != 42:
        raise DngError(f"not a TIFF file (magic number {magic})")
    (ifd,) = struct.unpack(order + "I", header[4:8])
    if ifd < 8:
        raise DngError(f"IFD0 offset {ifd} points into the header")
    (count,) = struct.unpack(order + "H", _read_at(file, size, ifd, 2, "the IFD0 entry count"))
    if count == 0:
        raise DngError("IFD0 has no entries")
    entries = _read_at(file, size, ifd + 2, count * _ENTRY_SIZE, "the IFD0 entries")

    name: str | None = None
    width: int | None = None
    height: int | None = None
    seen: set[int] = set()
    for index in range(count):
        entry = entries[index * _ENTRY_SIZE : (index + 1) * _ENTRY_SIZE]
        tag, kind, number = struct.unpack(order + "HHI", entry[:8])
        if tag in seen or tag not in (TAG_ORIGINAL_RAW_FILE_NAME, TAG_ORIGINAL_DEFAULT_FINAL_SIZE):
            continue
        seen.add(tag)
        if tag == TAG_ORIGINAL_RAW_FILE_NAME:
            if kind not in (TYPE_ASCII, TYPE_BYTE):
                raise DngError(f"OriginalRawFileName has type {kind}, not ASCII or BYTE")
            if number > MAX_NAME_BYTES:
                raise DngError(f"OriginalRawFileName is {number} bytes long")
            name = _decode_name(_value(file, size, order, kind, number, entry[8:]))
        else:
            if kind not in (TYPE_SHORT, TYPE_LONG):
                raise DngError(f"OriginalDefaultFinalSize has type {kind}, not SHORT or LONG")
            if number != 2:
                raise DngError(f"OriginalDefaultFinalSize has {number} values, not 2")
            raw = _value(file, size, order, kind, number, entry[8:])
            width, height = struct.unpack(order + ("HH" if kind == TYPE_SHORT else "II"), raw)
    return DngTags(original_name=name, original_width=width, original_height=height)


def _value(file: BinaryIO, size: int, order: str, kind: int, number: int, field: bytes) -> bytes:
    """An entry's value: inside the entry when it fits in 4 bytes, else at its offset."""
    length = _TYPE_SIZES[kind] * number
    if length <= 4:
        return field[:length]
    (offset,) = struct.unpack(order + "I", field)
    return _read_at(file, size, offset, length, "a tag value")


def _read_at(file: BinaryIO, size: int, offset: int, length: int, what: str) -> bytes:
    if offset + length > size:
        raise DngError(f"{what} runs past the end of the file")
    file.seek(offset)
    data = file.read(length)
    if len(data) != length:
        raise DngError(f"{what} runs past the end of the file")
    return data


def _decode_name(raw: bytes) -> str | None:
    text = raw.split(b"\x00", 1)[0]
    if not text:
        return None
    try:
        return text.decode("utf-8")
    except UnicodeDecodeError:
        return text.decode("latin-1")
