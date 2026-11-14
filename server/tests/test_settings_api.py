"""Runtime settings through the HTTP API, and what they do to the scheduler; status and health."""

import json
import math
import time
from datetime import datetime
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from conftest import Harness, post_job, wait_for, wait_job
from lrrp import scheduler
from lrrp.settings import auto_workers, available_cpus


def get_settings(client: TestClient) -> dict[str, Any]:
    response = client.get("/api/v1/settings")
    assert response.status_code == 200, response.text
    return response.json()


def patch(client: TestClient, body: Any, expect: int = 200) -> dict[str, Any]:
    response = client.patch("/api/v1/settings", json=body)
    assert response.status_code == expect, response.text
    return response.json()


def status(client: TestClient) -> dict[str, Any]:
    return client.get("/api/v1/status").json()


def busy(client: TestClient) -> bool:
    response = client.get("/healthz")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    return body["busy"]


def counts(client: TestClient, job_id: int) -> dict[str, int]:
    return client.get(f"/api/v1/jobs/{job_id}").json()["job"]["counts"]


DEFAULT_HOURS = {"enabled": False, "from": "22:00", "to": "07:00"}
DEFAULT_SCAN = {
    "enabled": False,
    "roots": [],
    "intervalMinutes": 60,
    "settleMinutes": 15,
    "maxFilesPerRun": 2000,
}
DEFAULT_CACHE = {"maxBytes": None, "maxAgeDays": None}


def test_settings_start_from_the_environment_and_round_trip(harness: Harness) -> None:
    with harness.client(workers=4, batch_size=8) as client:
        assert get_settings(client) == {
            "workers": 4,
            "effectiveWorkers": 4,
            "batchSize": 8,
            "paused": False,
            "workingHours": DEFAULT_HOURS,
            "autoScan": DEFAULT_SCAN,
            "cache": DEFAULT_CACHE,
        }
        changed = patch(
            client,
            {
                "workers": 3,
                "batchSize": 2,
                "paused": True,
                "workingHours": {"enabled": True, "from": "23:30", "to": "06:15"},
            },
        )
        assert changed == {
            "workers": 3,
            "effectiveWorkers": 3,
            "batchSize": 2,
            "paused": True,
            "workingHours": {"enabled": True, "from": "23:30", "to": "06:15"},
            "autoScan": DEFAULT_SCAN,
            "cache": DEFAULT_CACHE,
        }
        assert get_settings(client) == changed
        assert status(client)["workers"]["configured"] == 3
        # A subset changes only what it names; nothing at all changes nothing. Read-only and
        # unknown fields are ignored.
        assert patch(client, {"paused": False}) == {**changed, "paused": False}
        assert patch(client, {}) == {**changed, "paused": False}
        assert patch(client, {"effectiveWorkers": 9, "colour": "red"}) == {
            **changed,
            "paused": False,
        }
        auto = patch(client, {"workers": "auto"})
        assert auto["workers"] == "auto"
        assert auto["effectiveWorkers"] == auto_workers(available_cpus())
        assert status(client)["workers"]["configured"] == auto["effectiveWorkers"]


def test_auto_from_the_environment(harness: Harness) -> None:
    with harness.client(workers="auto") as client:
        settings = get_settings(client)
        assert settings["workers"] == "auto"
        assert settings["effectiveWorkers"] == auto_workers(available_cpus())


