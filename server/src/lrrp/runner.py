"""Runs Adobe DNG Converter: waves of batches, the warm-up of a fresh prefix, timeouts.

The rules come from measurements (see ``lrrp.converter``):

- Never ``-mp`` (``converter.converter_options`` has no way to pass it).
- The number of converter processes running at the same time is 1 or at least 3, never exactly
  2. Work runs in waves: ``plan_wave`` picks the number of processes for the files at hand (never
  2), splits the files evenly, the runner starts them together and waits for all of them before
  the next wave starts.
- A batch never holds two files with the same base name (the output is named after it), and
  every batch writes into its own fresh folder.
- One missing input fails a whole batch. The scheduler checks every source right before a wave,
  and a batch that fails, or that leaves outputs missing, is retried once, one file per process.
- A batch that runs too long is killed: its own process group only (each run starts in its own
  session), never the ``wineserver`` the runs share. The runner starts that wineserver itself,
  persistent and outside every batch's session, before the first run.
- A prefix where the converter has never run gets one warm-up run first (``Runner.prepare``).

Everything that touches Wine or X is injectable (``RunnerConfig``, ``Display``), so the tests run
a fake converter on any platform.
"""

import contextlib
import logging
import os
import shutil
import signal
import subprocess
import threading
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from lrrp.converter import (
    DEFAULT_WINE_USER,
    PREVIEW_LONG_EDGE,
    base_name_key,
    converter_arguments,
    gpu_config_path,
    wine_path,
)
from lrrp.display import Display, DisplayError
from lrrp.dng import DngError, DngTags, read_tags
from lrrp.settings import Settings

log = logging.getLogger(__name__)

POLL_INTERVAL = 0.02
"""Seconds between checks on running converter processes."""

WARM_UP_INPUT = "no-such-input.arw"
"""The input of the warm-up run. It never exists, so the run can never wait for or read a file."""

if os.name == "posix":
    _OWN_SESSION: dict[str, Any] = {"start_new_session": True}
else:  # Windows, for the tests: the fake converter's process tree is killed with taskkill.
    _OWN_SESSION = {"creationflags": getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)}


@dataclass(frozen=True)
class BatchFile:
    """One input of a batch."""

    key: str
    file: Path
    name: str
    """The file's base name with its extension, as requested: ``IMG_0001.ARW``."""
    identity: tuple[int, int] | None = None
    """Size and modification time (ns) of the source when it was requested."""

    @property
    def base(self) -> str:
        """What the output will be called, folded for comparison."""
        return base_name_key(self.name)


