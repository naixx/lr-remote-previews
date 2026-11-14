"""The converter self-test (``POST /api/v1/converter/selftest``) with the fake converter."""

import threading
import time
from typing import Any

import pytest
from fastapi.testclient import TestClient

from conftest import Harness, lookup, post_job, wait_for, wait_job
from fake_converter import dng_bytes
from lrrp.converter import DEFAULT_CONVERTER_EXE
from lrrp.display import DisplayError
from pe_builder import version_resource, windows_exe

FILE = {"root": "archive", "path": "2026/IMG_0001.ARW"}


def selftest(client: TestClient, body: Any = None, expect: int = 200) -> dict[str, Any]:
    if body is None:
        response = client.post("/api/v1/converter/selftest")
    else:
        response = client.post("/api/v1/converter/selftest", json=body)
    assert response.status_code == expect, response.text
    return response.json()


def names(answer: dict[str, Any]) -> list[str]:
    return [step["name"] for step in answer["steps"]]


class BrokenDisplay:
    def ensure(self) -> str | None:
        raise DisplayError("Xvfb could not start on any display from :99 to :108")

    def describe(self) -> str:
        return "Xvfb, not running"

    def stop(self) -> None:
        pass


def install_versioned_converter(harness: Harness, version: str = "17.2") -> None:
    exe = harness.prefix / "drive_c" / "Program Files" / "Adobe" / "Adobe DNG Converter"
    (exe / "Adobe DNG Converter.exe").write_bytes(windows_exe(version_resource(version)))


def test_the_first_steps_without_a_file(harness: Harness) -> None:
    install_versioned_converter(harness)
    with harness.client() as client:
        assert client.get("/api/v1/info").json()["converter"]["version"] == "17.2"
        answer = selftest(client)
        assert answer == {
            "ok": True,
            "steps": [
                {
                    "name": "installed",
                    "ok": True,
                    "detail": f"{DEFAULT_CONVERTER_EXE}, version 17.2",
                },
                {
                    "name": "display",
                    "ok": True,
                    "detail": "the DISPLAY of the server's environment",
                },
                {"name": "warm-up", "ok": True, "detail": "not needed"},
            ],
        }
        assert selftest(client, {}) == answer, "an empty body names no file"
    assert harness.runs() == []


def test_all_steps_with_a_file_and_nothing_is_kept(harness: Harness) -> None:
    harness.raw("2026/IMG_0001.ARW")
    with harness.client() as client:
        answer = selftest(client, FILE)
        assert answer["ok"] is True
        assert names(answer) == ["installed", "display", "warm-up", "conversion"]
        installed, _, _, conversion = answer["steps"]
        assert installed["detail"].endswith("version unknown"), "an empty file has no version"
        size = len(dng_bytes("IMG_0001.ARW", b"2026/IMG_0001.ARW"))
        assert conversion["detail"].startswith(f"IMG_0001.ARW → {size} bytes in ")
        assert conversion["detail"].endswith(" s, original name and size recorded")
        # Nothing stored: no cache entry, no build counted, no job, nothing queued.
        [found] = lookup(client, [FILE["path"]])
        assert found["state"] == "absent"
        status = client.get("/api/v1/status").json()
        assert status["cache"] == {"entries": 0, "bytes": 0}
        assert status["today"] == {"built": 0, "failed": 0}
        assert client.get("/api/v1/jobs").json()["jobs"] == []
        assert list((harness.tmp / "cache" / "work").iterdir()) == []
        # A job for the same file afterwards builds it.
        wait_job(client, post_job(client, [FILE["path"]])["job"]["id"])
    assert harness.runs() == [["IMG_0001.ARW"], ["IMG_0001.ARW"]]


