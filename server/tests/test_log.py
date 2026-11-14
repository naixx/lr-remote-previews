"""The server's recent log lines (``GET /api/v1/log``)."""

import logging
import re
from typing import Any

import pytest
from fastapi.testclient import TestClient

from conftest import Harness, post_job, wait_job
from lrrp.logring import LogRing

TIME = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")


def log_lines(client: TestClient, **params: Any) -> list[dict[str, Any]]:
    response = client.get("/api/v1/log", params=params)
    assert response.status_code == 200, response.text
    return response.json()["lines"]


def test_the_log_has_the_servers_own_lines_oldest_first(harness: Harness) -> None:
    harness.raw("IMG_0001.ARW")
    with harness.client() as client:
        wait_job(client, post_job(client, ["IMG_0001.ARW"])["job"]["id"])
        client.patch("/api/v1/settings", json={"batchSize": 4})
        client.get("/api/v1/status")
        lines = log_lines(client)
    messages = [line["message"] for line in lines]
    assert any("converter process(es) side by side" in m for m in messages), messages
    assert any(m.startswith("wave: 1 file(s) in 1 converter process(es)") for m in messages)
    assert messages[-1] == "settings changed: batchSize 8 -> 4", "the newest line comes last"
    for line in lines:
        assert set(line) == {"time", "level", "logger", "message"}
        assert TIME.fullmatch(line["time"]), line
        assert line["level"] in ("DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL")
        assert line["logger"].startswith("lrrp"), line
        # No request lines of the HTTP server.
        assert "HTTP/1.1" not in line["message"] and "GET /api" not in line["message"]
    assert [line["time"] for line in lines] == sorted(line["time"] for line in lines)


def test_limit_and_the_last_1000_lines(harness: Harness) -> None:
    with harness.client() as client:
        logger = logging.getLogger("lrrp.test")
        for index in range(1100):
            logger.info("line %d", index)
        logger.warning("the last one")
        everything = log_lines(client, limit=1000)
        assert len(everything) == 1000
        assert everything[0]["message"] == "line 101"
        assert everything[-1] == {
            "time": everything[-1]["time"],
            "level": "WARNING",
            "logger": "lrrp.test",
            "message": "the last one",
        }
        default = log_lines(client)
        assert len(default) == 200
        assert default == everything[-200:]
        assert [line["message"] for line in log_lines(client, limit=2)] == [
            "line 1099",
            "the last one",
        ]
        for limit in (0, 1001, -1):
            response = client.get("/api/v1/log", params={"limit": limit})
            assert response.status_code == 422
            assert isinstance(response.json()["detail"], str)


def test_an_exception_is_summarised_in_its_line(harness: Harness) -> None:
    with harness.client() as client:
        try:
            raise ValueError("something odd")
        except ValueError:
            logging.getLogger("lrrp.test").exception("cannot do it")
        [line] = log_lines(client, limit=1)
        assert line["level"] == "ERROR"
        assert line["message"] == "cannot do it (ValueError: something odd)"


def test_the_token_never_appears(harness: Harness, token: str, auth: dict[str, str]) -> None:
    harness.raw("IMG_0001.ARW")
    with harness.client(LRRP_TOKEN=token) as client:
        assert client.get("/api/v1/log").status_code == 401
        response = client.post(
            "/api/v1/jobs",
            json={"items": [{"ref": "1", "root": "archive", "path": "IMG_0001.ARW"}]},
            headers=auth,
        )
        wait_job_with_auth(client, response.json()["job"]["id"], auth)
        client.get("/api/v1/info", headers={"Authorization": f"Bearer {token}x"})
        logger = logging.getLogger("lrrp.test")
        logger.info("a careless line with the token %s inside", token)
        logger.warning(f"and one formatted beforehand: {token}")
        try:
            raise RuntimeError(token)
        except RuntimeError:
            logger.exception("an exception that carries it")
        response = client.get("/api/v1/log", params={"limit": 1000}, headers=auth)
        assert response.status_code == 200
        assert token not in response.text
        messages = [line["message"] for line in response.json()["lines"]]
        assert "a careless line with the token [token] inside" in messages
        assert "and one formatted beforehand: [token]" in messages
        assert "an exception that carries it (RuntimeError: [token])" in messages


def wait_job_with_auth(client: TestClient, job_id: int, auth: dict[str, str]) -> None:
    client.headers.update(auth)
    try:
        wait_job(client, job_id)
    finally:
        del client.headers["Authorization"]


def test_the_settings_repr_hides_the_token(make_client: Any, token: str) -> None:
    client = make_client(LRRP_TOKEN=token)
    assert token not in repr(client.app.state.settings)


@pytest.mark.parametrize("capacity", [1, 3])
def test_the_ring_keeps_the_newest_lines(capacity: int) -> None:
    ring = LogRing(capacity=capacity, secret="s3cret")
    logger = logging.getLogger("lrrp.test.ring")
    logger.addHandler(ring)
    logger.setLevel(logging.INFO)
    try:
        for index in range(5):
            logger.info("line %d s3cret", index)
    finally:
        logger.removeHandler(ring)
    lines = ring.lines(10)
    assert [line.message for line in lines] == [
        f"line {index} [token]" for index in range(5 - capacity, 5)
    ]
    assert ring.lines(1) == lines[-1:]
