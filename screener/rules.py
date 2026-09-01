"""The rule set and the verdict.

Two principles the rest of the file follows:

* A rule can only ever disqualify. There is no rule that says "buy" -- the best
  possible outcome is ``WATCHLIST``, meaning nothing mechanical disqualified it.
* A *critical* rule that could not be evaluated (``UNKNOWN``) caps the verdict
  at ``CAUTION``. Not knowing whether the mint authority is live is not the same
  as knowing it is dead, and a screener that conflates the two is worse than no
  screener, because it manufactures confidence.
"""

from __future__ import annotations

from .config import Config
from .models import Check, Result, Security, Snapshot, Status, Verdict

WARN_PENALTY = 8
BLIND_PENALTY = 12
CAUTION_SCORE = 70


def merge_security(*parts: Security) -> Security:
    """Merge per-source security facts, preferring the more pessimistic answer.

    Order matters only for holder data: the first source that supplies holders
    wins, so callers should pass the owner-aggregated on-chain source first.
    """
    out = Security()
    for part in parts:
        if part is None:
            continue
        out.sources.extend(part.sources)
        out.errors.extend(part.errors)
        for flag in (
            "mintable",
            "freezable",
            "honeypot",
            "can_take_back_ownership",
            "hidden_owner",
            "metadata_mutable",
            "transfer_hook",
        ):
            value = getattr(part, flag)
            if value is None:
                continue
            current = getattr(out, flag)
            # True (the dangerous answer) always wins a disagreement.
            setattr(out, flag, value if current is None else (current or value))
        for flag in ("open_source", "ownership_renounced"):
            value = getattr(part, flag)
            if value is None:
                continue
            current = getattr(out, flag)
            # False (the dangerous answer) always wins here.
            setattr(out, flag, value if current is None else (current and value))
        for num in ("buy_tax_pct", "sell_tax_pct", "transfer_fee_pct"):
            value = getattr(part, num)
            if value is None:
                continue
            current = getattr(out, num)
            setattr(out, num, value if current is None else max(current, value))
        if part.lp_locked_or_burned_pct is not None:
            cur = out.lp_locked_or_burned_pct
            out.lp_locked_or_burned_pct = (
                part.lp_locked_or_burned_pct if cur is None else min(cur, part.lp_locked_or_burned_pct)
            )
        if part.holder_count is not None:
            cur = out.holder_count
            out.holder_count = part.holder_count if cur is None else min(cur, part.holder_count)
        if part.top_holders and not out.top_holders:
            out.top_holders = list(part.top_holders)
    return out


def _check(key, title, status, detail, value=None, critical=False) -> Check:
    return Check(key=key, title=title, status=status, detail=detail, value=value, critical=critical)


def _unknown(key, title, why, critical=False) -> Check:
    return _check(key, title, Status.UNKNOWN, why, None, critical)


# --------------------------------------------------------------------------
# Contract / authority rules (critical)
# --------------------------------------------------------------------------

def rule_mint_authority(snap: Snapshot, cfg: Config) -> Check:
    key, title = "mint_authority", "Mint authority renounced"
    value = snap.security.mintable
    if value is None:
        return _unknown(key, title, "no source reported the mint authority", critical=True)
    if value:
        return _check(key, title, Status.FAIL, "mint authority is live — supply can be inflated at will", True, True)
    return _check(key, title, Status.OK, "mint authority renounced", False, True)


def rule_freeze_authority(snap: Snapshot, cfg: Config) -> Check | None:
    if snap.chain != "solana":
        return None
    key, title = "freeze_authority", "Freeze authority renounced"
    value = snap.security.freezable
    if value is None:
        return _unknown(key, title, "no source reported the freeze authority", critical=True)
    if value:
        return _check(key, title, Status.FAIL, "freeze authority is live — your tokens can be frozen and made unsellable", True, True)
    return _check(key, title, Status.OK, "freeze authority renounced", False, True)


def rule_honeypot(snap: Snapshot, cfg: Config) -> Check | None:
    if snap.chain == "solana":
        return None  # GoPlus reports honeypot only for EVM
    key, title = "honeypot", "Not a honeypot"
    value = snap.security.honeypot
    if value is None:
        return _unknown(key, title, "honeypot simulation unavailable", critical=True)
    if value:
        return _check(key, title, Status.FAIL, "simulated sell fails — honeypot", True, True)
    return _check(key, title, Status.OK, "sell simulation passes", False, True)


