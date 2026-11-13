from pathlib import Path
from typing import Any

import pytest
import yaml

from lrrp.converter import DEFAULT_CONVERTER_EXE
from lrrp.settings import Root, Settings, SettingsError, auto_workers


def write_config(tmp_path: Path, data: Any) -> Path:
    path = tmp_path / "lrrp.yaml"
    path.write_text(yaml.safe_dump(data), encoding="utf-8")
    return path


def test_defaults() -> None:
    settings = Settings.from_env({})
    assert settings.host == "0.0.0.0"
    assert settings.port == 8787
    assert settings.token is None
    assert settings.data_dir == Path("/data")
    assert settings.cache_dir == Path("/cache")
    assert settings.web_dir == Path("/app/web")
    assert settings.wineprefix == Path("/data/wine")
    assert settings.converter_exe == DEFAULT_CONVERTER_EXE
    assert settings.converter_exe.endswith(r"\Adobe DNG Converter\Adobe DNG Converter.exe")
    assert settings.roots == ()
    assert settings.batch_size == 8
    assert settings.workers in (1, 3, 4, 6)
    assert settings.job_retention_days == 30


@pytest.mark.parametrize(
    ("cpus", "workers"),
    [(1, 1), (4, 1), (5, 1), (6, 3), (7, 3), (8, 4), (15, 4), (16, 6), (64, 6)],
)
def test_workers_auto(cpus: int, workers: int) -> None:
    assert Settings.from_env({}, cpu_count=cpus).workers == workers
    assert Settings.from_env({"LRRP_WORKERS": "auto"}, cpu_count=cpus).workers == workers
    assert Settings.from_env({"LRRP_WORKERS": "AUTO"}, cpu_count=cpus).workers == workers
    assert auto_workers(cpus) == workers


@pytest.mark.parametrize("value", ["1", "3", "4", "6", "12"])
def test_workers_explicit(value: str) -> None:
    assert Settings.from_env({"LRRP_WORKERS": value}, cpu_count=2).workers == int(value)


def test_two_workers_are_refused() -> None:
    with pytest.raises(SettingsError, match=r"LRRP_WORKERS=2 is not allowed.*twice the CPU time"):
        Settings.from_env({"LRRP_WORKERS": "2"})


@pytest.mark.parametrize(
    ("value", "message"), [("0", "at least 1"), ("-3", "at least 1"), ("many", "'auto' or a")]
)
def test_bad_workers(value: str, message: str) -> None:
    with pytest.raises(SettingsError, match=message):
        Settings.from_env({"LRRP_WORKERS": value})


def test_batch_size() -> None:
    assert Settings.from_env({"LRRP_BATCH_SIZE": "1"}).batch_size == 1
    assert Settings.from_env({"LRRP_BATCH_SIZE": "64"}).batch_size == 64


@pytest.mark.parametrize(
    ("value", "message"),
    [("0", "between 1 and 64"), ("65", "between 1 and 64"), ("eight", "must be a number")],
)
def test_bad_batch_size(value: str, message: str) -> None:
    with pytest.raises(SettingsError, match=message):
        Settings.from_env({"LRRP_BATCH_SIZE": value})


def test_job_retention_days() -> None:
    assert Settings.from_env({"LRRP_JOB_RETENTION_DAYS": "1"}).job_retention_days == 1
    assert Settings.from_env({"LRRP_JOB_RETENTION_DAYS": "365"}).job_retention_days == 365
    assert Settings.from_env({"LRRP_JOB_RETENTION_DAYS": ""}).job_retention_days == 30


@pytest.mark.parametrize(
    ("value", "message"),
    [("0", "at least 1"), ("-5", "at least 1"), ("1.5", "whole number"), ("month", "whole number")],
)
def test_bad_job_retention_days(value: str, message: str) -> None:
    with pytest.raises(SettingsError, match=f"LRRP_JOB_RETENTION_DAYS must be .*{message}"):
        Settings.from_env({"LRRP_JOB_RETENTION_DAYS": value})


@pytest.mark.parametrize("variable", ["LRRP_DATA_DIR", "LRRP_CACHE_DIR"])
def test_server_folders_inside_a_root_are_refused(tmp_path: Path, variable: str) -> None:
    config = write_config(tmp_path, {"roots": [{"id": "archive", "path": str(tmp_path / "a")}]})
    with pytest.raises(SettingsError, match=f"{variable} .* is inside the root 'archive'"):
        Settings.from_env({"LRRP_CONFIG": str(config), variable: str(tmp_path / "a" / "x")})
    settings = Settings.from_env({"LRRP_CONFIG": str(config), variable: str(tmp_path / "b")})
    assert len(settings.roots) == 1


def test_environment_overrides_everything() -> None:
    settings = Settings.from_env(
        {
            "LRRP_HOST": "127.0.0.1",
            "LRRP_PORT": "9000",
            "LRRP_TOKEN": "abc",
            "LRRP_DATA_DIR": "/srv/lrrp/data",
            "LRRP_CACHE_DIR": "/srv/lrrp/cache",
            "LRRP_WEB_DIR": "/srv/lrrp/web",
            "LRRP_WINEPREFIX": "/srv/wine",
            "LRRP_CONVERTER_EXE": r"C:\Tools\Converter.exe",
        }
    )
    assert settings.host == "127.0.0.1"
    assert settings.port == 9000
    assert settings.token == "abc"
    assert settings.data_dir == Path("/srv/lrrp/data")
    assert settings.cache_dir == Path("/srv/lrrp/cache")
    assert settings.web_dir == Path("/srv/lrrp/web")
    assert settings.wineprefix == Path("/srv/wine")
    assert settings.converter_exe == r"C:\Tools\Converter.exe"