def process_count(files: int, workers: int, batch_size: int) -> int:
    """How many converter processes a wave of ``files`` files gets. Never 2."""
    if files <= 0:
        return 0
    count = min(workers, -(-files // batch_size))
    if count == 2:
        count = 3 if files >= 3 else 1
    return count


def plan_wave(
    files: Sequence[BatchFile], workers: int, batch_size: int
) -> tuple[list[list[BatchFile]], list[BatchFile]]:
    """Split the files at the head of the queue into the batches of one wave.

    Returns the batches (never exactly two of them, none larger than ``batch_size``, no two files
    with the same base name in one batch) and the files left for a later wave, in queue order.
    """
    if workers < 1 or workers == 2 or batch_size < 1:
        raise ValueError(f"bad wave limits: {workers} workers, batches of {batch_size}")
    limit = workers * batch_size
    taken, later = list(files[:limit]), list(files[limit:])
    count = process_count(len(taken), workers, batch_size)
    if count == 0:
        return [], later
    capacity = min(batch_size, -(-len(taken) // count))
    batches: list[list[BatchFile]] = [[] for _ in range(count)]
    names: list[set[str]] = [set() for _ in range(count)]
    left: list[BatchFile] = []
    for file in taken:
        fits = [i for i in range(count) if len(batches[i]) < capacity and file.base not in names[i]]
        if not fits:
            left.append(file)
            continue
        target = min(fits, key=lambda i: len(batches[i]))
        batches[target].append(file)
        names[target].add(file.base)
    batches = [batch for batch in batches if batch]
    if len(batches) == 2:
        # Not reachable with the placement above (every batch gets a file before any file is
        # left out); kept so that the rule holds whatever the placement becomes.
        first, second = batches
        if len(first) + len(second) >= 3:
            bigger = first if len(first) >= len(second) else second
            batches = [first, second, [bigger.pop()]]
        else:
            batches = [first]
            left = second + left
    return batches, left + later


@dataclass(frozen=True)
class RunnerConfig:
    command_prefix: tuple[str, ...]
    """The program to run: ``("wine", <converter exe>)``; the tests put a fake converter here."""
    env: Mapping[str, str]
    """The converter's environment (``DISPLAY`` is added per run)."""
    to_converter_path: Callable[..., str] = wine_path
    """Turns a server-side path into what the converter gets: ``Z:\\...``."""
    long_edge: int = PREVIEW_LONG_EDGE
    timeout_base: float = 60.0
    timeout_per_file: float = 30.0
    gpu_config: Path | None = None
    """``Camera Raw GPU Config.txt`` in the prefix; while it is missing, a warm-up run comes first.
    None skips the warm-up."""
    warm_up_timeout: float = 60.0
    wineserver: tuple[str, ...] | None = None
    """Started once before the first run, so that the shared wineserver lives in no batch's
    process group; None starts nothing."""


def default_config(settings: Settings, environ: Mapping[str, str] | None = None) -> RunnerConfig:
    """The production configuration: Wine, the converter in the prefix, ``Z:`` paths."""
    env = dict(os.environ if environ is None else environ)
    prefix = str(settings.wineprefix)
    if env.get("WINEPREFIX") not in (None, "", prefix):
        log.warning(
            "WINEPREFIX is %s but the server uses LRRP_WINEPREFIX %s for the converter",
            env["WINEPREFIX"],
            prefix,
        )
    env["WINEPREFIX"] = prefix
    env.setdefault("WINEDEBUG", "-all")
    user = env.get("USER") or DEFAULT_WINE_USER
    env["USER"] = user
    return RunnerConfig(
        command_prefix=("wine", settings.converter_exe),
        env=env,
        gpu_config=gpu_config_path(settings.wineprefix, user),
        wineserver=("wineserver", "-p"),
    )


@dataclass
class FileResult:
    """What became of one file in a run."""

    file: BatchFile
    work_dir: Path
    output: Path | None = None
    tags: DngTags | None = None
    error: str | None = None
    message: str | None = None
    retry: bool = False
    """The run failed in a way that a run with this file alone may not (first round only)."""

    @property
    def ok(self) -> bool:
        return self.output is not None and self.error is None


@dataclass
class _Run:
    work_dir: Path
    out_dir: Path
    log_path: Path
    timeout: float
    process: subprocess.Popen[bytes] | None = None
    deadline: float = 0.0
    exit_code: int | None = None
    timed_out: bool = False
    start_error: str | None = None
    aborted: bool = False
    names: list[str] = field(default_factory=list)


class Runner:
    def __init__(
        self,
        config: RunnerConfig,
        new_work_dir: Callable[[str], Path],
        display: Display,
    ) -> None:
        self.config = config
        self._new_work_dir = new_work_dir
        self._display = display
        self._display_value: str | None = None
        self._lock = threading.Lock()
        self._running: set[subprocess.Popen[bytes]] = set()
        self._aborted = False
        self._wineserver_started = False

    @property
    def busy(self) -> int:
        """Converter processes running now."""
        with self._lock:
            return len(self._running)

    def abort(self) -> None:
        """Kill every running converter and start no more. For shutdown."""
        with self._lock:
            self._aborted = True
            processes = list(self._running)
        for process in processes:
            _kill_group(process)

    def prepare(self) -> str | None:
        """Make sure the converter can run: X display, wineserver, warm-up of a fresh prefix.

        Returns None when it can, else a message for the items that cannot be built now.
        """
        try:
            self._display_value = self._display.ensure()
        except DisplayError as exc:
            log.error("no X display for the converter: %s", exc)
            return f"No X display could be started for Adobe DNG Converter ({exc})"
        self._start_wineserver()
        return self._warm_up()

    def run(self, batches: Sequence[Sequence[BatchFile]], *, final: bool) -> list[FileResult]:
        """Run one wave: start every batch together, wait for all, and check the outputs.

        ``final`` is the retry round: failures are reported instead of marked for a retry.
        """
        if len(batches) == 2:
            raise ValueError("never run exactly two converter processes side by side")
        runs = [self._new_run("batch-", self._timeout(len(batch))) for batch in batches]
        for batch, run in zip(batches, runs, strict=True):
            self._start(run, [file.file for file in batch])
            run.names = [file.name for file in batch]
        self._wait(runs)
        results: list[FileResult] = []
        for batch, run in zip(batches, runs, strict=True):
            results.extend(self._evaluate(batch, run, final))
        return results

    def discard(self, results: Sequence[FileResult]) -> None:
        """Remove the batch folders of these results (after their DNGs went into the cache)."""
        for folder in {result.work_dir for result in results}:
            shutil.rmtree(folder, ignore_errors=True)

    # --- Running processes ----------------------------------------------------------------------

    def _timeout(self, files: int) -> float:
        return self.config.timeout_base + self.config.timeout_per_file * files

    def _new_run(self, prefix: str, timeout: float) -> _Run:
        work_dir = self._new_work_dir(prefix)
        out_dir = work_dir / "out"
        out_dir.mkdir()
        return _Run(
            work_dir=work_dir, out_dir=out_dir, log_path=work_dir / "converter.log", timeout=timeout
        )

    def _start(self, run: _Run, inputs: Sequence[Path]) -> None:
        try:
            arguments = converter_arguments(
                inputs,
                run.out_dir,
                long_edge=self.config.long_edge,
                to_converter_path=self.config.to_converter_path,
            )
        except ValueError as exc:
            log.error("cannot pass this batch to the converter: %s", exc)
            run.start_error = "a path in the batch cannot be passed to the converter"
            return
        env = dict(self.config.env)
        if self._display_value:
            env["DISPLAY"] = self._display_value
        with self._lock:
            if self._aborted:
                run.aborted = True
                return
            try:
                with run.log_path.open("wb") as log_file:
                    run.process = subprocess.Popen(
                        [*self.config.command_prefix, *arguments],
                        stdin=subprocess.DEVNULL,
                        stdout=log_file,
                        stderr=subprocess.STDOUT,
                        env=env,
                        cwd=run.work_dir,
                        **_OWN_SESSION,
                    )
            except OSError as exc:
                log.error("cannot start the converter %s: %s", self.config.command_prefix, exc)
                run.start_error = exc.strerror or type(exc).__name__
                return
            self._running.add(run.process)
        run.deadline = time.monotonic() + run.timeout

    def _wait(self, runs: Sequence[_Run]) -> None:
        pending = [run for run in runs if run.process is not None]
        while pending:
            now = time.monotonic()
            for run in list(pending):
                assert run.process is not None
                code = run.process.poll()
                if code is None and now >= run.deadline:
                    log.warning(
                        "converter batch %s ran longer than %g s; stopping its process group",
                        run.work_dir.name,
                        run.timeout,
                    )
                    _kill_group(run.process)
                    run.timed_out = True
                    code = run.process.wait()
                if code is not None:
                    run.exit_code = code
                    pending.remove(run)
                    with self._lock:
                        self._running.discard(run.process)
                        run.aborted = run.aborted or self._aborted
            if pending:
                time.sleep(POLL_INTERVAL)

    # --- Results --------------------------------------------------------------------------------

    def _evaluate(self, batch: Sequence[BatchFile], run: _Run, final: bool) -> list[FileResult]:
        def result(file: BatchFile, **values: Any) -> FileResult:
            return FileResult(file=file, work_dir=run.work_dir, **values)

        if run.aborted:
            return [result(f, error="aborted", message="The server is stopping") for f in batch]
        failure: tuple[str, str] | None = None
        if run.start_error is not None:
            failure = (
                "converter_failed",
                f"Adobe DNG Converter could not be started: {run.start_error}",
            )
        elif run.timed_out:
            failure = (
                "converter_timeout",
                f"Adobe DNG Converter did not finish within {run.timeout:g} s and was stopped",
            )
        elif run.exit_code != 0:
            failure = ("converter_failed", f"Adobe DNG Converter exited with code {run.exit_code}")
        if failure is not None:
            log.warning(
                "converter batch %s (%s) failed: %s%s",
                run.work_dir.name,
                ", ".join(run.names),
                failure[1],
                _log_excerpt(run.log_path),
            )
            if not final:
                return [result(file, retry=True) for file in batch]
            alone = " when run with this file alone" if len(batch) == 1 else ""
            return [result(file, error=failure[0], message=failure[1] + alone) for file in batch]

        outputs: dict[str, Path] = {}
        try:
            for path in run.out_dir.iterdir():
                if path.is_file():
                    outputs[path.name.casefold()] = path
        except OSError as exc:
            log.warning("cannot list the output folder %s: %s", run.out_dir, exc)
        results = []
        for file in batch:
            produced = outputs.get(file.base + ".dng")
            if produced is None:
                if final:
                    results.append(
                        result(
                            file,
                            error="output_missing",
                            message="Adobe DNG Converter finished but wrote no DNG for this file",
                        )
                    )
                else:
                    results.append(result(file, retry=True))
                continue
            results.append(self._check(file, produced, result))
        return results

    @staticmethod
    def _check(file: BatchFile, produced: Path, result: Callable[..., FileResult]) -> FileResult:
        """The DNG must name the requested file as its original, or it is not used."""
        try:
            tags = read_tags(produced)
        except (DngError, OSError) as exc:
            return result(
                file,
                error="output_mismatch",
                message=f"The converter's output is not a DNG this server can read ({exc})",
            )
        if tags.original_name is None:
            return result(
                file, error="output_mismatch", message="The DNG does not name its original file"
            )
        if tags.original_name.casefold() != file.name.casefold():
            return result(
                file,
                error="output_mismatch",
                message=(
                    f"The DNG names {tags.original_name!r} as its original, not {file.name!r}"
                ),
            )
        return result(file, output=produced, tags=tags)

    # --- Preparation ----------------------------------------------------------------------------

    def _start_wineserver(self) -> None:
        command = self.config.wineserver
        if self._wineserver_started or not command:
            return
        self._wineserver_started = True
        try:
            process = subprocess.Popen(
                list(command),
                env=dict(self.config.env),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                **_OWN_SESSION,
            )
        except OSError as exc:
            log.warning("cannot start %s (%s); the converter starts its own", command[0], exc)
            return
        try:
            code = process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            log.info("%s keeps running in the foreground", command[0])
            return
        log.info("started a persistent wineserver (%s exited with code %s)", command[0], code)

    def _warm_up(self) -> str | None:
        config_file = self.config.gpu_config
        if config_file is None or config_file.is_file():
            return None
        log.info(
            "Adobe DNG Converter has not run in this Wine prefix yet (no %r); warming it up",
            config_file.name,
        )
        run = self._new_run("warm-up-", self.config.warm_up_timeout)
        run.names = [WARM_UP_INPUT]
        self._start(run, [run.work_dir / WARM_UP_INPUT])
        self._wait([run])
        excerpt = _tail(run.log_path)
        shutil.rmtree(run.work_dir, ignore_errors=True)
        if config_file.is_file():
            log.info("warm-up done (the run exited with code %s)", run.exit_code)
            return None
        if run.aborted:
            return "The server is stopping"
        if run.start_error is not None:
            how = f"it could not be started: {run.start_error}"
        elif run.timed_out:
            how = f"the warm-up run did not finish within {run.timeout:g} s"
        else:
            how = f"the warm-up run exited with code {run.exit_code}"
        log.error(
            "Adobe DNG Converter could not initialise in its Wine prefix: %s; %s is still missing."
            " Its last output: %s",
            how,
            config_file,
            excerpt or "(none)",
        )
        message = f"Adobe DNG Converter could not initialise in its Wine prefix ({how})"
        if excerpt:
            message += f"; its last output: {excerpt}"
        return message


def _kill_group(process: subprocess.Popen[bytes]) -> None:
    """Kill a converter run and everything it started, but nothing outside its session."""
    if os.name == "posix":
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.killpg(process.pid, signal.SIGKILL)
        return
    subprocess.run(
        ["taskkill", "/F", "/T", "/PID", str(process.pid)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    with contextlib.suppress(OSError):
        process.kill()


def _tail(path: Path, lines: int = 5, limit: int = 600) -> str:
    """The last few lines of a converter log, on one line, for a message."""
    try:
        with path.open("rb") as file:
            file.seek(0, os.SEEK_END)
            file.seek(max(0, file.tell() - 8192))
            text = file.read().decode("utf-8", errors="replace")
    except OSError:
        return ""
    kept = [line.strip() for line in text.splitlines() if line.strip()][-lines:]
    joined = " | ".join(kept)
    return joined if len(joined) <= limit else "..." + joined[-limit:]


def _log_excerpt(path: Path) -> str:
    excerpt = _tail(path)
    return f"; last output: {excerpt}" if excerpt else ""
