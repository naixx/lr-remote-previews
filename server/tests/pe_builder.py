"""Small synthetic Windows executables (PE files) with a version resource, for the tests.

Only what ``lrrp.peversion`` reads is real: the DOS header, the PE header, the optional header's
resource directory, the section table, a resource tree (type, name, language) and the
``VS_VERSIONINFO`` block. There is no code in them.
"""

import struct
from collections.abc import Sequence

RT_ICON = 3
RT_VERSION = 16
SECTION_ALIGNMENT = 0x1000
FILE_ALIGNMENT = 0x200


def block(
    key: str,
    value: bytes = b"",
    children: Sequence[bytes] = (),
    *,
    text: bool = False,
    value_length: int | None = None,
) -> bytes:
    """One version block: length, value length, type, key, padding, value, padding, children."""
    head = key.encode("utf-16-le") + b"\0\0"
    head += b"\0" * ((-(6 + len(head))) % 4)
    body = head + value
    if children:
        body += b"\0" * ((-(6 + len(body))) % 4)
        for child in children:
            body += child + b"\0" * ((-len(child)) % 4)
    if value_length is None:
        value_length = len(value) // 2 if text else len(value)
    return struct.pack("<HHH", 6 + len(body), value_length, 1 if text else 0) + body


def string(key: str, text: str, *, value_length: int | None = None) -> bytes:
    value = (text + "\0").encode("utf-16-le")
    return block(key, value, text=True, value_length=value_length)


def fixed_info(product: tuple[int, int, int, int], file: tuple[int, int, int, int]) -> bytes:
    def pair(version: tuple[int, int, int, int]) -> tuple[int, int]:
        a, b, c, d = version
        return (a << 16) | b, (c << 16) | d

    return struct.pack(
        "<13I", 0xFEEF04BD, 0x00010000, *pair(file), *pair(product), 0x3F, 0, 0x40004, 1, 0, 0, 0
    )


def version_resource(
    product: str | None = "17.2",
    *,
    fixed: tuple[int, int, int, int] | None = (17, 2, 0, 2155),
    strings: Sequence[bytes] | None = None,
    string_tables: bool = True,
) -> bytes:
    """A ``VS_VERSIONINFO`` block. ``strings`` replaces the default string table entries."""
    if strings is None:
        strings = [string("CompanyName", "Example"), string("FileVersion", "1.0")]
        if product is not None:
            strings = [*strings, string("ProductVersion", product)]
    children = []
    if string_tables:
        table = block("040904b0", children=strings)
        children.append(block("StringFileInfo", children=[table]))
    translation = block("Translation", struct.pack("<HH", 0x0409, 1200))
    children.append(block("VarFileInfo", children=[translation]))
    value = b"" if fixed is None else fixed_info(fixed, fixed)
    return block("VS_VERSION_INFO", value, children)


def windows_exe(
    resource: bytes | None,
    *,
    pe32_plus: bool = True,
    resource_type: int = RT_VERSION,
    data_rva_shift: int = 0,
    trailer: int = 0,
) -> bytes:
    """A PE file whose resource section holds ``resource`` under ``resource_type`` (None: no
    resource section). ``data_rva_shift`` moves the data entry's address (to break it);
    ``trailer`` adds that many zero bytes after the last section."""
    rsrc_rva = 2 * SECTION_ALIGNMENT
    rsrc = b""
    if resource is not None:

        def directory(entries: list[tuple[int, int, bool]]) -> bytes:
            data = struct.pack("<IIHHHH", 0, 0, 0, 0, 0, len(entries))
            for name, offset, is_dir in entries:
                data += struct.pack("<II", name, offset | (0x80000000 if is_dir else 0))
            return data

        # Type directory (an icon type before the version type), name directory, language
        # directory, data entry, then the resource itself.
        types = directory([(RT_ICON, 0x20, True), (resource_type, 0x20, True)])
        names = directory([(1, 0x38, True)])
        languages = directory([(0x0409, 0x50, False)])
        tree = types + names + languages
        assert len(tree) == 0x50
        entry = struct.pack("<IIII", rsrc_rva + 0x60 + data_rva_shift, len(resource), 0, 0)
        rsrc = tree + entry + b"\0" * (0x60 - 0x50 - len(entry)) + resource
    rsrc_raw = rsrc + b"\0" * ((-len(rsrc)) % FILE_ALIGNMENT)

    optional_size = 240 if pe32_plus else 224
    count_at, directories_at = (108, 112) if pe32_plus else (92, 96)
    optional = bytearray(optional_size)
    struct.pack_into("<H", optional, 0, 0x20B if pe32_plus else 0x10B)
    struct.pack_into("<I", optional, count_at, 16)
    if resource is not None:
        struct.pack_into("<II", optional, directories_at + 2 * 8, rsrc_rva, len(rsrc))

    sections = [(b".text", SECTION_ALIGNMENT, 0x100, FILE_ALIGNMENT, FILE_ALIGNMENT)]
    if resource is not None:
        sections.append((b".rsrc", rsrc_rva, len(rsrc), len(rsrc_raw), 2 * FILE_ALIGNMENT))
    table = b""
    for name, address, virtual_size, raw_size, raw_offset in sections:
        table += name.ljust(8, b"\0")
        table += struct.pack("<IIII", virtual_size, address, raw_size, raw_offset)
        table += b"\0" * 16

    dos = bytearray(0x80)
    dos[:2] = b"MZ"
    struct.pack_into("<I", dos, 0x3C, 0x80)
    coff = struct.pack("<HHIIIHH", 0x8664, len(sections), 0, 0, 0, optional_size, 0x22)
    headers = bytes(dos) + b"PE\0\0" + coff + bytes(optional) + table
    assert len(headers) <= FILE_ALIGNMENT
    headers += b"\0" * (FILE_ALIGNMENT - len(headers))
    return headers + b"\0" * FILE_ALIGNMENT + rsrc_raw + b"\0" * trailer
