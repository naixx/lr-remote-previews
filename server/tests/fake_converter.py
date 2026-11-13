"""A stand-in for Adobe DNG Converter in the tests. Standard library only; runs as a script.

It takes the same command line the server gives the real converter::

    fake_converter.py -lossy -side 2560 -p0 -d Z:\\out\\dir Z:\\in\\IMG_0001.ARW ...

``Z:\\a\\b`` is ``/a/b`` on Linux, as Wine maps it. On Windows the test suite passes
``Z:\\C\\Users\\...`` for ``C:\\Users\\...`` (see ``to_fake_path`` in conftest.py).

Like the real converter it exits with code 1 and writes nothing when an input is missing. For each
input it writes ``<base name>.dng`` into the output folder: a small classic TIFF whose IFD0 has
``OriginalRawFileName`` and ``OriginalDefaultFinalSize`` and a digest of the input's bytes.

Environment variables (names are base names with extension, comma-separated, any case):

- ``FAKE_CONVERTER_STATE`` folder for records: ``runs/`` gets one JSON file per run (its inputs),
  ``concurrency/`` one file per run with the number of runs going on at the same time.
- ``FAKE_CONVERTER_SETTLE`` seconds to wait before counting the runs going on (and again after).
- ``FAKE_CONVERTER_DELAY`` seconds every run takes.
- ``FAKE_CONVERTER_FAIL`` names it writes nothing for, and then exits with code 1.
- ``FAKE_CONVERTER_SKIP`` names it writes nothing for, exiting with code 0.
- ``FAKE_CONVERTER_HANG`` names that make the run hang.
- ``FAKE_CONVERTER_WRONG_NAME`` names whose DNG records another original name.
- ``FAKE_CONVERTER_FRESH_PREFIX=1``: behave like the real converter in a Wine prefix where it
  never ran: while ``Camera Raw GPU Config.txt`` is missing from the GPU folder of
  ``$WINEPREFIX`` and ``$USER``, abort with exit code 3 after writing that file.
"""

import hashlib
import json
import os
import struct
import sys
import time
from collections.abc import Sequence
from pathlib import Path

TAG_ORIGINAL_RAW_FILE_NAME = 0xC68B
TAG_ORIGINAL_DEFAULT_FINAL_SIZE = 0xC791
TAG_DNG_VERSION = 0xC612
TAG_PRIVATE_DIGEST = 65000

ORIGINAL_WIDTH = 6000
ORIGINAL_HEIGHT = 4000

BYTE, ASCII, SHORT, LONG, UNDEFINED = 1, 2, 3, 4, 7
_SIZES = {BYTE: 1, ASCII: 1, SHORT: 2, LONG: 4, UNDEFINED: 1}

Entry = tuple[int, int, bytes | Sequence[int]]


def tiff(entries: Sequence[Entry], order: str = "<") -> bytes:
    """A classic TIFF file with one IFD. ``order`` is ``<`` (II) or ``>`` (MM).

    Each entry is ``(tag, type, value)``: bytes for BYTE, ASCII and UNDEFINED, a sequence of ints
    for SHORT and LONG. Values longer than 4 bytes go into a data area after the IFD.
    """
    entries = sorted(entries, key=lambda entry: entry[0])
    data_start = 8 + 2 + 12 * len(entries) + 4
    ifd = struct.pack(order + "H", len(entries))
    data = b""
    for tag, kind, value in entries:
        if kind in (SHORT, LONG):
            assert not isinstance(value, bytes)
            raw = struct.pack(order + ("H" if kind == SHORT else "I") * len(value), *value)
        else:
            assert isinstance(value, bytes)
            raw = value
        count = len(raw) // _SIZES[kind]
        if len(raw) <= 4:
            field = raw.ljust(4, b"\0")
        else:
            field = struct.pack(order + "I", data_start + len(data))
            data += raw + (b"\0" if len(raw) % 2 else b"")
        ifd += struct.pack(order + "HHI", tag, kind, count) + field
    ifd += struct.pack(order + "I", 0)
    header = (b"II" if order == "<" else b"MM") + struct.pack(order + "HI", 42, 8)
    return header + ifd + data


