/*
 * content.js — injects a floating advisor panel into the MT5 web terminal.
 * The panel suggests LONG/SHORT + SL/TP + position size. It does NOT trade.
 */
(function () {
  "use strict";
  if (window.__mt5advLoaded) return;
  window.__mt5advLoaded = true;

  const DEFAULTS = {
    symbol: "EURUSD",
    timeframe: "M15",
    balance: 3000,
    leverage: 10,
    riskPct: 3,
    atrPeriod: 14,
    tpAtrMult: 3,
    swingLookback: 10,
    rsiPeriod: 7,
    emaPeriod: 9,
    overbought: 70,
    oversold: 35,
    autoRefresh: false,
    refreshSec: 30,
    x: null,
    y: null,
    collapsed: false,
  };

  const TF = ["M5", "M15", "M30", "H1", "H4", "D1"];
  const QUICK = ["EURUSD", "GBPUSD", "USDJPY", "AUDCAD", "BTCUSD", "ETHUSD"];

  let cfg = Object.assign({}, DEFAULTS);
  let panel, bodyEl, resultEl, symInput, refreshTimer = null, loading = false;

  // ── helpers ──────────────────────────────────────────────
  function fmtPrice(p) {
    if (p == null || isNaN(p)) return "—";
    const a = Math.abs(p);
    const d = a >= 1000 ? 2 : a >= 100 ? 3 : a >= 1 ? 5 : a >= 0.1 ? 5 : a >= 0.001 ? 6 : 8;
    return p.toFixed(d);
  }
  function money(x) {
    if (x == null || isNaN(x)) return "—";
    if (Math.abs(x) < 1 && x !== 0) return "$" + x.toFixed(2);
    return "$" + Math.round(x).toLocaleString("en-US");
  }
  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  function loadCfg() {
    return new Promise((resolve) => {
      try {
        chrome.storage.local.get("mt5adv", (s) => {
          if (s && s.mt5adv) cfg = Object.assign({}, DEFAULTS, s.mt5adv);
          resolve();
        });
      } catch (e) { resolve(); }
    });
  }
  function saveCfg() {
    try { chrome.storage.local.set({ mt5adv: cfg }); } catch (e) {}
  }

  // ── panel construction ───────────────────────────────────
  function buildPanel() {
    panel = el("div", "mt5adv-panel");
    if (cfg.x != null && cfg.y != null) {
      panel.style.left = cfg.x + "px";
      panel.style.top = cfg.y + "px";
      panel.style.right = "auto";
    }

    // header
    const header = el("div", "mt5adv-header");
    header.appendChild(el("span", "mt5adv-title", "📊 MT5 Advisor"));
    const spacer = el("span", "mt5adv-spacer");
    header.appendChild(spacer);
    const btnMin = el("button", "mt5adv-icon", cfg.collapsed ? "▢" : "—");
    btnMin.title = "Згорнути";
    btnMin.onclick = () => toggleCollapse();
    const btnClose = el("button", "mt5adv-icon", "✕");
    btnClose.title = "Закрити";
    btnClose.onclick = () => { panel.style.display = "none"; };
    header.appendChild(btnMin);
    header.appendChild(btnClose);
    panel.appendChild(header);
    makeDraggable(header, panel);

    // body
    bodyEl = el("div", "mt5adv-body");
    if (cfg.collapsed) bodyEl.style.display = "none";

    // symbol row
    const symRow = el("div", "mt5adv-row");
    symInput = el("input", "mt5adv-input");
    symInput.type = "text";
    symInput.value = cfg.symbol;
    symInput.placeholder = "Символ (EURUSD)";
    symInput.spellcheck = false;
    symInput.onkeydown = (ev) => {
      if (ev.key === "Enter") setSymbol(symInput.value);
    };
    const goBtn = el("button", "mt5adv-btn mt5adv-go", "▶");
    goBtn.title = "Розрахувати";
    goBtn.onclick = () => setSymbol(symInput.value);
    symRow.appendChild(symInput);
    symRow.appendChild(goBtn);
    bodyEl.appendChild(symRow);

    // quick symbols
    const quickRow = el("div", "mt5adv-quick");
    QUICK.forEach((q) => {
      const b = el("button", "mt5adv-chip", q);
      b.onclick = () => setSymbol(q);
      quickRow.appendChild(b);
    });
    bodyEl.appendChild(quickRow);

    // timeframe row
    const tfRow = el("div", "mt5adv-tf");
    TF.forEach((tf) => {
      const b = el("button", "mt5adv-chip mt5adv-tfbtn", tf);
      b.dataset.tf = tf;
      b.onclick = () => setTF(tf);
      tfRow.appendChild(b);
    });
    bodyEl.appendChild(tfRow);

    // result area
    resultEl = el("div", "mt5adv-result");
    bodyEl.appendChild(resultEl);

    // settings (collapsible)
    const setWrap = el("details", "mt5adv-settings");
    const sum = el("summary", null, "⚙️ Налаштування");
    setWrap.appendChild(sum);
    setWrap.appendChild(el("div", "mt5adv-sechead", "Ризик і розмір"));
    setWrap.appendChild(numField("Баланс, $", "balance", 1, 1e9, 1));
    setWrap.appendChild(numField("Плече, x", "leverage", 1, 1000, 1));
    setWrap.appendChild(numField("Ризик, %", "riskPct", 0.1, 100, 0.1));
    setWrap.appendChild(el("div", "mt5adv-sechead", "Рівні (авто, за ринком)"));
    setWrap.appendChild(numField("ATR період", "atrPeriod", 2, 100, 1));
    setWrap.appendChild(numField("TP = × ATR", "tpAtrMult", 0.5, 10, 0.5));
    setWrap.appendChild(numField("Свінг, барів", "swingLookback", 3, 100, 1));
    bodyEl.appendChild(setWrap);

    // footer
    const footer = el("div", "mt5adv-footer");
    const autoLbl = el("label", "mt5adv-auto");
    const chk = el("input");
    chk.type = "checkbox";
    chk.checked = cfg.autoRefresh;
    chk.onchange = () => { cfg.autoRefresh = chk.checked; saveCfg(); setupAuto(); };
    autoLbl.appendChild(chk);
    autoLbl.appendChild(document.createTextNode(" авто-оновл. 30с"));
    footer.appendChild(autoLbl);
    const upd = el("button", "mt5adv-btn", "🔄 Оновити");
    upd.onclick = () => refresh();
    footer.appendChild(upd);
    bodyEl.appendChild(footer);

    bodyEl.appendChild(el("div", "mt5adv-disclaimer",
      "💡 Підказка з аналізу ринку, не стратегія заробітку й не фінансова порада. Рівні SL/TP — орієнтовні, рахуються за волатильністю. Рішення — за тобою."));

    panel.appendChild(bodyEl);
    document.body.appendChild(panel);

    updateTFButtons();
    setupAuto();
  }

  function numField(label, key, lo, hi, step) {
    const row = el("div", "mt5adv-field");
    row.appendChild(el("span", "mt5adv-flabel", label));
    const inp = el("input", "mt5adv-num");
    inp.type = "number";
    inp.min = lo; inp.max = hi; inp.step = step;
    inp.value = cfg[key];
    inp.onchange = () => {
      let v = parseFloat(inp.value);
      if (isNaN(v)) { inp.value = cfg[key]; return; }
      v = Math.max(lo, Math.min(hi, v));
      cfg[key] = v; inp.value = v; saveCfg(); refresh();
    };
    row.appendChild(inp);
    return row;
  }

  function updateTFButtons() {
    panel.querySelectorAll(".mt5adv-tfbtn").forEach((b) => {
      b.classList.toggle("active", b.dataset.tf === cfg.timeframe);
    });
  }

  function setSymbol(sym) {
    const s = (sym || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
    if (!s) return;
    cfg.symbol = s;
    if (symInput) symInput.value = s;
    saveCfg();
    refresh();
  }
  function setTF(tf) {
    cfg.timeframe = tf;
    saveCfg();
    updateTFButtons();
    refresh();
  }
  function toggleCollapse() {
    cfg.collapsed = !cfg.collapsed;
    bodyEl.style.display = cfg.collapsed ? "none" : "block";
    saveCfg();
  }
  function setupAuto() {
    if (refreshTimer) { clearInterval(refreshTimer); refreshTimer = null; }
    if (cfg.autoRefresh) {
      refreshTimer = setInterval(refresh, Math.max(10, cfg.refreshSec) * 1000);
    }
  }

  // ── data + rendering ─────────────────────────────────────
  async function refresh() {
    if (loading) return;
    loading = true;
    renderLoading();
    try {
      const resp = await chrome.runtime.sendMessage({
        type: "fetchCandles", symbol: cfg.symbol, timeframe: cfg.timeframe,
      });
      if (!resp || resp.error) {
        renderError((resp && resp.error) || "Немає відповіді від фону");
        return;
      }
      const sig = window.MT5ADV.getSignal(resp.candles, cfg);
      renderSignal(sig, resp.source);
    } catch (e) {
      renderError(String(e.message || e));
    } finally {
      loading = false;
    }
  }

  function renderLoading() {
    resultEl.innerHTML = "";
    resultEl.appendChild(el("div", "mt5adv-loading", "⏳ Завантаження…"));
  }
  function renderError(msg) {
    resultEl.innerHTML = "";
    const box = el("div", "mt5adv-card mt5adv-err");
    box.appendChild(el("div", "mt5adv-badge", "❌ Помилка"));
    box.appendChild(el("div", "mt5adv-line", msg));
    box.appendChild(el("div", "mt5adv-line mt5adv-dim",
      "Спробуй інший символ/таймфрейм або повтори за хвилину."));
    resultEl.appendChild(box);
  }

  function line(label, value, valueClass) {
    const r = el("div", "mt5adv-line");
    r.appendChild(el("span", "mt5adv-k", label));
    r.appendChild(el("span", "mt5adv-v" + (valueClass ? " " + valueClass : ""), value));
    return r;
  }

  function rsiLabel(rsi) {
    if (rsi >= 70) return "🔴 перекуплено";
    if (rsi <= 30) return "🔵 перепродано";
    if (rsi >= 55) return "🟡 сильний";
    if (rsi <= 45) return "🟡 слабкий";
    return "🟢 нейтральний";
  }

  function renderSignal(sig, source) {
    resultEl.innerHTML = "";
    const card = el("div", "mt5adv-card");

    if (sig.status === "error") { renderError(sig.message); return; }

    // header line: symbol + tf + source
    const meta = el("div", "mt5adv-meta");
    meta.appendChild(el("span", null, cfg.symbol + " · " + cfg.timeframe));
    meta.appendChild(el("span", "mt5adv-dim", source ? "джерело: " + source : ""));
    card.appendChild(meta);

    if (sig.status === "wait") {
      card.appendChild(el("div", "mt5adv-badge mt5adv-wait", "⏳ ЧЕКАЙ"));
      card.appendChild(el("div", "mt5adv-line", sig.message));
      resultEl.appendChild(card);
      return;
    }

    // indicators
    if (sig.ema != null) {
      const dir = sig.price > sig.ema ? "↑ вище" : "↓ нижче";
      card.appendChild(line("EMA(" + cfg.emaPeriod + ")", fmtPrice(sig.ema) + "  " + dir));
    }
    if (sig.rsi != null) {
      card.appendChild(line("RSI(" + cfg.rsiPeriod + ")", sig.rsi.toFixed(1) + "  " + rsiLabel(sig.rsi)));
    }
    if (sig.atr != null) {
      card.appendChild(line("ATR(" + cfg.atrPeriod + ")", fmtPrice(sig.atr) + "  (волатильність)"));
    }

    if (sig.status === "blocked") {
      card.appendChild(el("div", "mt5adv-badge mt5adv-wait", "🚫 СИГНАЛ ЗАБЛОКОВАНО"));
      card.appendChild(el("div", "mt5adv-line", sig.reason));
      card.appendChild(el("div", "mt5adv-line mt5adv-dim", "Дія: ЧЕКАЙ"));
      resultEl.appendChild(card);
      return;
    }

    // market bias hint (not an instruction to trade)
    const isLong = sig.side === "LONG";
    const badge = el("div", "mt5adv-badge " + (isLong ? "mt5adv-long" : "mt5adv-short"),
      (isLong ? "📈 Ухил: LONG" : "📉 Ухил: SHORT"));
    card.appendChild(badge);

    card.appendChild(line("🎯 Орієнтир входу", fmtPrice(sig.price), "mt5adv-strong"));
    card.appendChild(line("🛑 Stop-Loss", fmtPrice(sig.slPrice) + "  (-" + sig.slPct.toFixed(2) + "%)", "mt5adv-red"));
    card.appendChild(line("✅ Take-Profit", fmtPrice(sig.tpPrice) + "  (+" + sig.tpPct.toFixed(2) + "%)", "mt5adv-green"));
    card.appendChild(line("⚖️ RR (плаваючий)", "1:" + sig.rr));
    card.appendChild(el("div", "mt5adv-line mt5adv-dim",
      "SL: свінг(" + cfg.swingLookback + ") + ATR · TP: " + sig.tpMult + "× ATR"));

    const hr = el("div", "mt5adv-hr");
    card.appendChild(hr);

    card.appendChild(line("💼 Розмір позиції", money(sig.notional)));
    card.appendChild(line("⚙️ Маржа (" + sig.lev + "x)", money(sig.margin) + "  (" + Math.round(sig.marginPct) + "%)"));
    card.appendChild(line("🔻 Ризик на SL", money(sig.riskUsd)));
    card.appendChild(line("🎯 Потенціал до TP", money(sig.profitUsd), "mt5adv-green"));

    if (!sig.afford) {
      card.appendChild(el("div", "mt5adv-line mt5adv-red",
        "⚠️ Маржа більша за баланс — зменш ризик або підвищ плече."));
    }

    card.appendChild(el("div", "mt5adv-line mt5adv-dim", "Свічка: " + sig.candleTime));
    resultEl.appendChild(card);
  }

  // ── dragging ─────────────────────────────────────────────
  function makeDraggable(handle, target) {
    let sx, sy, ox, oy, dragging = false;
    handle.addEventListener("mousedown", (e) => {
      if (e.target.classList.contains("mt5adv-icon")) return;
      dragging = true;
      const rect = target.getBoundingClientRect();
      sx = e.clientX; sy = e.clientY; ox = rect.left; oy = rect.top;
      target.style.right = "auto";
      document.addEventListener("mousemove", onMove);
      document.addEventListener("mouseup", onUp);
      e.preventDefault();
    });
    function onMove(e) {
      if (!dragging) return;
      const nx = Math.max(0, Math.min(window.innerWidth - 60, ox + e.clientX - sx));
      const ny = Math.max(0, Math.min(window.innerHeight - 30, oy + e.clientY - sy));
      target.style.left = nx + "px";
      target.style.top = ny + "px";
    }
    function onUp() {
      dragging = false;
      cfg.x = parseInt(target.style.left, 10);
      cfg.y = parseInt(target.style.top, 10);
      saveCfg();
      document.removeEventListener("mousemove", onMove);
      document.removeEventListener("mouseup", onUp);
    }
  }

  // toolbar popup can toggle the panel
  chrome.runtime.onMessage.addListener((m) => {
    if (m && m.type === "togglePanel") {
      panel.style.display = panel.style.display === "none" ? "block" : "none";
    }
  });

  // ── init ─────────────────────────────────────────────────
  loadCfg().then(() => {
    buildPanel();
    refresh();
  });
})();
