"""The HTTP application: health check, the JSON API under ``/api`` and the dashboard.

The API is ``docs/protocol.md``. The background work (queue, converter, cache) starts and stops
with the application's lifespan (``Services``).
"""

import asyncio
import logging
import mimetypes
import re
import secrets
import time
from collections.abc import AsyncIterator, Sequence
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath
from typing import Annotated, Any, Literal, Protocol

from fastapi import APIRouter, Depends, FastAPI, HTTPException, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse, Response
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import AfterValidator, BaseModel, Field

from lrrp import __version__, converter, sources
from lrrp.cache import CACHE_KEY, Cache, CacheEntry
from lrrp.display import Display, Xvfb
from lrrp.runner import Runner, RunnerConfig, default_config
from lrrp.scheduler import Scheduler
from lrrp.settings import Settings
from lrrp.store import DATABASE_NAME, ITEM_STATES, Item, Job, NewItem, Store

log = logging.getLogger(__name__)

NAME = "LR Remote Previews"
API_VERSION = 1
MAX_ITEMS_PER_JOB = 5000
RATE_WINDOW_SECONDS = 60
DNG_MEDIA_TYPE = "image/x-adobe-dng"
SHA256_HEADER = "X-LRRP-SHA256"
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

ItemState = Literal["queued", "building", "ready", "failed", "rejected", "cancelled"]
JobState = Literal["active", "done", "cancelled"]


# --- Errors ----------------------------------------------------------------------------------


class ApiError(Exception):
    """An error answer: ``{"detail": ..., "code": ...}`` with ``code`` only when given."""

    def __init__(self, status: int, detail: str, code: str | None = None) -> None:
        super().__init__(detail)
        self.status = status
        self.detail = detail
        self.code = code


async def _api_error(_request: Request, exc: Exception) -> JSONResponse:
    assert isinstance(exc, ApiError)
    body: dict[str, str] = {"detail": exc.detail}
    if exc.code is not None:
        body["code"] = exc.code
    return JSONResponse(body, status_code=exc.status)


async def _validation_error(_request: Request, exc: Exception) -> JSONResponse:
    assert isinstance(exc, RequestValidationError)
    return JSONResponse({"detail": describe_validation_errors(exc.errors())}, status_code=422)


def describe_validation_errors(errors: Sequence[Any], shown: int = 5) -> str:
    """One line for a person out of FastAPI's validation errors: ``items[0].ref: ...``."""
    parts = []
    for error in errors[:shown]:
        if error.get("type") == "json_invalid":
            parts.append("The request body is not valid JSON")
            continue
        location = list(error.get("loc", ()))
        if location and location[0] in ("body", "query", "path", "header"):
            location = location[1:]
        where = ""
        for part in location:
            where += f"[{part}]" if isinstance(part, int) else f"{'.' if where else ''}{part}"
        message = str(error.get("msg", "invalid value"))
        parts.append(f"{where}: {message}" if where else message)
    if len(errors) > shown:
        parts.append(f"and {len(errors) - shown} more")
    return "; ".join(parts) or "Invalid request"


# --- Models ----------------------------------------------------------------------------------


def _valid_unicode(value: str) -> str:
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        raise ValueError("must be valid Unicode text") from None
    return value


Text = Annotated[str, AfterValidator(_valid_unicode)]
Ref = Annotated[Text, Field(max_length=64)]
ShortText = Annotated[Text, Field(max_length=100)]


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
    max_items_per_job: int = Field(serialization_alias="maxItemsPerJob")
    job_retention_days: int = Field(serialization_alias="jobRetentionDays")


class Info(BaseModel):
    name: str
    version: str
    api: int
    auth: Literal["token", "none"]
    converter: ConverterInfo
    roots: list[RootInfo]
    capabilities: Capabilities


class ItemRequest(BaseModel):
    ref: Ref
    root: Text
    path: Text


class JobRequest(BaseModel):
    client: ShortText | None = None
    client_id: Ref | None = Field(default=None, alias="clientId")
    label: ShortText | None = None
    items: list[ItemRequest] = Field(min_length=1)


