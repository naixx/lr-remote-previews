import os
import sys
from pathlib import Path
from typing import Any

import pytest

from lrrp.display import DisplayError, NoDisplay, Xvfb

# Stands in for Xvfb: reports its display on the -displayfd pipe (or misbehaves), then waits.
FAKE_XVFB = """
import os, sys, time
mode, display = sys.argv[1], sys.argv[2]
assert display.startswith(":"), sys.argv
fd = int(sys.argv[sys.argv.index("-displayfd") + 1])
rest = sys.argv[sys.argv.index("-displayfd") + 2:]
assert rest == ["-screen", "0", "1280x1024x24", "-nolisten", "tcp"], sys.argv
if mode == "exit" or (mode == "first-taken" and display == ":99"):
    sys.exit(1)
if mode == "garbage":
    os.write(fd, b"what\\n")
elif mode != "silent":
    os.write(fd, display[1:].encode() + b"\\n")
time.sleep(60)
"""

posix_only = pytest.mark.skipif(os.name != "posix", reason="Xvfb is only started on Linux")


def fake_xvfb(tmp_path: Path, mode: str, **values: Any) -> Xvfb:
    script = tmp_path / "fake_xvfb.py"
    script.write_text(FAKE_XVFB, encoding="utf-8")
    return Xvfb(command=(sys.executable, str(script), mode), **values)


def test_no_display() -> None:
    display = NoDisplay()
    assert display.ensure() is None
    display.stop()


@pytest.mark.skipif(os.name == "posix", reason="only off Linux")
def test_xvfb_is_refused_off_linux() -> None:
    with pytest.raises(DisplayError, match="only be started on Linux"):
        Xvfb().ensure()


@posix_only
def test_xvfb_starts_once_and_again_after_it_died(tmp_path: Path) -> None:
    display = fake_xvfb(tmp_path, "ok")
    try:
        assert display.ensure() == ":99"
        first = display._process
        assert first is not None
        assert display.ensure() == ":99"
        assert display._process is first, "a running Xvfb is reused"
        first.kill()
        first.wait()
        assert display.ensure() == ":99"
        assert display._process is not first, "a dead Xvfb is replaced"
    finally:
        display.stop()
    assert display._process is None


@posix_only
def test_a_taken_display_is_skipped(tmp_path: Path) -> None:
    display = fake_xvfb(tmp_path, "first-taken")
    try:
        assert display.ensure() == ":100"
    finally:
        display.stop()


@posix_only
@pytest.mark.parametrize(
    ("mode", "message"),
    [
        ("exit", "could not start on any display from :99 to :101"),
        ("garbage", "instead of a display number"),
        ("silent", "no display within"),
    ],
)
def test_xvfb_that_fails_to_start(tmp_path: Path, mode: str, message: str) -> None:
    display = fake_xvfb(tmp_path, mode, start_timeout=1.0, attempts=3)
    with pytest.raises(DisplayError, match=message):
        display.ensure()
    display.stop()


@posix_only
def test_a_missing_xvfb(tmp_path: Path) -> None:
    display = Xvfb(command=(str(tmp_path / "no-such-xvfb"),))
    with pytest.raises(DisplayError, match="cannot start"):
        display.ensure()
