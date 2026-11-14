"""Start the server: ``python -m lrrp``."""

import logging
import sys

import uvicorn

from lrrp.app import create_app
from lrrp.logring import Redactor
from lrrp.settings import Settings, SettingsError


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
    uvicorn.run(create_app(settings), host=settings.host, port=settings.port)


if __name__ == "__main__":
    main()
