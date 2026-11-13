import json
import os
import sys
import time
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, TypeVar

import pytest
import yaml
from fastapi.testclient import TestClient

from lrrp.app import create_app
from lrrp.converter import gpu_config_path, wine_path
from lrrp.display import NoDisplay
from lrrp.runner import RunnerConfig
from lrrp.settings import Settings

FAKE_CONVERTER = Path(__file__).with_name("fake_converter.py")
WINE_USER = "tester"

T = TypeVar("T")


@pytest.fixture
def env(tmp_path: Path) -> dict[str, str]:
    """An environment that keeps every directory of the server inside ``tmp_path``."""
    return {
        "LRRP_DATA_DIR": str(tmp_path / "data"),
        "LRRP_CACHE_DIR": str(tmp_path / "cache"),
        "LRRP_WEB_DIR": str(tmp_path / "web"),
    }


@pytest.fixture
def make_client(env: dict[str, str]) -> Callable[..., TestClient]:
    """Build a client for an app whose settings are ``env`` plus the given variables."""

    def make(**variables: str) -> TestClient:
        return TestClient(create_app(Settings.from_env({**env, **variables})))

    return make


@pytest.fixture
def token() -> str:
    return "test-token-0123456789"


@pytest.fixture
def auth(token: str) -> dict[str, str]:
    """Request headers that carry ``token``."""
    return {"Authorization": f"Bearer {token}"}


def to_fake_path(path: str | Path) -> str:
    """The path form the fake converter understands: ``Z:\\...`` as Wine would pass it.

    On Linux that is the real ``wine_path``. On Windows ``C:\\x`` becomes ``Z:\\C\\x``.
    """
    if os.name == "nt":
        drive, rest = os.path.splitdrive(str(path))
        return "Z:\\" + drive.rstrip(":") + rest
    return wine_path(str(path))


def wait_for(check: Callable[[], T], timeout: float = 30.0, what: str = "a condition") -> T:
    deadline = time.monotonic() + timeout
    while True:
        value = check()
        if value:
            return value
        if time.monotonic() > deadline:
            raise AssertionError(f"timed out waiting for {what}")
        time.sleep(0.05)


@dataclass
class Harness:
    """A server with a root of fake originals, a fake Wine prefix and the fake converter."""

    tmp: Path
    originals: Path
    prefix: Path
    state: Path
    settings_env: dict[str, str] = field(default_factory=dict)

    def raw(self, path: str, content: bytes | None = None) -> Path:
        """Write a fake raw file under the root ``archive``; its bytes default to its path."""
        file = self.originals.joinpath(*path.split("/"))
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(path.encode("utf-8") if content is None else content)
        return file

    def client(
        self,
        *,
        workers: int = 3,
        batch_size: int = 8,
        timeout_base: float = 30.0,
        timeout_per_file: float = 10.0,
        fake: dict[str, str] | None = None,
        **variables: str,
    ) -> TestClient:
        settings = Settings.from_env(
            {
                **self.settings_env,
                "LRRP_WORKERS": str(workers),
                "LRRP_BATCH_SIZE": str(batch_size),
                **variables,
            }
        )
        config = RunnerConfig(
            command_prefix=(sys.executable, str(FAKE_CONVERTER)),
            env={
                **os.environ,
                "WINEPREFIX": str(self.prefix),
                "USER": WINE_USER,
                "FAKE_CONVERTER_STATE": str(self.state),
                **(fake or {}),
            },
            to_converter_path=to_fake_path,
            timeout_base=timeout_base,
            timeout_per_file=timeout_per_file,
            gpu_config=self.gpu_config,
            warm_up_timeout=30.0,
        )
        return TestClient(create_app(settings, runner_config=config, display=NoDisplay()))

    @property
    def gpu_config(self) -> Path:
        return gpu_config_path(self.prefix, WINE_USER)

    def runs(self) -> list[list[str]]:
        """The inputs of every run of the fake converter, oldest first."""
        folder = self.state / "runs"
        if not folder.is_dir():
            return []
        records = sorted(folder.iterdir(), key=lambda path: int(path.stem.split("-")[0]))
        return [json.loads(path.read_text(encoding="utf-8"))["inputs"] for path in records]

    def runs_with(self, name: str) -> int:
        return sum(name in run for run in self.runs())

    def concurrency(self) -> list[int]:
        folder = self.state / "concurrency"
        if not folder.is_dir():
            return []
        return [int(path.read_text(encoding="utf-8")) for path in folder.iterdir()]


@pytest.fixture
def harness(tmp_path: Path) -> Harness:
    originals = tmp_path / "originals"
    originals.mkdir()
    prefix = tmp_path / "wine"
    exe = prefix / "drive_c" / "Program Files" / "Adobe" / "Adobe DNG Converter"
    exe.mkdir(parents=True)
    (exe / "Adobe DNG Converter.exe").write_bytes(b"")
    config = tmp_path / "roots.yaml"
    config.write_text(
        yaml.safe_dump(
            {
                "roots": [
                    {"id": "archive", "path": str(originals), "label": "Archive"},
                    {"id": "offline", "path": str(tmp_path / "unmounted")},
                ]
            }
        ),
        encoding="utf-8",
    )
    harness = Harness(
        tmp=tmp_path,
        originals=originals,
        prefix=prefix,
        state=tmp_path / "fake-state",
        settings_env={
            "LRRP_DATA_DIR": str(tmp_path / "data"),
            "LRRP_CACHE_DIR": str(tmp_path / "cache"),
            "LRRP_WEB_DIR": str(tmp_path / "web"),
            "LRRP_WINEPREFIX": str(prefix),
            "LRRP_CONFIG": str(config),
        },
    )
    # A prefix the converter has already run in; tests of the warm-up remove the file.
    harness.gpu_config.parent.mkdir(parents=True)
    harness.gpu_config.write_text("config\n", encoding="utf-8")
    return harness


def post_job(
    http: TestClient,
    paths: Iterable[str],
    *,
    root: str = "archive",
    expect: int = 201,
    **fields: Any,
) -> dict[str, Any]:
    """Create a job with one item per path (refs "0", "1", ...) and return the answer."""
    items = [{"ref": str(index), "root": root, "path": path} for index, path in enumerate(paths)]
    response = http.post("/api/v1/jobs", json={"items": items, **fields})
    assert response.status_code == expect, response.text
    return response.json()


def wait_job(client: TestClient, job_id: int, timeout: float = 30.0) -> dict[str, Any]:
    """Poll a job until it is no longer active; return the job object."""

    def finished() -> dict[str, Any] | None:
        job = client.get(f"/api/v1/jobs/{job_id}").json()["job"]
        return job if job["state"] != "active" else None

    return wait_for(finished, timeout, f"job {job_id} to finish")


def items_by_path(client: TestClient, job_id: int) -> dict[str, dict[str, Any]]:
    items = client.get(f"/api/v1/jobs/{job_id}/items", params={"limit": 1000}).json()["items"]
    return {item["path"]: item for item in items}
