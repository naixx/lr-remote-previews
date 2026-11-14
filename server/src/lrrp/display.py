"""The X display the converter needs: one Xvfb for the whole server.

Adobe DNG Converter needs an X display even on the command line. Instead of wrapping every run in
``xvfb-run``, the server keeps one Xvfb child: started on first use, started again if it dies,
stopped at shutdown. Like ``xvfb-run -a`` it takes the first display from ``:99`` up that Xvfb
can open (a display in use, or locked by a live process, makes Xvfb exit, and the next number is
tried). Xvfb reports on a ``-displayfd`` pipe when it is ready.
"""

import logging
import os
import select
import subprocess
import threading
import time
from collections.abc import Sequence
from typing import Protocol

log = logging.getLogger(__name__)

XVFB_ARGS = ("-screen", "0", "1280x1024x24", "-nolisten", "tcp")
FIRST_DISPLAY = 99
DISPLAY_ATTEMPTS = 10


class Display(Protocol):
    def ensure(self) -> str | None:
        """The ``DISPLAY`` value for the converter, starting a display if needed.

        None leaves ``DISPLAY`` as the environment has it. Raises ``DisplayError``.
        """

    def describe(self) -> str:
        """For a person: the display the converter gets (after ``ensure``)."""

    def stop(self) -> None: ...


class DisplayError(RuntimeError):
    pass


class _TryNext(Exception):
    """Xvfb exited before it was ready: the display is probably taken."""


class NoDisplay:
    """Starts nothing; the converter gets ``DISPLAY`` from the environment. For tests."""

    def ensure(self) -> str | None:
        return None

    def describe(self) -> str:
        return "the DISPLAY of the server's environment"

    def stop(self) -> None:
        pass


class Xvfb:
    def __init__(
        self,
        command: Sequence[str] = ("Xvfb",),
        args: Sequence[str] = XVFB_ARGS,
        start_timeout: float = 15.0,
        first_display: int = FIRST_DISPLAY,
        attempts: int = DISPLAY_ATTEMPTS,
    ) -> None:
        self._command = tuple(command)
        self._args = tuple(args)
        self._start_timeout = start_timeout
        self._first_display = first_display
        self._attempts = attempts
        self._lock = threading.Lock()
        self._process: subprocess.Popen[bytes] | None = None
        self._display = ""

    def ensure(self) -> str:
        with self._lock:
            if self._process is not None:
                code = self._process.poll()
                if code is None:
                    return self._display
                log.warning(
                    "Xvfb on display %s exited with code %s; starting it again", self._display, code
                )
                self._process = None
            self._process, self._display = self._start()
            log.info("Xvfb started on display %s", self._display)
            return self._display

    def describe(self) -> str:
        with self._lock:
            return f"Xvfb on {self._display}" if self._process is not None else "Xvfb, not running"

    def stop(self) -> None:
        with self._lock:
            process, self._process = self._process, None
        if process is not None:
            _terminate(process)

    def _start(self) -> tuple[subprocess.Popen[bytes], str]:
        if os.name != "posix":
            raise DisplayError("Xvfb can only be started on Linux")
        last = self._first_display + self._attempts - 1
        reason = ""
        for number in range(self._first_display, last + 1):
            try:
                return self._start_on(number), f":{number}"
            except _TryNext as exc:
                reason = str(exc)
                log.info("Xvfb could not use display :%d (%s); trying the next", number, reason)
        raise DisplayError(
            f"Xvfb could not start on any display from :{self._first_display} to "
            f":{last} (last: {reason})"
        )

    def _start_on(self, number: int) -> subprocess.Popen[bytes]:
        read_fd, write_fd = os.pipe()
        try:
            process = subprocess.Popen(
                [*self._command, f":{number}", "-displayfd", str(write_fd), *self._args],
                pass_fds=(write_fd,),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError as exc:
            os.close(read_fd)
            os.close(write_fd)
            raise DisplayError(f"cannot start {self._command[0]}: {exc.strerror or exc}") from exc
        os.close(write_fd)
        try:
            reported = self._read_report(read_fd, process)
        except BaseException:
            _terminate(process)
            raise
        finally:
            os.close(read_fd)
        if reported != number:
            _terminate(process)
            raise DisplayError(f"Xvfb was asked for display :{number} but reported :{reported}")
        return process

    def _read_report(self, fd: int, process: subprocess.Popen[bytes]) -> int:
        """Xvfb writes the display number and a newline to the ``-displayfd`` pipe when ready."""
        deadline = time.monotonic() + self._start_timeout
        data = b""
        while b"\n" not in data:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise DisplayError(f"Xvfb reported no display within {self._start_timeout:g} s")
            ready, _, _ = select.select([fd], [], [], remaining)
            if not ready:
                continue
            chunk = os.read(fd, 64)
            if not chunk:
                try:
                    code = process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    code = None
                raise _TryNext(f"Xvfb exited with code {code} before it was ready")
            data += chunk
            if len(data) > 64:
                break
        text = data.split(b"\n", 1)[0].strip()
        if not text.isdigit():
            raise DisplayError(f"Xvfb reported {text[:20]!r} instead of a display number")
        return int(text)


def _terminate(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
