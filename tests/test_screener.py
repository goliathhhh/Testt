"""Offline tests. No network: parsers run against recorded fixtures and the
pipeline runs against stubbed sources.

The test that matters most is ``test_unverifiable_never_reaches_watchlist`` --
everything else is plumbing, that one is the design promise.
"""

from __future__ import annotations

import json
import sys
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from screener import rules, screen  # noqa: E402
from screener.config import Config  # noqa: E402
from screener.models import HolderSlice, Pair, Security, Snapshot, Status, Verdict  # noqa: E402
from screener.sources import dexscreener, geckoterminal, goplus, solana_rpc  # noqa: E402

FIXTURES = Path(__file__).parent / "fixtures"


def fixture(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


def now_ms() -> float:
    return time.time() * 1000


class ParserRobustness(unittest.TestCase):
    """Every parser must survive garbage without raising."""

    JUNK = [None, {}, [], "", {"pairs": "nope"}, {"data": 5}, {"result": []}, {"result": {"x": "y"}}]

    def test_parsers_never_raise(self):
        cfg = Config()
        for payload in self.JUNK:
            dexscreener.parse_pairs(payload if isinstance(payload, dict) else None)
            geckoterminal.parse_new_pools(payload if isinstance(payload, dict) else None, "solana")
            goplus.parse_solana(payload if isinstance(payload, dict) else None, "M", cfg)
            goplus.parse_evm(payload if isinstance(payload, dict) else None, "0x1", cfg)
            solana_rpc.parse_mint_account(payload)
            solana_rpc.parse_largest_accounts(payload)

    def test_dexscreener_fixture(self):
        pairs = dexscreener.parse_pairs(fixture("dexscreener_pair.json"))
        self.assertEqual(len(pairs), 1)
        p = pairs[0]
        self.assertEqual(p.symbol, "CLEAN")
        self.assertEqual(p.liquidity_usd, 128000.0)
        self.assertEqual(p.buys_h24, 1840)
        self.assertEqual(p.price_usd, 0.00042)  # numeric string coerced

    def test_pair_missing_base_address_is_dropped(self):
        pairs = dexscreener.parse_pairs({"pairs": [{"chainId": "solana", "baseToken": {}}]})
        self.assertEqual(pairs, [])


class GoPlusParsing(unittest.TestCase):
    def setUp(self):
        self.cfg = Config()

    def test_rug_fixture_flags_authorities(self):
        sec = goplus.parse_solana(
            fixture("goplus_solana_rug.json"), "RUGmint1111111111111111111111111111111111111", self.cfg
        )
        self.assertTrue(sec.mintable)
        self.assertTrue(sec.freezable)
        self.assertTrue(sec.metadata_mutable)
        self.assertFalse(sec.transfer_hook)
        self.assertEqual(sec.holder_count, 38)
        self.assertEqual(sec.lp_locked_or_burned_pct, 0.0)

    def test_pool_holder_excluded_from_concentration(self):
        sec = goplus.parse_solana(
            fixture("goplus_solana_rug.json"), "RUGmint1111111111111111111111111111111111111", self.cfg
        )
        # 62% sits in the LP pool; counting it would report 88% concentration.
        # The real figure among tradeable wallets is 19 + 7 = 26%.
        self.assertAlmostEqual(sec.top_n_percent(10), 26.0, places=4)
        self.assertAlmostEqual(sec.largest_holder_percent(), 19.0, places=4)

    def test_clean_fixture_lp_burned(self):
        sec = goplus.parse_solana(
            fixture("goplus_solana_clean.json"), "CLEANmint111111111111111111111111111111111111", self.cfg
        )
        self.assertFalse(sec.mintable)
        self.assertFalse(sec.freezable)
        self.assertAlmostEqual(sec.lp_locked_or_burned_pct, 98.5, places=4)
        self.assertAlmostEqual(sec.top_n_percent(10), 5.4, places=4)

    def test_unknown_payload_yields_unknowns_not_false(self):
        sec = goplus.parse_solana({"result": {"M": {}}}, "M", self.cfg)
        self.assertIsNone(sec.mintable)
        self.assertIsNone(sec.freezable)
        self.assertIsNone(sec.lp_locked_or_burned_pct)


class HolderAggregation(unittest.TestCase):
    def setUp(self):
        self.cfg = Config()

    def test_same_owner_accounts_are_summed(self):
        accounts = [("TA1", 200_000.0), ("TA2", 100_000.0), ("TA3", 50_000.0)]
        owners = {"TA1": "WHALE", "TA2": "WHALE", "TA3": "OTHER"}
        slices = solana_rpc.aggregate_holders(accounts, owners, 1_000_000.0, self.cfg)
        by_addr = {h.address: h.percent for h in slices}
        self.assertAlmostEqual(by_addr["WHALE"], 30.0)
        self.assertAlmostEqual(by_addr["OTHER"], 5.0)

    def test_known_pool_owner_is_excluded(self):
        raydium = self.cfg.excluded_owners[2]
        slices = solana_rpc.aggregate_holders(
            [("TA1", 700_000.0), ("TA2", 30_000.0)],
            {"TA1": raydium, "TA2": "W"},
            1_000_000.0,
            self.cfg,
        )
        self.assertTrue(next(h for h in slices if h.address == raydium).excluded)
        sec = Security(top_holders=slices)
        self.assertAlmostEqual(sec.top_n_percent(10), 3.0)

    def test_pair_address_is_excluded(self):
        slices = solana_rpc.aggregate_holders(
            [("TA1", 800_000.0)], {"TA1": "PoolOwner"}, 1_000_000.0, self.cfg, ("PoolOwner",)
        )
        self.assertTrue(slices[0].excluded)

    def test_unresolved_owner_is_kept_not_dropped(self):
        slices = solana_rpc.aggregate_holders([("TA1", 400_000.0)], {}, 1_000_000.0, self.cfg)
        self.assertEqual(len(slices), 1)
        self.assertAlmostEqual(slices[0].percent, 40.0)

    def test_zero_supply_yields_nothing(self):
        self.assertEqual(solana_rpc.aggregate_holders([("A", 1.0)], {}, 0.0, self.cfg), [])


class MergePessimism(unittest.TestCase):
    def test_dangerous_true_wins(self):
        merged = rules.merge_security(Security(mintable=False), Security(mintable=True))
        self.assertTrue(merged.mintable)

    def test_dangerous_false_wins_for_positive_flags(self):
        merged = rules.merge_security(Security(open_source=True), Security(open_source=False))
        self.assertFalse(merged.open_source)

    def test_worst_tax_wins(self):
        merged = rules.merge_security(Security(sell_tax_pct=1.0), Security(sell_tax_pct=40.0))
        self.assertEqual(merged.sell_tax_pct, 40.0)

    def test_lowest_lp_lock_wins(self):
        merged = rules.merge_security(
            Security(lp_locked_or_burned_pct=100.0), Security(lp_locked_or_burned_pct=10.0)
        )
        self.assertEqual(merged.lp_locked_or_burned_pct, 10.0)

    def test_first_source_supplies_holders(self):
        onchain = Security(top_holders=[HolderSlice("A", 1.0)])
        aggregator = Security(top_holders=[HolderSlice("B", 99.0)])
        self.assertEqual(rules.merge_security(onchain, aggregator).top_holders[0].address, "A")


def clean_snapshot(**overrides) -> Snapshot:
    """A token that passes everything, so tests can break one thing at a time."""
    sec = Security(
        mintable=False,
        freezable=False,
        honeypot=False,
        buy_tax_pct=0.0,
        sell_tax_pct=0.0,
        transfer_fee_pct=0.0,
        metadata_mutable=False,
        transfer_hook=False,
        lp_locked_or_burned_pct=99.0,
        holder_count=2000,
        top_holders=[HolderSlice(f"W{i}", 1.5) for i in range(20)],
    )
    pair = Pair(
        chain="solana",
        token_address="CLEAN",
        pair_address="POOL",
        dex="raydium",
        symbol="CLEAN",
        quote_symbol="SOL",
        liquidity_usd=128_000.0,
        fdv_usd=1_900_000.0,
        created_at_ms=now_ms() - 6 * 3600 * 1000,
        volume_h24=412_000.0,
        buys_h24=1840,
        sells_h24=1602,
        buyers_h24=940,
        sellers_h24=780,
    )
    snap = Snapshot(chain="solana", token_address="CLEAN", pair=pair, security=sec)
    for key, value in overrides.items():
        if hasattr(sec, key):
            setattr(sec, key, value)
        elif hasattr(pair, key):
            setattr(pair, key, value)
        else:
            raise AttributeError(key)
    return snap


class Rules(unittest.TestCase):
    def setUp(self):
        self.cfg = Config()

    def check(self, snap, key):
        return next(c for c in rules.evaluate(snap, self.cfg).checks if c.key == key)

    def test_clean_token_reaches_watchlist(self):
        result = rules.evaluate(clean_snapshot(), self.cfg)
        self.assertEqual(result.verdict, Verdict.WATCHLIST, result.reasons)

    def test_live_mint_authority_rejects(self):
        result = rules.evaluate(clean_snapshot(mintable=True), self.cfg)
        self.assertEqual(result.verdict, Verdict.REJECT)
        self.assertIn("mint_authority", [c.key for c in result.failed()])

    def test_live_freeze_authority_rejects(self):
        self.assertEqual(rules.evaluate(clean_snapshot(freezable=True), self.cfg).verdict, Verdict.REJECT)

    def test_unlocked_lp_rejects(self):
        self.assertEqual(
            rules.evaluate(clean_snapshot(lp_locked_or_burned_pct=12.0), self.cfg).verdict, Verdict.REJECT
        )

    def test_concentrated_supply_rejects(self):
        snap = clean_snapshot()
        snap.security.top_holders = [HolderSlice("WHALE", 40.0)] + [HolderSlice(f"W{i}", 0.5) for i in range(10)]
        result = rules.evaluate(snap, self.cfg)
        self.assertEqual(result.verdict, Verdict.REJECT)
        keys = [c.key for c in result.failed()]
        self.assertIn("top10_concentration", keys)
        self.assertIn("single_holder", keys)

    def test_thin_liquidity_rejects(self):
        self.assertEqual(rules.evaluate(clean_snapshot(liquidity_usd=3_000.0), self.cfg).verdict, Verdict.REJECT)

    def test_too_young_rejects(self):
        snap = clean_snapshot(created_at_ms=now_ms() - 5 * 60 * 1000)
        self.assertEqual(rules.evaluate(snap, self.cfg).verdict, Verdict.REJECT)

    def test_wash_trading_pattern_rejects(self):
        # Huge churn, almost nobody trading: bot loop, not demand.
        snap = clean_snapshot(volume_h24=9_000_000.0, buyers_h24=11, sellers_h24=9)
        result = rules.evaluate(snap, self.cfg)
        self.assertEqual(result.verdict, Verdict.REJECT)
        self.assertIn("wash_trading", [c.key for c in result.failed()])

    def test_notional_fdv_rejects(self):
        self.assertEqual(rules.evaluate(clean_snapshot(fdv_usd=90_000_000.0), self.cfg).verdict, Verdict.REJECT)

    def test_high_tax_rejects(self):
        self.assertEqual(rules.evaluate(clean_snapshot(sell_tax_pct=35.0), self.cfg).verdict, Verdict.REJECT)

    def test_freeze_rule_skipped_off_solana(self):
        snap = clean_snapshot()
        snap.chain = "base"
        snap.security.honeypot = False
        snap.security.open_source = True
        snap.security.ownership_renounced = True
        keys = [c.key for c in rules.evaluate(snap, self.cfg).checks]
        self.assertNotIn("freeze_authority", keys)
        self.assertIn("honeypot", keys)

    def test_honeypot_rejects_on_evm(self):
        snap = clean_snapshot()
        snap.chain = "base"
        snap.security.honeypot = True
        snap.security.open_source = True
        snap.security.ownership_renounced = True
        self.assertEqual(rules.evaluate(snap, self.cfg).verdict, Verdict.REJECT)


class UnknownHandling(unittest.TestCase):
    """The core invariant: absence of evidence is not evidence of safety."""

    def setUp(self):
        self.cfg = Config()

    def test_unverifiable_never_reaches_watchlist(self):
        for field in ("mintable", "freezable", "lp_locked_or_burned_pct"):
            with self.subTest(field=field):
                result = rules.evaluate(clean_snapshot(**{field: None}), self.cfg)
                self.assertEqual(result.verdict, Verdict.CAUTION, f"{field} unknown must not pass")
                self.assertTrue(result.blind_spots())

    def test_missing_holders_caps_at_caution(self):
        snap = clean_snapshot()
        snap.security.top_holders = []
        result = rules.evaluate(snap, self.cfg)
        self.assertEqual(result.verdict, Verdict.CAUTION)

    def test_totally_empty_snapshot_is_caution_not_watchlist(self):
        snap = Snapshot(chain="solana", token_address="X")
        result = rules.evaluate(snap, self.cfg)
        self.assertEqual(result.verdict, Verdict.CAUTION)
        self.assertLess(result.score, 100)

    def test_unknown_costs_score(self):
        full = rules.evaluate(clean_snapshot(), self.cfg).score
        partial = rules.evaluate(clean_snapshot(mintable=None), self.cfg).score
        self.assertLess(partial, full)


class Prefilter(unittest.TestCase):
    def setUp(self):
        self.cfg = Config()

    def test_known_bad_numbers_are_dropped(self):
        pairs = [
            Pair(chain="solana", token_address="thin", liquidity_usd=900.0),
            Pair(chain="solana", token_address="young", liquidity_usd=99_000.0, created_at_ms=now_ms() - 60_000),
            Pair(chain="solana", token_address="stale", liquidity_usd=99_000.0, created_at_ms=now_ms() - 200 * 3600_000),
            Pair(chain="solana", token_address="good", liquidity_usd=99_000.0, created_at_ms=now_ms() - 3600_000),
        ]
        kept = [p.token_address for p in screen.prefilter(pairs, self.cfg)]
        self.assertEqual(kept, ["good"])

    def test_missing_fields_are_not_dropped_here(self):
        kept = screen.prefilter([Pair(chain="solana", token_address="unknown")], self.cfg)
        self.assertEqual(len(kept), 1)


class Pipeline(unittest.TestCase):
    """End-to-end with the network layer stubbed out."""

    def setUp(self):
        self.cfg = Config()
        self._saved = (
            geckoterminal.fetch_new_pools,
            dexscreener.fetch,
            goplus.fetch,
            solana_rpc.fetch,
        )

    def tearDown(self):
        (
            geckoterminal.fetch_new_pools,
            dexscreener.fetch,
            goplus.fetch,
            solana_rpc.fetch,
        ) = self._saved
        screen.geckoterminal.fetch_new_pools = self._saved[0]
        screen.dexscreener.fetch = self._saved[1]
        screen.goplus.fetch = self._saved[2]
        screen.solana_rpc.fetch = self._saved[3]

    def _stub(self, security_by_token):
        pools = [
            Pair(
                chain="solana",
                token_address="CLEAN",
                pair_address="POOL1",
                liquidity_usd=128_000.0,
                created_at_ms=now_ms() - 6 * 3600_000,
                volume_h24=412_000.0,
                buyers_h24=940,
                sellers_h24=780,
                fdv_usd=1_900_000.0,
            ),
            Pair(
                chain="solana",
                token_address="RUG",
                pair_address="POOL2",
                liquidity_usd=60_000.0,
                created_at_ms=now_ms() - 2 * 3600_000,
                volume_h24=300_000.0,
                buyers_h24=400,
                sellers_h24=300,
                fdv_usd=2_000_000.0,
            ),
            Pair(chain="solana", token_address="TINY", liquidity_usd=400.0),
        ]
        screen.geckoterminal.fetch_new_pools = lambda net, cfg, pages=None: list(pools)
        screen.dexscreener.fetch = lambda addr, cfg: [p for p in pools if p.token_address == addr]
        screen.goplus.fetch = lambda chain, addr, cfg: security_by_token[addr]
        screen.solana_rpc.fetch = lambda addr, cfg, pool=(): Security()

    def test_run_separates_rug_from_clean(self):
        self._stub(
            {
                "CLEAN": Security(
                    mintable=False, freezable=False, lp_locked_or_burned_pct=99.0,
                    holder_count=2000, buy_tax_pct=0.0, sell_tax_pct=0.0,
                    metadata_mutable=False, transfer_hook=False,
                    top_holders=[HolderSlice(f"W{i}", 1.5) for i in range(20)],
                ),
                "RUG": Security(
                    mintable=True, freezable=True, lp_locked_or_burned_pct=0.0,
                    holder_count=38,
                    top_holders=[HolderSlice("DEV", 19.0), HolderSlice("W2", 7.0)],
                ),
            }
        )
        results = screen.run(self.cfg)
        by_token = {r.snapshot.token_address: r for r in results}
        self.assertEqual(by_token["CLEAN"].verdict, Verdict.WATCHLIST, by_token["CLEAN"].reasons)
        self.assertEqual(by_token["RUG"].verdict, Verdict.REJECT)
        self.assertNotIn("TINY", by_token, "prefilter should have dropped the tiny pool")

    def test_source_failure_degrades_to_caution_not_watchlist(self):
        self._stub({"CLEAN": Security(errors=["goplus: down"]), "RUG": Security(errors=["goplus: down"])})
        results = screen.run(self.cfg)
        for res in results:
            self.assertNotEqual(res.verdict, Verdict.WATCHLIST)


class Reporting(unittest.TestCase):
    def test_json_round_trips(self):
        from screener.report import render_json, render_text

        results = [rules.evaluate(clean_snapshot(), Config())]
        payload = json.loads(render_json(results))
        self.assertEqual(payload[0]["verdict"], "WATCHLIST")
        self.assertIn("checks", payload[0])
        text = render_text(results, verbose=True)
        self.assertIn("WATCHLIST", text)
        self.assertIn("not a buy signal", text)


class ConfigLoading(unittest.TestCase):
    def test_unknown_key_is_rejected(self):
        import tempfile

        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump({"min_liquidity_usd": 1.0, "typo_here": 2}, fh)
            path = fh.name
        with self.assertRaises(ValueError):
            Config.load(path)

    def test_override_applies(self):
        import tempfile

        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump({"min_liquidity_usd": 999.0, "networks": ["base", "solana"]}, fh)
            path = fh.name
        cfg = Config.load(path)
        self.assertEqual(cfg.min_liquidity_usd, 999.0)
        self.assertEqual(cfg.networks, ("base", "solana"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
