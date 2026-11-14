"""The HTTP application: health check, the JSON API under ``/api`` and the dashboard.

The API is ``docs/protocol.md``. The background work (queue, converter, cache) starts and stops
with the application's lifespan (``Services``).
"""

import asyncio
import logging
import math
import mimetypes
import re
import secrets
import time
from collections.abc import AsyncIterator, Callable, Iterable, Sequence
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import UTC, datetime
from functools import partial
from pathlib import Path, PurePosixPath
from typing import Annotated, Any, Literal, Protocol

from fastapi import APIRouter, Depends, FastAPI, HTTPException, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse, Response
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import AfterValidator, BaseModel, Field, ValidationInfo, field_validator
from starlette.concurrency import run_in_threadpool

from lrrp import __version__, converter, folders, runtime, sensors, sources
from lrrp.autoscan import AutoScanner, ScanBusy
from lrrp.cache import CACHE_KEY, Cache, CacheEntry
from lrrp.cleanup import CacheCleaner, CleanBusy
from lrrp.display import Display, Xvfb
from lrrp.logring import LogRing
from lrrp.peversion import VersionCache
from lrrp.runner import Runner, RunnerConfig, default_config
from lrrp.runtime import Controls
from lrrp.scheduler import Scheduler
from lrrp.selftest import SelfTest, SelfTestBusy
from lrrp.settings import Settings
from lrrp.store import (
    DATABASE_NAME,
    ITEM_STATES,
    USE_RESOLUTION,
    AppendRefused,
    Item,
    Job,
    NewItem,
    NewJob,
    Store,
)
from lrrp.waits import Waits, Watch

log = logging.getLogger(__name__)

NAME = "LR Remote Previews"
API_VERSION = 1
MAX_ITEMS_PER_JOB = 5000
MAX_WAIT_SECONDS = 55
"""The longest ``wait`` of ``GET /api/v1/jobs/{id}/items``: below the 60 s that reverse proxies
commonly allow for an answer (nginx's ``proxy_read_timeout``, for one)."""
WAIT_DRAIN_SECONDS = 10.0
"""At shutdown, how long the lifespan lets the waiting requests answer before it closes the
database."""
MAX_LISTED_FOLDERS = 5000
"""The most sub-folders ``GET /api/v1/browse`` lists."""
MAX_FOLDER_FILES = 50000
"""The most raw files ``POST /api/v1/folders`` queues at once."""
FOLDER_CLIENT = "dashboard"
RATE_WINDOW_SECONDS = 60
LOG_LIMIT_DEFAULT = 200
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
Priority = Literal["normal", "background"]


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
        cause = (error.get("ctx") or {}).get("error")
        if error.get("type") == "value_error" and isinstance(cause, ValueError):
            message = str(cause)  # our own message, without pydantic's "Value error, "
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
    busy: bool


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
    append_items: bool = Field(serialization_alias="appendItems")
    max_wait_seconds: int = Field(serialization_alias="maxWaitSeconds")


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
    priority: Priority | None = Field(
        default=None, description='"normal" (default) or "background"'
    )
    items: list[ItemRequest] = Field(min_length=1)


class AddItemsRequest(BaseModel):
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
    priority: Priority
    state: JobState
    created: str
    finished: str | None
    seq: int
    counts: JobCounts


class JobCreated(BaseModel):
    job: JobOut
    items: list[ItemOut]


class ItemsAdded(BaseModel):
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


class AutoScanStatus(BaseModel):
    running: bool
    last_run: str | None = Field(serialization_alias="lastRun")
    last_queued: int = Field(serialization_alias="lastQueued")
    next_run: str | None = Field(serialization_alias="nextRun")


ServerState = Literal["running", "idle", "paused", "waiting"]


class Status(BaseModel):
    state: ServerState
    queue: QueueStatus
    workers: WorkerStatus
    rate: RateStatus
    eta_seconds: int | None = Field(serialization_alias="etaSeconds")
    today: TodayStatus
    cache: CacheStatus
    jobs: JobsStatus
    cpu_temperature: float | None = Field(serialization_alias="cpuTemperature")
    auto_scan: AutoScanStatus = Field(serialization_alias="autoScan")


class WorkingHoursOut(BaseModel):
    enabled: bool
    start: str = Field(serialization_alias="from")
    end: str = Field(serialization_alias="to")


class AutoScanOut(BaseModel):
    enabled: bool
    roots: list[str]
    interval_minutes: int = Field(serialization_alias="intervalMinutes")
    settle_minutes: int = Field(serialization_alias="settleMinutes")
    max_files_per_run: int = Field(serialization_alias="maxFilesPerRun")


