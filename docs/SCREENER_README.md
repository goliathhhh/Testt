# On-chain screener for new DEX pairs

A mechanical filter for freshly launched tokens. It answers one question —
**"is there a structural reason this cannot work?"** — and nothing else. It has
no opinion on whether a token will go up, and it deliberately cannot produce a
buy signal.

Runs on stock Python 3.10+. No `pip install`, no API keys required.

## Why it is built this way

Most "rug checkers" fail open: when a data source is down or returns a shape
they do not recognise, the missing field reads as `False` and the token comes
back clean. That turns a broken API into a green light. Here:

* Every unavailable fact stays `None`, and the check that needed it reports
  `UNKNOWN`.
* An `UNKNOWN` on a **critical** check caps the verdict at `CAUTION`. You will
  never see `WATCHLIST` on a token whose mint authority could not be read.
* When two sources disagree, the **more dangerous** answer wins the merge.
* The best possible verdict is `WATCHLIST`, worded so it cannot be mistaken for
  a recommendation.

## Usage

```bash
# discover newly created pools and screen them
python3 -m screener scan

# widen the net
python3 -m screener scan --networks solana,base --pages 3 --limit 100

# screen one specific token (e.g. one somebody shilled at you)
python3 -m screener check solana <mint_address>
python3 -m screener check base 0x<contract_address>

# machine-readable output
python3 -m screener scan --json > run.json

# show passing checks too, and rejected tokens in full
python3 -m screener scan --verbose --all
```

Point the Solana RPC at your own endpoint — the public one is rate limited to
the point of uselessness for a real scan:

```bash
python3 -m screener scan --rpc https://mainnet.helius-rpc.com/?api-key=YOUR_KEY
```

## What it checks

**Critical** (a failure rejects; being unable to check caps you at `CAUTION`):

| Check | Failure mode it catches |
|---|---|
| Mint authority | Dev mints unlimited supply into your bid |
| Freeze authority (Solana) | Your tokens are frozen; you cannot sell at any price |
| LP burned/locked | Liquidity is pulled from under the pool |
| Top-10 concentration | A handful of wallets can exit through your liquidity |
| Largest single holder | One wallet is the entire float |
| Buy/sell tax, transfer fee | You are taxed out on exit |
| Honeypot simulation (EVM) | Buys succeed, sells revert |
| Ownership / hidden owner (EVM) | Owner reclaims control after "renouncing" |
| Liquidity floor | Your own exit moves the price against you |

**Non-critical** (failures still reject, but a missing value only costs score):

pair age window · 24h volume floor · FDV-to-liquidity ratio · volume-to-liquidity
ratio combined with unique buyer count (wash trading) · unique buyers · buyer/seller
skew · holder count · Solana token extensions (transfer hook, mutable metadata).

## The holder-concentration detail that matters

Naive concentration checks count the AMM pool's own token account as a whale and
report 80%+ on perfectly normal tokens — so people learn to ignore the number.
This screener:

1. reads `getTokenLargestAccounts`, which returns token *accounts*, not wallets;
2. resolves each account's **owner** via `getMultipleAccounts`, so one wallet
   holding through five accounts is counted once as five accounts' worth;
3. excludes known pool, burn, and locker addresses (Raydium, Orca, Meteora,
   pump.fun, the incinerator — see `DEFAULT_EXCLUDED_OWNERS`) plus the pair
   address itself.

An owner that cannot be resolved is kept at full weight rather than dropped;
undercounting concentration is the expensive direction to be wrong in.

## Data sources

| Source | Used for | Key |
|---|---|---|
| GeckoTerminal `/new_pools` | discovery; unique buyer/seller counts | none |
| Dexscreener `/tokens/{addr}` | liquidity, FDV, volume, pair age | none |
| GoPlus token security | authorities, taxes, honeypot, LP locks, holders | none |
| Solana JSON-RPC | mint/freeze authority, holder aggregation by owner | optional |

GoPlus has changed field names across versions, so its parser tries several
spellings per field and yields `None` when none match — an unrecognised payload
degrades to "unknown", never to "safe".

## Tuning

Thresholds live in `screener/config.py`. Override with JSON:

```bash
cat > strict.json <<'EOF'
{"min_liquidity_usd": 50000, "max_top10_percent": 15, "min_holder_count": 500}
EOF
python3 -m screener scan --config strict.json
```

An unknown key in the config file is an error, not a silent no-op.

**None of the default numbers are backtested.** They are strict starting points
chosen to err toward rejecting. Loosen them against your own recorded outcomes
— never against a token you have already decided you want.

## Tests

```bash
python3 -m unittest discover -s tests -v
```

40 tests, fully offline: parsers run against recorded fixtures, the pipeline
runs against stubbed sources. `UnknownHandling.test_unverifiable_never_reaches_watchlist`
is the one that encodes the design promise.

## What this does not do

* It does not detect a coordinated group that buys, pumps, and dumps a token
  whose contract is genuinely clean. Every check here is structural; a clean
  contract with a bad crowd passes.
* It does not measure sniper/bundle wallets from the launch block.
* It does not read social signal, and it will not tell you what to buy.
* It cannot see a rug that happens five minutes after you run it. The output is
  a snapshot, not a subscription.

Passing every filter here removes a specific list of known mechanical failures.
It does not make a token a good trade, and the base rate for new memecoins is
that they go to zero regardless.
