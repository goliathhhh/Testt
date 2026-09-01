"""GoPlus token security API (free tier, no key).

Two endpoints with different shapes -- EVM (``/token_security/{chain_id}``) and
Solana (``/solana/token_security``). Field names have changed across GoPlus
versions, so every read goes through ``_first``/``_flag`` helpers that try
several spellings and return ``None`` when none match. An unrecognised payload
must degrade to "unknown", never to "safe".
"""

from __future__ import annotations

from typing import Any, Iterable

from ..config import EVM_CHAIN_IDS, Config
from ..http import get_json
from ..models import HolderSlice, Security

API = "https://api.gopluslabs.io/api/v1"


def _first(data: dict[str, Any], *keys: str) -> Any:
    for key in keys:
        if key in data and data[key] not in (None, ""):
            return data[key]
    return None


def _flag(value: Any) -> bool | None:
    """GoPlus encodes booleans as "1"/"0" strings, sometimes as real bools."""
    if value is None or value == "":
        return None
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    text = str(value).strip().lower()
    if text in ("1", "true", "yes"):
        return True
    if text in ("0", "false", "no"):
        return False
    return None


def _pct(value: Any) -> float | None:
    """Taxes/percentages arrive either as 0..1 fractions or as 0..100 strings."""
    if value is None or value == "":
        return None
    try:
        num = float(value)
    except (TypeError, ValueError):
        return None
    if num != num:
        return None
    return round(num * 100.0, 4) if 0.0 <= num <= 1.0 else round(num, 4)


def _ratio_to_pct(value: Any) -> float | None:
    """Holder ``percent`` fields are fractions of supply (0..1)."""
    if value is None or value == "":
        return None
    try:
        num = float(value)
    except (TypeError, ValueError):
        return None
    if num != num:
        return None
    return round(num * 100.0, 6) if num <= 1.0 else round(num, 6)


def _holders(raw: Any, excluded: Iterable[str]) -> list[HolderSlice]:
    if not isinstance(raw, list):
        return []
    blocked = {a.lower() for a in excluded}
    out: list[HolderSlice] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        address = _first(item, "address", "account", "owner_address")
        pct = _ratio_to_pct(_first(item, "percent", "percentage", "balance_percent"))
        if not isinstance(address, str) or pct is None:
            continue
        tag = _first(item, "tag", "label")
        locked = _flag(_first(item, "is_locked")) or False
        contract = _flag(_first(item, "is_contract"))
        reason = None
        if address.lower() in blocked:
            reason = "known pool/burn address"
        elif locked:
            reason = "locked"
        elif isinstance(tag, str) and any(
            word in tag.lower() for word in ("lock", "burn", "null", "pool", "amm", "vault")
        ):
            reason = f"tagged {tag}"
        out.append(
            HolderSlice(
                address=address,
                percent=pct,
                tag=tag if isinstance(tag, str) else None,
                excluded=reason is not None,
                exclude_reason=reason,
            )
        )
    return out


def _lp_locked_percent(raw: Any) -> float | None:
    """Share of LP tokens that are burned or sitting in a locker."""
    if not isinstance(raw, list) or not raw:
        return None
    total = 0.0
    seen = False
    for item in raw:
        if not isinstance(item, dict):
            continue
        pct = _ratio_to_pct(_first(item, "percent", "percentage"))
        if pct is None:
            continue
        seen = True
        address = str(_first(item, "address") or "").lower()
        tag = str(_first(item, "tag") or "").lower()
        burned = address in ("0x000000000000000000000000000000000000dead", "0x0000000000000000000000000000000000000000")
        burned = burned or "burn" in tag or "null" in tag or "dead" in tag
        if _flag(_first(item, "is_locked")) or burned:
            total += pct
    return round(total, 4) if seen else None