@pytest.mark.parametrize(
    ("body", "fragment"),
    [
        ({"workers": 2}, "workers: 2 is not allowed"),
        ({"workers": 0}, "workers: must be"),
        ({"workers": 33}, "workers: must be"),
        ({"workers": "four"}, "workers: must be"),
        ({"workers": 3.5}, "workers: must be"),
        ({"workers": 3.0}, "workers: must be"),
        ({"workers": True}, "workers: must be"),
        ({"workers": None}, "workers: must be"),
        ({"batchSize": 0}, "batchSize: must be a whole number from 1 to 64"),
        ({"batchSize": 65}, "batchSize: must be a whole number from 1 to 64"),
        ({"batchSize": "8"}, "batchSize: must be"),
        ({"batchSize": None}, "batchSize: must be"),
        ({"paused": "yes"}, "paused: must be true or false"),
        ({"paused": 1}, "paused: must be true or false"),
        ({"paused": None}, "paused: must be true or false"),
        ({"workingHours": None}, "workingHours: must be an object"),
        ({"workingHours": "22:00-07:00"}, "workingHours: must be an object"),
        ({"workingHours": {"enabled": True, "from": "22:00"}}, "workingHours: 'to' missing"),
        (
            {"workingHours": {"enabled": 1, "from": "22:00", "to": "07:00"}},
            'workingHours: "enabled" must be true or false',
        ),
        (
            {"workingHours": {"enabled": True, "from": "25:00", "to": "07:00"}},
            'workingHours: "from" must be a time of day as HH:MM',
        ),
        (
            {"workingHours": {"enabled": True, "from": "22:00", "to": "7:00"}},
            'workingHours: "to" must be a time of day as HH:MM',
        ),
        (
            {"workingHours": {"enabled": False, "from": "08:00", "to": "08:00"}},
            'workingHours: "from" and "to" must differ',
        ),
        # One bad value refuses the whole change.
        ({"paused": True, "batchSize": 4, "workers": 2}, "workers: 2 is not allowed"),
        ([], "Input should be a valid dictionary"),
        ("paused", "Input should be a valid dictionary"),
        ({"autoScan": None}, 'autoScan: must be an object with "enabled"'),
        (
            {"autoScan": {"enabled": True}},
            "autoScan: 'roots', 'intervalMinutes', 'settleMinutes', 'maxFilesPerRun' missing",
        ),
        (
            {"autoScan": {**DEFAULT_SCAN, "intervalMinutes": 1}},
            'autoScan: "intervalMinutes" must be a whole number from 5 to 1440',
        ),
        (
            {"autoScan": {**DEFAULT_SCAN, "roots": ["archive", "nowhere", "elsewhere"]}},
            "autoScan: the server has no root 'nowhere', 'elsewhere'",
        ),
        (
            {"paused": True, "autoScan": {**DEFAULT_SCAN, "roots": ["nowhere"]}},
            "autoScan: the server has no root 'nowhere'",
        ),
        ({"cache": None}, 'cache: must be an object with "maxBytes" and "maxAgeDays"'),
        ({"cache": {"maxBytes": None}}, "cache: 'maxAgeDays' missing"),
        (
            {"cache": {"maxBytes": 1000, "maxAgeDays": None}},
            'cache: "maxBytes" must be null or a whole number of at least 104857600',
        ),
        (
            {"cache": {"maxBytes": None, "maxAgeDays": 0}},
            'cache: "maxAgeDays" must be null or a whole number from 1 to 3650',
        ),
    ],
)
def test_every_bad_value_is_refused_and_changes_nothing(
    harness: Harness, body: Any, fragment: str
) -> None:
    with harness.client(workers=4, batch_size=8) as client:
        before = get_settings(client)
        response = client.patch("/api/v1/settings", json=body)
        assert response.status_code == 422, response.text
        detail = response.json()["detail"]
        assert isinstance(detail, str)
        assert fragment in detail, detail
        assert "Value error" not in detail
        assert get_settings(client) == before


def test_scan_and_cache_settings_round_trip_and_survive_a_restart(harness: Harness) -> None:
    scan = {
        "enabled": True,
        "roots": ["offline", "archive"],
        "intervalMinutes": 5,
        "settleMinutes": 0,
        "maxFilesPerRun": 10,
    }
    cache = {"maxBytes": 104857600, "maxAgeDays": 30}
    with harness.client() as client:
        changed = patch(client, {"autoScan": {**scan, "roots": [*scan["roots"], "archive"]}})
        assert changed["autoScan"] == scan, "a root named twice counts once"
        assert patch(client, {"cache": cache})["cache"] == cache
        assert status(client)["autoScan"]["nextRun"] is not None
    with harness.client() as client:
        settings = get_settings(client)
        assert (settings["autoScan"], settings["cache"]) == (scan, cache)
        off = patch(client, {"autoScan": {**scan, "enabled": False}, "cache": DEFAULT_CACHE})
        assert off["autoScan"] == {**scan, "enabled": False}
        assert off["cache"] == DEFAULT_CACHE
        assert status(client)["autoScan"]["nextRun"] is None


def test_a_body_that_is_not_json_is_refused(harness: Harness) -> None:
    with harness.client() as client:
        response = client.patch(
            "/api/v1/settings", content=b"{paused", headers={"Content-Type": "application/json"}
        )
        assert response.status_code == 422
        assert response.json() == {"detail": "The request body is not valid JSON"}


def test_changed_settings_survive_a_restart(harness: Harness) -> None:
    hours = {"enabled": True, "from": "21:00", "to": "06:00"}
    with harness.client(workers=4, batch_size=8) as client:
        patch(client, {"batchSize": 3, "paused": True, "workingHours": hours})
    # The environment changed too: the values changed through the API win; workers, never
    # changed through the API, follows the environment.
    with harness.client(workers=6, batch_size=16) as client:
        assert get_settings(client) == {
            "workers": 6,
            "effectiveWorkers": 6,
            "batchSize": 3,
            "paused": True,
            "workingHours": hours,
            "autoScan": DEFAULT_SCAN,
            "cache": DEFAULT_CACHE,
        }
        patch(client, {"workers": 1})
    with harness.client(workers=6, batch_size=16) as client:
        assert get_settings(client)["workers"] == 1
        assert status(client)["state"] == "paused"


