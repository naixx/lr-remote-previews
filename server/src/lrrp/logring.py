"""The server's recent log records in memory, for the dashboard (``GET /api/v1/log``).

``LogRing`` is a logging handler on the ``lrrp`` logger, so it gets the server's own records and
not the HTTP server's request lines (uvicorn logs those under ``uvicorn.access``). It keeps the
last ``LOG_CAPACITY`` records.

The access token must never reach a log line. Nothing in the server logs it, the settings do not
show it in their ``repr``, and as a last guard ``Redactor`` replaces it in every record that
passes the handlers it is attached to (this ring, and the console handler in ``__main__``).
"""

import logging
import threading
import traceback
from collections import deque
from dataclasses import dataclass

LOG_CAPACITY = 1000
REDACTED = "[token]"


@dataclass(frozen=True)
class LogLine:
    time: float
    """Seconds since the epoch."""
    level: str
    logger: str
    message: str


class Redactor(logging.Filter):
    """Replaces a secret wherever it appears in a record's message. Lets every record pass."""

    def __init__(self, secret: str | None) -> None:
        super().__init__()
        self._secret = secret or None

    def redact(self, text: str) -> str:
        if self._secret is None:
            return text
        return text.replace(self._secret, REDACTED)

    def filter(self, record: logging.LogRecord) -> bool:
        if self._secret is None:
            return True
        message = record.getMessage()
        if self._secret in message:
            record.msg = self.redact(message)
            record.args = None
        if record.exc_text and self._secret in record.exc_text:
            record.exc_text = self.redact(record.exc_text)
        return True


class LogRing(logging.Handler):
    def __init__(self, capacity: int = LOG_CAPACITY, secret: str | None = None) -> None:
        super().__init__(logging.NOTSET)
        self._redactor = Redactor(secret)
        self.addFilter(self._redactor)
        self._lines: deque[LogLine] = deque(maxlen=capacity)
        self._lines_lock = threading.Lock()

    def emit(self, record: logging.LogRecord) -> None:
        try:
            message = record.getMessage()
            if record.exc_info and record.exc_info[1] is not None:
                summary = traceback.format_exception_only(record.exc_info[1])[-1].strip()
                message = f"{message} ({summary})"
            line = LogLine(
                time=record.created,
                level=record.levelname,
                logger=record.name,
                message=self._redactor.redact(message),
            )
            with self._lines_lock:
                self._lines.append(line)
        except Exception:
            self.handleError(record)

    def lines(self, limit: int) -> list[LogLine]:
        """The newest ``limit`` lines, oldest first."""
        with self._lines_lock:
            kept = list(self._lines)
        return kept[-limit:] if limit > 0 else []
