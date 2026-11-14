"""The CPU temperature for the dashboard, read from Linux sysfs.

The hottest reading of the CPU's own sensors: the ``hwmon`` devices of the CPU temperature
drivers (``coretemp`` for Intel: package and cores; ``k10temp`` and ``zenpower`` for AMD), else
the CPU thermal zones (``x86_pkg_temp``, ``cpu-thermal`` and the like). Other sensors (disks,
chipset, the ACPI zone that often reports a fixed value) are not CPU temperatures and are left
out. On AMD, ``Tctl`` can carry an offset over the real die temperature; when the driver also
reports ``Tdie``, ``Tctl`` is ignored.

Nothing is readable outside Linux, nor where the container does not see ``/sys``: the answer is
then None. Reading never raises.
"""

import logging
import sys
from pathlib import Path

log = logging.getLogger(__name__)

LINUX_SYSFS = Path("/sys")

CPU_HWMON_DRIVERS = frozenset({"coretemp", "k10temp", "zenpower", "cpu_thermal", "cpu-thermal"})
AMD_DRIVERS = frozenset({"k10temp", "zenpower"})

PLAUSIBLE = (-40.0, 150.0)
"""Readings outside this range (degrees Celsius) are sensor errors and are ignored."""


def cpu_temperature(sysfs: Path | None = None) -> float | None:
    """Degrees Celsius of the hottest CPU sensor, to 0.1 degree, or None.

    ``sysfs`` is where sysfs is mounted; the default is ``/sys`` on Linux and nothing elsewhere.
    """
    if sysfs is None:
        if not sys.platform.startswith("linux"):
            return None
        sysfs = LINUX_SYSFS
    try:
        readings = _hwmon_readings(sysfs / "class" / "hwmon")
        if not readings:
            readings = _thermal_zone_readings(sysfs / "class" / "thermal")
    except Exception as exc:  # a sensor must never break the status
        log.debug("cannot read the CPU temperature: %s", exc)
        return None
    return round(max(readings), 1) if readings else None


def _hwmon_readings(folder: Path) -> list[float]:
    readings: list[float] = []
    for device in _entries(folder):
        driver = _text(device / "name")
        if driver not in CPU_HWMON_DRIVERS:
            continue
        labelled: dict[str, float] = {}
        for sensor in sorted(device.glob("temp*_input")):
            value = _celsius(sensor)
            if value is None:
                continue
            label = _text(sensor.with_name(sensor.name.replace("_input", "_label"))) or sensor.name
            labelled[label] = value
        if driver in AMD_DRIVERS and "Tdie" in labelled:
            labelled.pop("Tctl", None)
        readings.extend(labelled.values())
    return readings


def _thermal_zone_readings(folder: Path) -> list[float]:
    readings: list[float] = []
    for zone in _entries(folder):
        if not zone.name.startswith("thermal_zone"):
            continue
        kind = (_text(zone / "type") or "").lower()
        if kind == "x86_pkg_temp" or "cpu" in kind or kind.startswith("soc"):
            value = _celsius(zone / "temp")
            if value is not None:
                readings.append(value)
    return readings


def _entries(folder: Path) -> list[Path]:
    try:
        return sorted(folder.iterdir())
    except OSError:
        return []


def _text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return None


def _celsius(path: Path) -> float | None:
    """A sysfs temperature (millidegrees Celsius) in degrees, or None if unreadable or absurd."""
    text = _text(path)
    if not text:
        return None
    try:
        value = int(text) / 1000
    except ValueError:
        return None
    low, high = PLAUSIBLE
    return value if low < value < high else None
