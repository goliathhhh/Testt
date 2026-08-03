/*
 * indicators.js — RSI / EMA / ATR + level suggestion logic.
 *
 * This is an ANALYSIS HELPER, not a profit strategy. It reads recent price
 * action and proposes:
 *   - a market bias (EMA trend, filtered by RSI extremes)
 *   - Stop-Loss / Take-Profit levels derived from volatility (ATR) and the
 *     nearest swing high/low — so they adapt to the market instead of being
 *     a fixed +4% / -1%.
 * Exposes window.MT5ADV.{computeEMA, computeRSI, computeATR, getSignal}.
 */
(function () {
  "use strict";

  function computeEMA(candles, period) {
    const n = candles.length;
    const out = new Array(n).fill(null);
    if (n < period) return out;
    let sma = 0;
    for (let i = 0; i < period; i++) sma += candles[i].close;
    sma /= period;
    out[period - 1] = sma;
    const k = 2 / (period + 1);
    for (let i = period; i < n; i++) {
      out[i] = candles[i].close * k + out[i - 1] * (1 - k);
    }
    return out;
  }

  function computeRSI(candles, period) {
    const n = candles.length;
    const out = new Array(n).fill(null);
    if (n < period + 1) return out;
    const c = candles.map((x) => x.close);
    let avgGain = 0, avgLoss = 0;
    for (let i = 1; i <= period; i++) {
      const d = c[i] - c[i - 1];
      avgGain += Math.max(d, 0);
      avgLoss += Math.max(-d, 0);
    }
    avgGain /= period;
    avgLoss /= period;
    for (let i = period; i < n; i++) {
      if (i > period) {
        const d = c[i] - c[i - 1];
        avgGain = (avgGain * (period - 1) + Math.max(d, 0)) / period;
        avgLoss = (avgLoss * (period - 1) + Math.max(-d, 0)) / period;
      }
      out[i] = avgLoss === 0 ? 100 : 100 - 100 / (1 + avgGain / avgLoss);
    }
    return out;
  }

  // Average True Range (Wilder smoothing) — a volatility measure.
  function computeATR(candles, period) {
    const n = candles.length;
    const out = new Array(n).fill(null);
    if (n < period + 1) return out;
    const tr = new Array(n).fill(0);
    tr[0] = candles[0].high - candles[0].low;
    for (let i = 1; i < n; i++) {
      const h = candles[i].high, l = candles[i].low, pc = candles[i - 1].close;
      tr[i] = Math.max(h - l, Math.abs(h - pc), Math.abs(l - pc));
    }
    let sum = 0;
    for (let i = 1; i <= period; i++) sum += tr[i];
    let atr = sum / period;
    out[period] = atr;
    for (let i = period + 1; i < n; i++) {
      atr = (atr * (period - 1) + tr[i]) / period;
      out[i] = atr;
    }
    return out;
  }

  /**
   * Build a market hint from candles + user config.
   *  - bias: EMA trend (price > EMA -> LONG, else SHORT)
   *  - RSI blocks chasing overbought (LONG) / oversold (SHORT)
   *  - SL: beyond the recent swing low/high, bounded by ATR (volatility)
   *  - TP: a multiple of ATR (scales with current volatility)
   *  => SL/TP and RR change with the market; they are NOT fixed.
   */
  function getSignal(candles, cfg) {
    const atrP = cfg.atrPeriod || 14;
    const look = cfg.swingLookback || 10;
    const need = Math.max(cfg.emaPeriod, cfg.rsiPeriod, atrP, look) + 2;
    if (!candles || candles.length < need) {
      return { status: "error", message: "Недостатньо даних для розрахунку" };
    }

    const emas = computeEMA(candles, cfg.emaPeriod);
    const rsis = computeRSI(candles, cfg.rsiPeriod);
    const atrs = computeATR(candles, atrP);

    const last = candles[candles.length - 1];
    const price = last.close;
    const ema = emas[emas.length - 1];
    const rsi = rsis[rsis.length - 1];
    const atr = atrs[atrs.length - 1];

    if (ema == null || rsi == null || atr == null || !(atr > 0)) {
      return { status: "wait", message: "Індикатори накопичують дані", price };
    }

    const side = price > ema ? "LONG" : "SHORT";

    let blocked = false;
    let reason = "";
    if (side === "LONG" && rsi > cfg.overbought) {
      blocked = true;
      reason = `RSI ${rsi.toFixed(1)} > ${cfg.overbought} — перекуплено`;
    } else if (side === "SHORT" && rsi < cfg.oversold) {
      blocked = true;
      reason = `RSI ${rsi.toFixed(1)} < ${cfg.oversold} — перепродано`;
    }

    // recent swing extremes (near) — used for the swing stop
    const swWin = candles.slice(-look);
    let swingLow = Infinity, swingHigh = -Infinity;
    for (const c of swWin) {
      if (c.low < swingLow) swingLow = c.low;
      if (c.high > swingHigh) swingHigh = c.high;
    }
    // wider extremes (far) — used for a structural target
    const structLook = cfg.structLookback || 30;
    const stWin = candles.slice(-structLook);
    let structLow = Infinity, structHigh = -Infinity;
    for (const c of stWin) {
      if (c.low < structLow) structLow = c.low;
      if (c.high > structHigh) structHigh = c.high;
    }

    const slMode = cfg.slMode || "swing"; // "swing" | "atr"
    const tpMode = cfg.tpMode || "atr";   // "atr"   | "structure"
    const slAtrMult = cfg.slAtrMult || 1.5;
    const tpMult = cfg.tpAtrMult || 3.0;
    const buffer = 0.25 * atr;
    const slFloor = 1.0 * atr;  // don't place the swing stop too tight
    const slCap = 2.0 * atr;    // keep swing-stop risk sane
    const tpCap = 8.0 * atr;    // avoid an absurdly far structural target

    let slDist, tpDist, slBasis, tpBasis, slFromLevel = null;

    // ── Stop-Loss ──
    if (slMode === "atr") {
      slDist = slAtrMult * atr;
      slBasis = slAtrMult + "× ATR";
    } else { // swing
      if (side === "LONG") {
        slDist = clamp(price - (swingLow - buffer), slFloor, slCap);
        slFromLevel = swingLow;
      } else {
        slDist = clamp((swingHigh + buffer) - price, slFloor, slCap);
        slFromLevel = swingHigh;
      }
      slBasis = "свінг(" + look + ") + ATR";
    }

    // ── Take-Profit ──
    if (tpMode === "structure") {
      const dist = side === "LONG" ? structHigh - price : price - structLow;
      if (dist >= 0.5 * atr) {
        tpDist = Math.min(dist, tpCap);
        tpBasis = "рівень(" + structLook + ")";
      } else {
        tpDist = tpMult * atr; // no room to structure -> volatility fallback
        tpBasis = tpMult + "× ATR (запас)";
      }
    } else { // atr
      tpDist = tpMult * atr;
      tpBasis = tpMult + "× ATR";
    }

    const slPrice = side === "LONG" ? price - slDist : price + slDist;
    const tpPrice = side === "LONG" ? price + tpDist : price - tpDist;

    const slPct = (slDist / price) * 100;
    const tpPct = (tpDist / price) * 100;
    const rr = slDist > 0 ? tpDist / slDist : 0;

    // position sizing from risk % of balance
    const bal = Math.max(cfg.balance, 0);
    const lev = cfg.leverage || 1;
    const riskUsd = bal * (cfg.riskPct / 100);
    const notional = slPct > 0 ? riskUsd / (slPct / 100) : 0;
    const margin = lev ? notional / lev : notional;
    const profitUsd = notional * (tpPct / 100);

    return {
      status: blocked ? "blocked" : "signal",
      side,
      price,
      ema,
      rsi,
      atr,
      slPrice,
      tpPrice,
      slPct,
      tpPct,
      rr: +rr.toFixed(2),
      slFromLevel,
      slBasis,
      tpBasis,
      notional,
      margin,
      marginPct: bal ? (margin / bal) * 100 : 0,
      lev,
      riskUsd,
      profitUsd,
      balance: bal,
      afford: margin <= bal,
      reason,
      candleTime: new Date(last.ts).toLocaleString(),
    };
  }

  function clamp(v, lo, hi) {
    return Math.max(lo, Math.min(hi, v));
  }

  window.MT5ADV = { computeEMA, computeRSI, computeATR, getSignal };
})();
