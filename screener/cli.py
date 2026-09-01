"""Command line entry point.

    python -m screener scan                    # discover + screen new pools
    python -m screener check solana <mint>     # screen one token you were shown
"""

from __future__ import annotations

import argparse
import sys

from .config import Config
from .report import render_json, render_text
from .screen import run, screen_token


def _add_common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--config", help="path to a JSON file overriding thresholds")
    parser.add_argument("--json", action="store_true", help="emit JSON instead of text")
    parser.add_argument("--verbose", action="store_true", help="show passing checks too")
    parser.add_argument("--rpc", help="Solana RPC url (use your own key; the public one is rate limited)")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="screener", description="Mechanical on-chain filter for new DEX pairs.")
    sub = parser.add_subparsers(dest="command", required=True)

    scan = sub.add_parser("scan", help="discover new pools and screen them")
    _add_common(scan)
    scan.add_argument("--networks", help="comma-separated, e.g. solana,base")
    scan.add_argument("--pages", type=int, help="discovery pages per network")
    scan.add_argument("--limit", type=int, help="max candidates to fully screen")
    scan.add_argument("--all", action="store_true", help="show rejected tokens in full, not one line")

    check = sub.add_parser("check", help="screen one token by address")
    _add_common(check)
    check.add_argument("chain", help="solana, ethereum, base, bsc, …")
    check.add_argument("address", help="token mint / contract address")

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    try:
        cfg = Config.load(args.config)
    except (OSError, ValueError) as exc:
        print(f"config error: {exc}", file=sys.stderr)
        return 2

    if args.rpc:
        cfg.solana_rpc_url = args.rpc
    if getattr(args, "networks", None):
        cfg.networks = tuple(n.strip().lower() for n in args.networks.split(",") if n.strip())
    if getattr(args, "pages", None):
        cfg.discovery_pages = args.pages
    if getattr(args, "limit", None):
        cfg.max_candidates = args.limit

    log = (lambda _m: None) if args.json else (lambda m: print(m, file=sys.stderr))

    if args.command == "scan":
        results = run(cfg, log)
        verbose = args.verbose or args.all
    else:
        results = [screen_token(args.chain.lower(), args.address, cfg)]
        verbose = True

    print(render_json(results) if args.json else render_text(results, verbose))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