# --- Pause, working hours, workers -----------------------------------------------------------


def test_pause_and_resume_in_the_middle_of_a_multi_wave_job(harness: Harness) -> None:
    names = [f"IMG_{index:04d}.ARW" for index in range(1, 8)]
    for name in names:
        harness.raw(name)
    # Waves of three processes with one file each: 3, 3 and 1 files. The first is held.
    first = names[:3]
    harness.hold(",".join(first))
    with harness.client(workers=3, batch_size=1) as client:
        assert status(client)["state"] == "idle"
        assert busy(client) is False
        job_id = post_job(client, names)["job"]["id"]
        wait_for(
            lambda: all(harness.runs_with(name) == 1 for name in first),
            what="the first wave to start",
        )
        assert status(client)["state"] == "running"
        assert busy(client) is True

        assert patch(client, {"paused": True})["paused"] is True
        # The wave that runs is not stopped.
        assert status(client)["state"] == "running"
        assert busy(client) is True
        harness.release()
        wait_for(lambda: counts(client, job_id)["ready"] == 3, what="the first wave")
        # No new wave starts while paused.
        wait_for(lambda: status(client)["state"] == "paused", what="the paused state")
        time.sleep(1.0)
        assert len(harness.runs()) == 3
        assert counts(client, job_id)["queued"] == 4
        paused = status(client)
        assert paused["state"] == "paused"
        assert paused["queue"] == {"queued": 4, "building": 0}
        assert paused["etaSeconds"] is None
        assert busy(client) is False

        assert patch(client, {"paused": False})["paused"] is False
        job = wait_job(client, job_id)
        assert job["state"] == "done"
        assert job["counts"]["ready"] == len(names)
        assert status(client)["state"] == "idle"
        assert busy(client) is False
    for name in names:
        assert harness.runs_with(name) == 1, name


def test_working_hours_with_a_fake_clock(harness: Harness, monkeypatch: pytest.MonkeyPatch) -> None:
    # The scheduler looks at the clock again every IDLE_WAIT seconds while it may not start.
    monkeypatch.setattr(scheduler, "IDLE_WAIT", 0.05)
    names = [f"IMG_{index:04d}.ARW" for index in range(1, 5)]
    for name in names:
        harness.raw(name)
    now = [datetime(2026, 11, 14, 12, 0)]
    hours = {"enabled": True, "from": "22:00", "to": "07:00"}
    with harness.client(workers=1, batch_size=1, local_clock=lambda: now[0]) as client:
        patch(client, {"workingHours": hours})
        assert status(client)["state"] == "idle", "nothing queued: idle, whatever the hours"
        job_id = post_job(client, names)["job"]["id"]
        time.sleep(0.5)
        waiting = status(client)
        assert waiting["state"] == "waiting"
        assert waiting["etaSeconds"] is None
        assert waiting["queue"] == {"queued": 4, "building": 0}
        assert busy(client) is False
        assert harness.runs() == []

        # 22:00 opens the window. The second file's run is held; meanwhile 07:00 closes it.
        harness.hold(names[1])
        now[0] = datetime(2026, 11, 14, 22, 0)
        wait_for(lambda: harness.runs_with(names[1]) == 1, what="the second wave")
        assert status(client)["state"] == "running"
        now[0] = datetime(2026, 11, 15, 7, 0)
        harness.release()
        wait_for(lambda: counts(client, job_id)["ready"] == 2, what="the running wave")
        wait_for(lambda: status(client)["state"] == "waiting", what="the waiting state")
        time.sleep(0.5)
        assert counts(client, job_id)["queued"] == 2
        assert len(harness.runs()) == 2
        assert status(client)["state"] == "waiting"

        now[0] = datetime(2026, 11, 15, 6, 59, 59)  # back inside, a second before the end
        job = wait_job(client, job_id)
        assert job["counts"]["ready"] == len(names)
        assert status(client)["state"] == "idle"


