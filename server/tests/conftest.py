from collections.abc import Callable
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from lrrp.app import create_app
from lrrp.settings import Settings


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