def rule_taxes(snap: Snapshot, cfg: Config) -> Check:
    key, title = "taxes", "Buy/sell tax within limit"
    buy, sell = snap.security.buy_tax_pct, snap.security.sell_tax_pct
    fee = snap.security.transfer_fee_pct
    values = [v for v in (buy, sell, fee) if v is not None]
    if not values:
        if snap.chain == "solana":
            return _unknown(key, title, "no transfer-fee data", critical=False)
        return _unknown(key, title, "no tax data", critical=True)
    worst = max(values)
    limit = max(cfg.max_buy_tax_percent, cfg.max_sell_tax_percent)
    detail = f"buy {buy}%, sell {sell}%, transfer fee {fee}%"
    if worst > limit:
        return _check(key, title, Status.FAIL, f"{detail} — above the {limit}% limit", worst, True)
    if worst > limit / 2:
        return _check(key, title, Status.WARN, detail, worst, True)
    return _check(key, title, Status.OK, detail, worst, True)


def rule_lp_locked(snap: Snapshot, cfg: Config) -> Check:
    key, title = "lp_locked", "LP burned or locked"
    value = snap.security.lp_locked_or_burned_pct
    if value is None:
        return _unknown(key, title, "LP holder data unavailable — cannot tell whether liquidity can be pulled", critical=True)
    if value < cfg.min_lp_locked_percent:
        return _check(key, title, Status.FAIL, f"only {value}% of LP is burned/locked (need {cfg.min_lp_locked_percent}%) — liquidity can be pulled", value, True)
    return _check(key, title, Status.OK, f"{value}% of LP burned/locked", value, True)


def rule_evm_ownership(snap: Snapshot, cfg: Config) -> Check | None:
    if snap.chain == "solana":
        return None
    key, title = "ownership", "Owner cannot reclaim control"
    sec = snap.security
    if sec.can_take_back_ownership:
        return _check(key, title, Status.FAIL, "contract can reclaim ownership after renouncing", True, True)
    if sec.hidden_owner:
        return _check(key, title, Status.FAIL, "hidden owner detected", True, True)
    if sec.open_source is False:
        return _check(key, title, Status.FAIL, "contract source is not verified — nothing here can be audited", False, True)
    if sec.ownership_renounced is None and sec.open_source is None:
        return _unknown(key, title, "no ownership data", critical=True)
    if sec.ownership_renounced is False:
        return _check(key, title, Status.WARN, "ownership not renounced", False, True)
    return _check(key, title, Status.OK, "ownership renounced, source verified", True, True)


def rule_solana_extensions(snap: Snapshot, cfg: Config) -> Check | None:
    if snap.chain != "solana":
        return None
    key, title = "token_extensions", "No hostile token extensions"
    sec = snap.security
    problems = []
    if sec.transfer_hook:
        problems.append("transfer hook (arbitrary code on every transfer)")
    if sec.metadata_mutable:
        problems.append("metadata still mutable (name/logo can be swapped)")
    if not problems:
        return _check(key, title, Status.OK, "no transfer hook, metadata immutable", None)
    status = Status.FAIL if sec.transfer_hook else Status.WARN
    return _check(key, title, status, "; ".join(problems), None)


# --------------------------------------------------------------------------
# Distribution rules (critical)
# --------------------------------------------------------------------------

def rule_top10(snap: Snapshot, cfg: Config) -> Check:
    key, title = "top10_concentration", "Top-10 holders below limit"
    value = snap.security.top_n_percent(10)
    if value is None:
        return _unknown(key, title, "holder distribution unavailable", critical=True)
    excluded = [h for h in snap.security.top_holders if h.excluded]
    note = f" ({len(excluded)} pool/burn account(s) excluded)" if excluded else ""
    if value > cfg.max_top10_percent:
        return _check(key, title, Status.FAIL, f"top 10 wallets hold {value}% (limit {cfg.max_top10_percent}%){note}", value, True)
    if value > cfg.max_top10_percent * 0.8:
        return _check(key, title, Status.WARN, f"top 10 wallets hold {value}%{note}", value, True)
    return _check(key, title, Status.OK, f"top 10 wallets hold {value}%{note}", value, True)