def test_a_fresh_prefix_is_warmed_up(harness: Harness) -> None:
    harness.gpu_config.unlink()
    with harness.client(fake={"FAKE_CONVERTER_FRESH_PREFIX": "1"}) as client:
        answer = selftest(client)
        assert answer["ok"] is True
        warm_up = answer["steps"][2]
        assert warm_up["name"] == "warm-up"
        assert "exited with code 3" in warm_up["detail"]
        assert warm_up["detail"].startswith("done")
        assert selftest(client)["steps"][2]["detail"] == "not needed"
    assert harness.gpu_config.is_file()
    assert harness.runs() == [["no-such-input.arw"]]


def test_the_converter_is_not_installed(harness: Harness) -> None:
    (harness.prefix / "drive_c" / "Program Files").rename(harness.prefix / "drive_c" / "Gone")
    harness.raw("2026/IMG_0001.ARW")
    with harness.client() as client:
        answer = selftest(client, FILE)
        assert answer["ok"] is False
        [installed] = answer["steps"]
        assert installed["name"] == "installed" and installed["ok"] is False
        assert "was not found" in installed["detail"]
        assert str(harness.tmp) not in installed["detail"]
    assert harness.runs() == []


def test_the_display_fails(harness: Harness) -> None:
    harness.raw("2026/IMG_0001.ARW")
    with harness.client(display=BrokenDisplay()) as client:
        answer = selftest(client, FILE)
        assert answer["ok"] is False
        assert names(answer) == ["installed", "display"]
        display = answer["steps"][1]
        assert display["ok"] is False
        assert "No X display could be started" in display["detail"]
        assert ":99 to :108" in display["detail"]
    assert harness.runs() == []


def test_the_warm_up_fails(harness: Harness) -> None:
    harness.gpu_config.unlink()
    harness.raw("2026/IMG_0001.ARW")
    with harness.client() as client:
        answer = selftest(client, FILE)
        assert answer["ok"] is False
        assert names(answer) == ["installed", "display", "warm-up"]
        detail = answer["steps"][2]["detail"]
        assert "could not initialise" in detail
        assert "cannot open no-such-input.arw" in detail, "the converter's last output"
    assert harness.runs() == [["no-such-input.arw"]]


@pytest.mark.parametrize(
    ("fake", "fragments"),
    [
        (
            {"FAKE_CONVERTER_FAIL": "IMG_0001.ARW"},
            ["exited with code 1", "last output: Error: cannot convert IMG_0001.ARW (fake)"],
        ),
        ({"FAKE_CONVERTER_SKIP": "IMG_0001.ARW"}, ["wrote no DNG for this file"]),
        ({"FAKE_CONVERTER_WRONG_NAME": "IMG_0001.ARW"}, ["names 'OTHER_IMG_0001.ARW'"]),
        ({"FAKE_CONVERTER_HANG": "IMG_0001.ARW"}, ["did not finish within 1 s"]),
    ],
)
def test_the_conversion_fails(harness: Harness, fake: dict[str, str], fragments: list[str]) -> None:
    harness.raw("2026/IMG_0001.ARW")
    with harness.client(fake=fake, timeout_base=1.0, timeout_per_file=0.0) as client:
        answer = selftest(client, FILE)
        assert answer["ok"] is False
        assert names(answer) == ["installed", "display", "warm-up", "conversion"]
        assert [step["ok"] for step in answer["steps"]] == [True, True, True, False]
        detail = answer["steps"][3]["detail"]
        for fragment in fragments:
            assert fragment in detail, detail
        assert client.get("/api/v1/status").json()["today"] == {"built": 0, "failed": 0}
        assert list((harness.tmp / "cache" / "work").iterdir()) == []


@pytest.mark.parametrize(
    ("body", "code"),
    [
        ({"root": "nowhere", "path": "2026/IMG_0001.ARW"}, "unknown_root"),
        ({"root": "archive", "path": "2026/../IMG_0001.ARW"}, "bad_path"),
        ({"root": "archive", "path": "2026/readme.txt"}, "unsupported_format"),
        ({"root": "offline", "path": "IMG_0001.ARW"}, "root_unavailable"),
        ({"root": "archive", "path": "2026/IMG_0002.ARW"}, "not_found"),
        ({"root": "archive", "path": "2026/folder.ARW"}, "not_a_file"),
    ],
)
def test_the_file_is_checked_like_an_item(
    harness: Harness, body: dict[str, str], code: str
) -> None:
    harness.raw("2026/IMG_0001.ARW")
    harness.raw("2026/readme.txt")
    (harness.originals / "2026" / "folder.ARW").mkdir()
    with harness.client() as client:
        answer = selftest(client, body, expect=422)
        assert answer["code"] == code
        assert isinstance(answer["detail"], str) and answer["detail"]
    assert harness.runs() == []


