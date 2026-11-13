from pathlib import Path

import pytest

from lrrp.settings import Root
from lrrp.sources import (
    MAX_PATH_LENGTH,
    Rejection,
    Source,
    cache_key,
    identity,
    locate,
    path_problem,
    resolve,
)


@pytest.fixture
def root(tmp_path: Path) -> Root:
    folder = tmp_path / "originals"
    (folder / "2026" / "shoot").mkdir(parents=True)
    (folder / "2026" / "shoot" / "IMG_0001.ARW").write_bytes(b"raw bytes")
    return Root(id="archive", path=folder, label="Archive")


@pytest.mark.parametrize(
    "path",
    ["IMG_0001.ARW", "2026/2026.06.20 - shoot/IMG_0001.ARW", "a/b c/Día/x.nef", "..a/b../x.ARW"],
)
def test_acceptable_paths(path: str) -> None:
    assert path_problem(path) is None


@pytest.mark.parametrize(
    ("path", "fragment"),
    [
        ("", "empty"),
        ("/2026/IMG_0001.ARW", "absolute"),
        ("2026\\IMG_0001.ARW", "backslash"),
        ("2026/IMG\x000001.ARW", "NUL"),
        ("2026/../IMG_0001.ARW", "'..'"),
        ("../IMG_0001.ARW", "'..'"),
        ("./IMG_0001.ARW", "'.'"),
        ("2026/./IMG_0001.ARW", "'.'"),
        ("2026//IMG_0001.ARW", "empty"),
        ("2026/", "empty"),
        ("\ud800.ARW", "Unicode"),
        ("a" * (MAX_PATH_LENGTH + 1), "longer"),
    ],
)
def test_bad_paths(path: str, fragment: str) -> None:
    problem = path_problem(path)
    assert problem is not None
    assert fragment in problem


def test_resolve_a_file(root: Root) -> None:
    found = resolve({"archive": root}, "archive", "2026/shoot/IMG_0001.ARW")
    assert isinstance(found, Source)
    assert found.file == root.path / "2026" / "shoot" / "IMG_0001.ARW"
    assert found.name == "IMG_0001.ARW"
    assert found.size == len(b"raw bytes")
    assert found.mtime_ns == found.file.stat().st_mtime_ns
    assert (found.size, found.mtime_ns) == identity(found.file)


@pytest.mark.parametrize("extension", [".ARW", ".arw", ".Nef", ".DNG", ".3FR"])
def test_extensions_are_compared_in_lower_case(root: Root, extension: str) -> None:
    (root.path / f"x{extension}").write_bytes(b"x")
    assert isinstance(resolve({"archive": root}, "archive", f"x{extension}"), Source)


@pytest.mark.parametrize(
    ("root_id", "path", "code"),
    [
        ("other", "2026/shoot/IMG_0001.ARW", "unknown_root"),
        ("archive", "2026/../2026/shoot/IMG_0001.ARW", "bad_path"),
        ("archive", "2026/shoot/IMG_0001.jpg", "unsupported_format"),
        ("archive", "2026/shoot/IMG_0001", "unsupported_format"),
        ("archive", "2026/shoot/IMG_0002.ARW", "not_found"),
        ("archive", "2026/shoot/IMG_0001.ARW/x.ARW", "not_found"),
        ("archive", "2026.ARW", "not_found"),
    ],
)
def test_rejections(root: Root, root_id: str, path: str, code: str) -> None:
    found = resolve({"archive": root}, root_id, path)
    assert isinstance(found, Rejection)
    assert found.code == code
    assert str(root.path) not in found.message


def test_a_folder_is_not_a_file(root: Root) -> None:
    (root.path / "folder.ARW").mkdir()
    found = resolve({"archive": root}, "archive", "folder.ARW")
    assert found == Rejection("not_a_file", "Not a regular file")


def test_an_unavailable_root(tmp_path: Path) -> None:
    root = Root(id="archive", path=tmp_path / "unmounted", label="Archive")
    found = resolve({"archive": root}, "archive", "IMG_0001.ARW")
    assert isinstance(found, Rejection)
    assert found.code == "root_unavailable"


def test_unknown_root_message_is_short() -> None:
    found = resolve({}, "x" * 1000, "IMG_0001.ARW")
    assert isinstance(found, Rejection)
    assert len(found.message) < 100


def _symlink(link: Path, target: Path) -> None:
    try:
        link.symlink_to(target, target_is_directory=target.is_dir())
    except (OSError, NotImplementedError) as exc:
        pytest.skip(f"cannot create symbolic links here: {exc}")


def test_symbolic_links_out_of_the_root_are_bad_paths(root: Root, tmp_path: Path) -> None:
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "IMG_0009.ARW").write_bytes(b"x")
    _symlink(root.path / "escape.ARW", outside / "IMG_0009.ARW")
    _symlink(root.path / "escape", outside)
    _symlink(root.path / "dangling.ARW", outside / "missing.ARW")
    for path in ("escape.ARW", "escape/IMG_0009.ARW", "dangling.ARW"):
        found = resolve({"archive": root}, "archive", path)
        assert found == Rejection("bad_path", "The path leads outside its root"), path
        assert locate(root, path) is None


def test_a_symbolic_link_inside_the_root_is_followed(root: Root) -> None:
    target = root.path / "2026" / "shoot" / "IMG_0001.ARW"
    _symlink(root.path / "alias.ARW", target)
    found = resolve({"archive": root}, "archive", "alias.ARW")
    assert isinstance(found, Source)
    # The converter gets the link, so the output is named after the requested file.
    assert found.file == root.path / "alias.ARW"
    assert found.size == target.stat().st_size


def test_a_root_reached_through_a_symbolic_link(root: Root, tmp_path: Path) -> None:
    _symlink(tmp_path / "mounted", root.path)
    linked = Root(id="archive", path=tmp_path / "mounted", label="Archive")
    assert isinstance(resolve({"archive": linked}, "archive", "2026/shoot/IMG_0001.ARW"), Source)


def test_identity_of_missing_and_odd_files(tmp_path: Path) -> None:
    assert identity(tmp_path / "missing.ARW") is None
    assert identity(tmp_path) is None


def test_cache_key() -> None:
    key = cache_key("archive", "2026/IMG_0001.ARW", 100, 123456789, "recipe")
    assert len(key) == 64
    assert key == key.lower()
    assert int(key, 16) >= 0
    assert key == cache_key("archive", "2026/IMG_0001.ARW", 100, 123456789, "recipe")
    others = {
        cache_key("scans", "2026/IMG_0001.ARW", 100, 123456789, "recipe"),
        cache_key("archive", "2026/IMG_0002.ARW", 100, 123456789, "recipe"),
        cache_key("archive", "2026/IMG_0001.ARW", 101, 123456789, "recipe"),
        cache_key("archive", "2026/IMG_0001.ARW", 100, 123456790, "recipe"),
        cache_key("archive", "2026/IMG_0001.ARW", 100, 123456789, "other recipe"),
        # No ambiguity between the parts.
        cache_key("archive/2026", "IMG_0001.ARW", 100, 123456789, "recipe"),
    }
    assert key not in others
    assert len(others) == 6
