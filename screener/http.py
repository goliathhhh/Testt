"""Tiny stdlib HTTP client.

Deliberately dependency-free so the screener runs on a clean Python 3.10+ with
no ``pip install`` step. Retries only on transport errors and 429/5xx; a 4xx
other than 429 is an answer, not a glitch.
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

USER_AGENT = "memescreener/0.1 (+local research tool)"


class HttpError(RuntimeError):
    def __init__(self, message: str, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


def _sleep_backoff(attempt: int, base: float) -> None:
    time.sleep(base * (2 ** attempt))


def get_json(
    url: str,
    params: dict[str, Any] | None = None,
    *,
    timeout: float = 15.0,
    retries: int = 3,
    backoff: float = 1.0,
    headers: dict[str, str] | None = None,
) -> Any:
    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"
    return _request(url, None, timeout, retries, backoff, headers)


def post_json(
    url: str,
    payload: Any,
    *,
    timeout: float = 15.0,
    retries: int = 3,
    backoff: float = 1.0,
    headers: dict[str, str] | None = None,
) -> Any:
    body = json.dumps(payload).encode("utf-8")
    merged = {"Content-Type": "application/json", **(headers or {})}
    return _request(url, body, timeout, retries, backoff, merged)


def _request(
    url: str,
    body: bytes | None,
    timeout: float,
    retries: int,
    backoff: float,
    headers: dict[str, str] | None,
) -> Any:
    hdrs = {"Accept": "application/json", "User-Agent": USER_AGENT, **(headers or {})}
    last: Exception | None = None
    for attempt in range(retries):
        req = urllib.request.Request(url, data=body, headers=hdrs)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            # 429 and 5xx are worth another attempt; everything else is final.
            if exc.code == 429 or 500 <= exc.code < 600:
                last = HttpError(f"HTTP {exc.code} from {url}", exc.code)
                if attempt < retries - 1:
                    _sleep_backoff(attempt, backoff)
                    continue
            raise HttpError(f"HTTP {exc.code} from {url}", exc.code) from exc
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as exc:
            last = HttpError(f"{type(exc).__name__} for {url}: {exc}")
            if attempt < retries - 1:
                _sleep_backoff(attempt, backoff)
                continue
    raise last if last else HttpError(f"request to {url} failed")
