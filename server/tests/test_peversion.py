"""Reading the product version from a Windows executable's version resource."""

import os
from pathlib import Path

import pytest

from lrrp import peversion
from lrrp.peversion import VersionCache, parse_version_resource, read_product_version
from pe_builder import RT_ICON, string, version_resource, windows_exe


def write(tmp_path: Path, data: bytes, name: str = "converter.exe") -> Path:
    path = tmp_path / name
    path.write_bytes(data)
    return path


@pytest.mark.parametrize("pe32_plus", [True, False])
def test_the_product_version_string(tmp_path: Path, pe32_plus: bool) -> None:
    exe = write(tmp_path, windows_exe(version_resource("17.2"), pe32_plus=pe32_plus))
    assert read_product_version(exe) == "17.2"


def test_the_string_is_trimmed_and_may_have_any_form(tmp_path: Path) -> None:
    exe = write(tmp_path, windows_exe(version_resource(" 17.4.1 (build 2201) ")))
    assert read_product_version(exe) == "17.4.1 (build 2201)"


def test_a_string_whose_declared_length_counts_bytes(tmp_path: Path) -> None:
    # Some tools write the value length in bytes instead of characters; the value is still
    # read up to its terminating NUL.
    strings = [string("ProductVersion", "17.2", value_length=10)]
    exe = write(tmp_path, windows_exe(version_resource(strings=strings)))
    assert read_product_version(exe) == "17.2"


def test_without_strings_the_fixed_version_is_used(tmp_path: Path) -> None:
    exe = write(tmp_path, windows_exe(version_resource(string_tables=False)))
    assert read_product_version(exe) == "17.2.0.2155"
    exe = write(tmp_path, windows_exe(version_resource(product=None)))
    assert read_product_version(exe) == "17.2.0.2155", "a string table without ProductVersion"
    exe = write(tmp_path, windows_exe(version_resource(product="")))
    assert read_product_version(exe) == "17.2.0.2155", "an empty ProductVersion"


def test_no_version_at_all(tmp_path: Path) -> None:
    resource = version_resource(product=None, fixed=None)
    assert read_product_version(write(tmp_path, windows_exe(resource))) is None


@pytest.mark.parametrize(
    "data",
    [
        b"",
        b"MZ",
        b"just text, not an executable\n" * 10,
        b"MZ" + b"\0" * 62,  # the PE header offset is 0: no PE signature there
        windows_exe(None),  # no resource section
        windows_exe(version_resource(), resource_type=RT_ICON),  # resources, but no version
        windows_exe(version_resource(), data_rva_shift=0x100000),  # points outside every section
        windows_exe(version_resource())[:0x480],  # cut inside the resource tree
        windows_exe(version_resource())[:0x470],
    ],
)
def test_anything_unexpected_is_none(tmp_path: Path, data: bytes) -> None:
    assert read_product_version(write(tmp_path, data)) is None


def test_broken_resources_are_none_or_an_error_but_never_crash(tmp_path: Path) -> None:
    good = version_resource()
    for cut in range(0, len(good), 7):
        exe = write(tmp_path, windows_exe(good[:cut] + b"\xff" * (len(good) - cut)))
        assert read_product_version(exe) in (None, "17.2", "17.2.0.2155")
    with pytest.raises(peversion.PeError):
        parse_version_resource(b"\x10\x00\x00\x00\x00\x00X\x00Y\x00")


def test_a_missing_or_unreadable_file_is_none(tmp_path: Path) -> None:
    assert read_product_version(tmp_path / "missing.exe") is None
    assert read_product_version(tmp_path) is None


def test_only_a_few_kilobytes_are_read(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    exe = write(tmp_path, windows_exe(version_resource(), trailer=8 * 1024 * 1024))
    read: list[int] = []
    original = peversion._File.read

    def counted(self: peversion._File, offset: int, length: int, what: str) -> bytes:
        read.append(length)
        return original(self, offset, length, what)

    monkeypatch.setattr(peversion._File, "read", counted)
    assert read_product_version(exe) == "17.2"
    assert sum(read) < 4096, read


def test_the_cache_reads_again_only_after_a_change(tmp_path: Path) -> None:
    exe = write(tmp_path, windows_exe(version_resource("17.2")))
    calls: list[Path] = []

    def reader(path: Path) -> str | None:
        calls.append(path)
        return read_product_version(path)

    cache = VersionCache(reader)
    assert cache.get(exe) == "17.2"
    assert cache.get(exe) == "17.2"
    assert len(calls) == 1
    exe.write_bytes(windows_exe(version_resource("17.4")))
    info = exe.stat()
    os.utime(exe, ns=(info.st_atime_ns, info.st_mtime_ns + 10**9))
    assert cache.get(exe) == "17.4"
    assert len(calls) == 2
    assert cache.get(tmp_path / "missing.exe") is None
    assert len(calls) == 2, "a missing file is not read"