class LookupRequest(BaseModel):
    items: list[ItemRequest] = Field(min_length=1)


class ItemError(BaseModel):
    code: str
    message: str


class ItemResult(BaseModel):
    key: str
    size: int
    sha256: str
    original_name: str | None = Field(serialization_alias="originalName")
    original_width: int | None = Field(serialization_alias="originalWidth")
    original_height: int | None = Field(serialization_alias="originalHeight")


class ItemOut(BaseModel):
    id: int
    ref: str
    root: str
    path: str
    state: ItemState
    seq: int
    error: ItemError | None
    result: ItemResult | None


class JobCounts(BaseModel):
    total: int
    queued: int
    building: int
    ready: int
    failed: int
    rejected: int
    cancelled: int


class JobOut(BaseModel):
    id: int
    label: str | None
    client: str | None
    client_id: str | None = Field(serialization_alias="clientId")
    state: JobState
    created: str
    finished: str | None
    seq: int
    counts: JobCounts


class JobCreated(BaseModel):
    job: JobOut
    items: list[ItemOut]


class JobEnvelope(BaseModel):
    job: JobOut


class JobList(BaseModel):
    jobs: list[JobOut]


class ItemPage(BaseModel):
    job: JobOut
    items: list[ItemOut]
    more: bool


class LookupItem(BaseModel):
    ref: str
    state: Literal["ready", "pending", "absent", "rejected"]
    error: ItemError | None
    result: ItemResult | None


class LookupAnswer(BaseModel):
    items: list[LookupItem]


class QueueStatus(BaseModel):
    queued: int
    building: int


class WorkerStatus(BaseModel):
    configured: int
    busy: int


class RateStatus(BaseModel):
    per_minute: float = Field(serialization_alias="perMinute")
    window_seconds: int = Field(serialization_alias="windowSeconds")


class TodayStatus(BaseModel):
    built: int
    failed: int


class CacheStatus(BaseModel):
    entries: int
    bytes: int


class JobsStatus(BaseModel):
    active: int


class Status(BaseModel):
    queue: QueueStatus
    workers: WorkerStatus
    rate: RateStatus
    today: TodayStatus
    cache: CacheStatus
    jobs: JobsStatus


# --- Background services ---------------------------------------------------------------------


@dataclass
class Services:
    """What runs behind the API: the database, the cache, the converter runner, the scheduler."""

    store: Store
    cache: Cache
    runner: Runner
    scheduler: Scheduler
    display: Display

    @classmethod
    def start(cls, settings: Settings, runner_config: RunnerConfig, display: Display) -> "Services":
        settings.data_dir.mkdir(parents=True, exist_ok=True)
        cache = Cache(settings.cache_dir)
        cache.prepare()
        store = Store(settings.data_dir / DATABASE_NAME)
        recovered = store.recover(time.time())
        if recovered:
            log.info("put %d item(s) left building by the last run back into the queue", recovered)
        runner = Runner(runner_config, cache.new_work_dir, display)
        scheduler = Scheduler(
            store,
            cache,
            runner,
            settings.roots,
            settings.workers,
            settings.batch_size,
            job_retention_days=settings.job_retention_days,
        )
        scheduler.start()
        return cls(store=store, cache=cache, runner=runner, scheduler=scheduler, display=display)

    def close(self) -> None:
        self.scheduler.stop()
        self.display.stop()
        self.store.close()


# --- Dependencies ----------------------------------------------------------------------------


def get_settings(request: Request) -> Settings:
    return request.app.state.settings


def get_services(request: Request) -> Services:
    return request.app.state.services


SettingsDep = Annotated[Settings, Depends(get_settings)]
ServicesDep = Annotated[Services, Depends(get_services)]

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


# --- The API ---------------------------------------------------------------------------------

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
            max_items_per_job=MAX_ITEMS_PER_JOB,
            job_retention_days=settings.job_retention_days,
        ),
    )


