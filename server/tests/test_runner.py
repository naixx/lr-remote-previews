import itertools
import os
import sys
from dataclasses import replace
from pathlib import Path
from typing import Any

import pytest

from conftest import FAKE_CONVERTER, WINE_USER, to_fake_path
from lrrp.converter import gpu_config_path
from lrrp.display import NoDisplay
from lrrp.runner import (
    BatchFile,
    Runner,
    RunnerConfig,
    default_config,
    plan_wave,
    process_count,
)
from lrrp.settings import Settings


def files(*names: str) -> list[BatchFile]:
    return [
        BatchFile(key=f"{index:064x}", file=Path(name), name=name)
        for index, name in enumerate(names)
    ]


def distinct(count: int) -> list[BatchFile]:
    return files(*(f"IMG_{index:04d}.ARW" for index in range(count)))


@pytest.mark.parametrize(
    ("count", "workers", "batch_size", "expected"),
    [
        (0, 4, 8, 0),
        (1, 4, 8, 1),
        (8, 4, 8, 1),
        (9, 4, 8, 3),  # two batches would be needed: three instead
        (16, 4, 8, 3),
        (17, 4, 8, 3),
        (25, 4, 8, 4),
        (2, 4, 1, 1),  # two files can never fill three processes: one
        (3, 4, 1, 3),
        (3, 1, 8, 1),
        (100, 6, 8, 6),
        (9, 3, 8, 3),
    ],
)
def test_process_count(count: int, workers: int, batch_size: int, expected: int) -> None:
    assert process_count(count, workers, batch_size) == expected


def test_plan_splits_evenly() -> None:
    batches, later = plan_wave(distinct(10), workers=4, batch_size=8)
    assert [len(batch) for batch in batches] == [4, 3, 3]
    assert later == []
    batches, later = plan_wave(distinct(40), workers=4, batch_size=8)
    assert [len(batch) for batch in batches] == [8, 8, 8, 8]
    assert [file.name for file in later] == [f"IMG_{index:04d}.ARW" for index in range(32, 40)]


def test_plan_with_two_files_and_batches_of_one() -> None:
    batches, later = plan_wave(distinct(2), workers=4, batch_size=1)
    assert [len(batch) for batch in batches] == [1]
    assert len(later) == 1


def test_plan_keeps_files_with_the_same_base_name_apart() -> None:
    wave = files("a/IMG_1.ARW", "b/IMG_1.ARW", "c/img_1.cr2", "d/IMG_2.ARW")
    batches, later = plan_wave(wave, workers=1, batch_size=8)
    assert [[file.name for file in batch] for batch in batches] == [["a/IMG_1.ARW", "d/IMG_2.ARW"]]
    assert [file.name for file in later] == ["b/IMG_1.ARW", "c/img_1.cr2"]


@pytest.mark.parametrize("workers", [1, 3, 4, 6])
@pytest.mark.parametrize("batch_size", [1, 2, 3, 8])
def test_plan_invariants(workers: int, batch_size: int) -> None:
    """Never two batches, never too many, no base name twice in a batch, nothing lost."""
    patterns = ["distinct", "pairs", "same", "mixed"]
    for count, pattern in itertools.product(range(0, 3 * workers * batch_size + 3), patterns):
        if pattern == "distinct":
            names = [f"d/IMG_{index}.ARW" for index in range(count)]
        elif pattern == "pairs":
            names = [f"{index % 2}/IMG_{index // 2}.ARW" for index in range(count)]
        elif pattern == "same":
            names = [f"{index}/IMG_0001.ARW" for index in range(count)]
        else:
            names = [f"{index}/IMG_{index % 3}.ARW" for index in range(count)]
        wave = [
            BatchFile(key=str(index), file=Path(name), name=name.rsplit("/", 1)[-1])
            for index, name in enumerate(names)
        ]
        batches, later = plan_wave(wave, workers, batch_size)
        context = (count, pattern)
        assert len(batches) != 2, context
        assert len(batches) <= workers, context
        assert all(1 <= len(batch) <= batch_size for batch in batches), context
        for batch in batches:
            bases = [file.base for file in batch]
            assert len(bases) == len(set(bases)), context
        placed = [file for batch in batches for file in batch]
        assert sorted(f.key for f in placed + later) == sorted(f.key for f in wave), context
        if wave:
            assert placed, f"a wave always makes progress {context}"
        if pattern == "distinct" and count:
            sizes = [len(batch) for batch in batches]
            assert max(sizes) - min(sizes) <= 1, context


@pytest.mark.parametrize(("workers", "batch_size"), [(2, 8), (0, 8), (4, 0)])
def test_plan_refuses_bad_limits(workers: int, batch_size: int) -> None:
    with pytest.raises(ValueError, match="bad wave limits"):
        plan_wave(distinct(3), workers, batch_size)


