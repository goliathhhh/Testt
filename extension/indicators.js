/*
 * indicators.js — RSI / EMA / signal logic.
 * Ported from the Phantom Trader Telegram bot (Python).
 * Exposes window.MT5ADV.{computeEMA, computeRSI, getSignal}.
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

  /**
   * Build a trading suggestion from candles + user config.
   * Strategy (same as the Telegram bot):
   *   - direction by EMA trend (price > EMA -> LONG, else SHORT)
   *   - RSI blocks entries that are overbought (LONG) / oversold (SHORT)
   *   - SL / TP are percent of price; position size from balance & risk %
   */
  function getSignal(candles, cfg) {
    const need = Math.max(cfg.emaPeriod, cfg.rsiPeriod) + 2;
    if (!candles || candles.length < need) {
      return { status: "error", message: "Недостатньо даних для розрахунку" };
    }

    const emas = computeEMA(candles, cfg.emaPeriod);
    const rsis = computeRSI(candles, cfg.rsiPeriod);
    const last = candles[candles.length - 1];
    const price = last.close;
    const ema = emas[emas.length - 1];
    const rsi = rsis[rsis.length - 1];

    if (ema == null || rsi == null) {
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

    const sl = cfg.slPct;
    const tp = cfg.tpPct;
    const slPrice = side === "LONG" ? price * (1 - sl / 100) : price * (1 + sl / 100);
    const tpPrice = side === "LONG" ? price * (1 + tp / 100) : price * (1 - tp / 100);

    const bal = Math.max(cfg.balance, 0);
    const lev = cfg.leverage || 1;
    const riskUsd = bal * (cfg.riskPct / 100);
    const notional = sl ? riskUsd / (sl / 100) : 0;
    const margin = lev ? notional / lev : notional;
    const profitUsd = notional * (tp / 100);

    return {
      status: blocked ? "blocked" : "signal",
      side,
      price,
      ema,
      rsi,
      slPrice,
      tpPrice,
      slPct: sl,
      tpPct: tp,
      rr: sl ? +(tp / sl).toFixed(2) : 0,
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

  window.MT5ADV = { computeEMA, computeRSI, getSignal };
})();
