"""Dexscreener: market data for a token's pairs (free, no API key).

Only the parsing is interesting -- ``parse_pairs`` is total: any field the API
omits or returns as a string stays ``None`` rather than raising.
"""

from __future__ import annotations

from typing import Any

from ..config import Config
from ..http import get_json
from ..models import Pair

API = "https://api.dexscreener.com/latest/dex/tokens/"

# Quote assets we treat as real liquidity. A pair quoted in another memecoin is
# not priced against anything, so we prefer a major-quoted pair when choosing.
MAJOR_QUOTES = {"SOL", "WSOL", "USDC", "USDT", "WETH", "ETH", "WBNB", "BNB", "WAVAX", "DAI"}


def _num(value: Any) -> float | None:
    """Coerce to float; the API mixes numbers and numeric strings."""
    if value is None or isinstance(value, bool):
        return None
    try:
        out = float(value)
    except (TypeError, ValueError):
        return None
    return out if out == out and out not in (float("inf"), float("-inf")) else None


def _int(value: Any) -> int | None:
    n = _num(value)
    return None if n is None else int(n)


def parse_pairs(payload: dict[str, Any] | None) -> list[Pair]:
    if not isinstance(payload, dict):
        return []
    raw_pairs = payload.get("pairs")
    if not isinstance(raw_pairs, list):
        return []

    out: list[Pair] = []
    for item in raw_pairs:
        if not isinstance(item, dict):
            continue
        base = item.get("baseToken") or {}
        quote = item.get("quoteToken") or {}
        address = base.get("address")
        if not isinstance(address, str) or not address:
            continue
        liq = item.get("liquidity") or {}
        vol = item.get("volume") or {}
        txns = item.get("txns") or {}
        h24 = txns.get("h24") or {}
        change = item.get("priceChange") or {}

        out.append(
            Pair(
                chain=str(item.get("chainId") or "").lower(),
                token_address=address,
                pair_address=item.get("pairAddress"),
                dex=item.get("dexId"),
                symbol=base.get("symbol"),
                name=base.get("name"),
                quote_symbol=(quote.get("symbol") or None),
                price_usd=_num(item.get("priceUsd")),
                liquidity_usd=_num(liq.get("usd")),
                fdv_usd=_num(item.get("fdv")),
                market_cap_usd=_num(item.get("marketCap")),
                created_at_ms=_int(item.get("pairCreatedAt")),
                volume_h24=_num(vol.get("h24")),
                volume_h6=_num(vol.get("h6")),
                volume_h1=_num(vol.get("h1")),
                buys_h24=_int(h24.get("buys")),
                sells_h24=_int(h24.get("sells")),
                price_change_h1=_num(change.get("h1")),
                price_change_h24=_num(change.get("h24")),
                url=item.get("url"),
            )
        )
    return out


def pick_primary(pairs: list[Pair]) -> Pair | None:
    """Choose the pair that actually carries the token's liquidity.

    Deepest pool wins, but a pool quoted in a major asset outranks a deeper one
    quoted in some other memecoin -- the latter's "liquidity" is circular.
    """
    if not pairs:
        return None

    def key(p: Pair) -> tuple[int, float]:
        major = 1 if (p.quote_symbol or "").upper() in MAJOR_QUOTES else 0
        return (major, p.liquidity_usd or 0.0)

    return max(pairs, key=key)


def fetch(token_address: str, cfg: Config) -> list[Pair]:
    payload = get_json(
        API + token_address,
        timeout=cfg.request_timeout,
        retries=cfg.max_retries,
        backoff=cfg.rate_limit_sleep,
    )
    return parse_pairs(payload)
