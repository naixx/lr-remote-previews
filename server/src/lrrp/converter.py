"""Adobe DNG Converter under Wine: where the server looks for it and how a batch is invoked.

The converter is not part of this project. The user installs it into the server's Wine prefix;
this module only finds it there and builds its command line. Running it is stage 1.

Measured facts, for the stage 1 runner. They were measured with Adobe DNG Converter 17.2 under
Wine 8.0 (Debian 12) on a 14-core, 20-thread desktop CPU. Keep them when changing the runner.

- Options for a Lightroom-compatible smart preview: ``-lossy -side 2560 -p0 -d <out dir>
  <files...>``. Each output file is named after the input's base name, so a batch must not contain
  two files with the same base name, and each batch needs its own output folder.
- Never pass ``-mp``: with it a photo takes 1.3-1.5 s and four times the CPU time, against
  0.26-0.42 s per photo without it.
- Run one converter process, or three to six side by side, but never exactly two: two processes
  cost twice the CPU time per photo. This was repeatable; the cause is unknown.
- One missing input file makes the converter exit with code 1 and write nothing for the whole
  batch.
- The converter needs an X display (Xvfb). In a container without a Vulkan device it also needs
  an empty marker file named ``TempDisableGPU2`` in the folder
  ``<prefix>/drive_c/users/<user>/AppData/Roaming/Adobe/CameraRaw/GPU/Adobe DNG Converter/``;
  without it Wine aborts in vkd3d. The container entrypoint creates that file at every start.
- Linux paths are passed to it as ``Z:\\...`` paths.
"""

import re
from collections.abc import Sequence
from pathlib import Path, PurePosixPath

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


def wine_path(path: str | PurePosixPath) -> str:
    """Return the Windows form of an absolute Linux path, as Wine sees it: ``Z:\\data\\x.arw``."""
    posix = PurePosixPath(path)
    if not posix.is_absolute():
        raise ValueError(f"not an absolute path: {str(posix)!r}")
    if "\\" in str(posix):
        raise ValueError(f"a backslash cannot be passed to Wine: {str(posix)!r}")
    return "Z:\\" + "\\".join(posix.parts[1:])


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
    batch alone. Raises ``ValueError`` for an empty batch, for two inputs with the same base name
    (the outputs would collide; compared case-insensitively, as Windows does) and for paths
    that cannot be passed to Wine.
    """
    if not inputs:
        raise ValueError("a batch needs at least one input file")
    if long_edge <= 0:
        raise ValueError(f"long edge must be positive, got {long_edge}")
    seen: dict[str, PurePosixPath] = {}
    for item in inputs:
        path = PurePosixPath(item)
        key = path.stem.casefold()
        if key in seen:
            raise ValueError(
                f"{str(seen[key])!r} and {str(path)!r} have the same base name; "
                "put them into different batches"
            )
        seen[key] = path
    return [
        wine,
        exe,
        "-lossy",
        "-side",
        str(long_edge),
        "-p0",
        "-d",
        wine_path(out_dir),
        *(wine_path(item) for item in inputs),
    ]
