/*
 * background.js — service worker.
 * Fetches OHLC candles from Yahoo Finance / Binance / Stooq.
 * Runs in the extension context so host_permissions bypass page CORS.
 */
"use strict";

// MT5 timeframe -> data-source interval
const YF_IV = {
  M1: "1m", M5: "5m", M15: "15m", M30: "30m",
  H1: "60m", H4: "60m", D1: "1d", W1: "1wk", MN: "1mo",
};
const BINANCE_IV = {
  M1: "1m", M5: "5m", M15: "15m", M30: "30m",
  H1: "1h", H4: "4h", D1: "1d", W1: "1w", MN: "1M",
};

const FX = new Set([
  "USD","EUR","GBP","JPY","CHF","AUD","CAD","NZD","PLN","HUF","CZK",
  "SEK","NOK","DKK","TRY","CNY","HKD","SGD","ZAR","MXN","ZAR",
]);
const CRYPTO = new Set([
  "BTC","ETH","SOL","BNB","XRP","ADA","DOGE","AVAX","DOT","MATIC",
  "LINK","UNI","ATOM","LTC","BCH","TRX",
]);
// Metals / common CFD symbols -> a usable proxy on Yahoo
const SPECIAL_YF = { XAUUSD: "GC=F", XAGUSD: "SI=F", XBRUSD: "BZ=F", XTIUSD: "CL=F" };

