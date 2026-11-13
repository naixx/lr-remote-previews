from pathlib import Path, PurePosixPath

import pytest

from lrrp.converter import (
    DEFAULT_CONVERTER_EXE,
    PREVIEW_LONG_EDGE,
    RAW_EXTENSIONS,
    base_name_key,
    build_command,
    converter_arguments,
    converter_options,
    gpu_config_path,
    gpu_folder,
    is_drive_c_path,
    is_installed,
    prefix_path,
    recipe,
    wine_path,
)


@pytest.mark.parametrize(
    ("windows_path", "expected"),
    [
        (
            DEFAULT_CONVERTER_EXE,
            "drive_c/Program Files/Adobe/Adobe DNG Converter/Adobe DNG Converter.exe",
        ),
        (r"c:\Tools\dngc.exe", "drive_c/Tools/dngc.exe"),
        ("C:/Tools/dngc.exe", "drive_c/Tools/dngc.exe"),
        (r"C:\Tools\\sub\dngc.exe", "drive_c/Tools/sub/dngc.exe"),
    ],
)
def test_prefix_path(windows_path: str, expected: str) -> None:
    prefix = Path("/data/wine")
    assert is_drive_c_path(windows_path)
    assert prefix_path(prefix, windows_path) == prefix / expected


@pytest.mark.parametrize(
    "path", ["/opt/x.exe", "x.exe", "C:x.exe", r"D:\Tools\x.exe", r"\\server\share\x.exe", ""]
)
def test_prefix_path_rejects_other_paths(path: str) -> None:
    assert not is_drive_c_path(path)
    with pytest.raises(ValueError, match="not an absolute path on drive C:"):
        prefix_path(Path("/data/wine"), path)


def test_is_installed(tmp_path: Path) -> None:
    exe = r"C:\Program Files\Tool\tool.exe"
    target = tmp_path / "drive_c" / "Program Files" / "Tool" / "tool.exe"
    assert not is_installed(tmp_path, exe)
    target.mkdir(parents=True)
    assert not is_installed(tmp_path, exe), "a folder with the exe's name is not the exe"
    target.rmdir()
    target.write_bytes(b"MZ")
    assert is_installed(tmp_path, exe)


def test_is_installed_with_a_bad_path(tmp_path: Path) -> None:
    assert not is_installed(tmp_path, "/usr/bin/tool")


@pytest.mark.parametrize(
    ("path", "expected"),
    [
        ("/data/batch-1", r"Z:\data\batch-1"),
        ("/sources/archive/2024/a b/DSC00001.ARW", r"Z:\sources\archive\2024\a b\DSC00001.ARW"),
        (PurePosixPath("/cache/x"), r"Z:\cache\x"),
        ("/sources//archive/", r"Z:\sources\archive"),
        ("/", "Z:\\"),
    ],
)
def test_wine_path(path: str | PurePosixPath, expected: str) -> None:
    assert wine_path(path) == expected


@pytest.mark.parametrize(
    ("path", "message"),
    [("relative/x.arw", "not an absolute path"), ("/data/a\\b.arw", "backslash")],
)
def test_wine_path_rejects(path: str, message: str) -> None:
    with pytest.raises(ValueError, match=message):
        wine_path(path)


def test_build_command() -> None:
    command = build_command(
        ["/sources/archive/2024/DSC00001.ARW", "/sources/archive/2024/DSC00002.ARW"],
        "/cache/work/batch-7",
    )
    assert command == [
        "wine",
        DEFAULT_CONVERTER_EXE,
        "-lossy",
        "-side",
        "2560",
        "-p0",
        "-d",
        r"Z:\cache\work\batch-7",
        r"Z:\sources\archive\2024\DSC00001.ARW",
        r"Z:\sources\archive\2024\DSC00002.ARW",
    ]


def test_build_command_never_uses_mp() -> None:
    assert "-mp" not in build_command(["/s/a.nef"], "/out")


def test_build_command_options() -> None:
    command = build_command(
        [PurePosixPath("/s/a.nef")],
        PurePosixPath("/out"),
        exe=r"C:\Tools\dngc.exe",
        long_edge=1024,
        wine="wine64",
    )
    assert command == [
        "wine64",
        r"C:\Tools\dngc.exe",
        "-lossy",
        "-side",
        "1024",
        "-p0",
        "-d",
        r"Z:\out",
        r"Z:\s\a.nef",
    ]