def dng_bytes(original_name: str, content: bytes) -> bytes:
    """What the fake converter writes for an input called ``original_name`` with ``content``."""
    return tiff(
        [
            (254, LONG, [1]),
            (256, SHORT, [2560]),
            (257, SHORT, [1707]),
            (TAG_DNG_VERSION, BYTE, b"\x01\x07\x00\x00"),
            (TAG_ORIGINAL_RAW_FILE_NAME, ASCII, original_name.encode("utf-8") + b"\0"),
            (TAG_ORIGINAL_DEFAULT_FINAL_SIZE, LONG, [ORIGINAL_WIDTH, ORIGINAL_HEIGHT]),
            (TAG_PRIVATE_DIGEST, UNDEFINED, hashlib.sha256(content).digest()),
        ]
    )


def native_path(argument: str) -> Path:
    if not argument.startswith("Z:\\"):
        raise SystemExit(f"fake converter: not a Z: path: {argument!r}")
    parts = [part for part in argument[3:].split("\\") if part]
    if os.name == "nt":
        drive, *rest = parts
        return Path(drive + ":\\", *rest)
    return Path("/", *parts)


def names(variable: str) -> set[str]:
    return {name.strip().casefold() for name in os.environ.get(variable, "").split(",") if name}


def parse(arguments: list[str]) -> tuple[Path, list[Path]]:
    if "-mp" in arguments:
        raise SystemExit("fake converter: -mp must never be passed")
    expected = ["-lossy", "-side", "2560", "-p0", "-d"]
    if arguments[:5] != expected or len(arguments) < 6:
        raise SystemExit(f"fake converter: unexpected arguments {arguments!r}")
    return native_path(arguments[5]), [native_path(argument) for argument in arguments[6:]]


def gpu_config() -> Path:
    return Path(
        os.environ["WINEPREFIX"],
        "drive_c",
        "users",
        os.environ["USER"],
        "AppData",
        "Roaming",
        "Adobe",
        "CameraRaw",
        "GPU",
        "Adobe DNG Converter",
        "Camera Raw GPU Config.txt",
    )


def main(arguments: list[str]) -> int:
    out_dir, inputs = parse(arguments)
    state = (
        Path(os.environ["FAKE_CONVERTER_STATE"]) if "FAKE_CONVERTER_STATE" in os.environ else None
    )
    run_id = f"{time.time_ns()}-{os.getpid()}"
    if state is not None:
        (state / "runs").mkdir(parents=True, exist_ok=True)
        record = {"inputs": [path.name for path in inputs], "out": out_dir.name}
        (state / "runs" / f"{run_id}.json").write_text(json.dumps(record), encoding="utf-8")

    if os.environ.get("FAKE_CONVERTER_FRESH_PREFIX") == "1":
        config = gpu_config()
        if not config.exists():
            config.parent.mkdir(parents=True, exist_ok=True)
            config.write_text("fake GPU config\n", encoding="utf-8")
            print("Assertion failed: vkd3d device (fake)", file=sys.stderr)
            return 3

    running = None
    if state is not None:
        (state / "running").mkdir(parents=True, exist_ok=True)
        (state / "concurrency").mkdir(parents=True, exist_ok=True)
        running = state / "running" / run_id
        running.write_text("", encoding="utf-8")
    try:
        settle = float(os.environ.get("FAKE_CONVERTER_SETTLE", "0"))
        if state is not None:
            time.sleep(settle)
            count = len(list((state / "running").iterdir()))
            (state / "concurrency" / run_id).write_text(str(count), encoding="utf-8")
            time.sleep(settle)
        missing = [path for path in inputs if not path.is_file()]
        if missing or not inputs:
            print(f"Error: cannot open {missing[0].name if missing else 'input'}", file=sys.stderr)
            return 1
        if names("FAKE_CONVERTER_HANG") & {path.name.casefold() for path in inputs}:
            time.sleep(3600)
        time.sleep(float(os.environ.get("FAKE_CONVERTER_DELAY", "0")))
        failed = False
        for path in inputs:
            name = path.name.casefold()
            if name in names("FAKE_CONVERTER_SKIP"):
                continue
            if name in names("FAKE_CONVERTER_FAIL"):
                failed = True
                continue
            recorded = path.name
            if name in names("FAKE_CONVERTER_WRONG_NAME"):
                recorded = "OTHER_" + path.name
            (out_dir / f"{path.stem}.dng").write_bytes(dng_bytes(recorded, path.read_bytes()))
        return 1 if failed else 0
    finally:
        if running is not None:
            running.unlink()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
