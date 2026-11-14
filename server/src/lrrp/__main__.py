"""Start the server: ``python -m lrrp``."""

import contextlib
import logging
import sys
from typing import Any

import uvicorn
from fastapi import FastAPI
from uvicorn.main import STARTUP_FAILURE

from lrrp.app import create_app, end_waits
from lrrp.logring import Redactor
from lrrp.settings import Settings, SettingsError


class Server(uvicorn.Server):
    """uvicorn's server, which first ends the requests that wait for a change (``wait`` of
    ``GET /api/v1/jobs/{id}/items``) when it begins to stop: they answer at once, as when their
    time is up. uvicorn itself lets every open request finish before it stops and tells the
    application only after that, so a stop could otherwise take up to ``maxWaitSeconds``, longer
    than a container runtime waits before it kills the process."""

    def __init__(self, config: uvicorn.Config, app: FastAPI) -> None:
        super().__init__(config)
        self._app = app

    async def shutdown(self, *args: Any, **kwargs: Any) -> None:
        end_waits(self._app)
        await super().shutdown(*args, **kwargs)


def main() -> None:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s"
    )
    try:
        settings = Settings.from_env()
    except SettingsError as exc:
        sys.exit(f"lrrp: configuration error: {exc}")
    if settings.token is None:
        print(
            "lrrp: LRRP_TOKEN is not set; the API is open to anyone who can reach the port.",
            file=sys.stderr,
        )
    # The token never appears in a log line; this guards the console as LogRing guards the API.
    for handler in logging.getLogger().handlers:
        handler.addFilter(Redactor(settings.token))
    app = create_app(settings)
    # What uvicorn.run does for one process, with the server above.
    server = Server(uvicorn.Config(app, host=settings.host, port=settings.port), app)
    with contextlib.suppress(KeyboardInterrupt):
        server.run()
    if not server.started:
        sys.exit(STARTUP_FAILURE)


if __name__ == "__main__":
    main()
