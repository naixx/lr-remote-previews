"""Start the server: ``python -m lrrp``."""

import sys

import uvicorn

from lrrp.app import create_app
from lrrp.settings import Settings, SettingsError


def main() -> None:
    try:
        settings = Settings.from_env()
    except SettingsError as exc:
        sys.exit(f"lrrp: configuration error: {exc}")
    if settings.token is None:
        print(
            "lrrp: LRRP_TOKEN is not set; the API is open to anyone who can reach the port.",
            file=sys.stderr,
        )
    uvicorn.run(create_app(settings), host=settings.host, port=settings.port)


if __name__ == "__main__":
    main()
