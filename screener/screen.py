"""Pipeline: discover candidates, enrich them, run the rules.

Cheap filters run on the discovery payload first so we do not spend rate limit
on pools that a single number already disqualifies.
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from typing import Callable, Iterable

from .config import Config
from .models import Pair, Result, Security, Snapshot
from .rules import evaluate, merge_security
from .sources import dexscreener, geckoterminal, goplus, solana_rpc


def prefilter(pairs: Iterable[Pair], cfg: Config) -> list[Pair]:
    """Drop candidates on discovery-payload data alone.

    Only rejects on facts that are present; a missing field never removes a
    candidate here, it is left for the full rule pass to flag as UNKNOWN.
    """
    kept: list[Pair] = []
    for pair in pairs:
        if pair.liquidity_usd is not None and pair.liquidity_usd < cfg.min_liquidity_usd:
            continue
        age = pair.age_minutes
        if age is not None and (age < cfg.min_pair_age_minutes or age > cfg.max_pair_age_hours * 60):
            continue
        if pair.volume_h24 is not None and pair.volume_h24 < cfg.min_volume_h24_usd:
            continue
        kept.append(pair)
    return kept


def discover(cfg: Config, log: Callable[[str], None] = lambda _m: None) -> list[Pair]:
    candidates: list[Pair] = []
    for network in cfg.networks:
        try:
            pools = geckoterminal.fetch_new_pools(network, cfg)
        except Exception as exc:
            log(f"  ! discovery failed for {network}: {type(exc).__name__}: {exc}")
            continue
        kept = prefilter(pools, cfg)
        log(f"  {network}: {len(pools)} new pools -> {len(kept)} past the cheap filters")
        candidates.extend(kept)
    candidates.sort(key=lambda p: p.liquidity_usd or 0.0, reverse=True)
    return candidates[: cfg.max_candidates]


def build_snapshot(chain: str, token_address: str, cfg: Config, seed: Pair | None = None) -> Snapshot:
    """Fetch every source for one token and fold them into a Snapshot."""
    snap = Snapshot(chain=chain, token_address=token_address)

    pair = seed
    try:
        pairs = dexscreener.fetch(token_address, cfg)
        primary = dexscreener.pick_primary([p for p in pairs if not chain or p.chain == chain] or pairs)
        if primary is not None:
            pair = primary
    except Exception as exc:
        snap.errors.append(f"dexscreener: {type(exc).__name__}: {exc}")
    snap.pair = pair

    pool_addresses = tuple(a for a in [(pair.pair_address if pair else None)] if a)

    parts: list[Security] = []
    # On-chain first: its holder aggregation is by owner wallet and wins the
    # merge over any aggregator's account-level view.
    if chain == "solana":
        parts.append(solana_rpc.fetch(token_address, cfg, pool_addresses))
    parts.append(goplus.fetch(chain, token_address, cfg))

    snap.security = merge_security(*parts)
    return snap


def screen_token(chain: str, token_address: str, cfg: Config, seed: Pair | None = None) -> Result:
    return evaluate(build_snapshot(chain, token_address, cfg, seed), cfg)


def run(cfg: Config, log: Callable[[str], None] = lambda _m: None) -> list[Result]:
    log("Discovering new pools…")
    candidates = discover(cfg, log)
    if not candidates:
        log("No candidates survived discovery.")
        return []

    log(f"Screening {len(candidates)} candidates…")

    def work(pair: Pair) -> Result | None:
        try:
            return screen_token(pair.chain, pair.token_address, cfg, seed=pair)
        except Exception as exc:
            log(f"  ! {pair.token_address[:10]}…: {type(exc).__name__}: {exc}")
            return None

    with ThreadPoolExecutor(max_workers=max(1, cfg.workers)) as pool:
        results = [r for r in pool.map(work, candidates) if r is not None]

    results.sort(key=lambda r: (r.verdict.value, -r.score))
    return results