function cleanSymbol(raw) {
  return (raw || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
}

function isCrypto(sym) {
  const s = cleanSymbol(sym);
  for (const base of CRYPTO) {
    if (s === base + "USD" || s === base + "USDT") return true;
  }
  return false;
}

function isForex(sym) {
  const s = cleanSymbol(sym);
  return s.length === 6 && FX.has(s.slice(0, 3)) && FX.has(s.slice(3));
}

function toYahoo(sym) {
  const s = cleanSymbol(sym);
  if (SPECIAL_YF[s]) return SPECIAL_YF[s];
  if (isCrypto(s)) {
    for (const base of CRYPTO) {
      if (s === base + "USD" || s === base + "USDT") return base + "-USD";
    }
  }
  if (isForex(s)) return s + "=X";
  return s; // stock ticker
}

function toBinance(sym) {
  const s = cleanSymbol(sym);
  for (const base of CRYPTO) {
    if (s === base + "USD" || s === base + "USDT") return base + "USDT";
  }
  return s.endsWith("USDT") ? s : s + "USDT";
}

function toStooq(sym) {
  const s = cleanSymbol(sym);
  if (isForex(s)) return s.toLowerCase();
  return s.toLowerCase() + ".us"; // stocks
}

function yfRange(iv) {
  if (iv === "1m") return "5d";
  if (["5m", "15m", "30m"].includes(iv)) return "1mo";
  if (iv === "60m") return "3mo";
  if (iv === "1d") return "1y";
  if (iv === "1wk") return "5y";
  if (iv === "1mo") return "max";
  return "3mo";
}

async function fetchYahoo(symbol, timeframe) {
  const iv = YF_IV[timeframe] || "1d";
  const range = yfRange(iv);
  const ysym = encodeURIComponent(toYahoo(symbol));
  let lastErr = "невідомо";
  for (const host of ["query1.finance.yahoo.com", "query2.finance.yahoo.com"]) {
    const url =
      `https://${host}/v8/finance/chart/${ysym}` +
      `?interval=${iv}&range=${range}&includePrePost=false`;
    try {
      const r = await fetch(url);
      if (!r.ok) { lastErr = "HTTP " + r.status; continue; }
      const j = await r.json();
      const res = j && j.chart && j.chart.result && j.chart.result[0];
      if (!res) { lastErr = "порожній результат"; continue; }
      const ts = res.timestamp || [];
      const q = (res.indicators && res.indicators.quote && res.indicators.quote[0]) || {};
      const candles = [];
      for (let i = 0; i < ts.length; i++) {
        const o = q.open && q.open[i];
        const h = q.high && q.high[i];
        const l = q.low && q.low[i];
        const c = q.close && q.close[i];
        if (o == null || h == null || l == null || c == null) continue;
        if (o <= 0 || c <= 0 || h < l) continue;
        candles.push({ ts: ts[i] * 1000, open: o, high: h, low: l, close: c });
      }
      if (candles.length >= 2) return candles;
      lastErr = "немає валідних свічок";
    } catch (e) {
      lastErr = String(e.message || e).slice(0, 80);
    }
  }
  throw new Error("Yahoo: " + lastErr);
}

async function fetchBinance(symbol, timeframe) {
  const bsym = toBinance(symbol);
  const iv = BINANCE_IV[timeframe] || "1h";
  let lastErr = "невідомо";
  for (const host of ["https://api.binance.com", "https://api.binance.us"]) {
    const url = `${host}/api/v3/klines?symbol=${bsym}&interval=${iv}&limit=300`;
    try {
      const r = await fetch(url);
      if (!r.ok) { lastErr = "HTTP " + r.status; continue; }
      const data = await r.json();
      if (!Array.isArray(data) || !data.length) { lastErr = "порожня відповідь"; continue; }
      const candles = [];
      for (const k of data) {
        const o = +k[1], h = +k[2], l = +k[3], c = +k[4];
        if (o <= 0 || c <= 0 || h < l) continue;
        candles.push({ ts: +k[0], open: o, high: h, low: l, close: c });
      }
      if (candles.length >= 2) return candles;
      lastErr = "не розпарсилось";
    } catch (e) {
      lastErr = String(e.message || e).slice(0, 80);
    }
  }
  throw new Error("Binance: " + lastErr);
}

async function fetchStooq(symbol) {
  const s = encodeURIComponent(toStooq(symbol));
  const url = `https://stooq.com/q/d/l/?s=${s}&i=d`;
  const r = await fetch(url);
  if (!r.ok) throw new Error("Stooq: HTTP " + r.status);
  const text = (await r.text()).trim();
  if (!text || text[0] === "<" || /no data|exceeded/i.test(text)) {
    throw new Error("Stooq: немає даних");
  }
  const lines = text.split(/\r?\n/).slice(1);
  const candles = [];
  for (const line of lines) {
    const p = line.split(",");
    if (p.length < 5) continue;
    const o = +p[1], h = +p[2], l = +p[3], c = +p[4];
    if (!(o > 0) || !(c > 0) || h < l) continue;
    const ts = Date.parse(p[0] + "T00:00:00Z");
    if (isNaN(ts)) continue;
    candles.push({ ts, open: o, high: h, low: l, close: c });
  }
  if (!candles.length) throw new Error("Stooq: порожньо після парсингу");
  return candles;
}

async function fetchCandles(symbol, timeframe) {
  const crypto = isCrypto(symbol);
  const sources = crypto
    ? [["Yahoo", () => fetchYahoo(symbol, timeframe)], ["Binance", () => fetchBinance(symbol, timeframe)]]
    : [["Yahoo", () => fetchYahoo(symbol, timeframe)], ["Stooq", () => fetchStooq(symbol)]];

  const errors = [];
  for (const [name, fn] of sources) {
    try {
      const candles = await fn();
      if (candles && candles.length >= 2) return { candles, source: name };
    } catch (e) {
      errors.push(String(e.message || e));
    }
  }
  throw new Error(errors.join(" · ") || "Джерела даних недоступні");
}

// group N consecutive candles into one (for H4 / W1 built from H1 / D1)
function aggregate(candles, factor) {
  if (!candles || factor <= 1) return candles;
  const out = [];
  const start = candles.length % factor;
  for (let i = start; i + factor <= candles.length; i += factor) {
    const grp = candles.slice(i, i + factor);
    let hi = -Infinity, lo = Infinity;
    for (const c of grp) { if (c.high > hi) hi = c.high; if (c.low < lo) lo = c.low; }
    out.push({ ts: grp[0].ts, open: grp[0].open, high: hi, low: lo, close: grp[grp.length - 1].close });
  }
  return out;
}

// fetch a multi-timeframe bundle: M15, H1, H4, D1, W1
async function fetchMTF(symbol) {
  const crypto = isCrypto(symbol);
  const results = await Promise.allSettled([
    fetchCandles(symbol, "M15"),
    fetchCandles(symbol, "H1"),
    fetchCandles(symbol, "D1"),
  ]);
  const get = (r) => (r.status === "fulfilled" ? r.value : null);
  const m15 = get(results[0]);
  const h1 = get(results[1]);
  const d1 = get(results[2]);

  const byTF = {};
  let source = null;
  if (m15) { byTF.M15 = m15.candles; source = source || m15.source; }
  if (h1) {
    byTF.H1 = h1.candles;
    byTF.H4 = aggregate(h1.candles, 4);
    source = source || h1.source;
  }
  if (d1) {
    byTF.D1 = d1.candles;
    byTF.W1 = aggregate(d1.candles, 5);
    source = source || d1.source;
  }
  // crypto has a native 4h — prefer it over the aggregate
  if (crypto) {
    try { byTF.H4 = (await fetchCandles(symbol, "H4")).candles; } catch (e) {}
  }

  if (!Object.keys(byTF).length) {
    const errs = results.map((r) => (r.status === "rejected" ? String(r.reason && r.reason.message || r.reason) : "")).filter(Boolean);
    throw new Error(errs.join(" · ") || "Немає даних для аналізу");
  }
  return { byTF, source };
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg.type === "fetchCandles") {
    fetchCandles(msg.symbol, msg.timeframe)
      .then((res) => sendResponse(res))
      .catch((e) => sendResponse({ error: String(e.message || e) }));
    return true; // keep the message channel open for async response
  }
  if (msg && msg.type === "fetchMTF") {
    fetchMTF(msg.symbol)
      .then((res) => sendResponse(res))
      .catch((e) => sendResponse({ error: String(e.message || e) }));
    return true;
  }
});
