import tomllib
from collections.abc import Callable
from pathlib import Path

import pytest
import yaml
from fastapi.testclient import TestClient

import lrrp
from lrrp.converter import DEFAULT_CONVERTER_EXE, RAW_EXTENSIONS

MakeClient = Callable[..., TestClient]


def test_healthz(make_client: MakeClient) -> None:
    response = make_client().get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_healthz_needs_no_token(make_client: MakeClient, token: str) -> None:
    response = make_client(LRRP_TOKEN=token).get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_info_without_a_token_configured(make_client: MakeClient) -> None:
    response = make_client().get("/api/v1/info")
    assert response.status_code == 200
    assert response.json() == {
        "name": "LR Remote Previews",
        "version": "0.3.0",
        "api": 1,
        "auth": "none",
        "converter": {"installed": False, "path": DEFAULT_CONVERTER_EXE, "version": None},
        "roots": [],
        "capabilities": {
            "extensions": list(RAW_EXTENSIONS),
            "previewLongEdge": 2560,
            "maxItemsPerJob": 5000,
            "jobRetentionDays": 30,
        },
    }


def test_info_reports_the_job_retention(make_client: MakeClient) -> None:
    capabilities = make_client(LRRP_JOB_RETENTION_DAYS="7").get("/api/v1/info").json()
    assert capabilities["capabilities"]["jobRetentionDays"] == 7


def test_info_with_the_right_token(
    make_client: MakeClient, token: str, auth: dict[str, str]
) -> None:
    response = make_client(LRRP_TOKEN=token).get("/api/v1/info", headers=auth)
    assert response.status_code == 200
    assert response.json()["auth"] == "token"


def test_bearer_scheme_is_case_insensitive(make_client: MakeClient, token: str) -> None:
    client = make_client(LRRP_TOKEN=token)
    response = client.get("/api/v1/info", headers={"Authorization": f"bearer {token}"})
    assert response.status_code == 200


@pytest.mark.parametrize(
    ("headers", "detail"),
    [
        ({}, "Missing bearer token"),
        ({"Authorization": "Bearer"}, "Missing bearer token"),
        ({"Authorization": "Basic dXNlcjpwYXNz"}, "Missing bearer token"),
        ({"Authorization": "Bearer wrong-token"}, "Invalid token"),
        ({"Authorization": "Bearer {token}x"}, "Invalid token"),
        ({"Authorization": "Bearer x{token}"}, "Invalid token"),
    ],
)
def test_info_rejects_a_missing_or_wrong_token(
    make_client: MakeClient, token: str, headers: dict[str, str], detail: str
) -> None:
    headers = {name: value.format(token=token) for name, value in headers.items()}
    response = make_client(LRRP_TOKEN=token).get("/api/v1/info", headers=headers)
    assert response.status_code == 401
    assert response.json() == {"detail": detail}
    assert response.headers["www-authenticate"] == "Bearer"


def test_unknown_api_path_is_a_json_404(make_client: MakeClient) -> None:
    response = make_client().get("/api/v1/nothing-here")
    assert response.status_code == 404
    assert response.json() == {"detail": "Not Found"}


def test_unknown_api_path_still_needs_the_token(
    make_client: MakeClient, token: str, auth: dict[str, str]
) -> None:
    client = make_client(LRRP_TOKEN=token)
    assert client.post("/api/v1/nothing").status_code == 401
    assert client.post("/api/v1/nothing", headers=auth).status_code == 404


def test_root_availability(make_client: MakeClient, tmp_path: Path) -> None:
    present = tmp_path / "originals"
    present.mkdir()
    a_file = tmp_path / "not-a-folder"
    a_file.write_text("x", encoding="utf-8")
    config = tmp_path / "lrrp.yaml"
    config.write_text(
        yaml.safe_dump(
            {
                "roots": [
                    {"id": "archive", "path": str(present), "label": "Archive"},
                    {"id": "missing", "path": str(tmp_path / "unmounted")},
                    {"id": "file", "path": str(a_file)},
                ]
            }
        ),
        encoding="utf-8",
    )
    response = make_client(LRRP_CONFIG=str(config)).get("/api/v1/info")
    assert response.status_code == 200
    assert response.json()["roots"] == [
        {"id": "archive", "label": "Archive", "available": True},
        {"id": "missing", "label": "missing", "available": False},
        {"id": "file", "label": "file", "available": False},
    ]
    assert str(tmp_path) not in response.text


def test_converter_found_in_the_default_prefix(make_client: MakeClient, tmp_path: Path) -> None:
    exe = (
        tmp_path
        / "data"
        / "wine"
        / "drive_c"
        / "Program Files"
        / "Adobe"
        / "Adobe DNG Converter"
        / "Adobe DNG Converter.exe"
    )
    exe.parent.mkdir(parents=True)
    exe.write_bytes(b"")
    converter = make_client().get("/api/v1/info").json()["converter"]
    assert converter == {"installed": True, "path": DEFAULT_CONVERTER_EXE, "version": None}


def test_converter_in_a_custom_prefix_and_location(make_client: MakeClient, tmp_path: Path) -> None:
    prefix = tmp_path / "prefix"
    exe = prefix / "drive_c" / "Tools" / "dngc.exe"
    exe.parent.mkdir(parents=True)
    exe.write_bytes(b"")
    client = make_client(LRRP_WINEPREFIX=str(prefix), LRRP_CONVERTER_EXE=r"C:\Tools\dngc.exe")
    converter = client.get("/api/v1/info").json()["converter"]
    assert converter == {"installed": True, "path": r"C:\Tools\dngc.exe", "version": None}


def test_converter_missing_from_the_prefix(make_client: MakeClient, tmp_path: Path) -> None:
    (tmp_path / "data" / "wine" / "drive_c").mkdir(parents=True)
    assert make_client().get("/api/v1/info").json()["converter"]["installed"] is False


def test_openapi_describes_the_api(make_client: MakeClient) -> None:
    response = make_client().get("/openapi.json")
    assert response.status_code == 200
    paths = response.json()["paths"]
    for path in [
        "/api/v1/info",
        "/api/v1/jobs",
        "/api/v1/jobs/{job_id}",
        "/api/v1/jobs/{job_id}/items",
        "/api/v1/jobs/{job_id}/retry",
        "/api/v1/items/{item_id}/file",
        "/api/v1/lookup",
        "/api/v1/files/{key}",
        "/api/v1/status",
    ]:
        assert path in paths


def test_version_matches_pyproject() -> None:
    pyproject = Path(__file__).resolve().parents[1] / "pyproject.toml"
    with pyproject.open("rb") as file:
        assert tomllib.load(file)["project"]["version"] == lrrp.__version__
