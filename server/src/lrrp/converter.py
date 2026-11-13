"""Adobe DNG Converter under Wine: where the server looks for it and how a batch is invoked.

The converter is not part of this project. The user installs it into the server's Wine prefix;
this module only finds it there and builds its command line. ``lrrp.runner`` runs it.

Measured facts, for the runner. They were measured with Adobe DNG Converter 17.2 under Wine 8.0
(Debian 12) on a 14-core, 20-thread desktop CPU. Keep them when changing the runner.

- Options for a Lightroom-compatible smart preview: ``-lossy -side 2560 -p0 -d <out dir>
  <files...>``. Each output file is named after the input's base name, so a batch must not contain
  two files with the same base name, and each batch needs its own output folder.
- Never pass ``-mp``: with it a photo takes 1.3-1.5 s and four times the CPU time, against
  0.26-0.42 s per photo without it.
- Run one converter process, or three to six side by side, but never exactly two: two processes
  cost twice the CPU time per photo. This was repeatable; the cause is unknown.
- One missing input file makes the converter exit with code 1 and write nothing for the whole
  batch. Exit code 1 is also its answer to a batch whose only input does not exist.
- The converter needs an X display (Xvfb). In a container without a Vulkan device it also needs
  an empty marker file named ``TempDisableGPU2`` in the folder
  ``<prefix>/drive_c/users/<user>/AppData/Roaming/Adobe/CameraRaw/GPU/Adobe DNG Converter/``;
  without it Wine aborts in vkd3d. The container entrypoint creates that file at every start.
- In a Wine prefix where the converter has never run, its first run always aborts with exit
  code 3 (the same vkd3d assertion), even with the marker in place and whatever the input is (a
  real raw file, a path that does not exist, or none). That run writes ``Camera Raw GPU
  Config.txt`` next to the marker; every later run finds the marker ("Special file
  'TempDisableGPU2' found -- skipping GPU2") and works. The runner therefore warms a prefix up
  with one throw-away run whenever that file is missing. Do not create the file by hand: it
  holds a machine-specific digest. (Found 2026-11-14 on a fresh prefix.)
- Linux paths are passed to it as ``Z:\\...`` paths.
"""

import re
from collections.abc import Callable, Sequence
from pathlib import Path, PurePath, PurePosixPath

DEFAULT_CONVERTER_EXE = r"C:\Program Files\Adobe\Adobe DNG Converter\Adobe DNG Converter.exe"

PREVIEW_LONG_EDGE = 2560
"""Long edge of a Lightroom smart preview, in pixels."""

RAW_EXTENSIONS = (
    ".arw",
    ".cr2",
    ".cr3",
    ".crw",
    ".dng",
    ".erf",
    ".iiq",
    ".kdc",
    ".mos",
    ".mrw",
    ".nef",
    ".nrw",
    ".orf",
    ".pef",
    ".raf",
    ".rw2",
    ".rwl",
    ".sr2",
    ".srf",
    ".srw",
    ".x3f",
    ".3fr",
)
"""Lower-case extensions of the camera raw files the server accepts."""

DEFAULT_WINE_USER = "lrrp"
"""The Wine profile name when ``USER`` is not set; the container entrypoint uses the same."""

GPU_MARKER_NAME = "TempDisableGPU2"
GPU_CONFIG_NAME = "Camera Raw GPU Config.txt"

_DRIVE_C_PATH = re.compile(r"[Cc]:[\\/](?P<rest>.*)", re.DOTALL)


def is_drive_c_path(path: str) -> bool:
    """Whether ``path`` is an absolute Windows path on drive C:, such as ``C:\\x\\y``."""
    return _DRIVE_C_PATH.fullmatch(path) is not None


def prefix_path(prefix: Path, windows_path: str) -> Path:
    """Return where a path on drive C: of the Wine prefix lives on the Linux side.

    ``C:\\x\\y`` maps to ``<prefix>/drive_c/x/y``. Raises ``ValueError`` for any other path.
    """
    match = _DRIVE_C_PATH.fullmatch(windows_path)
    if match is None:
        raise ValueError(f"not an absolute path on drive C: {windows_path!r}")
    parts = [part for part in re.split(r"[\\/]+", match["rest"]) if part]
    return prefix.joinpath("drive_c", *parts)