def make_runner(tmp_path: Path, **values: Any) -> Runner:
    """A runner with the fake converter; ``values`` replace fields of its configuration."""
    work = tmp_path / "work"
    work.mkdir(exist_ok=True)
    counter = itertools.count()

    def new_work_dir(prefix: str) -> Path:
        folder = work / f"{prefix}{next(counter)}"
        folder.mkdir()
        return folder

    config = RunnerConfig(
        command_prefix=(sys.executable, str(FAKE_CONVERTER)),
        env={**os.environ, "WINEPREFIX": str(tmp_path / "wine"), "USER": WINE_USER},
        to_converter_path=to_fake_path,
    )
    return Runner(replace(config, **values), new_work_dir, NoDisplay())


def test_the_runner_refuses_exactly_two_processes(tmp_path: Path) -> None:
    runner = make_runner(tmp_path)
    two = [distinct(1), files("IMG_9999.ARW")]
    with pytest.raises(ValueError, match="never run exactly two"):
        runner.run(two, final=False)


def test_a_run_and_its_results(tmp_path: Path) -> None:
    source = tmp_path / "IMG_0001.ARW"
    source.write_bytes(b"raw")
    missing = tmp_path / "IMG_0002.ARW"
    runner = make_runner(tmp_path)
    one = BatchFile(key="a" * 64, file=source, name="IMG_0001.ARW")
    gone = BatchFile(key="b" * 64, file=missing, name="IMG_0002.ARW")

    [result] = runner.run([[one]], final=False)
    assert result.ok
    assert result.output is not None and result.output.name == "IMG_0001.dng"
    assert result.tags is not None and result.tags.original_name == "IMG_0001.ARW"
    runner.discard([result])
    assert not result.work_dir.exists()

    # A missing input fails the whole batch (exit code 1): first round asks for a retry...
    results = runner.run([[one, gone]], final=False)
    assert [r.retry for r in results] == [True, True]
    assert all(r.output is None for r in results)
    # ...and the final round reports it.
    [result] = runner.run([[gone]], final=True)
    assert result.error == "converter_failed"
    assert result.message == "Adobe DNG Converter exited with code 1 when run with this file alone"
    assert runner.busy == 0


def test_a_converter_that_cannot_be_started(tmp_path: Path) -> None:
    runner = make_runner(tmp_path, command_prefix=(str(tmp_path / "no-such-program"),))
    source = tmp_path / "IMG_0001.ARW"
    source.write_bytes(b"raw")
    batch = [BatchFile(key="a" * 64, file=source, name="IMG_0001.ARW")]
    [result] = runner.run([batch], final=True)
    assert result.error == "converter_failed"
    assert result.message is not None
    assert result.message.startswith("Adobe DNG Converter could not be started")
    assert str(tmp_path) not in result.message


def test_warm_up_only_when_the_config_file_is_missing(tmp_path: Path) -> None:
    config = gpu_config_path(tmp_path / "wine", WINE_USER)
    runner = make_runner(tmp_path, gpu_config=config)
    message = runner.prepare()
    assert message is not None
    assert "could not initialise" in message
    config.parent.mkdir(parents=True)
    config.write_text("x", encoding="utf-8")
    assert runner.prepare() is None


def test_abort_stops_running_converters_and_refuses_new_ones(tmp_path: Path) -> None:
    source = tmp_path / "IMG_0001.ARW"
    source.write_bytes(b"raw")
    runner = make_runner(tmp_path)
    runner.abort()
    [result] = runner.run([[BatchFile(key="a" * 64, file=source, name="IMG_0001.ARW")]], final=True)
    assert result.error == "aborted"
    assert runner.busy == 0


def test_default_config(tmp_path: Path) -> None:
    settings = Settings.from_env({"LRRP_DATA_DIR": "/srv/data"})
    config = default_config(
        settings, {"USER": "someone", "WINEPREFIX": "/elsewhere", "PATH": "/bin"}
    )
    assert config.command_prefix == ("wine", settings.converter_exe)
    assert config.env["WINEPREFIX"] == str(settings.wineprefix)
    assert config.env["WINEDEBUG"] == "-all"
    assert config.env["PATH"] == "/bin"
    assert config.gpu_config == gpu_config_path(settings.wineprefix, "someone")
    assert config.wineserver == ("wineserver", "-p")
    assert "-mp" not in config.command_prefix
    # Without USER the profile is the one the container entrypoint uses.
    config = default_config(settings, {})
    assert config.env["USER"] == "lrrp"
    assert config.gpu_config == gpu_config_path(settings.wineprefix, "lrrp")