class CacheLimitsOut(BaseModel):
    max_bytes: int | None = Field(serialization_alias="maxBytes")
    max_age_days: int | None = Field(serialization_alias="maxAgeDays")


class SettingsOut(BaseModel):
    workers: Literal["auto"] | int
    effective_workers: int = Field(serialization_alias="effectiveWorkers")
    batch_size: int = Field(serialization_alias="batchSize")
    paused: bool
    working_hours: WorkingHoursOut = Field(serialization_alias="workingHours")
    auto_scan: AutoScanOut = Field(serialization_alias="autoScan")
    cache: CacheLimitsOut


class SettingsPatch(BaseModel):
    """Any subset of the settings; each value is checked by ``lrrp.runtime``."""

    workers: Any = Field(default=None, description='"auto" or 1 to 32, never 2')
    batch_size: Any = Field(default=None, alias="batchSize", description="1 to 64")
    paused: Any = Field(default=None, description="true or false")
    working_hours: Any = Field(
        default=None,
        alias="workingHours",
        description='{"enabled": bool, "from": "HH:MM", "to": "HH:MM"}, from != to',
    )
    auto_scan: Any = Field(
        default=None,
        alias="autoScan",
        description='{"enabled": bool, "roots": [root ids], "intervalMinutes": 5 to 1440,'
        ' "settleMinutes": 0 to 1440, "maxFilesPerRun": 1 to 50000}',
    )
    cache: Any = Field(
        default=None,
        description='{"maxBytes": null or at least 104857600, "maxAgeDays": null or 1 to 3650}',
    )

    @field_validator("workers", "batch_size", "paused", "working_hours", "auto_scan", "cache")
    @classmethod
    def _check(cls, value: Any, info: ValidationInfo) -> Any:
        assert info.field_name is not None
        name = cls.model_fields[info.field_name].alias or info.field_name
        return runtime.PARSERS[name][1](value)

    def changes(self) -> dict[str, Any]:
        """The checked values that were given, by API name."""
        return {
            (SettingsPatch.model_fields[field].alias or field): getattr(self, field)
            for field in self.model_fields_set
        }


class FolderEntry(BaseModel):
    name: str
    path: str


class BrowseAnswer(BaseModel):
    root: str
    path: str
    parent: str | None
    dirs: list[FolderEntry]
    raw_files: int = Field(serialization_alias="rawFiles")
    built_files: int = Field(serialization_alias="builtFiles")
    other_files: int = Field(serialization_alias="otherFiles")
    truncated: bool


class FolderRequest(BaseModel):
    root: Text
    path: Text | None = None
    recursive: bool = False
    label: ShortText | None = None
    priority: Priority | None = Field(
        default=None, description='"normal" (default) or "background"'
    )


class FolderQueued(BaseModel):
    files: int
    already_built: int = Field(serialization_alias="alreadyBuilt")
    jobs: list[JobOut]


class ScanRequest(BaseModel):
    roots: list[Text] | None = None


class ScanStarted(BaseModel):
    started: bool


class CleanRequest(BaseModel):
    # Strict: a value that only looks like a boolean must not turn a dry run into a real one.
    dry_run: bool = Field(default=False, alias="dryRun", strict=True)


class CleanRemoved(BaseModel):
    original_gone: int = Field(serialization_alias="originalGone")
    expired: int
    over_limit: int = Field(serialization_alias="overLimit")


class CleanAnswer(BaseModel):
    dry_run: bool = Field(serialization_alias="dryRun")
    removed: CleanRemoved
    bytes_freed: int = Field(serialization_alias="bytesFreed")


class SelfTestRequest(BaseModel):
    root: Text | None = None
    path: Text | None = None


class SelfTestStep(BaseModel):
    name: Literal["installed", "display", "warm-up", "conversion"]
    ok: bool
    detail: str


class SelfTestAnswer(BaseModel):
    ok: bool
    steps: list[SelfTestStep]


class LogLineOut(BaseModel):
    time: str
    level: str
    logger: str
    message: str


class LogAnswer(BaseModel):
    lines: list[LogLineOut]


# --- Background services ---------------------------------------------------------------------


