"""Thresholds for the screener.

None of these numbers are backtested. They are deliberately strict starting
points chosen so the screener errs toward rejecting; loosen them only against
your own recorded outcomes, not against a token you already want to buy.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, fields
from pathlib import Path

# Accounts that hold supply on behalf of a pool, a burn, or a lock -- counting
# them as "whales" is the most common way a holder-concentration check lies.
DEFAULT_EXCLUDED_OWNERS: tuple[str, ...] = (
    # Solana burn / incinerator
    "1nc1nerator11111111111111111111111111111111",
    "11111111111111111111111111111111",
    # Raydium
    "5Q544fKrFoe6tsEbD7S8EmxGTJYAKtTVhAW5Q5pge4j1",  # AMM v4 authority
    "GThUX1Atko4tqhN2NaiTazWSeFWMuiUvfFnyJyUghFMJ",  # staking/authority
    "7YttLkHDoNj9wyDur5pM1ejNaAvT9X4eqaYcHQqtj2G5",  # CPMM authority
    # Orca / Whirlpool
    "9W959DqEETiGZocYWCQPaJ6sBmUzgfxXfqGeTEdp3aQP",
    # Meteora
    "24Uqj9JCLxUeoC3hGfh5W3s9FM9uCHDS2SG3LYwBpyTi",
    # pump.fun bonding curve + AMM
    "6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P",
    "pAMMBay6oceH9fJKBRHGP5D4bD4sWpmSwMn52FMfXEA",
)

# GoPlus chain ids for the EVM chains the screener understands.
EVM_CHAIN_IDS: dict[str, str] = {
    "ethereum": "1",
    "bsc": "56",
    "polygon": "137",
    "arbitrum": "42161",
    "optimism": "10",
    "avalanche": "43114",
    "base": "8453",
    "fantom": "250",
    "cronos": "25",
    "linea": "59144",
    "scroll": "534352",
    "zksync": "324",
}


@dataclass
class Config:
    # --- liquidity and size -------------------------------------------------
    min_liquidity_usd: float = 15_000.0
    min_volume_h24_usd: float = 25_000.0
    max_fdv_to_liquidity: float = 60.0

    # --- age ----------------------------------------------------------------
    # Below min_age the numbers are noise; above max_age it is not a new launch
    # and this tool's assumptions stop applying.
    min_pair_age_minutes: float = 30.0
    max_pair_age_hours: float = 72.0

    # --- distribution -------------------------------------------------------
    max_top10_percent: float = 25.0
    max_single_holder_percent: float = 8.0
    min_holder_count: int = 150

    # --- contract / authority ----------------------------------------------
    max_buy_tax_percent: float = 5.0
    max_sell_tax_percent: float = 5.0
    min_lp_locked_percent: float = 90.0

    # --- trade-flow sanity --------------------------------------------------
    max_volume_to_liquidity: float = 40.0
    min_unique_buyers_h24: int = 100
    max_buyer_seller_skew: float = 4.0

    # --- discovery ----------------------------------------------------------
    networks: tuple[str, ...] = ("solana",)
    discovery_pages: int = 2
    max_candidates: int = 60

    # --- plumbing -----------------------------------------------------------
    request_timeout: float = 15.0
    max_retries: int = 3
    rate_limit_sleep: float = 2.1
    workers: int = 4
    solana_rpc_url: str = "https://api.mainnet-beta.solana.com"
    excluded_owners: tuple[str, ...] = DEFAULT_EXCLUDED_OWNERS

    @classmethod
    def load(cls, path: str | Path | None) -> "Config":
        """Build a config, overriding defaults with a JSON file if given."""
        cfg = cls()
        if not path:
            return cfg
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
        known = {f.name: f for f in fields(cls)}
        unknown = sorted(set(raw) - set(known))
        if unknown:
            raise ValueError(f"unknown config keys: {', '.join(unknown)}")
        for key, value in raw.items():
            if key in ("networks", "excluded_owners"):
                value = tuple(value)
            setattr(cfg, key, value)
        return cfg

    def to_dict(self) -> dict:
        d = asdict(self)
        d["networks"] = list(self.networks)
        d["excluded_owners"] = list(self.excluded_owners)
        return d