@api.post("/v1/jobs", status_code=201)
def create_job(body: JobRequest, settings: SettingsDep, services: ServicesDep) -> JobCreated:
    _check_requests(body.items, "A job")
    checked, keys = _identify(settings, body.items)
    entries = services.store.cache_entries(key for key in keys if key is not None)
    new_items: list[NewItem] = []
    to_build = False
    for item, found, key in zip(body.items, checked, keys, strict=True):
        if isinstance(found, sources.Rejection):
            new_items.append(
                NewItem(
                    ref=item.ref,
                    root=item.root,
                    path=item.path,
                    state="rejected",
                    error_code=found.code,
                    error_message=found.message,
                )
            )
            continue
        assert key is not None
        entry = entries.get(key)
        state = "ready" if entry is not None and services.cache.has(key, entry.size) else "queued"
        to_build = to_build or state == "queued"
        new_items.append(
            NewItem(
                ref=item.ref,
                root=item.root,
                path=item.path,
                state=state,
                cache_key=key,
                size=found.size,
                mtime_ns=found.mtime_ns,
            )
        )
    if to_build and not converter.is_installed(settings.wineprefix, settings.converter_exe):
        raise ApiError(
            409,
            "Adobe DNG Converter is not installed on the server, so these files cannot be built",
            "converter_not_installed",
        )
    # An empty label, client or clientId counts as none (null in the job object).
    job, items = services.store.create_job(
        body.client or None,
        body.label or None,
        new_items,
        time.time(),
        client_id=body.client_id or None,
    )
    if to_build:
        services.scheduler.wake()
    return JobCreated(job=_job_out(job), items=_items_out(items))


@api.get("/v1/jobs")
def list_jobs(
    services: ServicesDep,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    state: JobState | None = None,
    client_id: Annotated[str | None, Query(alias="clientId")] = None,
) -> JobList:
    jobs = services.store.list_jobs(limit, state, client_id)
    return JobList(jobs=[_job_out(job) for job in jobs])


@api.get("/v1/jobs/{job_id}")
def get_job(job_id: int, services: ServicesDep) -> JobEnvelope:
    return JobEnvelope(job=_job_out(_existing_job(services, job_id)))


@api.get("/v1/jobs/{job_id}/items")
def get_job_items(
    job_id: int,
    services: ServicesDep,
    since: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[int, Query(ge=1, le=1000)] = 500,
    state: ItemState | None = None,
) -> ItemPage:
    _existing_job(services, job_id)
    items, more = services.store.items_since(job_id, since, limit, state)
    # Read the job after its items, so that its seq is never behind theirs.
    return ItemPage(
        job=_job_out(_existing_job(services, job_id)), items=_items_out(items), more=more
    )


@api.post("/v1/jobs/{job_id}/retry")
def retry_job(job_id: int, settings: SettingsDep, services: ServicesDep) -> JobEnvelope:
    job = _existing_job(services, job_id)
    if job.state == "cancelled":
        raise _job_cancelled()
    # Each failed item is tried again with its file as it is now, so that an item that failed
    # because its file changed gets built from the changed file.
    failed = services.store.items_of_job(job_id, "failed")
    checked, keys = _identify(settings, failed)
    identities = {
        item.id: (key, found.size, found.mtime_ns)
        for item, found, key in zip(failed, checked, keys, strict=True)
        if isinstance(found, sources.Source) and key is not None
    }
    outcome = services.store.retry_job(job_id, identities, time.time())
    if outcome == "unknown":
        raise _no_job()
    if outcome == "cancelled":
        raise _job_cancelled()
    if outcome == "retried":
        services.scheduler.wake()
    return JobEnvelope(job=_job_out(_existing_job(services, job_id)))


@api.delete("/v1/jobs/{job_id}")
def cancel_job(job_id: int, services: ServicesDep) -> JobEnvelope:
    if not services.store.cancel_job(job_id, time.time()):
        raise _no_job()
    return JobEnvelope(job=_job_out(_existing_job(services, job_id)))


