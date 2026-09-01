"""Rendering. Text for a terminal, JSON for anything downstream."""

from __future__ import annotations

import json
from dataclasses import asdict

from .models import Result, Status, Verdict

GLYPH = {Status.OK: "ok  ", Status.WARN: "warn", Status.FAIL: "FAIL", Status.UNKNOWN: "??  "}
VERDICT_NOTE = {
    Verdict.REJECT: "disqualified by a hard rule",
    Verdict.CAUTION: "not disqualified, but something could not be verified",
    Verdict.WATCHLIST: "passed every mechanical filter — this is not a buy signal",
}


def render_text(results: list[Result], verbose: bool = False) -> str:
    if not results:
        return "No tokens to report.\n"

    lines: list[str] = []
    tally = {v: 0 for v in Verdict}
    for res in results:
        tally[res.verdict] += 1

    lines.append("")
    lines.append(
        f"{tally[Verdict.WATCHLIST]} watchlist / {tally[Verdict.CAUTION]} caution / "
        f"{tally[Verdict.REJECT]} rejected   (of {len(results)} screened)"
    )
    lines.append("=" * 78)

    for res in results:
        snap = res.snapshot
        pair = snap.pair
        if res.verdict is Verdict.REJECT and not verbose:
            reason = res.reasons[0] if res.reasons else "rejected"
            lines.append(f"REJECT     {snap.label:<34} {reason}")
            continue

        lines.append("")
        lines.append(f"{res.verdict.value:<10} {snap.label}   score {res.score}/100")
        lines.append(f"           {VERDICT_NOTE[res.verdict]}")
        if pair:
            bits = []
            if pair.liquidity_usd is not None:
                bits.append(f"liq ${pair.liquidity_usd:,.0f}")
            if pair.volume_h24 is not None:
                bits.append(f"vol24h ${pair.volume_h24:,.0f}")
            if pair.fdv_usd is not None:
                bits.append(f"fdv ${pair.fdv_usd:,.0f}")
            if pair.age_minutes is not None:
                bits.append(f"age {pair.age_minutes/60:.1f}h")
            if pair.dex:
                bits.append(pair.dex)
            if bits:
                lines.append("           " + "  ".join(bits))
            if pair.url:
                lines.append(f"           {pair.url}")
        for check in res.checks:
            if not verbose and check.status is Status.OK:
                continue
            lines.append(f"           [{GLYPH[check.status]}] {check.title}: {check.detail}")
        if snap.security.errors or snap.errors:
            for err in (snap.errors + snap.security.errors):
                lines.append(f"           (source) {err}")

    lines.append("")
    lines.append("-" * 78)
    lines.append("WATCHLIST means nothing mechanical disqualified the token. It says nothing")
    lines.append("about whether the price goes up. Most tokens that pass these filters still")
    lines.append("go to zero — the filters remove specific known failure modes, not risk.")
    lines.append("")
    return "\n".join(lines)


def render_json(results: list[Result]) -> str:
    payload = []
    for res in results:
        snap = res.snapshot
        payload.append(
            {
                "chain": snap.chain,
                "token_address": snap.token_address,
                "symbol": snap.pair.symbol if snap.pair else None,
                "verdict": res.verdict.value,
                "score": res.score,
                "reasons": res.reasons,
                "url": snap.pair.url if snap.pair else None,
                "pair": asdict(snap.pair) if snap.pair else None,
                "security": {
                    k: v for k, v in asdict(snap.security).items() if k != "top_holders"
                },
                "top_holders": [asdict(h) for h in snap.security.top_holders[:15]],
                "checks": [
                    {
                        "key": c.key,
                        "title": c.title,
                        "status": c.status.value,
                        "detail": c.detail,
                        "value": c.value,
                        "critical": c.critical,
                    }
                    for c in res.checks
                ],
                "errors": snap.errors,
                "fetched_at": snap.fetched_at,
            }
        )
    return json.dumps(payload, indent=2, ensure_ascii=False)