@dataclass
class Services:
    """What runs behind the API: the database, the cache, the converter runner, the scheduler,
    the runtime settings, the self-test, the automatic scan, the cache clean-up and the requests
    that wait for a change."""

    store: Store
    cache: Cache
    runner: Runner
    scheduler: Scheduler
    display: Display
    controls: Controls
    selftest: SelfTest
    autoscan: AutoScanner
    cleaner: CacheCleaner
    waits: Waits
    clock: Callable[[], float]
    """The time (seconds since the epoch) of everything the server records."""
    sysfs: Path | None
    """Where sysfs is for the CPU temperature; None: ``/sys`` on Linux, nothing elsewhere."""

    @classmethod
    def start(
        cls,
        settings: Settings,
        runner_config: RunnerConfig,
        display: Display,
        *,
        converter_version: Callable[[], str | None],
        local_clock: Callable[[], datetime] | None = None,
        clock: Callable[[], float] | None = None,
        sysfs: Path | None = None,
    ) -> "Services":
        clock = clock or time.time
        settings.data_dir.mkdir(parents=True, exist_ok=True)
        cache = Cache(settings.cache_dir)
        cache.prepare()
        waits = Waits()
        store = Store(settings.data_dir / DATABASE_NAME, on_change=waits.changed)
        recovered = store.recover(clock())
        if recovered:
            log.info("put %d item(s) left building by the last run back into the queue", recovered)
        controls = Controls.from_settings(settings, store, local_clock)
        current = controls.current()
        log.info(
            "%d converter process(es) side by side (workers: %s), batches of up to %d files%s%s",
            controls.effective_workers(current),
            "auto" if current.workers is None else current.workers,
            current.batch_size,
            "; paused" if current.paused else "",
            f"; working hours {current.working_hours.start}-{current.working_hours.end}"
            if current.working_hours.enabled
            else "",
        )
        runner = Runner(runner_config, cache.new_work_dir, display)
        scheduler = Scheduler(
            store,
            cache,
            runner,
            settings.roots,
            settings.workers,
            settings.batch_size,
            clock=clock,
            job_retention_days=settings.job_retention_days,
            controls=controls,
        )
        scheduler.start()
        autoscan = AutoScanner(
            store,
            settings.roots,
            controls,
            converter_installed=lambda: converter.is_installed(
                settings.wineprefix, settings.converter_exe
            ),
            on_queued=scheduler.wake,
            max_items_per_job=MAX_ITEMS_PER_JOB,
            clock=clock,
        )
        autoscan.start()
        cleaner = CacheCleaner(store, cache, settings.roots, controls, clock)
        cleaner.start()
        return cls(
            store=store,
            cache=cache,
            runner=runner,
            scheduler=scheduler,
            display=display,
            controls=controls,
            selftest=SelfTest(settings, runner, scheduler, converter_version),
            autoscan=autoscan,
            cleaner=cleaner,
            waits=waits,
            clock=clock,
            sysfs=sysfs,
        )

    def close(self) -> None:
        self.waits.close()
        self.autoscan.stop()
        self.cleaner.stop()
        self.scheduler.stop()
        self.display.stop()
        self.waits.stop()
        self.store.close()

    def touch(self, entries: Iterable[CacheEntry]) -> None:
        """Record a use of these cache entries (found by a job or a lookup, downloaded): written
        only for those whose last recorded use is ``USE_RESOLUTION`` or more ago."""
        now = self.clock()
        stale = [e.key for e in entries if e.used is None or e.used <= now - USE_RESOLUTION]
        if stale:
            self.store.touch(stale, now)

    def state(self, queued: int, building: int) -> ServerState:
        """``status.state``: a wave in progress (or a self-test's converter) is ``running`` even
        when paused meanwhile; then ``paused``; ``idle`` with nothing queued; ``waiting`` outside
        the working hours; else ``running`` (a wave is about to start)."""
        if building > 0 or self.runner.busy > 0 or (queued > 0 and self.scheduler.in_wave):
            return "running"
        gate = self.controls.gate()
        if gate == "paused":
            return "paused"
        if queued == 0:
            return "idle"
        if gate == "waiting":
            return "waiting"
        return "running"


# --- Dependencies ----------------------------------------------------------------------------
# Coroutines, though nothing in them waits: FastAPI runs a plain function dependency in a worker
# thread, which would cost every request (also each waiting one) a few trips to the thread pool.


async def get_settings(request: Request) -> Settings:
    return request.app.state.settings


async def get_services(request: Request) -> Services:
    return request.app.state.services


async def get_versions(request: Request) -> VersionCache:
    return request.app.state.converter_versions


async def get_log_ring(request: Request) -> LogRing:
    return request.app.state.log_ring


SettingsDep = Annotated[Settings, Depends(get_settings)]
ServicesDep = Annotated[Services, Depends(get_services)]
VersionsDep = Annotated[VersionCache, Depends(get_versions)]
LogRingDep = Annotated[LogRing, Depends(get_log_ring)]

