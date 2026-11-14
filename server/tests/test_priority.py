"""Job priority: ``normal`` jobs are built before ``background`` ones, through the HTTP API."""

from typing import Any

import pytest

from conftest import Harness, items_by_path, post_job, wait_for, wait_job


def test_a_normal_job_goes_ahead_of_a_background_job_at_the_next_wave(harness: Harness) -> None:
    background = [f"bg/IMG_{index:04d}.ARW" for index in range(1, 5)]
    normal = [f"lr/DSC_{index:04d}.ARW" for index in range(1, 3)]
    for path in background + normal:
        harness.raw(path)
    # One file per wave. The first background wave is held until the normal job exists.
    harness.hold("IMG_0001.ARW")
    with harness.client(workers=1, batch_size=1) as client:
        bg = post_job(client, background, priority="background")["job"]
        assert bg["priority"] == "background"
        wait_for(lambda: harness.runs_with("IMG_0001.ARW") == 1, what="the first wave")
        lr = post_job(client, normal)["job"]
        assert lr["priority"] == "normal"
        assert client.get(f"/api/v1/jobs/{bg['id']}").json()["job"]["counts"]["building"] == 1
        harness.release()
        assert wait_job(client, lr["id"])["counts"]["ready"] == 2
        assert wait_job(client, bg["id"])["counts"]["ready"] == 4
    assert harness.runs() == [
        ["IMG_0001.ARW"],  # the wave that ran was not interrupted
        ["DSC_0001.ARW"],
        ["DSC_0002.ARW"],
        ["IMG_0002.ARW"],
        ["IMG_0003.ARW"],
        ["IMG_0004.ARW"],
    ]


def test_a_wave_takes_normal_files_first_and_fills_up_with_background_ones(
    harness: Harness,
) -> None:
    background = [f"IMG_{index:04d}.ARW" for index in range(1, 7)]
    for path in [*background, "DSC_0001.ARW"]:
        harness.raw(path)
    first = background[:3]
    harness.hold(",".join(first))
    # Waves of three processes with one file each.
    with harness.client(workers=3, batch_size=1) as client:
        bg = post_job(client, background, priority="background")["job"]["id"]
        wait_for(lambda: all(harness.runs_with(name) == 1 for name in first), what="wave one")
        lr = post_job(client, ["DSC_0001.ARW"])["job"]["id"]
        harness.release()
        wait_job(client, lr)
        wait_job(client, bg)
    runs = harness.runs()
    assert sorted(name for run in runs[:3] for name in run) == first
    assert sorted(name for run in runs[3:6] for name in run) == [
        "DSC_0001.ARW",
        "IMG_0004.ARW",
        "IMG_0005.ARW",
    ]
    assert runs[6:] == [["IMG_0006.ARW"]]


def test_a_file_both_priorities_want_is_built_once_as_normal(harness: Harness) -> None:
    for name in ("IMG_0001.ARW", "IMG_0002.ARW", "SHARED.ARW", "DSC_0001.ARW"):
        harness.raw(name)
    harness.hold("IMG_0001.ARW")
    with harness.client(workers=1, batch_size=1) as client:
        bg = post_job(
            client, ["IMG_0001.ARW", "IMG_0002.ARW", "SHARED.ARW"], priority="background"
        )["job"]["id"]
        wait_for(lambda: harness.runs_with("IMG_0001.ARW") == 1, what="the first wave")
        lr = post_job(client, ["DSC_0001.ARW", "SHARED.ARW"])["job"]["id"]
        harness.release()
        wait_job(client, lr)
        wait_job(client, bg)
        one = items_by_path(client, bg)["SHARED.ARW"]
        two = items_by_path(client, lr)["SHARED.ARW"]
        assert one["state"] == two["state"] == "ready"
        assert one["result"] == two["result"]
    assert harness.runs() == [
        ["IMG_0001.ARW"],
        ["DSC_0001.ARW"],
        ["SHARED.ARW"],
        ["IMG_0002.ARW"],
    ]


@pytest.mark.parametrize(("fields", "expected"), [({}, "normal"), ({"priority": None}, "normal")])
def test_the_default_priority_is_normal(
    harness: Harness, fields: dict[str, Any], expected: str
) -> None:
    with harness.client() as client:
        job = post_job(client, ["photo.jpg"], **fields)["job"]
        assert job["priority"] == expected
        assert client.get(f"/api/v1/jobs/{job['id']}").json()["job"]["priority"] == expected
        assert client.get("/api/v1/jobs").json()["jobs"][0]["priority"] == expected


@pytest.mark.parametrize("priority", ["urgent", "Normal", "", 1, True])
def test_an_unknown_priority_is_refused(harness: Harness, priority: Any) -> None:
    with harness.client() as client:
        body = {"priority": priority, "items": [{"ref": "1", "root": "archive", "path": "a.jpg"}]}
        response = client.post("/api/v1/jobs", json=body)
        assert response.status_code == 422, response.text
        assert response.json()["detail"].startswith("priority:")
        response = client.post("/api/v1/folders", json={"root": "archive", "priority": priority})
        assert response.status_code == 422, response.text
        assert response.json()["detail"].startswith("priority:")
        assert client.get("/api/v1/jobs").json()["jobs"] == []


def test_a_queued_folder_takes_a_priority(harness: Harness) -> None:
    for name in ("IMG_0001.ARW", "IMG_0002.ARW"):
        harness.raw(f"day/{name}")
    with harness.client() as client:
        response = client.post(
            "/api/v1/folders", json={"root": "archive", "path": "day", "priority": "background"}
        )
        assert response.status_code == 201, response.text
        [job] = response.json()["jobs"]
        assert job["priority"] == "background"
        assert wait_job(client, job["id"])["priority"] == "background"
        again = client.post("/api/v1/folders", json={"root": "archive", "path": "day"}).json()
        assert again["jobs"][0]["priority"] == "normal"


def test_priority_survives_a_restart(harness: Harness) -> None:
    harness.raw("IMG_0001.ARW")
    harness.raw("DSC_0001.ARW")
    harness.hold()
    with harness.client(workers=1, batch_size=1) as client:
        # Held from the start: the first job's file is building, the second job is queued.
        first = post_job(client, ["IMG_0001.ARW"], priority="background")["job"]["id"]
        wait_for(lambda: harness.runs_with("IMG_0001.ARW") == 1, what="the first build")
        second = post_job(client, ["DSC_0001.ARW"], priority="background")["job"]["id"]
    harness.release()
    with harness.client(workers=1, batch_size=1) as client:
        for job_id in (first, second):
            job = wait_job(client, job_id)
            assert (job["priority"], job["state"]) == ("background", "done")
