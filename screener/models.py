"""Data model shared by every source and rule.

Design rule that everything else follows: a field that could not be fetched is
``None``, and a check that could not be evaluated is ``UNKNOWN``. Missing data
never silently becomes a pass.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Any


class Status(str, Enum):
    """Outcome of a single check."""

    OK = "OK"
    WARN = "WARN"
    FAIL = "FAIL"
    UNKNOWN = "UNKNOWN"


class Verdict(str, Enum):
    """Outcome for the token as a whole.

    ``WATCHLIST`` is the best a token can score. It means "survived the
    mechanical filters", not "worth buying" -- the screener has no opinion on
    the second question.
    """

    REJECT = "REJECT"
    CAUTION = "CAUTION"
    WATCHLIST = "WATCHLIST"


@dataclass
class Check:
    key: str
    title: str
    status: Status
    detail: str
    value: Any = None
    critical: bool = False

    @property
    def blocking(self) -> bool:
        return self.status is Status.FAIL

    @property
    def blind(self) -> bool:
        """A critical check we could not evaluate -- as bad as a soft failure."""
        return self.critical and self.status is Status.UNKNOWN


@dataclass
class Pair:
    """A DEX pair as reported by a market-data source."""

    chain: str
    token_address: str
    pair_address: str | None = None
    dex: str | None = None
    symbol: str | None = None
    name: str | None = None
    quote_symbol: str | None = None
    price_usd: float | None = None
    liquidity_usd: float | None = None
    fdv_usd: float | None = None
    market_cap_usd: float | None = None
    created_at_ms: int | None = None
    volume_h24: float | None = None
    volume_h6: float | None = None
    volume_h1: float | None = None
    buys_h24: int | None = None
    sells_h24: int | None = None
    buyers_h24: int | None = None
    sellers_h24: int | None = None
    price_change_h1: float | None = None
    price_change_h24: float | None = None
    url: str | None = None

    @property
    def age_minutes(self) -> float | None:
        if self.created_at_ms is None:
            return None
        return max(0.0, (time.time() * 1000 - self.created_at_ms) / 60_000)


@dataclass
class HolderSlice:
    """One holder's share of supply, already aggregated per owner wallet."""

    address: str
    percent: float
    tag: str | None = None
    excluded: bool = False
    exclude_reason: str | None = None


@dataclass
class Security:
    """Contract- and authority-level facts, merged from every source.

    Tri-state booleans: ``True``/``False`` are answers, ``None`` means the
    source did not tell us.
    """

    mintable: bool | None = None
    freezable: bool | None = None
    honeypot: bool | None = None
    buy_tax_pct: float | None = None
    sell_tax_pct: float | None = None
    transfer_fee_pct: float | None = None
    open_source: bool | None = None
    ownership_renounced: bool | None = None
    can_take_back_ownership: bool | None = None
    hidden_owner: bool | None = None
    metadata_mutable: bool | None = None
    transfer_hook: bool | None = None
    lp_locked_or_burned_pct: float | None = None
    holder_count: int | None = None
    top_holders: list[HolderSlice] = field(default_factory=list)
    sources: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    def top_n_percent(self, n: int) -> float | None:
        """Combined share of the ``n`` largest *counted* holders."""
        counted = [h for h in self.top_holders if not h.excluded]
        if not counted:
            return None
        return round(sum(h.percent for h in sorted(counted, key=lambda h: -h.percent)[:n]), 4)

    def largest_holder_percent(self) -> float | None:
        counted = [h for h in self.top_holders if not h.excluded]
        if not counted:
            return None
        return round(max(h.percent for h in counted), 4)


@dataclass
class Snapshot:
    """Everything known about one token at one point in time."""

    chain: str
    token_address: str
    pair: Pair | None = None
    security: Security = field(default_factory=Security)
    fetched_at: float = field(default_factory=time.time)
    errors: list[str] = field(default_factory=list)

    @property
    def label(self) -> str:
        sym = self.pair.symbol if self.pair and self.pair.symbol else "?"
        return f"{sym} ({self.chain}:{self.token_address[:8]}…)"


@dataclass
class Result:
    snapshot: Snapshot
    checks: list[Check]
    verdict: Verdict
    score: int
    reasons: list[str]

    def failed(self) -> list[Check]:
        return [c for c in self.checks if c.status is Status.FAIL]

    def blind_spots(self) -> list[Check]:
        return [c for c in self.checks if c.blind]