@api.get("/v1/items/{item_id}/file", response_class=FileResponse)
def get_item_file(item_id: int, services: ServicesDep) -> FileResponse:
    item = services.store.get_item(item_id)
    if item is None:
        raise ApiError(404, "No such item")
    if item.state != "ready" or item.result is None:
        raise ApiError(409, f"The item is {item.state}, not ready", "not_ready")
    entry = item.result
    if not services.cache.has(entry.key, entry.size):
        log.error(
            "item %d is ready, but its DNG %s is missing or has another size",
            item_id,
            services.cache.path(entry.key),
        )
        raise _not_in_cache()
    return _dng_response(services, entry, PurePosixPath(item.path).stem)


@api.post("/v1/lookup")
def lookup(body: LookupRequest, settings: SettingsDep, services: ServicesDep) -> LookupAnswer:
    _check_requests(body.items, "A lookup")
    checked, keys = _identify(settings, body.items)
    wanted = [key for key in keys if key is not None]
    entries = services.store.cache_entries(wanted)
    ready = {key for key, entry in entries.items() if services.cache.has(key, entry.size)}
    pending = services.store.pending_keys(key for key in wanted if key not in ready)
    answers: list[LookupItem] = []
    for item, found, key in zip(body.items, checked, keys, strict=True):
        if isinstance(found, sources.Rejection):
            error = ItemError(code=found.code, message=found.message)
            answers.append(LookupItem(ref=item.ref, state="rejected", error=error, result=None))
        elif key in ready:
            result = _result_out(entries[key])
            answers.append(LookupItem(ref=item.ref, state="ready", error=None, result=result))
        else:
            state: Literal["pending", "absent"] = "pending" if key in pending else "absent"
            answers.append(LookupItem(ref=item.ref, state=state, error=None, result=None))
    return LookupAnswer(items=answers)


@api.get("/v1/files/{key}", response_class=FileResponse)
def get_file(key: str, services: ServicesDep) -> FileResponse:
    if not CACHE_KEY.fullmatch(key):
        raise ApiError(422, "A cache key is 64 lower-case hexadecimal characters")
    entry = services.store.cache_entry(key)
    if entry is None or not services.cache.has(key, entry.size):
        raise _not_in_cache()
    # The DNG records its original's name (checked against the request when it was built).
    original = re.split(r"[\\/]", entry.original_name or "")[-1]
    return _dng_response(services, entry, PurePosixPath(original).stem or key)


@api.get("/v1/status")
def get_status(settings: SettingsDep, services: ServicesDep) -> Status:
    now = time.time()
    midnight = datetime.now().astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
    status = services.store.status(now - RATE_WINDOW_SECONDS, midnight.timestamp())
    return Status(
        queue=QueueStatus(queued=status.queued, building=status.building),
        workers=WorkerStatus(configured=settings.workers, busy=services.runner.busy),
        rate=RateStatus(
            per_minute=status.built_recently * 60 / RATE_WINDOW_SECONDS,
            window_seconds=RATE_WINDOW_SECONDS,
        ),
        today=TodayStatus(built=status.built_today, failed=status.failed_today),
        cache=CacheStatus(entries=status.cache_entries, bytes=status.cache_bytes),
        jobs=JobsStatus(active=status.active_jobs),
    )


@api.api_route("/{rest:path}", methods=API_METHODS, include_in_schema=False)
def api_not_found() -> None:
    # Registered after every API route. Unknown API paths get a JSON 404 (after the token
    # check) instead of the dashboard.
    raise HTTPException(status_code=404, detail="Not Found")


def _existing_job(services: Services, job_id: int) -> Job:
    job = services.store.get_job(job_id)
    if job is None:
        raise _no_job()
    return job


def _no_job() -> ApiError:
    return ApiError(404, "No such job")


def _job_cancelled() -> ApiError:
    return ApiError(409, "The job is cancelled; ask for its files in a new job", "job_cancelled")


def _not_in_cache() -> ApiError:
    return ApiError(404, "The DNG is not in the server's cache", "not_in_cache")


