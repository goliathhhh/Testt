"""GeckoTerminal: the discovery firehose of newly created pools (free, no key).

Used instead of Dexscreener for discovery because it reports *unique* buyers
and sellers, which is what separates organic flow from a bot washing volume
between two wallets.
"""

from __future__ import annotations

from typing import Any

from ..config import Config
from ..http import get_json
from ..models import Pair

API = "https://api.geckoterminal.com/api/v2"
HEADERS = {"Accept": "application/json;version=20230302"}


def _num(value: Any) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _int(value: Any) -> int | None:
    n = _num(value)
    return None if n is None else int(n)


def _parse_created_at(value: Any) -> int | None:
    """``pool_created_at`` is ISO-8601, usually with a trailing ``Z``."""
    if not isinstance(value, str) or not value:
        return None
    from datetime import datetime

    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return int(dt.timestamp() * 1000)


def _token_address(pool: dict[str, Any], network: str) -> str | None:
    """Relationship ids look like ``solana_<mint>`` / ``eth_0xabc...``."""
    rel = ((pool.get("relationships") or {}).get("base_token") or {}).get("data") or {}
    ident = rel.get("id")
    if not isinstance(ident, str) or "_" not in ident:
        return None
    return ident.split("_", 1)[1] or None


def parse_new_pools(payload: dict[str, Any] | None, network: str) -> list[Pair]:
    if not isinstance(payload, dict):
        return []
    items = payload.get("data")
    if not isinstance(items, list):
        return []

    out: list[Pair] = []
    for pool in items:
        if not isinstance(pool, dict):
            continue
        attrs = pool.get("attributes") or {}
        token = _token_address(pool, network)
        if not token:
            continue
        vol = attrs.get("volume_usd") or {}
        tx = attrs.get("transactions") or {}
        tx24 = tx.get("h24") or {}
        change = attrs.get("price_change_percentage") or {}

        out.append(
            Pair(
                chain=network,
                token_address=token,
                pair_address=attrs.get("address"),
                dex=(((pool.get("relationships") or {}).get("dex") or {}).get("data") or {}).get("id"),
                name=attrs.get("name"),
                price_usd=_num(attrs.get("base_token_price_usd")),
                liquidity_usd=_num(attrs.get("reserve_in_usd")),
                fdv_usd=_num(attrs.get("fdv_usd")),
                market_cap_usd=_num(attrs.get("market_cap_usd")),
                created_at_ms=_parse_created_at(attrs.get("pool_created_at")),
                volume_h24=_num(vol.get("h24")),
                volume_h6=_num(vol.get("h6")),
                volume_h1=_num(vol.get("h1")),
                buys_h24=_int(tx24.get("buys")),
                sells_h24=_int(tx24.get("sells")),
                buyers_h24=_int(tx24.get("buyers")),
                sellers_h24=_int(tx24.get("sellers")),
                price_change_h1=_num(change.get("h1")),
                price_change_h24=_num(change.get("h24")),
            )
        )
    return out


def fetch_new_pools(network: str, cfg: Config, pages: int | None = None) -> list[Pair]:
    """Newest pools first. Pages are fetched serially -- the free tier is 30/min."""
    pages = pages if pages is not None else cfg.discovery_pages
    found: list[Pair] = []
    seen: set[str] = set()
    for page in range(1, max(1, pages) + 1):
        payload = get_json(
            f"{API}/networks/{network}/new_pools",
            {"page": page},
            timeout=cfg.request_timeout,
            retries=cfg.max_retries,
            backoff=cfg.rate_limit_sleep,
            headers=HEADERS,
        )
        batch = parse_new_pools(payload, network)
        if not batch:
            break
        for pair in batch:
            if pair.token_address in seen:
                continue
            seen.add(pair.token_address)
            found.append(pair)
    return found