def test_wine_prefix_follows_the_data_dir() -> None:
    settings = Settings.from_env({"LRRP_DATA_DIR": "/srv/lrrp"})
    assert settings.wineprefix == Path("/srv/lrrp/wine")


@pytest.mark.parametrize("value", ["", "   "])
def test_empty_variables_count_as_unset(value: str) -> None:
    settings = Settings.from_env({"LRRP_TOKEN": value, "LRRP_PORT": value, "LRRP_DATA_DIR": value})
    assert settings.token is None
    assert settings.port == 8787
    assert settings.data_dir == Path("/data")


def test_token_is_stripped() -> None:
    assert Settings.from_env({"LRRP_TOKEN": " abc\r\n"}).token == "abc"


@pytest.mark.parametrize(
    ("value", "message"),
    [("abc", "must be a number"), ("0", "between 1 and 65535"), ("70000", "between 1 and 65535")],
)
def test_bad_port(value: str, message: str) -> None:
    with pytest.raises(SettingsError, match=message):
        Settings.from_env({"LRRP_PORT": value})


@pytest.mark.parametrize(
    "value", ["/opt/converter.exe", "converter.exe", r"D:\Tools\x.exe", r"\\server\share\x.exe"]
)
def test_converter_exe_must_be_a_windows_path(value: str) -> None:
    with pytest.raises(SettingsError, match="LRRP_CONVERTER_EXE"):
        Settings.from_env({"LRRP_CONVERTER_EXE": value})


def test_roots_from_yaml(tmp_path: Path) -> None:
    config = write_config(
        tmp_path,
        {
            "roots": [
                {"id": "archive", "path": "/sources/archive", "label": "Archive"},
                {"id": "travel-2024", "path": "/sources/travel"},
            ]
        },
    )
    settings = Settings.from_env({"LRRP_CONFIG": str(config)})
    assert settings.roots == (
        Root(id="archive", path=Path("/sources/archive"), label="Archive"),
        Root(id="travel-2024", path=Path("/sources/travel"), label="travel-2024"),
    )


@pytest.mark.parametrize("text", ["", "# nothing yet\n", "roots:\n", "roots: []\n"])
def test_config_without_roots(tmp_path: Path, text: str) -> None:
    config = tmp_path / "lrrp.yaml"
    config.write_text(text, encoding="utf-8")
    assert Settings.from_env({"LRRP_CONFIG": str(config)}).roots == ()


def test_missing_config_file(tmp_path: Path) -> None:
    with pytest.raises(SettingsError, match="cannot read the file"):
        Settings.from_env({"LRRP_CONFIG": str(tmp_path / "missing.yaml")})


def test_config_that_is_not_yaml(tmp_path: Path) -> None:
    config = tmp_path / "lrrp.yaml"
    config.write_text("roots: [unclosed\n", encoding="utf-8")
    with pytest.raises(SettingsError, match="not valid YAML"):
        Settings.from_env({"LRRP_CONFIG": str(config)})


@pytest.mark.parametrize(
    ("data", "message"),
    [
        (["archive"], "expected a mapping"),
        ({"root": []}, r"unknown key\(s\) root"),
        ({"roots": {"id": "archive"}}, "'roots' must be a list"),
    ],
)
def test_bad_top_level(tmp_path: Path, data: Any, message: str) -> None:
    config = write_config(tmp_path, data)
    with pytest.raises(SettingsError, match=message):
        Settings.from_env({"LRRP_CONFIG": str(config)})


@pytest.mark.parametrize(
    ("entry", "message"),
    [
        ("archive", r"roots\[0\]: expected a mapping"),
        ({"path": "/sources/a"}, "'id' is missing"),
        ({"id": "Archive", "path": "/sources/a"}, "id 'Archive' is not valid"),
        ({"id": "my archive", "path": "/sources/a"}, "is not valid"),
        ({"id": "-archive", "path": "/sources/a"}, "is not valid"),
        ({"id": "", "path": "/sources/a"}, "is not valid"),
        ({"id": "a" * 33, "path": "/sources/a"}, "is not valid"),
        ({"id": "a/b", "path": "/sources/a"}, "is not valid"),
        ({"id": 2024, "path": "/sources/a"}, "id 2024 is not valid"),
        ({"id": "archive"}, "'path' must be a non-empty string"),
        ({"id": "archive", "path": ""}, "'path' must be a non-empty string"),
        ({"id": "archive", "path": "sources/a"}, "must be absolute"),
        ({"id": "archive", "path": "/sources/a", "label": ""}, "'label' must be"),
        ({"id": "archive", "path": "/sources/a", "label": 7}, "'label' must be"),
        ({"id": "archive", "path": "/sources/a", "readonly": True}, r"unknown key\(s\) readonly"),
    ],
)
def test_bad_root(tmp_path: Path, entry: Any, message: str) -> None:
    config = write_config(tmp_path, {"roots": [entry]})
    with pytest.raises(SettingsError, match=message):
        Settings.from_env({"LRRP_CONFIG": str(config)})


def test_duplicate_root_ids(tmp_path: Path) -> None:
    config = write_config(
        tmp_path,
        {
            "roots": [
                {"id": "archive", "path": "/sources/a"},
                {"id": "archive", "path": "/sources/b"},
            ]
        },
    )
    with pytest.raises(SettingsError, match=r"roots\[1\]: duplicate id 'archive'"):
        Settings.from_env({"LRRP_CONFIG": str(config)})


def test_error_names_the_config_file(tmp_path: Path) -> None:
    config = write_config(tmp_path, {"roots": [{"id": "BAD", "path": "/x"}]})
    with pytest.raises(SettingsError) as error:
        Settings.from_env({"LRRP_CONFIG": str(config)})
    assert str(config) in str(error.value)
