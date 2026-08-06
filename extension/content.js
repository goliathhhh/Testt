/*
 * content.js — injects the MT5 Web Advisor panel.
 * Multi-timeframe bias + Smart-Money-Concepts analysis with
 * structure-derived SL/TP. Advises, does NOT trade.
 */
(function () {
  "use strict";
  if (window.__mt5advLoaded) return;
  window.__mt5advLoaded = true;

  const DEFAULTS = {
    symbol: "EURUSD",
    timeframe: "H1",
    autoSymbol: true,
    balance: 3000,
    leverage: 10,
    riskPct: 3,
    atrPeriod: 14,
    pivotStrength: 2,
    autoRefresh: false,
    refreshSec: 45,
    x: null,
    y: null,
    collapsed: false,
  };

  const TF = ["M15", "H1", "H4", "D1", "W1"];        // execution timeframe
  const QUICK = ["EURUSD", "GBPUSD", "USDJPY", "AUDCAD", "BTCUSD", "ETHUSD"];

  let cfg = Object.assign({}, DEFAULTS);
  let panel, bodyEl, mtfEl, resultEl, symInput, autoBtn, refreshTimer = null, loading = false;

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
  function biasClass(b) { return b === "bull" ? "mt5adv-bull" : b === "bear" ? "mt5adv-short" : "mt5adv-neutral"; }
  function biasWord(b) { return b === "bull" ? "ВГОРУ" : b === "bear" ? "ВНИЗ" : "ЗМІШАНИЙ"; }

  function loadCfg() {
    return new Promise((resolve) => {
      try {
        chrome.storage.local.get("mt5adv", (s) => {
          if (s && s.mt5adv) cfg = Object.assign({}, DEFAULTS, s.mt5adv);
          if (TF.indexOf(cfg.timeframe) < 0) cfg.timeframe = "H1";
          resolve();
        });
      } catch (e) { resolve(); }
    });
  }
  function saveCfg() { try { chrome.storage.local.set({ mt5adv: cfg }); } catch (e) {} }

  // ── panel ────────────────────────────────────────────────
  function buildPanel() {
    panel = el("div", "mt5adv-panel");
    if (cfg.x != null && cfg.y != null) {
      panel.style.left = cfg.x + "px";
      panel.style.top = cfg.y + "px";
      panel.style.right = "auto";
    }

    const header = el("div", "mt5adv-header");
    header.appendChild(el("span", "mt5adv-title", "🧠 MT5 SMC Advisor"));
    header.appendChild(el("span", "mt5adv-spacer"));
    const btnMin = el("button", "mt5adv-icon", cfg.collapsed ? "▢" : "—");
    btnMin.title = "Згорнути"; btnMin.onclick = () => toggleCollapse();
    const btnClose = el("button", "mt5adv-icon", "✕");
    btnClose.title = "Закрити"; btnClose.onclick = () => { panel.style.display = "none"; };
    header.appendChild(btnMin); header.appendChild(btnClose);
    panel.appendChild(header);
    makeDraggable(header, panel);

    bodyEl = el("div", "mt5adv-body");
    if (cfg.collapsed) bodyEl.style.display = "none";

    // symbol row
    const symRow = el("div", "mt5adv-row");
    autoBtn = el("button", "mt5adv-btn mt5adv-autobtn", "🎯");
    autoBtn.title = "Авто: слідувати за символом графіка MT5";
    autoBtn.onclick = () => toggleAuto();
    symInput = el("input", "mt5adv-input");
    symInput.type = "text";
    symInput.value = cfg.symbol;
    symInput.placeholder = "Символ (EURUSD)";
    symInput.spellcheck = false;
    symInput.onkeydown = (ev) => { if (ev.key === "Enter") setSymbol(symInput.value); };
    const goBtn = el("button", "mt5adv-btn mt5adv-go", "▶");
    goBtn.title = "Аналізувати"; goBtn.onclick = () => setSymbol(symInput.value);
    symRow.appendChild(autoBtn); symRow.appendChild(symInput); symRow.appendChild(goBtn);
    bodyEl.appendChild(symRow);

    // quick symbols
    const quickRow = el("div", "mt5adv-quick");
    QUICK.forEach((q) => {
      const b = el("button", "mt5adv-chip", q);
      b.onclick = () => setSymbol(q);
      quickRow.appendChild(b);
    });
    bodyEl.appendChild(quickRow);

    // execution timeframe
    const tfRow = el("div", "mt5adv-tf");
    tfRow.appendChild(el("span", "mt5adv-tflabel", "Сетап:"));
    TF.forEach((tf) => {
      const b = el("button", "mt5adv-chip mt5adv-tfbtn", tf);
      b.dataset.tf = tf;
      b.onclick = () => setTF(tf);
      tfRow.appendChild(b);
    });
    bodyEl.appendChild(tfRow);

    // multi-timeframe bias strip
    mtfEl = el("div", "mt5adv-mtf");
    bodyEl.appendChild(mtfEl);

    // result
    resultEl = el("div", "mt5adv-result");
    bodyEl.appendChild(resultEl);

    // settings
    const setWrap = el("details", "mt5adv-settings");
    setWrap.appendChild(el("summary", null, "⚙️ Налаштування"));
    setWrap.appendChild(el("div", "mt5adv-sechead", "Ризик і розмір"));
    setWrap.appendChild(numField("Баланс, $", "balance", 1, 1e9, 1));
    setWrap.appendChild(numField("Плече, x", "leverage", 1, 1000, 1));
    setWrap.appendChild(numField("Ризик, %", "riskPct", 0.1, 100, 0.1));
    setWrap.appendChild(el("div", "mt5adv-sechead", "Аналіз"));
    setWrap.appendChild(numField("ATR період", "atrPeriod", 2, 100, 1));
    setWrap.appendChild(numField("Свінги (сила)", "pivotStrength", 1, 10, 1));
    bodyEl.appendChild(setWrap);

    // footer
    const footer = el("div", "mt5adv-footer");
    const autoLbl = el("label", "mt5adv-auto");
    const chk = el("input"); chk.type = "checkbox"; chk.checked = cfg.autoRefresh;
    chk.onchange = () => { cfg.autoRefresh = chk.checked; saveCfg(); setupAuto(); };
    autoLbl.appendChild(chk);
    autoLbl.appendChild(document.createTextNode(" авто 45с"));
    footer.appendChild(autoLbl);
    const upd = el("button", "mt5adv-btn", "🔄 Аналіз");
    upd.onclick = () => refresh();
    footer.appendChild(upd);
    bodyEl.appendChild(footer);

    bodyEl.appendChild(el("div", "mt5adv-disclaimer",
      "💡 SMC-аналіз по свічках (без ордерфлоу). Підказка, не порада й не гарантія. Рішення — за тобою."));

    panel.appendChild(bodyEl);
    document.body.appendChild(panel);

    updateTFButtons();
    setupAuto();
  }

  function numField(label, key, lo, hi, step) {
    const row = el("div", "mt5adv-field");
    row.appendChild(el("span", "mt5adv-flabel", label));
    const inp = el("input", "mt5adv-num");
    inp.type = "number"; inp.min = lo; inp.max = hi; inp.step = step; inp.value = cfg[key];
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

  function setSymbol(sym, manual) {
    if (manual === undefined) manual = true;
    const s = (sym || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
    if (!s) return;
    cfg.symbol = s;
    if (symInput) symInput.value = s;
    if (manual) cfg.autoSymbol = false;
    saveCfg(); updateAutoBtn(); refresh();
  }
  function setTF(tf) { cfg.timeframe = tf; saveCfg(); updateTFButtons(); refresh(); }
  function toggleCollapse() {
    cfg.collapsed = !cfg.collapsed;
    bodyEl.style.display = cfg.collapsed ? "none" : "block";
    saveCfg();
  }
  function setupAuto() {
    if (refreshTimer) { clearInterval(refreshTimer); refreshTimer = null; }
    if (cfg.autoRefresh) refreshTimer = setInterval(refresh, Math.max(20, cfg.refreshSec) * 1000);
  }

  // ── auto-detect chart symbol ─────────────────────────────
  function detectChartSymbol() {
    const t = (document.title || "").toUpperCase();
    let m = t.match(/\b([A-Z]{6})\b[ ,]*(?:M1|M5|M15|M30|H1|H4|D1|W1|MN)\b/);
    if (m) return m[1];
    m = t.match(/\b([A-Z]{3,10}(?:USDT|USD))\b/);
    if (m) return m[1];
    m = t.match(/\b([A-Z]{6})\b/);
    if (m) return m[1];
    return null;
  }
  function updateAutoBtn() { if (autoBtn) autoBtn.classList.toggle("active", !!cfg.autoSymbol); }
  function toggleAuto() {
    cfg.autoSymbol = !cfg.autoSymbol;
    saveCfg(); updateAutoBtn();
    if (cfg.autoSymbol) {
      const s = detectChartSymbol();
      if (s && s !== cfg.symbol) { cfg.symbol = s; if (symInput) symInput.value = s; saveCfg(); }
      refresh();
    }
  }
  function autoDetectTick() {
    if (!cfg.autoSymbol) return;
    const s = detectChartSymbol();
    if (s && s !== cfg.symbol) {
      cfg.symbol = s; if (symInput) symInput.value = s; saveCfg(); refresh();
    }
  }

  // ── data + rendering ─────────────────────────────────────
  async function refresh() {
    if (loading) return;
    loading = true;
    renderLoading();
    try {
      const resp = await chrome.runtime.sendMessage({ type: "fetchMTF", symbol: cfg.symbol });
      if (!resp || resp.error) { renderError((resp && resp.error) || "Немає відповіді"); return; }
      const a = window.MT5ADV.analyze(resp.byTF, cfg.timeframe, cfg);
      renderMTF(a.mtf, a.overall, resp.source);
      renderExec(a.exec);
    } catch (e) {
      renderError(String(e.message || e));
    } finally {
      loading = false;
    }
  }

  function renderLoading() {
    mtfEl.innerHTML = "";
    resultEl.innerHTML = "";
    resultEl.appendChild(el("div", "mt5adv-loading", "⏳ Читаю таймфрейми…"));
  }
  function renderError(msg) {
    mtfEl.innerHTML = "";
    resultEl.innerHTML = "";
    const box = el("div", "mt5adv-card mt5adv-err");
    box.appendChild(el("div", "mt5adv-badge", "❌ Помилка"));
    box.appendChild(el("div", "mt5adv-line", msg));
    box.appendChild(el("div", "mt5adv-line mt5adv-dim", "Спробуй інший символ або повтори за хвилину."));
    resultEl.appendChild(box);
  }

  function renderMTF(mtf, overall, source) {
    mtfEl.innerHTML = "";
    const head = el("div", "mt5adv-mtfhead");
    head.appendChild(el("span", null, (cfg.autoSymbol ? "🎯 " : "") + cfg.symbol));
    head.appendChild(el("span", "mt5adv-dim", source ? "джерело: " + source : ""));
    mtfEl.appendChild(head);

    const strip = el("div", "mt5adv-mtfstrip");
    (mtf || []).forEach((m) => {
      const cell = el("div", "mt5adv-tfcell " + biasClass(m.bias));
      cell.appendChild(el("div", "mt5adv-tfname", m.tf));
      cell.appendChild(el("div", "mt5adv-tfarrow", m.bias === "bull" ? "▲" : m.bias === "bear" ? "▼" : "◆"));
      cell.title = m.tf + ": " + biasWord(m.bias);
      strip.appendChild(cell);
    });
    mtfEl.appendChild(strip);

    const ov = el("div", "mt5adv-overall " + biasClass(overall));
    ov.textContent = "HTF ухил: " + biasWord(overall);
    mtfEl.appendChild(ov);
  }

  function line(label, value, valueClass) {
    const r = el("div", "mt5adv-line");
    r.appendChild(el("span", "mt5adv-k", label));
    r.appendChild(el("span", "mt5adv-v" + (valueClass ? " " + valueClass : ""), value));
    return r;
  }

  function renderExec(ex) {
    resultEl.innerHTML = "";
    const card = el("div", "mt5adv-card");
    card.appendChild(el("div", "mt5adv-meta", "Сетап на " + cfg.timeframe));

    if (ex.status === "error") { renderError(ex.message); return; }

    if (ex.structure) card.appendChild(line("Структура", ex.structure));
    if (ex.rsi != null) card.appendChild(line("RSI(14)", ex.rsi.toFixed(1)));
    if (ex.atr != null) card.appendChild(line("ATR", fmtPrice(ex.atr)));

    if (ex.status === "wait") {
      card.appendChild(el("div", "mt5adv-badge mt5adv-wait", "⏳ ЧЕКАЙ"));
      card.appendChild(el("div", "mt5adv-line", ex.message || "Немає чіткого сетапу"));
      resultEl.appendChild(card);
      return;
    }

    // setup
    const isLong = ex.side === "LONG";
    card.appendChild(el("div", "mt5adv-badge " + (isLong ? "mt5adv-long" : "mt5adv-short"),
      (isLong ? "📈 Ідея: LONG" : "📉 Ідея: SHORT")));

    if (ex.sweep) card.appendChild(line("Liquidity sweep", ex.sweep));

    card.appendChild(line("🎯 Вхід (зона)", fmtPrice(ex.entry), "mt5adv-strong"));
    card.appendChild(line("🛑 Stop-Loss", fmtPrice(ex.sl) + "  (-" + ex.slPct.toFixed(2) + "%)", "mt5adv-red"));
    card.appendChild(line("✅ TP1", fmtPrice(ex.tp1) + "  (+" + ex.tp1Pct.toFixed(2) + "%)", "mt5adv-green"));
    card.appendChild(line("✅ TP2", fmtPrice(ex.tp2) + "  (+" + ex.tp2Pct.toFixed(2) + "%)", "mt5adv-green"));
    card.appendChild(line("⚖️ RR", "1:" + ex.rr1 + "  /  1:" + ex.rr2));

    if (ex.reasons && ex.reasons.length) {
      const why = el("div", "mt5adv-reasons");
      why.appendChild(el("div", "mt5adv-sechead", "Чому"));
      ex.reasons.forEach((r) => why.appendChild(el("div", "mt5adv-reason", "• " + r)));
      card.appendChild(why);
    }

    card.appendChild(el("div", "mt5adv-hr"));
    card.appendChild(line("💼 Розмір позиції", money(ex.notional)));
    card.appendChild(line("⚙️ Маржа (" + ex.lev + "x)", money(ex.margin) + "  (" + Math.round(ex.marginPct) + "%)"));
    card.appendChild(line("🔻 Ризик на SL", money(ex.riskUsd)));
    card.appendChild(line("🎯 Потенціал до TP1", money(ex.profitUsd), "mt5adv-green"));
    if (!ex.afford) card.appendChild(el("div", "mt5adv-line mt5adv-red",
      "⚠️ Маржа більша за баланс — зменш ризик або підвищ плече."));

    card.appendChild(el("div", "mt5adv-line mt5adv-dim", "Свічка: " + ex.candleTime));
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

  chrome.runtime.onMessage.addListener((m) => {
    if (m && m.type === "togglePanel") {
      panel.style.display = panel.style.display === "none" ? "block" : "none";
    }
  });

  // ── init ─────────────────────────────────────────────────
  loadCfg().then(() => {
    buildPanel();
    updateAutoBtn();
    if (cfg.autoSymbol) {
      const s = detectChartSymbol();
      if (s) { cfg.symbol = s; if (symInput) symInput.value = s; }
    }
    refresh();
    setInterval(autoDetectTick, 2500);
  });
})();
