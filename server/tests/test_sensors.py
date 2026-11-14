"""The CPU temperature from a fake sysfs tree."""

import sys
from pathlib import Path

import pytest

from lrrp import sensors
from lrrp.sensors import cpu_temperature


def hwmon(sysfs: Path, number: int, driver: str, **sensors_: tuple[str | None, str]) -> None:
    """A hwmon device: ``temp1=("Package id 0", "67500")`` writes temp1_label and temp1_input."""
    device = sysfs / "class" / "hwmon" / f"hwmon{number}"
    device.mkdir(parents=True)
    (device / "name").write_text(driver + "\n", encoding="utf-8")
    for sensor, (label, value) in sensors_.items():
        (device / f"{sensor}_input").write_text(value + "\n", encoding="utf-8")
        if label is not None:
            (device / f"{sensor}_label").write_text(label + "\n", encoding="utf-8")


def zone(sysfs: Path, number: int, kind: str, value: str) -> None:
    folder = sysfs / "class" / "thermal" / f"thermal_zone{number}"
    folder.mkdir(parents=True)
    (folder / "type").write_text(kind + "\n", encoding="utf-8")
    (folder / "temp").write_text(value + "\n", encoding="utf-8")


def test_intel_package_and_cores(tmp_path: Path) -> None:
    hwmon(
        tmp_path,
        0,
        "coretemp",
        temp1=("Package id 0", "67500"),
        temp2=("Core 0", "72125"),
        temp3=("Core 4", "70000"),
    )
    hwmon(tmp_path, 1, "nvme", temp1=("Composite", "81850"))  # a disk, not the CPU
    hwmon(tmp_path, 2, "acpitz", temp1=(None, "95000"))
    zone(tmp_path, 0, "x86_pkg_temp", "99000")  # zones only count without a CPU hwmon
    assert cpu_temperature(tmp_path) == 72.1


def test_amd_tdie_wins_over_an_offset_tctl(tmp_path: Path) -> None:
    hwmon(tmp_path, 0, "k10temp", temp1=("Tctl", "77000"), temp2=("Tdie", "50000"))
    hwmon(tmp_path, 1, "k10temp", temp3=("Tccd1", "48000"))
    assert cpu_temperature(tmp_path) == 50.0
    other = tmp_path / "other"
    hwmon(other, 0, "zenpower", temp1=("Tctl", "61000"), temp3=("Tccd1", "58000"))
    assert cpu_temperature(other) == 61.0, "without Tdie, Tctl is the die temperature"


def test_thermal_zones_when_no_cpu_hwmon(tmp_path: Path) -> None:
    hwmon(tmp_path, 0, "nvme", temp1=("Composite", "40000"))
    zone(tmp_path, 0, "acpitz", "27800")
    zone(tmp_path, 1, "x86_pkg_temp", "64000")
    zone(tmp_path, 2, "cpu-thermal", "66000")
    zone(tmp_path, 3, "iwlwifi_1", "90000")
    assert cpu_temperature(tmp_path) == 66.0


@pytest.mark.parametrize("value", ["", "abc", "-273150", "255000", "nan"])
def test_unreadable_or_absurd_readings_are_ignored(tmp_path: Path, value: str) -> None:
    hwmon(tmp_path, 0, "coretemp", temp1=("Package id 0", value), temp2=("Core 0", "55000"))
    assert cpu_temperature(tmp_path) == 55.0
    lonely = tmp_path / "lonely"
    hwmon(lonely, 0, "coretemp", temp1=("Package id 0", value))
    assert cpu_temperature(lonely) is None


def test_nothing_readable_is_none(tmp_path: Path) -> None:
    assert cpu_temperature(tmp_path / "missing") is None
    assert cpu_temperature(tmp_path) is None
    (tmp_path / "class" / "hwmon").mkdir(parents=True)
    (tmp_path / "class" / "hwmon" / "hwmon0").write_text("not a folder", encoding="utf-8")
    assert cpu_temperature(tmp_path) is None


def test_off_linux_nothing_is_read(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(sys, "platform", "win32")
    assert cpu_temperature() is None


def test_a_failing_read_never_raises(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    hwmon(tmp_path, 0, "coretemp", temp1=("Package id 0", "50000"))

    def broken(_folder: Path) -> list[float]:
        raise RuntimeError("unexpected")

    monkeypatch.setattr(sensors, "_hwmon_readings", broken)
    assert cpu_temperature(tmp_path) is None