@pytest.mark.parametrize(
    "body",
    [{"root": "archive"}, {"path": "2026/IMG_0001.ARW"}, {"root": 1, "path": "x.ARW"}, []],
)
def test_malformed_selftest_requests(harness: Harness, body: Any) -> None:
    with harness.client() as client:
        answer = selftest(client, body, expect=422)
        assert isinstance(answer["detail"], str)


def test_a_second_selftest_at_the_same_time_is_refused(harness: Harness) -> None:
    harness.raw("2026/IMG_0001.ARW")
    harness.hold("IMG_0001.ARW")
    with harness.client() as client:
        answers: list[dict[str, Any]] = []
        first = threading.Thread(target=lambda: answers.append(selftest(client, FILE)))
        first.start()
        try:
            wait_for(lambda: harness.runs_with("IMG_0001.ARW") == 1, what="the first self-test")
            body = selftest(client, expect=409)
            assert body["code"] == "busy"
            assert isinstance(body["detail"], str)
            status = client.get("/api/v1/status").json()
            assert status["workers"]["busy"] == 1
            assert client.get("/healthz").json()["busy"] is True
        finally:
            harness.release()
            first.join(30)
        assert answers and answers[0]["ok"] is True
        assert selftest(client)["ok"] is True, "the next one runs"


def test_it_waits_for_a_wave_and_holds_new_ones(harness: Harness) -> None:
    for name in ("WAVE.ARW", "SELF.ARW", "NEXT.ARW"):
        harness.raw(name)
    harness.hold("WAVE.ARW")
    fake = {"FAKE_CONVERTER_SETTLE": "0.2"}
    with harness.client(workers=1, batch_size=1, fake=fake) as client:
        wave = post_job(client, ["WAVE.ARW"])["job"]["id"]
        wait_for(lambda: harness.runs_with("WAVE.ARW") == 1, what="the wave")
        answers: list[dict[str, Any]] = []
        thread = threading.Thread(
            target=lambda: answers.append(selftest(client, {"root": "archive", "path": "SELF.ARW"}))
        )
        thread.start()
        try:
            time.sleep(0.5)
            assert thread.is_alive(), "the self-test waits for the running wave"
            assert harness.runs_with("SELF.ARW") == 0
            # The wave finishes; the self-test's converter starts and is held.
            harness.hold("SELF.ARW")
            wait_for(lambda: harness.runs_with("SELF.ARW") == 1, what="the self-test's run")
            assert client.get(f"/api/v1/jobs/{wave}").json()["job"]["state"] == "done"
            following = post_job(client, ["NEXT.ARW"])["job"]["id"]
            time.sleep(0.5)
            assert harness.runs_with("NEXT.ARW") == 0, "no wave starts during the self-test"
            assert client.get("/api/v1/status").json()["state"] == "running"
        finally:
            harness.release()
            thread.join(30)
        assert answers and answers[0]["ok"] is True
        wait_job(client, following)
    assert harness.runs() == [["WAVE.ARW"], ["SELF.ARW"], ["NEXT.ARW"]]
    assert harness.concurrency() == [1, 1, 1], "never two converters at the same time"


def test_selftest_and_info_need_the_token(
    harness: Harness, token: str, auth: dict[str, str]
) -> None:
    with harness.client(LRRP_TOKEN=token) as client:
        response = client.post("/api/v1/converter/selftest")
        assert response.status_code == 401
        response = client.post("/api/v1/converter/selftest", headers=auth)
        assert response.status_code == 200
        assert response.json()["ok"] is True