def parse_evm(payload: dict[str, Any] | None, address: str, cfg: Config) -> Security:
    sec = Security(sources=["goplus:evm"])
    if not isinstance(payload, dict):
        sec.errors.append("goplus: empty response")
        return sec
    if str(payload.get("code")) not in ("1", "None") and payload.get("result") is None:
        sec.errors.append(f"goplus: code={payload.get('code')} {payload.get('message')}")
        return sec
    result = payload.get("result")
    if not isinstance(result, dict) or not result:
        sec.errors.append("goplus: token not indexed")
        return sec

    # The result is keyed by the (lowercased) address; take it by key, else the
    # single entry present.
    data = result.get(address.lower()) or result.get(address)
    if data is None and len(result) == 1:
        data = next(iter(result.values()))
    if not isinstance(data, dict):
        sec.errors.append("goplus: unexpected result shape")
        return sec

    sec.honeypot = _flag(_first(data, "is_honeypot", "honeypot"))
    sec.buy_tax_pct = _pct(_first(data, "buy_tax"))
    sec.sell_tax_pct = _pct(_first(data, "sell_tax"))
    sec.open_source = _flag(_first(data, "is_open_source"))
    sec.mintable = _flag(_first(data, "is_mintable"))
    sec.can_take_back_ownership = _flag(_first(data, "can_take_back_ownership"))
    sec.hidden_owner = _flag(_first(data, "hidden_owner"))

    owner = _first(data, "owner_address")
    if isinstance(owner, str):
        sec.ownership_renounced = owner.strip("0x").strip("0") == "" or owner.lower().endswith("dead")
    sec.holder_count = int(_first(data, "holder_count") or 0) or None
    sec.top_holders = _holders(data.get("holders"), cfg.excluded_owners)
    sec.lp_locked_or_burned_pct = _lp_locked_percent(data.get("lp_holders"))
    return sec


def parse_solana(payload: dict[str, Any] | None, address: str, cfg: Config) -> Security:
    sec = Security(sources=["goplus:solana"])
    if not isinstance(payload, dict):
        sec.errors.append("goplus: empty response")
        return sec
    result = payload.get("result")
    if not isinstance(result, dict) or not result:
        sec.errors.append("goplus: token not indexed")
        return sec
    data = result.get(address) or result.get(address.lower())
    if data is None and len(result) == 1:
        data = next(iter(result.values()))
    if not isinstance(data, dict):
        sec.errors.append("goplus: unexpected result shape")
        return sec

    # Solana authorities are reported as objects like
    # {"authority": [...], "malicious_address": 0} -- a non-empty authority
    # list means the power still exists.
    def _authority_present(key: str) -> bool | None:
        node = data.get(key)
        if node is None:
            return None
        if isinstance(node, dict):
            if "authority" in node:
                auth = node.get("authority")
                return bool(auth) if isinstance(auth, list) else _flag(auth)
            return _flag(_first(node, "status", "value"))
        return _flag(node)

    sec.mintable = _authority_present("mintable")
    sec.freezable = _authority_present("freezable")
    sec.metadata_mutable = _authority_present("metadata_mutable")
    sec.transfer_hook = _authority_present("transfer_hook")
    fee = data.get("transfer_fee")
    if isinstance(fee, dict):
        sec.transfer_fee_pct = _pct(_first(fee, "transfer_fee_percent", "fee_rate", "percent"))
    else:
        sec.transfer_fee_pct = _pct(fee)

    sec.holder_count = int(_first(data, "holder_count") or 0) or None
    sec.top_holders = _holders(data.get("holders"), cfg.excluded_owners)
    sec.lp_locked_or_burned_pct = _lp_locked_percent(data.get("lp_holders"))
    return sec


def fetch(chain: str, address: str, cfg: Config) -> Security:
    chain = chain.lower()
    try:
        if chain == "solana":
            payload = get_json(
                f"{API}/solana/token_security",
                {"contract_addresses": address},
                timeout=cfg.request_timeout,
                retries=cfg.max_retries,
                backoff=cfg.rate_limit_sleep,
            )
            return parse_solana(payload, address, cfg)
        chain_id = EVM_CHAIN_IDS.get(chain)
        if not chain_id:
            sec = Security()
            sec.errors.append(f"goplus: chain '{chain}' not supported")
            return sec
        payload = get_json(
            f"{API}/token_security/{chain_id}",
            {"contract_addresses": address.lower()},
            timeout=cfg.request_timeout,
            retries=cfg.max_retries,
            backoff=cfg.rate_limit_sleep,
        )
        return parse_evm(payload, address, cfg)
    except Exception as exc:  # network/parse failures must not kill the run
        sec = Security()
        sec.errors.append(f"goplus: {type(exc).__name__}: {exc}")
        return sec