class _Requested(Protocol):
    @property
    def root(self) -> str: ...

    @property
    def path(self) -> str: ...


def _check_requests(items: Sequence[ItemRequest], what: str) -> None:
    """The limits of a list of requested files: their number and unique refs."""
    if len(items) > MAX_ITEMS_PER_JOB:
        raise ApiError(
            413,
            f"{what} may have at most {MAX_ITEMS_PER_JOB} items; this one has {len(items)}",
            "too_many_items",
        )
    seen: set[str] = set()
    for item in items:
        if item.ref in seen:
            raise ApiError(
                422, f"The ref {item.ref!r} is used by more than one item", "duplicate_ref"
            )
        seen.add(item.ref)


def _identify(
    settings: Settings, items: Sequence[_Requested]
) -> tuple[list[sources.Source | sources.Rejection], list[str | None]]:
    """Check each requested file as it is now; the cache key of each acceptable one."""
    resolver = sources.Resolver({root.id: root for root in settings.roots})
    recipe = converter.recipe()
    checked = [resolver.resolve(item.root, item.path) for item in items]
    keys = [
        sources.cache_key(found.root, found.path, found.size, found.mtime_ns, recipe)
        if isinstance(found, sources.Source)
        else None
        for found in checked
    ]
    return checked, keys


def _dng_response(services: Services, entry: CacheEntry, stem: str) -> FileResponse:
    return FileResponse(
        services.cache.path(entry.key),
        media_type=DNG_MEDIA_TYPE,
        filename=stem + ".dng",
        headers={SHA256_HEADER: entry.sha256},
    )


def _job_out(job: Job) -> JobOut:
    counts = {state: job.counts.get(state, 0) for state in ITEM_STATES}
    return JobOut(
        id=job.id,
        label=job.label,
        client=job.client,
        client_id=job.client_id,
        state=job.state,
        created=_iso(job.created),
        finished=None if job.finished is None else _iso(job.finished),
        seq=job.seq,
        counts=JobCounts(total=sum(counts.values()), **counts),
    )


def _items_out(items: Sequence[Item]) -> list[ItemOut]:
    return [_item_out(item) for item in items]


def _item_out(item: Item) -> ItemOut:
    error = None
    if item.error_code is not None:
        error = ItemError(code=item.error_code, message=item.error_message or "")
    result = None
    if item.state == "ready" and item.result is not None:
        result = _result_out(item.result)
    return ItemOut(
        id=item.id,
        ref=item.ref,
        root=item.root,
        path=item.path,
        state=item.state,
        seq=item.seq,
        error=error,
        result=result,
    )


def _result_out(entry: CacheEntry) -> ItemResult:
    return ItemResult(
        key=entry.key,
        size=entry.size,
        sha256=entry.sha256,
        original_name=entry.original_name,
        original_width=entry.original_width,
        original_height=entry.original_height,
    )


def _iso(timestamp: float) -> str:
    return datetime.fromtimestamp(timestamp, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


# --- Health check and dashboard --------------------------------------------------------------


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


def create_app(
    settings: Settings,
    *,
    runner_config: RunnerConfig | None = None,
    display: Display | None = None,
) -> FastAPI:
    """Build the application. ``runner_config`` and ``display`` replace Wine and Xvfb in tests."""

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        services = await asyncio.to_thread(
            Services.start,
            settings,
            runner_config or default_config(settings),
            display or Xvfb(),
        )
        app.state.services = services
        try:
            yield
        finally:
            await asyncio.to_thread(services.close)

    app = FastAPI(title=NAME, version=__version__, redoc_url=None, lifespan=lifespan)
    app.state.settings = settings
    app.add_exception_handler(ApiError, _api_error)
    app.add_exception_handler(RequestValidationError, _validation_error)
    app.add_api_route("/healthz", healthz, methods=["GET"])
    app.include_router(api)
    # Registered last: it catches every GET path that nothing above matched.
    app.add_api_route("/{path:path}", dashboard, methods=["GET"], include_in_schema=False)
    return app
