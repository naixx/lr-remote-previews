"""Start the server: ``python -m lrrp``."""

import logging
import sys

import uvicorn

from lrrp.app import create_app
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
    logging.getLogger("lrrp").info(
        "%d converter process(es) side by side, batches of up to %d files",
        settings.workers,
        settings.batch_size,
    )
    uvicorn.run(create_app(settings), host=settings.host, port=settings.port)


if __name__ == "__main__":
    main()