_bearer = HTTPBearer(auto_error=False, description="The server's token (LRRP_TOKEN).")


async def require_token(
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
def get_info(settings: SettingsDep, versions: VersionsDep) -> Info:
    installed = converter.is_installed(settings.wineprefix, settings.converter_exe)
    return Info(
        name=NAME,
        version=__version__,
        api=API_VERSION,
        auth="token" if settings.token else "none",
        converter=ConverterInfo(
            installed=installed,
            path=settings.converter_exe,
            version=_converter_version(settings, versions) if installed else None,
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
            append_items=True,
            max_wait_seconds=MAX_WAIT_SECONDS,
        ),
    )


@api.post("/v1/jobs", status_code=201)
def create_job(body: JobRequest, settings: SettingsDep, services: ServicesDep) -> JobCreated:
    _check_requests(body.items, "A job")
    new_items, to_build = _new_items(settings, services, body.items)
    if to_build and not converter.is_installed(settings.wineprefix, settings.converter_exe):
        raise _converter_not_installed()
    # An empty label, client or clientId counts as none (null in the job object).
    job, items = services.store.create_job(
        body.client or None,
        body.label or None,
        new_items,
        services.clock(),
        client_id=body.client_id or None,
        priority=body.priority or "normal",
    )
    services.touch(item.result for item in items if item.result is not None)
    if job.state == "active":
        services.scheduler.wake()
    return JobCreated(job=_job_out(job), items=_items_out(items))


@api.post("/v1/jobs/{job_id}/items")
def add_job_items(
    job_id: int, body: AddItemsRequest, settings: SettingsDep, services: ServicesDep
) -> ItemsAdded:
    # The cheap refusals come before the files are looked at; the store checks them all again in
    # the transaction that adds the items, so a change meanwhile cannot slip through.
    job = _existing_job(services, job_id)
    if job.state == "cancelled":
        raise _job_cancelled()
    _check_requests(body.items, "A request")
    refs = [item.ref for item in body.items]
    used = services.store.used_refs(job_id, refs)
    if used:
        raise _ref_in_job(next(ref for ref in refs if ref in used))
    total = sum(job.counts.values())
    if total + len(body.items) > MAX_ITEMS_PER_JOB:
        raise _job_too_big(total, len(body.items))
    new_items, to_build = _new_items(settings, services, body.items)
    if to_build and not converter.is_installed(settings.wineprefix, settings.converter_exe):
        raise _converter_not_installed()
    outcome = services.store.append_items(job_id, new_items, services.clock(), MAX_ITEMS_PER_JOB)
    if isinstance(outcome, AppendRefused):
        if outcome.reason == "unknown":
            raise _no_job()
        if outcome.reason == "cancelled":
            raise _job_cancelled()
        if outcome.reason == "duplicate_ref":
            raise _ref_in_job(outcome.ref or "")
        raise _job_too_big(outcome.total, len(new_items))
    services.touch(item.result for item in outcome.items if item.result is not None)
    if any(item.state == "queued" for item in outcome.items):
        services.scheduler.wake()
    return ItemsAdded(job=_job_out(outcome.job), items=_items_out(outcome.items))


def _new_items(
    settings: Settings, services: Services, requested: Sequence[ItemRequest]
) -> tuple[list[NewItem], bool]:
    """Each requested file checked as it is now: rejected, ready (its DNG is in the cache) or
    queued; and whether any is queued."""
    checked, keys = _identify(settings, requested)
    entries = services.store.cache_entries(key for key in keys if key is not None)
    new_items: list[NewItem] = []
    to_build = False
    for item, found, key in zip(requested, checked, keys, strict=True):
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
    return new_items, to_build


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


@api.get("/v1/jobs/{job_id}/items", response_model=ItemPage)
async def get_job_items(
    job_id: int,
    request: Request,
    services: ServicesDep,
    since: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[int, Query(ge=1, le=1000)] = 500,
    state: ItemState | None = None,
    wait: Annotated[
        float,
        Query(
            ge=0,
            le=MAX_WAIT_SECONDS,
            description="Seconds to wait for a change when there is nothing to return "
            f"(0 to {MAX_WAIT_SECONDS})",
        ),
    ] = 0,
) -> ItemPage | Response:
    look = partial(_item_page, services, job_id, since, limit, state)
    if wait == 0:
        return await run_in_threadpool(look)
    return await _wait_for_items(request, services.waits, job_id, state, wait, look)


def _item_page(
    services: Services, job_id: int, since: int, limit: int, state: str | None
) -> ItemPage:
    items, more = services.store.items_since(job_id, since, limit, state)
    # Read the job after its items, so that its seq is never behind theirs.
    return ItemPage(
        job=_job_out(_existing_job(services, job_id)), items=_items_out(items), more=more
    )


async def _wait_for_items(
    request: Request,
    waits: Waits,
    job_id: int,
    state: str | None,
    wait: float,
    look: Callable[[], ItemPage],
) -> ItemPage | Response:
    """Look until a look finds items, the job is gone (the look answers 404), ``wait`` seconds
    have passed or the server stops; between looks, sleep until the job changes (``lrrp.waits``).
    """
    loop = asyncio.get_running_loop()
    deadline = loop.time() + wait
    watch = waits.watch(job_id, state)
    listener = asyncio.create_task(_until_disconnected(request, watch))
    try:
        while True:
            watch.clear()
            page = await waits.look(look)
            if page.items or watch.closing or loop.time() >= deadline:
                return page
            await watch.sleep(deadline - loop.time())
            if watch.client_gone:
                return Response(status_code=204)  # nobody reads it
    finally:
        listener.cancel()
        waits.forget(watch)


async def _until_disconnected(request: Request, watch: Watch) -> None:
    """Wake ``watch`` when the client closes its connection."""
    try:
        while (await request.receive())["type"] != "http.disconnect":
            pass
    except Exception:  # the server's affair; the request then just waits its time
        log.debug("cannot follow the connection of a waiting request", exc_info=True)
        return
    watch.client_gone = True
    watch.wake()


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
    outcome = services.store.retry_job(job_id, identities, services.clock())
    if outcome == "unknown":
        raise _no_job()
    if outcome == "cancelled":
        raise _job_cancelled()
    if outcome == "retried":
        services.scheduler.wake()
    return JobEnvelope(job=_job_out(_existing_job(services, job_id)))


@api.delete("/v1/jobs/{job_id}")
def cancel_job(job_id: int, services: ServicesDep) -> JobEnvelope:
    if not services.store.cancel_job(job_id, services.clock()):
        raise _no_job()
    return JobEnvelope(job=_job_out(_existing_job(services, job_id)))


@api.get("/v1/items/{item_id}/file", response_class=FileResponse)
def get_item_file(item_id: int, services: ServicesDep) -> FileResponse:
    item = services.store.get_item(item_id)
    if item is None:
        raise ApiError(404, "No such item")
    if item.state != "ready":
        raise ApiError(409, f"The item is {item.state}, not ready", "not_ready")
    entry = item.result
    if entry is None:
        # The clean-up removed its DNG (and the index entry) after the job had finished.
        raise _not_in_cache()
    if not services.cache.has(entry.key, entry.size):
        log.error(
            "item %d is ready, but its DNG %s is missing or has another size",
            item_id,
            services.cache.path(entry.key),
        )
        raise _not_in_cache()
    services.touch([entry])
    return _dng_response(services, entry, PurePosixPath(item.path).stem)


@api.post("/v1/lookup")
def lookup(body: LookupRequest, settings: SettingsDep, services: ServicesDep) -> LookupAnswer:
    _check_requests(body.items, "A lookup")
    checked, keys = _identify(settings, body.items)
    wanted = [key for key in keys if key is not None]
    entries = services.store.cache_entries(wanted)
    ready = {key for key, entry in entries.items() if services.cache.has(key, entry.size)}
    services.touch(entries[key] for key in ready)
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
    services.touch([entry])
    # The DNG records its original's name (checked against the request when it was built).
    original = re.split(r"[\\/]", entry.original_name or "")[-1]
    return _dng_response(services, entry, PurePosixPath(original).stem or key)


@api.get("/v1/status")
def get_status(services: ServicesDep) -> Status:
    now = services.clock()
    midnight = (
        datetime.fromtimestamp(now).astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
    )
    status = services.store.status(now - RATE_WINDOW_SECONDS, midnight.timestamp())
    state = services.state(status.queued, status.building)
    per_minute = status.built_recently * 60 / RATE_WINDOW_SECONDS
    eta = None
    if state == "running" and per_minute > 0 and status.pending_files > 0:
        # Files, not items: two jobs that ask for one file share its build.
        eta = math.ceil(status.pending_files * 60 / per_minute)
    scan = services.autoscan.status()
    return Status(
        state=state,
        queue=QueueStatus(queued=status.queued, building=status.building),
        workers=WorkerStatus(
            configured=services.controls.effective_workers(), busy=services.runner.busy
        ),
        rate=RateStatus(per_minute=per_minute, window_seconds=RATE_WINDOW_SECONDS),
        eta_seconds=eta,
        today=TodayStatus(built=status.built_today, failed=status.failed_today),
        cache=CacheStatus(entries=status.cache_entries, bytes=status.cache_bytes),
        jobs=JobsStatus(active=status.active_jobs),
        cpu_temperature=sensors.cpu_temperature(services.sysfs),
        auto_scan=AutoScanStatus(
            running=scan.running,
            last_run=None if scan.last_run is None else _iso(scan.last_run),
            last_queued=scan.last_queued,
            next_run=None if scan.next_run is None else _iso(scan.next_run),
        ),
    )


# --- Settings --------------------------------------------------------------------------------


@api.get("/v1/settings")
def get_runtime_settings(services: ServicesDep) -> SettingsOut:
    return _settings_out(services.controls)


@api.patch("/v1/settings")
def patch_runtime_settings(body: SettingsPatch, services: ServicesDep) -> SettingsOut:
    changes = body.changes()
    auto_scan = changes.get("autoScan")
    if auto_scan is not None:
        unknown = services.controls.unknown_roots(auto_scan.roots)
        if unknown:
            raise ApiError(422, f"autoScan: the server has no root {_listed(unknown)}")
    services.controls.update(changes)
    services.scheduler.wake()
    services.autoscan.wake()
    return _settings_out(services.controls)


def _settings_out(controls: Controls) -> SettingsOut:
    current = controls.current()
    hours = current.working_hours
    scan = current.auto_scan
    return SettingsOut(
        workers="auto" if current.workers is None else current.workers,
        effective_workers=controls.effective_workers(current),
        batch_size=current.batch_size,
        paused=current.paused,
        working_hours=WorkingHoursOut(enabled=hours.enabled, start=hours.start, end=hours.end),
        auto_scan=AutoScanOut(
            enabled=scan.enabled,
            roots=list(scan.roots),
            interval_minutes=scan.interval_minutes,
            settle_minutes=scan.settle_minutes,
            max_files_per_run=scan.max_files_per_run,
        ),
        cache=CacheLimitsOut(
            max_bytes=current.cache.max_bytes, max_age_days=current.cache.max_age_days
        ),
    )


def _listed(values: Sequence[str]) -> str:
    return ", ".join(repr(value) for value in values)


# --- Browsing and queueing folders -----------------------------------------------------------


@api.get("/v1/browse")
def browse(settings: SettingsDep, services: ServicesDep, root: str, path: str = "") -> BrowseAnswer:
    folder = _existing_folder(settings, root, path)
    try:
        listing = folders.list_folder(folder)
    except folders.FolderUnreadable:
        raise ApiError(404, "The folder cannot be read", "not_found") from None
    built = len(_built(services, folder.root, listing.raw))
    shown = listing.dirs[:MAX_LISTED_FOLDERS]
    return BrowseAnswer(
        root=folder.root,
        path=folder.path,
        parent=None if folder.path == "" else folder.path.rpartition("/")[0],
        dirs=[
            FolderEntry(name=name, path=f"{folder.path}/{name}" if folder.path else name)
            for name in shown
        ],
        raw_files=len(listing.raw),
        built_files=built,
        other_files=listing.other,
        truncated=len(listing.dirs) > len(shown),
    )


@api.post("/v1/folders", status_code=201)
def queue_folder(body: FolderRequest, settings: SettingsDep, services: ServicesDep) -> FolderQueued:
    folder = _existing_folder(settings, body.root, body.path or "")
    try:
        files = folders.find_raw_files(folder, recursive=body.recursive, limit=MAX_FOLDER_FILES)
    except folders.FolderUnreadable:
        raise ApiError(404, "The folder cannot be read", "not_found") from None
    except folders.TooManyFiles:
        raise ApiError(
            422,
            f"The folder has more than {MAX_FOLDER_FILES} raw files; queue its sub-folders instead",
            "too_many_files",
        ) from None
    if not files:
        return FolderQueued(files=0, already_built=0, jobs=[])
    recipe = converter.recipe()
    keys = [
        sources.cache_key(folder.root, file.path, file.size, file.mtime_ns, recipe)
        for file in files
    ]
    built = _built(services, folder.root, files, keys)
    to_build = len(files) - sum(key in built for key in keys)
    if to_build and not converter.is_installed(settings.wineprefix, settings.converter_exe):
        raise _converter_not_installed()
    label = body.label or _folder_label(folder)
    items = [
        NewItem(
            ref=str(index),
            root=folder.root,
            path=file.path,
            state="ready" if key in built else "queued",
            cache_key=key,
            size=file.size,
            mtime_ns=file.mtime_ns,
        )
        for index, (file, key) in enumerate(zip(files, keys, strict=True), start=1)
    ]
    per_job = MAX_ITEMS_PER_JOB
    priority = body.priority or "normal"
    jobs = services.store.create_jobs(
        [
            NewJob(
                client=FOLDER_CLIENT,
                label=label,
                items=items[start : start + per_job],
                priority=priority,
            )
            for start in range(0, len(items), per_job)
        ],
        services.clock(),
    )
    services.touch(built.values())
    if any(job.state == "active" for job in jobs):
        services.scheduler.wake()
    log.info(
        "queued the folder %r of root %r%s: %d raw file(s), %d already built, in %d job(s)",
        folder.path,
        folder.root,
        " with its sub-folders" if body.recursive else "",
        len(files),
        len(files) - to_build,
        len(jobs),
    )
    return FolderQueued(
        files=len(files), already_built=len(files) - to_build, jobs=[_job_out(j) for j in jobs]
    )


def _existing_folder(settings: Settings, root: str, path: str) -> sources.Folder:
    found = sources.Resolver({r.id: r for r in settings.roots}).resolve_folder(root, path)
    if isinstance(found, sources.Rejection):
        status = 422 if found.code in ("bad_path", "not_a_folder") else 404
        raise ApiError(status, found.message, found.code)
    return found


def _built(
    services: Services,
    root: str,
    files: Sequence[folders.RawFile],
    keys: Sequence[str] | None = None,
) -> dict[str, CacheEntry]:
    """The cache entries of these files whose DNG is in the cache now, by key."""
    if keys is None:
        recipe = converter.recipe()
        keys = [sources.cache_key(root, f.path, f.size, f.mtime_ns, recipe) for f in files]
    entries = services.store.cache_entries(keys)
    return {key: e for key, e in entries.items() if services.cache.has(key, e.size)}


def _folder_label(folder: sources.Folder) -> str:
    label = folder.path or folder.root
    limit = 100
    return label if len(label) <= limit else "…" + label[-(limit - 1) :]


# --- The automatic scan and the cache clean-up -----------------------------------------------


@api.post("/v1/autoscan/run", status_code=202)
def run_auto_scan(
    settings: SettingsDep, services: ServicesDep, body: ScanRequest | None = None
) -> ScanStarted:
    roots = list(dict.fromkeys(body.roots)) if body is not None and body.roots else []
    if not roots:
        roots = list(services.controls.current().auto_scan.roots)
        if not roots:
            raise ApiError(
                422, "No root to scan: name one, or choose the roots of the automatic scan"
            )
    unknown = services.controls.unknown_roots(roots)
    if unknown:
        raise ApiError(422, f"The server has no root {_listed(unknown)}", "unknown_root")
    if not converter.is_installed(settings.wineprefix, settings.converter_exe):
        raise _converter_not_installed()
    try:
        services.autoscan.request(roots)
    except ScanBusy:
        raise ApiError(409, "A scan is running", "busy") from None
    log.info("automatic scan of %s asked for", _listed(roots))
    return ScanStarted(started=True)


@api.post("/v1/cache/clean")
def clean_cache(services: ServicesDep, body: CleanRequest | None = None) -> CleanAnswer:
    dry_run = body is not None and body.dry_run
    try:
        result = services.cleaner.clean(dry_run)
    except CleanBusy:
        raise ApiError(409, "A cache clean-up is running", "busy") from None
    return CleanAnswer(
        dry_run=result.dry_run,
        removed=CleanRemoved(
            original_gone=result.original_gone,
            expired=result.expired,
            over_limit=result.over_limit,
        ),
        bytes_freed=result.bytes_freed,
    )


# --- The converter self-test and the log -----------------------------------------------------


@api.post("/v1/converter/selftest")
def converter_selftest(
    settings: SettingsDep, services: ServicesDep, body: SelfTestRequest | None = None
) -> SelfTestAnswer:
    source = None
    if body is not None and (body.root is not None or body.path is not None):
        if body.root is None or body.path is None:
            raise ApiError(422, "Name the file to convert with both root and path")
        found = sources.Resolver({r.id: r for r in settings.roots}).resolve(body.root, body.path)
        if isinstance(found, sources.Rejection):
            raise ApiError(422, found.message, found.code)
        source = found
    try:
        steps = services.selftest.run(source)
    except SelfTestBusy:
        raise ApiError(409, "Another converter self-test is running", "busy") from None
    return SelfTestAnswer(
        ok=all(step.ok for step in steps),
        steps=[SelfTestStep.model_validate(vars(step)) for step in steps],
    )


@api.get("/v1/log")
def get_log(
    ring: LogRingDep,
    limit: Annotated[int, Query(ge=1, le=1000)] = LOG_LIMIT_DEFAULT,
) -> LogAnswer:
    return LogAnswer(
        lines=[
            LogLineOut(
                time=_iso(line.time), level=line.level, logger=line.logger, message=line.message
            )
            for line in ring.lines(limit)
        ]
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


def _ref_in_job(ref: str) -> ApiError:
    return ApiError(422, f"The job already has an item with the ref {ref!r}", "duplicate_ref")


def _job_too_big(total: int, added: int) -> ApiError:
    return ApiError(
        413,
        f"The job has {total} items; {added} more would make more than {MAX_ITEMS_PER_JOB}."
        " Start another job for the rest",
        "too_many_items",
    )


def _not_in_cache() -> ApiError:
    return ApiError(404, "The DNG is not in the server's cache", "not_in_cache")


def _converter_not_installed() -> ApiError:
    return ApiError(
        409,
        "Adobe DNG Converter is not installed on the server, so these files cannot be built",
        "converter_not_installed",
    )


def _converter_version(settings: Settings, versions: VersionCache) -> str | None:
    """The converter's product version, from its executable (read again only when it changes)."""
    try:
        exe = converter.prefix_path(settings.wineprefix, settings.converter_exe)
    except ValueError:
        return None
    return versions.get(exe)


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
        priority=job.priority,
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


def healthz(request: Request) -> Health:
    """No token, and cheap: one small query (the queue's counts) and a look at the settings."""
    services: Services | None = getattr(request.app.state, "services", None)
    if services is None:
        return Health(status="ok", busy=False)
    queued, building = services.store.pending()
    return Health(status="ok", busy=services.state(queued, building) == "running")


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


def end_waits(app: FastAPI) -> None:
    """The server begins to stop: every request that waits for a change answers now, and later
    ones do not wait. From any thread."""
    services: Services | None = getattr(app.state, "services", None)
    if services is not None:
        services.waits.close()


def create_app(
    settings: Settings,
    *,
    runner_config: RunnerConfig | None = None,
    display: Display | None = None,
    local_clock: Callable[[], datetime] | None = None,
    clock: Callable[[], float] | None = None,
    sysfs: Path | None = None,
) -> FastAPI:
    """Build the application. ``runner_config`` and ``display`` replace Wine and Xvfb in tests,
    ``local_clock`` the local time the working hours are checked against, ``clock`` the time
    (seconds since the epoch) of what the server records and schedules (jobs, the cache's last
    uses, the automatic scan, the clean-up), and ``sysfs`` the folder the CPU temperature is read
    from (default: ``/sys`` on Linux, nothing elsewhere)."""
    versions = VersionCache()
    ring = LogRing(secret=settings.token)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        # The ring is attached here, not earlier: uvicorn configures logging before this runs.
        server_log = logging.getLogger("lrrp")
        server_log.addHandler(ring)
        if server_log.level == logging.NOTSET and server_log.getEffectiveLevel() > logging.INFO:
            server_log.setLevel(logging.INFO)
        try:
            services = await asyncio.to_thread(
                Services.start,
                settings,
                runner_config or default_config(settings),
                display or Xvfb(),
                converter_version=lambda: _converter_version(settings, versions),
                local_clock=local_clock,
                clock=clock,
                sysfs=sysfs,
            )
            app.state.services = services
            try:
                yield
            finally:
                # The waiting requests answer now, while the database is still open.
                services.waits.close()
                if not await services.waits.drained(WAIT_DRAIN_SECONDS):
                    log.warning("stopping with %d waiting request(s)", services.waits.watching())
                await asyncio.to_thread(services.close)
        finally:
            server_log.removeHandler(ring)

    app = FastAPI(title=NAME, version=__version__, redoc_url=None, lifespan=lifespan)
    app.state.settings = settings
    app.state.converter_versions = versions
    app.state.log_ring = ring
    app.add_exception_handler(ApiError, _api_error)
    app.add_exception_handler(RequestValidationError, _validation_error)
    app.add_api_route("/healthz", healthz, methods=["GET"])
    app.include_router(api)
    # Registered last: it catches every GET path that nothing above matched.
    app.add_api_route("/{path:path}", dashboard, methods=["GET"], include_in_schema=False)
    return app