def test_a_workers_change_applies_to_the_next_wave(harness: Harness) -> None:
    names = [f"IMG_{index:04d}.ARW" for index in range(1, 9)]
    for name in names:
        harness.raw(name)
    harness.hold(names[0])
    with harness.client(workers=1, batch_size=1) as client:
        job_id = post_job(client, names)["job"]["id"]
        wait_for(lambda: harness.runs_with(names[0]) == 1, what="the first wave")
        assert status(client)["workers"] == {"configured": 1, "busy": 1}
        changed = patch(client, {"workers": 3, "batchSize": 2})
        assert changed["effectiveWorkers"] == 3
        # The wave that runs keeps its one process.
        assert status(client)["workers"] == {"configured": 3, "busy": 1}
        # Let the first wave go and hold the next: three processes with two files each.
        second = names[1:7]
        harness.hold(",".join(second))
        wait_for(
            lambda: all(harness.runs_with(name) == 1 for name in second),
            what="the second wave to start",
        )
        wait_for(lambda: status(client)["workers"]["busy"] == 3, what="three converters")
        assert len(harness.runs()) == 4
        harness.release()
        job = wait_job(client, job_id)
        assert job["counts"]["ready"] == len(names)
        assert status(client)["workers"]["busy"] == 0
    runs = harness.runs()
    assert runs[0] == [names[0]], "the first wave: one process with one file"
    assert sorted(len(run) for run in runs[1:4]) == [2, 2, 2]
    assert sorted(name for run in runs[1:4] for name in run) == second
    assert runs[4:] == [[names[7]]], "the last file alone: one process, never two"


# --- Status and health -----------------------------------------------------------------------


def test_status_estimates_the_time_left_from_the_rate(harness: Harness) -> None:
    names = [f"IMG_{index:04d}.ARW" for index in range(1, 7)]
    for name in names:
        harness.raw(name)
    second = names[3:]
    harness.hold(",".join(second))
    with harness.client(workers=3, batch_size=1) as client:
        job_id = post_job(client, names)["job"]["id"]
        wait_for(
            lambda: all(harness.runs_with(name) == 1 for name in second),
            what="the second wave to start",
        )
        # A second job asks for the files being built: more items, the same files.
        post_job(client, second)
        running = status(client)
        assert running["state"] == "running"
        assert running["queue"] == {"queued": 3, "building": 3}
        assert running["workers"] == {"configured": 3, "busy": 3}
        assert running["rate"] == {"perMinute": 3.0, "windowSeconds": 60}
        # Three files left at three a minute.
        assert running["etaSeconds"] == math.ceil(3 * 60 / 3.0) == 60
        assert running["cpuTemperature"] is None
        assert busy(client) is True
        harness.release()
        wait_job(client, job_id)
        wait_for(lambda: status(client)["state"] == "idle", what="the idle state")
        done = status(client)
        assert done["etaSeconds"] is None
        assert done["rate"]["perMinute"] == 6.0
        assert done["queue"] == {"queued": 0, "building": 0}
        assert busy(client) is False


def test_status_reports_the_cpu_temperature(harness: Harness, tmp_path: Path) -> None:
    sysfs = tmp_path / "sys"
    device = sysfs / "class" / "hwmon" / "hwmon3"
    device.mkdir(parents=True)
    (device / "name").write_text("coretemp\n", encoding="utf-8")
    for index, (label, value) in enumerate([("Package id 0", 67500), ("Core 0", 61000)], 1):
        (device / f"temp{index}_label").write_text(label + "\n", encoding="utf-8")
        (device / f"temp{index}_input").write_text(f"{value}\n", encoding="utf-8")
    with harness.client(sysfs=sysfs) as client:
        body = client.get("/api/v1/status").json()
        assert body["cpuTemperature"] == 67.5
        assert json.dumps(body["cpuTemperature"]) == "67.5"
        (device / "temp1_input").write_text("garbage\n", encoding="utf-8")
        assert client.get("/api/v1/status").json()["cpuTemperature"] == 61.0
        (device / "name").unlink()
        response = client.get("/api/v1/status")
        assert response.status_code == 200
        assert response.json()["cpuTemperature"] is None


def test_healthz_needs_no_token_and_reports_busy(
    harness: Harness, token: str, auth: dict[str, str]
) -> None:
    harness.raw("IMG_0001.ARW")
    harness.hold()
    with harness.client(LRRP_TOKEN=token) as client:
        assert client.get("/healthz").json() == {"status": "ok", "busy": False}
        post = client.post(
            "/api/v1/jobs",
            json={"items": [{"ref": "1", "root": "archive", "path": "IMG_0001.ARW"}]},
            headers=auth,
        )
        assert post.status_code == 201
        wait_for(lambda: client.get("/healthz").json()["busy"], what="busy")
        harness.release()
        wait_for(lambda: not client.get("/healthz").json()["busy"], what="not busy")