def is_installed(prefix: Path, exe: str) -> bool:
    """Whether the converter executable ``exe`` (a Windows path) exists in the Wine prefix."""
    try:
        return prefix_path(prefix, exe).is_file()
    except (OSError, ValueError):
        return False


def gpu_folder(prefix: Path, user: str) -> Path:
    """The converter's GPU folder in the Wine profile ``user``: the marker and its config file.

    The same folder the container entrypoint puts the ``TempDisableGPU2`` marker into.
    """
    return prefix.joinpath(
        "drive_c",
        "users",
        user,
        "AppData",
        "Roaming",
        "Adobe",
        "CameraRaw",
        "GPU",
        "Adobe DNG Converter",
    )


def gpu_config_path(prefix: Path, user: str) -> Path:
    """The file the converter's first run in a prefix writes; while it is missing, runs abort."""
    return gpu_folder(prefix, user) / GPU_CONFIG_NAME


def wine_path(path: str | PurePosixPath) -> str:
    """Return the Windows form of an absolute Linux path, as Wine sees it: ``Z:\\data\\x.arw``."""
    posix = PurePosixPath(path)
    if not posix.is_absolute():
        raise ValueError(f"not an absolute path: {str(posix)!r}")
    if "\\" in str(posix):
        raise ValueError(f"a backslash cannot be passed to Wine: {str(posix)!r}")
    return "Z:\\" + "\\".join(posix.parts[1:])


def converter_options(long_edge: int = PREVIEW_LONG_EDGE) -> list[str]:
    """The options that make a smart preview. Never ``-mp`` (see the module docstring)."""
    if long_edge <= 0:
        raise ValueError(f"long edge must be positive, got {long_edge}")
    return ["-lossy", "-side", str(long_edge), "-p0"]


def recipe(long_edge: int = PREVIEW_LONG_EDGE) -> str:
    """A string that names how a DNG is made; part of the cache key, so new options rebuild."""
    return "adobe-dng-converter " + " ".join(converter_options(long_edge))


def base_name_key(path: str | PurePath) -> str:
    """The name the converter gives the output of ``path``, folded for comparison: ``img_0001``."""
    stem = path.stem if isinstance(path, PurePath) else PurePosixPath(path).stem
    return stem.casefold()


def converter_arguments(
    inputs: Sequence[str | PurePath],
    out_dir: str | PurePath,
    *,
    long_edge: int = PREVIEW_LONG_EDGE,
    to_converter_path: Callable[..., str] = wine_path,
) -> list[str]:
    """The converter's arguments (everything after the program) for one batch.

    ``to_converter_path`` turns a server-side path into the form the converter gets; the default
    makes ``Z:\\...`` paths out of absolute Linux paths. Raises ``ValueError`` for an empty batch,
    for two inputs with the same base name (the outputs would collide; compared
    case-insensitively, as Windows does) and for paths that cannot be passed on.
    """
    if not inputs:
        raise ValueError("a batch needs at least one input file")
    options = converter_options(long_edge)
    seen: dict[str, str | PurePath] = {}
    for item in inputs:
        key = base_name_key(item)
        if key in seen:
            raise ValueError(
                f"{str(seen[key])!r} and {str(item)!r} have the same base name; "
                "put them into different batches"
            )
        seen[key] = item
    return [
        *options,
        "-d",
        to_converter_path(out_dir),
        *(to_converter_path(item) for item in inputs),
    ]


def build_command(
    inputs: Sequence[str | PurePosixPath],
    out_dir: str | PurePosixPath,
    *,
    exe: str = DEFAULT_CONVERTER_EXE,
    long_edge: int = PREVIEW_LONG_EDGE,
    wine: str = "wine",
) -> list[str]:
    """Build the argument list that converts one batch of raw files into smart previews.

    ``inputs`` and ``out_dir`` are absolute Linux paths. The output folder must belong to this
    batch alone. Raises ``ValueError`` as ``converter_arguments`` does.
    """
    return [wine, exe, *converter_arguments(inputs, out_dir, long_edge=long_edge)]
