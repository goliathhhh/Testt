"""Direct Solana RPC checks -- the part no aggregator can fake for us.

Two things are worth reading from the chain itself:

1. ``mintAuthority`` / ``freezeAuthority`` on the mint account. A live mint
   authority means the supply you measured is not the supply that will exist;
   a live freeze authority means your tokens can be made unsellable.
2. Holder concentration *by owner wallet*. ``getTokenLargestAccounts`` returns
   token accounts, and one wallet can hold several. Summing raw accounts
   understates concentration; the pool's own account, counted as a whale,
   overstates it. We resolve owners and exclude known pool/burn programs.

The public endpoint is heavily rate limited -- point ``solana_rpc_url`` at a
Helius/QuickNode free key for real use.
"""

from __future__ import annotations

from typing import Any

from ..config import Config
from ..http import post_json
from ..models import HolderSlice, Security


def _rpc(url: str, method: str, params: list[Any], cfg: Config) -> Any:
    payload = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    resp = post_json(
        url,
        payload,
        timeout=cfg.request_timeout,
        retries=cfg.max_retries,
        backoff=cfg.rate_limit_sleep,
    )
    if isinstance(resp, dict) and resp.get("error"):
        raise RuntimeError(f"{method}: {resp['error']}")
    return (resp or {}).get("result")


def parse_mint_account(result: Any) -> dict[str, Any]:
    """Extract authorities/supply from a jsonParsed ``getAccountInfo`` result."""
    out: dict[str, Any] = {
        "mint_authority": None,
        "freeze_authority": None,
        "supply": None,
        "decimals": None,
        "parsed": False,
    }
    value = (result or {}).get("value") if isinstance(result, dict) else None
    if not isinstance(value, dict):
        return out
    info = (((value.get("data") or {}).get("parsed") or {}).get("info")) or {}
    if not isinstance(info, dict) or not info:
        return out
    out["parsed"] = True
    out["mint_authority"] = info.get("mintAuthority")
    out["freeze_authority"] = info.get("freezeAuthority")
    out["decimals"] = info.get("decimals")
    try:
        out["supply"] = float(info.get("supply"))
    except (TypeError, ValueError):
        out["supply"] = None
    return out


def parse_largest_accounts(result: Any) -> list[tuple[str, float]]:
    """[(token_account_address, ui_amount)] from ``getTokenLargestAccounts``."""
    value = (result or {}).get("value") if isinstance(result, dict) else None
    if not isinstance(value, list):
        return []
    out: list[tuple[str, float]] = []
    for item in value:
        if not isinstance(item, dict):
            continue
        address = item.get("address")
        amount = item.get("uiAmount")
        if amount is None:
            try:
                amount = float(item.get("amount", 0)) / (10 ** int(item.get("decimals", 0)))
            except (TypeError, ValueError, ZeroDivisionError):
                continue
        if isinstance(address, str) and isinstance(amount, (int, float)):
            out.append((address, float(amount)))
    return out


def parse_account_owners(result: Any, addresses: list[str]) -> dict[str, str]:
    """Map token account -> owner wallet from ``getMultipleAccounts``."""
    value = (result or {}).get("value") if isinstance(result, dict) else None
    if not isinstance(value, list):
        return {}
    owners: dict[str, str] = {}
    for address, node in zip(addresses, value):
        if not isinstance(node, dict):
            continue
        info = (((node.get("data") or {}).get("parsed") or {}).get("info")) or {}
        owner = info.get("owner")
        if isinstance(owner, str):
            owners[address] = owner
    return owners


def aggregate_holders(
    accounts: list[tuple[str, float]],
    owners: dict[str, str],
    supply: float | None,
    cfg: Config,
    pool_addresses: tuple[str, ...] = (),
) -> list[HolderSlice]:
    """Sum balances per owner wallet and mark pool/burn holders as excluded."""
    if not supply or supply <= 0:
        return []
    blocked = {a.lower() for a in cfg.excluded_owners} | {a.lower() for a in pool_addresses if a}

    totals: dict[str, float] = {}
    unresolved = 0.0
    for account, amount in accounts:
        owner = owners.get(account)
        if owner is None:
            # Owner unknown: keep it as its own bucket keyed by the token
            # account so the balance is never silently dropped.
            unresolved += amount
            totals[account] = totals.get(account, 0.0) + amount
            continue
        totals[owner] = totals.get(owner, 0.0) + amount

    slices: list[HolderSlice] = []
    for address, amount in totals.items():
        pct = round(amount / supply * 100.0, 6)
        excluded = address.lower() in blocked
        slices.append(
            HolderSlice(
                address=address,
                percent=pct,
                excluded=excluded,
                exclude_reason="known pool/burn address" if excluded else None,
            )
        )
    slices.sort(key=lambda h: -h.percent)
    return slices


def fetch(mint: str, cfg: Config, pool_addresses: tuple[str, ...] = ()) -> Security:
    sec = Security(sources=["solana-rpc"])
    url = cfg.solana_rpc_url
    try:
        mint_info = parse_mint_account(
            _rpc(url, "getAccountInfo", [mint, {"encoding": "jsonParsed"}], cfg)
        )
    except Exception as exc:
        sec.errors.append(f"rpc getAccountInfo: {type(exc).__name__}: {exc}")
        return sec

    if not mint_info["parsed"]:
        sec.errors.append("rpc: mint account not parseable (wrong address or non-SPL token)")
        return sec

    sec.mintable = mint_info["mint_authority"] is not None
    sec.freezable = mint_info["freeze_authority"] is not None
    supply_raw = mint_info["supply"]
    decimals = mint_info["decimals"]
    supply = None
    if supply_raw is not None and isinstance(decimals, int):
        supply = supply_raw / (10 ** decimals)

    try:
        accounts = parse_largest_accounts(_rpc(url, "getTokenLargestAccounts", [mint], cfg))
    except Exception as exc:
        sec.errors.append(f"rpc getTokenLargestAccounts: {type(exc).__name__}: {exc}")
        return sec

    owners: dict[str, str] = {}
    if accounts:
        addresses = [a for a, _ in accounts]
        try:
            owners = parse_account_owners(
                _rpc(url, "getMultipleAccounts", [addresses, {"encoding": "jsonParsed"}], cfg),
                addresses,
            )
        except Exception as exc:
            sec.errors.append(f"rpc getMultipleAccounts: {type(exc).__name__}: {exc}")

    sec.top_holders = aggregate_holders(accounts, owners, supply, cfg, pool_addresses)
    if not sec.top_holders and supply:
        sec.errors.append("rpc: no token accounts returned")
    return sec
