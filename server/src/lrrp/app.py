"""The HTTP application: health check, the JSON API under ``/api`` and the dashboard."""

import mimetypes
import secrets
from pathlib import Path
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, PlainTextResponse, Response
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field

from lrrp import __version__, converter
from lrrp.settings import Settings

NAME = "LR Remote Previews"
API_VERSION = 1
NO_DASHBOARD = (
    "LR Remote Previews server is running, but the dashboard is not installed.\n"
    "The API is at /api/v1/info.\n"
)
API_METHODS = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]

# The platform's MIME table can be wrong: on Windows it comes from the registry, which may call
# JavaScript text/plain, and browsers refuse to run module scripts served like that.
for _media_type, _extension in (
    ("text/javascript", ".js"),
    ("text/javascript", ".mjs"),
    ("text/css", ".css"),
    ("image/svg+xml", ".svg"),
    ("font/woff2", ".woff2"),
):
    mimetypes.add_type(_media_type, _extension)


class Health(BaseModel):
    status: Literal["ok"]


class ConverterInfo(BaseModel):
    installed: bool
    path: str
    version: str | None


class RootInfo(BaseModel):
    id: str
    label: str
    available: bool


class Capabilities(BaseModel):
    extensions: list[str]
    preview_long_edge: int = Field(serialization_alias="previewLongEdge")


class Info(BaseModel):
    name: str
    version: str
    api: int
    auth: Literal["token", "none"]
    converter: ConverterInfo
    roots: list[RootInfo]
    capabilities: Capabilities


def get_settings(request: Request) -> Settings:
    return request.app.state.settings


SettingsDep = Annotated[Settings, Depends(get_settings)]

_bearer = HTTPBearer(auto_error=False, description="The server's token (LRRP_TOKEN).")


def require_token(
    settings: SettingsDep,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
) -> None:
    """Reject the request unless it carries the configured token. No token configured: open."""
    if settings.token is None:
        return
    if credentials is None:
        raise _unauthorized("Missing bearer token")
    if not secrets.compare_digest(credentials.credentials.encode(), settings.token.encode()):
        raise _unauthorized("Invalid token")


def _unauthorized(detail: str) -> HTTPException:
    return HTTPException(status_code=401, detail=detail, headers={"WWW-Authenticate": "Bearer"})


api = APIRouter(prefix="/api", dependencies=[Depends(require_token)])


@api.get("/v1/info")
def get_info(settings: SettingsDep) -> Info:
    return Info(
        name=NAME,
        version=__version__,
        api=API_VERSION,
        auth="token" if settings.token else "none",
        converter=ConverterInfo(
            installed=converter.is_installed(settings.wineprefix, settings.converter_exe),
            path=settings.converter_exe,
            version=None,
        ),
        roots=[
            RootInfo(id=root.id, label=root.label, available=_is_dir(root.path))
            for root in settings.roots
        ],
        capabilities=Capabilities(
            extensions=list(converter.RAW_EXTENSIONS),
            preview_long_edge=converter.PREVIEW_LONG_EDGE,
        ),
    )


@api.api_route("/{rest:path}", methods=API_METHODS, include_in_schema=False)
def api_not_found() -> None:
    # Unknown API paths get a JSON 404 (after the token check) instead of the dashboard.
    raise HTTPException(status_code=404, detail="Not Found")


def healthz() -> Health:
    return Health(status="ok")


def dashboard(path: str, settings: SettingsDep) -> Response:
    """Serve the built dashboard; unknown paths get index.html (single-page app routing)."""
    if path == "api" or path.startswith("api/"):
        raise HTTPException(status_code=404, detail="Not Found")
    if not _is_dir(settings.web_dir):
        if path == "":
            return PlainTextResponse(NO_DASHBOARD)
        return PlainTextResponse("Not Found\n", status_code=404)
    root = settings.web_dir.resolve()
    index = root / "index.html"
    file = _web_file(root, path)
    if file is not None and file != index:
        return FileResponse(file)
    if not _is_file(index):
        return PlainTextResponse("Not Found\n", status_code=404)
    # index.html names the hashed asset files; never let a browser keep an old copy.
    return FileResponse(index, headers={"Cache-Control": "no-cache"})


def _web_file(root: Path, path: str) -> Path | None:
    """The file that ``path`` names under ``root``; None if there is none or it is outside."""
    if not path or "\x00" in path:
        return None
    try:
        candidate = (root / path).resolve()
    except (OSError, ValueError):
        return None
    if not candidate.is_relative_to(root) or not _is_file(candidate):
        return None
    return candidate


def _is_dir(path: Path) -> bool:
    try:
        return path.is_dir()
    except OSError:
        return False


def _is_file(path: Path) -> bool:
    try:
        return path.is_file()
    except OSError:
        return False


def create_app(settings: Settings) -> FastAPI:
    app = FastAPI(title=NAME, version=__version__, redoc_url=None)
    app.state.settings = settings
    app.add_api_route("/healthz", healthz, methods=["GET"])
    app.include_router(api)
    # Registered last: it catches every GET path that nothing above matched.
    app.add_api_route("/{path:path}", dashboard, methods=["GET"], include_in_schema=False)
    return app