def rule_single_holder(snap: Snapshot, cfg: Config) -> Check:
    key, title = "single_holder", "No single dominant wallet"
    value = snap.security.largest_holder_percent()
    if value is None:
        return _unknown(key, title, "holder distribution unavailable", critical=True)
    if value > cfg.max_single_holder_percent:
        return _check(key, title, Status.FAIL, f"largest wallet holds {value}% (limit {cfg.max_single_holder_percent}%)", value, True)
    return _check(key, title, Status.OK, f"largest wallet holds {value}%", value, True)


def rule_holder_count(snap: Snapshot, cfg: Config) -> Check:
    key, title = "holder_count", "Enough holders"
    value = snap.security.holder_count
    if value is None:
        return _unknown(key, title, "holder count unavailable")
    if value < cfg.min_holder_count:
        return _check(key, title, Status.FAIL, f"{value} holders (need {cfg.min_holder_count})", value)
    return _check(key, title, Status.OK, f"{value} holders", value)


# --------------------------------------------------------------------------
# Market rules
# --------------------------------------------------------------------------

def rule_liquidity(snap: Snapshot, cfg: Config) -> Check:
    key, title = "liquidity", "Liquidity above floor"
    pair = snap.pair
    value = pair.liquidity_usd if pair else None
    if value is None:
        return _unknown(key, title, "no liquidity data", critical=True)
    if value < cfg.min_liquidity_usd:
        return _check(key, title, Status.FAIL, f"${value:,.0f} liquidity (floor ${cfg.min_liquidity_usd:,.0f}) — your own exit would move the price", value, True)
    return _check(key, title, Status.OK, f"${value:,.0f} liquidity", value, True)


def rule_age(snap: Snapshot, cfg: Config) -> Check:
    key, title = "pair_age", "Pair age in window"
    age = snap.pair.age_minutes if snap.pair else None
    if age is None:
        return _unknown(key, title, "pair creation time unknown")
    hours = age / 60
    if age < cfg.min_pair_age_minutes:
        return _check(key, title, Status.FAIL, f"{age:.0f} min old — too new for any metric here to mean anything", age)
    if hours > cfg.max_pair_age_hours:
        return _check(key, title, Status.WARN, f"{hours:.1f} h old — outside the new-launch window this tool is tuned for", age)
    return _check(key, title, Status.OK, f"{hours:.1f} h old", age)


def rule_volume(snap: Snapshot, cfg: Config) -> Check:
    key, title = "volume", "24h volume above floor"
    value = snap.pair.volume_h24 if snap.pair else None
    if value is None:
        return _unknown(key, title, "no volume data")
    if value < cfg.min_volume_h24_usd:
        return _check(key, title, Status.FAIL, f"${value:,.0f} 24h volume (floor ${cfg.min_volume_h24_usd:,.0f})", value)
    return _check(key, title, Status.OK, f"${value:,.0f} 24h volume", value)


def rule_wash_trading(snap: Snapshot, cfg: Config) -> Check:
    """Volume far above liquidity, with few unique traders, is a bot loop."""
    key, title = "wash_trading", "Volume consistent with pool depth"
    pair = snap.pair
    if not pair or not pair.liquidity_usd or pair.volume_h24 is None or pair.liquidity_usd <= 0:
        return _unknown(key, title, "volume/liquidity data incomplete")
    ratio = pair.volume_h24 / pair.liquidity_usd
    buyers = pair.buyers_h24
    detail = f"24h volume is {ratio:.1f}x pool liquidity"
    if buyers is not None:
        detail += f", {buyers} unique buyers"
    if ratio > cfg.max_volume_to_liquidity and (buyers is None or buyers < cfg.min_unique_buyers_h24):
        return _check(key, title, Status.FAIL, detail + " — churn without traders, consistent with wash trading", ratio)
    if ratio > cfg.max_volume_to_liquidity:
        return _check(key, title, Status.WARN, detail, ratio)
    return _check(key, title, Status.OK, detail, ratio)


def rule_unique_buyers(snap: Snapshot, cfg: Config) -> Check:
    key, title = "unique_buyers", "Enough unique buyers"
    pair = snap.pair
    buyers = pair.buyers_h24 if pair else None
    if buyers is None:
        return _unknown(key, title, "unique buyer counts unavailable (source does not report them)")
    if buyers < cfg.min_unique_buyers_h24:
        return _check(key, title, Status.FAIL, f"{buyers} unique buyers in 24h (need {cfg.min_unique_buyers_h24})", buyers)
    return _check(key, title, Status.OK, f"{buyers} unique buyers in 24h", buyers)