def test_build_command_needs_inputs() -> None:
    with pytest.raises(ValueError, match="at least one input"):
        build_command([], "/out")


@pytest.mark.parametrize(
    "inputs",
    [
        ["/s/2024/IMG_0001.CR2", "/s/2025/IMG_0001.CR2"],
        ["/s/IMG_0001.CR2", "/s/IMG_0001.CR3"],
        ["/s/a/img_0001.cr2", "/s/b/IMG_0001.CR2"],
    ],
)
def test_build_command_rejects_the_same_base_name(inputs: list[str]) -> None:
    with pytest.raises(ValueError, match="same base name"):
        build_command(inputs, "/out")


def test_build_command_rejects_relative_paths() -> None:
    with pytest.raises(ValueError, match="not an absolute path"):
        build_command(["/s/a.nef"], "out")
    with pytest.raises(ValueError, match="not an absolute path"):
        build_command(["s/a.nef"], "/out")


def test_build_command_rejects_a_bad_long_edge() -> None:
    with pytest.raises(ValueError, match="long edge"):
        build_command(["/s/a.nef"], "/out", long_edge=0)


def test_raw_extensions() -> None:
    assert len(set(RAW_EXTENSIONS)) == len(RAW_EXTENSIONS)
    assert all(ext.startswith(".") and ext == ext.lower() for ext in RAW_EXTENSIONS)
    expected = (
        "arw cr2 cr3 crw dng erf iiq kdc mos mrw nef nrw orf pef raf rw2 rwl sr2 srf srw x3f 3fr"
    )
    assert set(RAW_EXTENSIONS) == {f".{ext}" for ext in expected.split(" ")}
    assert PREVIEW_LONG_EDGE == 2560


def test_gpu_folder_matches_the_entrypoint() -> None:
    # deploy/entrypoint.sh: "$WINEPREFIX/drive_c/users/$USER" +
    # "/AppData/Roaming/Adobe/CameraRaw/GPU/Adobe DNG Converter"
    prefix = PurePosixPath("/data/wine")
    folder = gpu_folder(Path(prefix), "lrrp")
    assert folder.as_posix().endswith(
        "/data/wine/drive_c/users/lrrp/AppData/Roaming/Adobe/CameraRaw/GPU/Adobe DNG Converter"
    )
    assert gpu_config_path(Path(prefix), "lrrp") == folder / "Camera Raw GPU Config.txt"
    assert gpu_config_path(Path("/p"), "someone").parent == gpu_folder(Path("/p"), "someone")


def test_the_entrypoint_creates_the_marker_in_that_folder() -> None:
    entrypoint = Path(__file__).resolve().parents[2] / "deploy" / "entrypoint.sh"
    if not entrypoint.is_file():
        pytest.skip("deploy/entrypoint.sh is not next to the server")
    text = entrypoint.read_text(encoding="utf-8")
    assert 'marker_dir="$profile/AppData/Roaming/Adobe/CameraRaw/GPU/Adobe DNG Converter"' in text
    assert '"$WINEPREFIX/drive_c/users/$USER"' in text
    assert 'export USER="${USER:-lrrp}"' in text


def test_options_and_recipe() -> None:
    assert converter_options() == ["-lossy", "-side", "2560", "-p0"]
    assert converter_options(1024) == ["-lossy", "-side", "1024", "-p0"]
    assert recipe() == "adobe-dng-converter -lossy -side 2560 -p0"
    assert recipe(1024) != recipe()


def test_converter_arguments_with_another_path_form() -> None:
    arguments = converter_arguments(
        [Path("/s/a.nef"), "/s/b.nef"], "/out", to_converter_path=lambda path: f"<{path}>"
    )
    assert arguments[:5] == ["-lossy", "-side", "2560", "-p0", "-d"]
    assert arguments[5] == "</out>"
    assert arguments[6:] == [f"<{Path('/s/a.nef')}>", "</s/b.nef>"]


@pytest.mark.parametrize(
    ("path", "expected"),
    [("/s/IMG_0001.ARW", "img_0001"), (Path("x/IMG_0001.CR2"), "img_0001"), ("a.b.nef", "a.b")],
)
def test_base_name_key(path: str | Path, expected: str) -> None:
    assert base_name_key(path) == expected
