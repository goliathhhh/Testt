/*
 * smc.js — Smart-Money-Concepts analysis on OHLC candles.
 * Deterministic detectors: swing pivots, market structure (BOS/CHoCH),
 * liquidity sweeps, Fair Value Gaps, and liquidity targets for SL/TP.
 * Multi-timeframe bias + a structure-derived trade idea.
 *
 * NOTE: this works on candles only (no order flow / real volume for forex),
 * so it is a heuristic helper, not a guaranteed edge.
 *
 * Exposes window.MT5ADV.analyze(byTF, execTF, cfg).
 */
(function () {
  "use strict";
  const I = window.MT5ADV; // computeEMA / computeRSI / computeATR

  const TF_ORDER = ["M15", "H1", "H4", "D1", "W1"];
  const TF_WEIGHT = { M15: 1, H1: 2, H4: 3, D1: 4, W1: 4 };

  // ── swing pivots (fractals) ──────────────────────────────
  function pivots(c, k) {
    const highs = [], lows = [];
    for (let i = k; i < c.length - k; i++) {
      let isH = true, isL = true;
      for (let j = i - k; j <= i + k; j++) {
        if (j === i) continue;
        if (c[j].high >= c[i].high) isH = false;
        if (c[j].low <= c[i].low) isL = false;
      }
      if (isH) highs.push({ i, price: c[i].high });
      if (isL) lows.push({ i, price: c[i].low });
    }
    return { highs, lows };
  }

  // ── market structure + BOS / CHoCH ───────────────────────
  function structure(c, highs, lows) {
    const price = c[c.length - 1].close;
    let trend = "range";
    if (highs.length >= 2 && lows.length >= 2) {
      const hh = highs[highs.length - 1].price > highs[highs.length - 2].price;
      const hl = lows[lows.length - 1].price > lows[lows.length - 2].price;
      const lh = highs[highs.length - 1].price < highs[highs.length - 2].price;
      const ll = lows[lows.length - 1].price < lows[lows.length - 2].price;
      if (hh && hl) trend = "bull";
      else if (lh && ll) trend = "bear";
    }
    const lastHigh = highs.length ? highs[highs.length - 1] : null;
    const lastLow = lows.length ? lows[lows.length - 1] : null;
    let event = null, kind = null;
    if (lastHigh && price > lastHigh.price) {
      event = "bull"; kind = trend === "bear" ? "CHoCH↑" : "BOS↑";
    } else if (lastLow && price < lastLow.price) {
      event = "bear"; kind = trend === "bull" ? "CHoCH↓" : "BOS↓";
    }
    return { trend, event, kind };
  }

  // ── liquidity sweep (stop hunt) in the last few bars ─────
  function sweep(c, highs, lows) {
    const last = c[c.length - 1];
    let res = null;
    for (const h of highs.slice(-3)) {
      if (last.high > h.price && last.close < h.price) res = { side: "buy", level: h.price };
    }
    for (const l of lows.slice(-3)) {
      if (last.low < l.price && last.close > l.price) res = { side: "sell", level: l.price };
    }
    return res; // "buy" = buy-side (highs) taken -> bearish; "sell" = sell-side (lows) taken -> bullish
  }

  // ── Fair Value Gaps (3-candle imbalance) ─────────────────
  function fvgs(c) {
    const out = [];
    const from = Math.max(1, c.length - 40);
    for (let i = from; i < c.length - 1; i++) {
      if (c[i - 1].high < c[i + 1].low)
        out.push({ type: "bull", lo: c[i - 1].high, hi: c[i + 1].low });
      else if (c[i - 1].low > c[i + 1].high)
        out.push({ type: "bear", lo: c[i + 1].high, hi: c[i - 1].low });
    }
    return out;
  }

  function nearestFVG(list, price) {
    let best = null, bestDist = Infinity;
    for (const f of list) {
      const mid = (f.lo + f.hi) / 2;
      const d = Math.abs(mid - price);
      if (d < bestDist) { bestDist = d; best = f; }
    }
    return best;
  }

  // ── per-timeframe bias ───────────────────────────────────
  function biasOfTF(c) {
    if (!c || c.length < 55) return { bias: "range", note: "мало даних" };
    const ema20 = I.computeEMA(c, 20);
    const ema50 = I.computeEMA(c, 50);
    const e20 = ema20[ema20.length - 1];
    const e50 = ema50[ema50.length - 1];
    const price = c[c.length - 1].close;
    const { highs, lows } = pivots(c, 3);
    const st = structure(c, highs, lows);
    const emaBias = e20 > e50 && price > e50 ? "bull"
      : e20 < e50 && price < e50 ? "bear" : "range";
    let bias = emaBias;
    if (st.trend === "bull" && emaBias !== "bear") bias = "bull";
    else if (st.trend === "bear" && emaBias !== "bull") bias = "bear";
    return { bias, note: st.trend };
  }

  function trendWord(t) {
    return t === "bull" ? "висхідна" : t === "bear" ? "низхідна" : "флет";
  }

  // ── main analysis ────────────────────────────────────────
  function analyze(byTF, execTF, cfg) {
    const mtf = [];
    for (const tf of TF_ORDER) {
      if (byTF[tf] && byTF[tf].length) {
        const b = biasOfTF(byTF[tf]);
        mtf.push({ tf, bias: b.bias });
      }
    }
    // weighted overall bias (higher timeframes count more)
    let score = 0, wsum = 0;
    for (const m of mtf) {
      const w = TF_WEIGHT[m.tf] || 1;
      wsum += w;
      score += (m.bias === "bull" ? 1 : m.bias === "bear" ? -1 : 0) * w;
    }
    const norm = wsum ? score / wsum : 0;
    const overall = norm > 0.2 ? "bull" : norm < -0.2 ? "bear" : "mixed";

    const c = byTF[execTF] || byTF.H1 || (mtf.length ? byTF[mtf[0].tf] : null);
    if (!c || c.length < 60) {
      return { mtf, overall, exec: { status: "error", message: "Недостатньо даних для аналізу" } };
    }

    const k = cfg.pivotStrength || 2;
    const atrArr = I.computeATR(c, cfg.atrPeriod || 14);
    const atr = atrArr[atrArr.length - 1] || 0;
    const rsiArr = I.computeRSI(c, 14);
    const rsi = rsiArr[rsiArr.length - 1];
    const price = c[c.length - 1].close;

    const { highs, lows } = pivots(c, k);
    const st = structure(c, highs, lows);
    const sw = sweep(c, highs, lows);
    const gaps = fvgs(c);
    const nfvg = nearestFVG(gaps, price);

    const reasons = [];

    // ── decide direction ──
    let side = null;
    if (sw) {
      if (sw.side === "sell" && overall !== "bear") { side = "LONG"; reasons.push("Sell-side liquidity sweep (стоп-хант знизу)"); }
      else if (sw.side === "buy" && overall !== "bull") { side = "SHORT"; reasons.push("Buy-side liquidity sweep (стоп-хант зверху)"); }
    }
    if (!side && st.event) {
      if (st.event === "bull" && overall !== "bear") { side = "LONG"; reasons.push("Структура: " + st.kind); }
      else if (st.event === "bear" && overall !== "bull") { side = "SHORT"; reasons.push("Структура: " + st.kind); }
    }
    if (!side) {
      if (overall === "bull") { side = "LONG"; reasons.push("HTF ухил вгору — лонг з підтримки"); }
      else if (overall === "bear") { side = "SHORT"; reasons.push("HTF ухил вниз — шорт з опору"); }
    }

    const structLabel = trendWord(st.trend) + (st.kind ? " · " + st.kind : "");

    if (!side) {
      return {
        mtf, overall,
        exec: {
          status: "wait", price, atr, rsi,
          structure: structLabel,
          message: "Немає чіткого сетапу — таймфрейми не узгоджені",
        },
      };
    }

    // ── SL / TP from structure & liquidity ──
    let sl, tp1, tp2;
    const buf = 0.2 * atr;
    if (side === "LONG") {
      const swLow = lows.length ? lows[lows.length - 1].price : Math.min.apply(null, c.slice(-10).map((x) => x.low));
      const base = sw && sw.side === "sell" ? Math.min(sw.level, swLow) : swLow;
      sl = base - buf;
      if (sl >= price) sl = price - Math.max(atr, price * 0.001);
      const above = highs.map((h) => h.price).filter((p) => p > price + 0.1 * atr).sort((a, b) => a - b);
      const risk = price - sl;
      tp1 = above[0] != null ? above[0] : price + 2 * risk;
      tp2 = above[1] != null ? above[1] : price + 3 * risk;
      if (tp2 <= tp1) tp2 = tp1 + risk;
    } else {
      const swHigh = highs.length ? highs[highs.length - 1].price : Math.max.apply(null, c.slice(-10).map((x) => x.high));
      const base = sw && sw.side === "buy" ? Math.max(sw.level, swHigh) : swHigh;
      sl = base + buf;
      if (sl <= price) sl = price + Math.max(atr, price * 0.001);
      const below = lows.map((l) => l.price).filter((p) => p < price - 0.1 * atr).sort((a, b) => b - a);
      const risk = sl - price;
      tp1 = below[0] != null ? below[0] : price - 2 * risk;
      tp2 = below[1] != null ? below[1] : price - 3 * risk;
      if (tp2 >= tp1) tp2 = tp1 - risk;
    }

    // confluence notes
    reasons.push("HTF ухил: " + (overall === "bull" ? "вгору" : overall === "bear" ? "вниз" : "змішаний"));
    if (nfvg) reasons.push("FVG поруч: " + (nfvg.type === "bull" ? "бичачий" : "ведмежий") + " імбаланс");
    if (rsi != null) {
      if (side === "LONG" && rsi > 72) reasons.push("⚠️ RSI " + rsi.toFixed(0) + " — перекуплено, чекай відкату");
      if (side === "SHORT" && rsi < 28) reasons.push("⚠️ RSI " + rsi.toFixed(0) + " — перепродано, чекай відскоку");
    }

    const entry = price;
    const slDist = Math.abs(entry - sl);
    const slPct = (slDist / entry) * 100;
    const tp1Pct = (Math.abs(tp1 - entry) / entry) * 100;
    const tp2Pct = (Math.abs(tp2 - entry) / entry) * 100;
    const rr1 = slDist > 0 ? Math.abs(tp1 - entry) / slDist : 0;
    const rr2 = slDist > 0 ? Math.abs(tp2 - entry) / slDist : 0;

    // sizing
    const bal = Math.max(cfg.balance, 0);
    const lev = cfg.leverage || 1;
    const riskUsd = bal * (cfg.riskPct / 100);
    const notional = slPct > 0 ? riskUsd / (slPct / 100) : 0;
    const margin = lev ? notional / lev : notional;
    const profitUsd = notional * (tp1Pct / 100);

    return {
      mtf, overall,
      exec: {
        status: "setup",
        side, price, entry, atr, rsi,
        structure: structLabel,
        sweep: sw ? (sw.side === "sell" ? "sell-side (бичача)" : "buy-side (ведмежа)") : null,
        sl, tp1, tp2,
        slPct, tp1Pct, tp2Pct,
        rr1: +rr1.toFixed(2), rr2: +rr2.toFixed(2),
        reasons,
        notional, margin, marginPct: bal ? (margin / bal) * 100 : 0, lev,
        riskUsd, profitUsd, balance: bal, afford: margin <= bal,
        candleTime: new Date(c[c.length - 1].ts).toLocaleString(),
      },
    };
  }

  window.MT5ADV.analyze = analyze;
})();