def rule_flow_balance(snap: Snapshot, cfg: Config) -> Check:
    """Extreme buy/sell asymmetry usually means one side is manufactured."""
    key, title = "flow_balance", "Buy/sell flow not manufactured"
    pair = snap.pair
    if not pair:
        return _unknown(key, title, "no trade data")
    buyers, sellers = pair.buyers_h24, pair.sellers_h24
    if buyers is None or sellers is None:
        buys, sells = pair.buys_h24, pair.sells_h24
        if buys is None or sells is None:
            return _unknown(key, title, "no trade counts")
        buyers, sellers = buys, sells
        label = "trades"
    else:
        label = "traders"
    if sellers == 0 and buyers == 0:
        return _check(key, title, Status.FAIL, "no trades at all", 0.0)
    if sellers == 0:
        return _check(key, title, Status.WARN, f"{buyers} buying {label}, zero selling — nobody has exited yet, untested", None)
    skew = buyers / sellers
    detail = f"{buyers} buying vs {sellers} selling {label} (ratio {skew:.2f})"
    if skew > cfg.max_buyer_seller_skew or skew < 1 / cfg.max_buyer_seller_skew:
        return _check(key, title, Status.WARN, detail + " — lopsided", skew)
    return _check(key, title, Status.OK, detail, skew)


def rule_fdv_ratio(snap: Snapshot, cfg: Config) -> Check:
    """A huge valuation resting on a thin pool cannot be exited at that price."""
    key, title = "fdv_to_liquidity", "Valuation supported by liquidity"
    pair = snap.pair
    if not pair or not pair.fdv_usd or not pair.liquidity_usd or pair.liquidity_usd <= 0:
        return _unknown(key, title, "FDV or liquidity unavailable")
    ratio = pair.fdv_usd / pair.liquidity_usd
    detail = f"FDV ${pair.fdv_usd:,.0f} is {ratio:.1f}x the ${pair.liquidity_usd:,.0f} pool"
    if ratio > cfg.max_fdv_to_liquidity:
        return _check(key, title, Status.FAIL, detail + " — the market cap is notional, not exitable", ratio)
    if ratio > cfg.max_fdv_to_liquidity * 0.7:
        return _check(key, title, Status.WARN, detail, ratio)
    return _check(key, title, Status.OK, detail, ratio)


RULES = (
    rule_mint_authority,
    rule_freeze_authority,
    rule_honeypot,
    rule_taxes,
    rule_lp_locked,
    rule_evm_ownership,
    rule_solana_extensions,
    rule_top10,
    rule_single_holder,
    rule_holder_count,
    rule_liquidity,
    rule_age,
    rule_volume,
    rule_wash_trading,
    rule_unique_buyers,
    rule_flow_balance,
    rule_fdv_ratio,
)


def evaluate(snap: Snapshot, cfg: Config) -> Result:
    checks: list[Check] = []
    for rule in RULES:
        check = rule(snap, cfg)
        if check is not None:
            checks.append(check)

    fails = [c for c in checks if c.status is Status.FAIL]
    warns = [c for c in checks if c.status is Status.WARN]
    blind = [c for c in checks if c.blind]

    score = max(0, 100 - WARN_PENALTY * len(warns) - BLIND_PENALTY * len(blind))
    reasons: list[str] = []

    if fails:
        verdict = Verdict.REJECT
        score = 0
        reasons = [f"{c.title}: {c.detail}" for c in fails]
    elif blind:
        verdict = Verdict.CAUTION
        reasons = [f"cannot verify — {c.title}: {c.detail}" for c in blind]
        reasons += [f"{c.title}: {c.detail}" for c in warns]
    elif score < CAUTION_SCORE:
        verdict = Verdict.CAUTION
        reasons = [f"{c.title}: {c.detail}" for c in warns]
    else:
        verdict = Verdict.WATCHLIST
        reasons = [f"{c.title}: {c.detail}" for c in warns]

    return Result(snapshot=snap, checks=checks, verdict=verdict, score=score, reasons=reasons)
