"""The converter self-test (``POST /api/v1/converter/selftest``).

Steps, in order, each reported with a detail for a person: ``installed`` (the converter is in the
Wine prefix; its version), ``display`` (the X display and the wineserver, as before a wave),
``warm-up`` (the throw-away first run in a fresh prefix, as before a wave) and, when a raw file
is named, ``conversion`` (one converter process for that file, its DNG checked as a build's is).
The first step that fails ends the test.

It uses the runner's own preparation and runs, and it holds the scheduler (``Scheduler.hold``):
it waits for a running wave to finish and no wave starts while it runs, so converter processes
of a wave and of the self-test never run side by side (the self-test runs one at a time). The
DNG it makes is thrown away: nothing goes into the cache or the database.
"""

import logging
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass

from lrrp import converter
from lrrp.runner import BatchFile, Runner
from lrrp.scheduler import Scheduler
from lrrp.settings import Settings
from lrrp.sources import Source

log = logging.getLogger(__name__)


@dataclass(frozen=True)
class Step:
    name: str
    ok: bool
    detail: str


class SelfTestBusy(Exception):
    """Another self-test is running."""


class SelfTest:
    def __init__(
        self,
        settings: Settings,
        runner: Runner,
        scheduler: Scheduler,
        converter_version: Callable[[], str | None],
    ) -> None:
        self._settings = settings
        self._runner = runner
        self._scheduler = scheduler
        self._converter_version = converter_version
        self._lock = threading.Lock()

    def run(self, source: Source | None) -> list[Step]:
        """Run the steps; ``source`` is the file to convert, or None. Raises ``SelfTestBusy``."""
        if not self._lock.acquire(blocking=False):
            raise SelfTestBusy
        try:
            with self._scheduler.hold():
                steps = self._steps(source)
        finally:
            self._lock.release()
        failed = [step for step in steps if not step.ok]
        if failed:
            log.warning("converter self-test failed at %s: %s", failed[0].name, failed[0].detail)
        else:
            log.info("converter self-test passed: %s", "; ".join(step.detail for step in steps))
        return steps

    def _steps(self, source: Source | None) -> list[Step]:
        steps = [self._installed()]
        if steps[-1].ok:
            steps.append(self._display())
        if steps[-1].ok:
            steps.append(self._warm_up())
        if steps[-1].ok and source is not None:
            steps.append(self._conversion(source))
        return steps

    def _installed(self) -> Step:
        exe = self._settings.converter_exe
        if not converter.is_installed(self._settings.wineprefix, exe):
            return Step(
                "installed",
                False,
                f"{exe} was not found in the server's Wine prefix (see docs/converter.md)",
            )
        version = self._converter_version()
        return Step("installed", True, f"{exe}, version {version or 'unknown'}")

    def _display(self) -> Step:
        problem = self._runner.prepare_display()
        if problem is not None:
            return Step("display", False, problem)
        return Step("display", True, self._runner.describe_display())

    def _warm_up(self) -> Step:
        result = self._runner.warm_up()
        if result.problem is not None:
            return Step("warm-up", False, result.problem)
        if not result.needed:
            return Step("warm-up", True, "not needed")
        return Step(
            "warm-up",
            True,
            "done: the converter's first run in this Wine prefix exited with code "
            f"{result.exit_code} and prepared the prefix",
        )

    def _conversion(self, source: Source) -> Step:
        file = BatchFile(
            key="selftest",
            file=source.file,
            name=source.name,
            identity=(source.size, source.mtime_ns),
        )
        started = time.monotonic()
        [result] = self._runner.run([[file]], final=True)
        elapsed = time.monotonic() - started
        try:
            if not result.ok or result.output is None or result.tags is None:
                detail = result.message or "Adobe DNG Converter failed"
                tail = self._runner.output_tail(result)
                if tail:
                    detail += f"; its last output: {tail}"
                return Step("conversion", False, detail)
            size = result.output.stat().st_size
            made = f"{source.name} → {size} bytes in {elapsed:.1f} s"
            if result.tags.original_width is None or result.tags.original_height is None:
                return Step(
                    "conversion",
                    False,
                    f"{made}, but the DNG does not record the original's pixel size "
                    "(OriginalDefaultFinalSize), which the plug-in checks",
                )
            return Step("conversion", True, f"{made}, original name and size recorded")
        except OSError as exc:
            reason = exc.strerror or type(exc).__name__
            return Step("conversion", False, f"The converter's output cannot be read ({reason})")
        finally:
            self._runner.discard([result])
