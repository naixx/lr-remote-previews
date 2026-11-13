from collections.abc import Callable
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

MakeClient = Callable[..., TestClient]

INDEX = "<!doctype html><title>dashboard</title><script type=module src=/assets/app.js></script>"
SCRIPT = "console.log('dashboard');"


@pytest.fixture
def web_dir(tmp_path: Path) -> Path:
    web = tmp_path / "web"
    (web / "assets").mkdir(parents=True)
    (web / "index.html").write_text(INDEX, encoding="utf-8")
    (web / "assets" / "app.js").write_text(SCRIPT, encoding="utf-8")
    return web


def test_without_a_web_dir_the_root_is_a_short_message(make_client: MakeClient) -> None:
    client = make_client()
    response = client.get("/")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/plain")
    assert "dashboard is not installed" in response.text
    assert client.get("/library").status_code == 404


@pytest.mark.usefixtures("web_dir")
def test_root_serves_index_html(make_client: MakeClient) -> None:
    response = make_client().get("/")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/html")
    assert response.headers["cache-control"] == "no-cache"
    assert response.text == INDEX


@pytest.mark.usefixtures("web_dir")
def test_index_html_by_name(make_client: MakeClient) -> None:
    response = make_client().get("/index.html")
    assert response.status_code == 200
    assert response.text == INDEX


@pytest.mark.usefixtures("web_dir")
def test_assets_are_served(make_client: MakeClient) -> None:
    response = make_client().get("/assets/app.js")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/javascript")
    assert response.text == SCRIPT


@pytest.mark.usefixtures("web_dir")
@pytest.mark.parametrize("path", ["/library", "/library/archive/2024", "/assets/", "/settings?x=1"])
def test_unknown_paths_fall_back_to_index_html(make_client: MakeClient, path: str) -> None:
    response = make_client().get(path)
    assert response.status_code == 200
    assert response.text == INDEX


@pytest.mark.usefixtures("web_dir")
def test_dashboard_needs_no_token(make_client: MakeClient, token: str) -> None:
    client = make_client(LRRP_TOKEN=token)
    assert client.get("/").status_code == 200
    assert client.get("/library").text == INDEX


@pytest.mark.usefixtures("web_dir")
@pytest.mark.parametrize("path", ["/api", "/api/", "/api/v1", "/api/v2/info", "/api/v1/info/x"])
def test_api_paths_never_fall_back_to_the_dashboard(make_client: MakeClient, path: str) -> None:
    response = make_client().get(path)
    assert response.status_code == 404
    assert response.json() == {"detail": "Not Found"}


@pytest.mark.usefixtures("web_dir")
def test_files_outside_the_web_dir_are_not_served(make_client: MakeClient, tmp_path: Path) -> None:
    (tmp_path / "secret.txt").write_text("secret", encoding="utf-8")
    client = make_client()
    for path in ["/../secret.txt", "/%2e%2e/secret.txt", "/assets/%2e%2e/%2e%2e/secret.txt"]:
        response = client.get(path)
        assert "secret" not in response.text, path


def test_web_dir_without_index_html(make_client: MakeClient, tmp_path: Path) -> None:
    (tmp_path / "web").mkdir()
    (tmp_path / "web" / "robots.txt").write_bytes(b"User-agent: *\n")
    client = make_client()
    assert client.get("/robots.txt").text == "User-agent: *\n"
    assert client.get("/library").status_code == 404
