import struct
from pathlib import Path

import pytest

from fake_converter import ASCII, BYTE, LONG, SHORT, UNDEFINED, dng_bytes, tiff
from lrrp.dng import (
    MAX_NAME_BYTES,
    TAG_ORIGINAL_DEFAULT_FINAL_SIZE,
    TAG_ORIGINAL_RAW_FILE_NAME,
    DngError,
    DngTags,
    parse_tags,
    read_tags,
)

NAME = TAG_ORIGINAL_RAW_FILE_NAME
SIZE = TAG_ORIGINAL_DEFAULT_FINAL_SIZE


def test_a_hand_written_little_endian_file() -> None:
    # II, 42, IFD0 at 8; two entries; the name (12 bytes) at offset 38, after the IFD.
    data = (
        b"II*\x00\x08\x00\x00\x00"
        b"\x02\x00"
        + b"\x8b\xc6\x02\x00\x0c\x00\x00\x00\x26\x00\x00\x00"  # OriginalRawFileName, ASCII, 12
        + b"\x91\xc7\x03\x00\x02\x00\x00\x00\x70\x17\xa0\x0f"  # OriginalDefaultFinalSize, SHORT
        + b"\x00\x00\x00\x00"
        + b"IMG_0001.ARW"
    )
    assert len(data) == 38 + 12
    assert parse_tags(data) == DngTags("IMG_0001.ARW", 6000, 4000)


@pytest.mark.parametrize("order", ["<", ">"])
@pytest.mark.parametrize("kind", [SHORT, LONG])
def test_both_byte_orders_and_size_types(order: str, kind: int) -> None:
    data = tiff(
        [
            (256, SHORT, [2560]),
            (NAME, ASCII, b"DSC00001.ARW\0"),
            (SIZE, kind, [6048, 4024]),
        ],
        order,
    )
    assert parse_tags(data) == DngTags("DSC00001.ARW", 6048, 4024)


@pytest.mark.parametrize("order", ["<", ">"])
def test_a_name_of_type_byte_in_utf8(order: str) -> None:
    name = "Día_0001.NEF"
    data = tiff([(NAME, BYTE, name.encode("utf-8"))], order)
    assert parse_tags(data) == DngTags(name, None, None)


@pytest.mark.parametrize("order", ["<", ">"])
def test_a_short_name_inside_the_entry(order: str) -> None:
    # Four bytes or fewer live in the entry itself instead of at an offset.
    data = tiff([(NAME, ASCII, b"A.X\0")], order)
    assert len(data) == 8 + 2 + 12 + 4
    assert parse_tags(data).original_name == "A.X"


def test_a_name_that_is_not_utf8_is_read_as_latin1() -> None:
    data = tiff([(NAME, ASCII, b"caf\xe9.ARW\0")])
    assert parse_tags(data).original_name == "café.ARW"


def test_missing_tags_are_none() -> None:
    assert parse_tags(tiff([(256, SHORT, [10])])) == DngTags(None, None, None)
    assert parse_tags(tiff([(NAME, ASCII, b"\0")])).original_name is None


def test_the_fake_converters_output() -> None:
    assert parse_tags(dng_bytes("IMG_0001.ARW", b"content")) == DngTags("IMG_0001.ARW", 6000, 4000)


def test_read_tags_from_a_file(tmp_path: Path) -> None:
    path = tmp_path / "x.dng"
    path.write_bytes(dng_bytes("IMG_0001.ARW", b"content"))
    assert read_tags(path).original_name == "IMG_0001.ARW"


def _broken_offset(data: bytes, entry: int, offset: int) -> bytes:
    """Point the value of IFD0 entry ``entry`` (little endian) at ``offset``."""
    position = 8 + 2 + 12 * entry + 8
    return data[:position] + struct.pack("<I", offset) + data[position + 4 :]


@pytest.mark.parametrize(
    ("data", "message"),
    [
        (b"", "TIFF header"),
        (b"II*\x00", "TIFF header"),
        (b"XX*\x00\x08\x00\x00\x00\x00\x00", "byte order"),
        (b"II+\x00\x08\x00\x00\x00\x00\x00\x00\x00", "BigTIFF"),
        (b"II\x07\x00\x08\x00\x00\x00\x00\x00", "magic number 7"),
        (b"II*\x00\x04\x00\x00\x00\x00\x00", "points into the header"),
        (b"II*\x00\xff\xff\xff\xff", "entry count"),
        (b"II*\x00\x08\x00\x00\x00\x00\x00", "no entries"),
        (b"II*\x00\x08\x00\x00\x00\xff\xff" + b"\x00" * 24, "IFD0 entries"),
        (_broken_offset(tiff([(NAME, ASCII, b"IMG_0001.ARW\0")]), 0, 0xFFFFFF00), "tag value"),
        (tiff([(NAME, SHORT, [1, 2, 3])]), "OriginalRawFileName has type 3"),
        (tiff([(NAME, UNDEFINED, b"IMG.ARW\0")]), "OriginalRawFileName has type 7"),
        (tiff([(NAME, ASCII, b"x" * (MAX_NAME_BYTES + 1))]), "bytes long"),
        (tiff([(SIZE, LONG, [1, 2, 3])]), "3 values"),
        (tiff([(SIZE, ASCII, b"6000x4000\0")]), "OriginalDefaultFinalSize has type 2"),
    ],
)
def test_malformed_files_are_refused(data: bytes, message: str) -> None:
    with pytest.raises(DngError, match=message):
        parse_tags(data)


def test_a_huge_declared_name_is_not_read(tmp_path: Path) -> None:
    # The count claims 4 GiB; the reader must refuse without trying to read it.
    data = tiff([(NAME, ASCII, b"IMG_0001.ARW\0")])
    position = 8 + 2 + 4
    data = data[:position] + struct.pack("<I", 0xFFFFFFFF) + data[position + 4 :]
    with pytest.raises(DngError, match="bytes long"):
        parse_tags(data)


def test_a_truncated_file_is_refused(tmp_path: Path) -> None:
    data = dng_bytes("IMG_0001.ARW", b"content")
    path = tmp_path / "cut.dng"
    path.write_bytes(data[:30])
    with pytest.raises(DngError, match="past the end"):
        read_tags(path)
