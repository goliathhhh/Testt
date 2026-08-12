//+------------------------------------------------------------------+
//|                                       MultiSymbol_ScannerBot.mq5  |
//|      Multi-symbol trend scanner & trader for MetaTrader 5         |
//|                                                                  |
//|  What it does:                                                    |
//|   - Scans MANY symbols (Market Watch or a custom list) every      |
//|     20 seconds from a single chart.                               |
//|   - Scores each symbol by trend quality:                          |
//|       ADX strength + EMA separation (in ATR units) +              |
//|       higher-timeframe direction agreement.                       |
//|   - Opens positions only on the BEST-scoring setups               |
//|     (up to InpMaxPositions symbols at once).                      |
//|   - Holds as long as the trend lives: exits on trend flip,        |
//|     ATR trailing stop, or a hard max-hold (default 72h) —         |
//|     so trades naturally last from hours to days.                  |
//|                                                                  |
//|  Risk management:                                                 |
//|   - Risk % per trade with ATR stop, margin-fit lot sizing         |
//|     (leverage-agnostic via OrderCalcMargin).                      |
//|   - Daily loss limit: stops opening new trades for the day.       |
//|   - Break-even move + ATR trailing.                               |
//|   - Friday evening flat option (no weekend gaps).                 |
//|                                                                  |
//|  NOTE: No bot can guarantee profit. Scoring only prioritizes      |
//|  the strongest trends available. Test on DEMO.                    |
//+------------------------------------------------------------------+
#property copyright "MultiSymbol ScannerBot"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//--- Inputs -------------------------------------------------------------------
input group "=== General ==="
input long   InpMagic          = 20250812;   // Magic number
input string InpComment        = "Scanner";  // Order comment
input int    InpSlippage       = 20;         // Max slippage (points)

input group "=== Symbols ==="
input string InpSymbols        = "AUTO";     // "AUTO" = Market Watch, or comma list (EURUSD,GBPUSD,...)
input int    InpMaxScan        = 20;         // Max symbols to scan (AUTO mode)

input group "=== Signal / Scoring ==="
input ENUM_TIMEFRAMES InpTF    = PERIOD_H1;  // Working timeframe
input ENUM_TIMEFRAMES InpHTF   = PERIOD_H4;  // Higher timeframe (confirmation)
input int    InpEmaFast        = 12;         // Fast EMA
input int    InpEmaSlow        = 48;         // Slow EMA
input int    InpAdxPeriod      = 14;         // ADX period
input double InpAdxMin         = 22.0;       // Min ADX (trend strength)
input double InpMinScore       = 30.0;       // Min score to enter
input bool   InpRequireHTF     = true;       // Require HTF direction agreement

input group "=== Risk ==="
input double InpRiskPercent    = 1.0;        // Risk % of balance per trade
input int    InpMaxPositions   = 3;          // Max simultaneous positions (symbols)
input double InpMaxMarginUse   = 25.0;       // Max % of free margin per position
input double InpMaxLot         = 5.0;        // Hard lot cap
input double InpMaxDailyLoss   = 3.0;        // Daily loss limit % (0 = off)

input group "=== Stops / Exits ==="
input int    InpAtrPeriod      = 14;         // ATR period
input double InpSlAtrMult      = 2.5;        // Stop-Loss = ATR x
input double InpTpAtrMult      = 0.0;        // Take-Profit = ATR x (0 = trend/trailing exit)
input bool   InpUseTrailing    = true;       // ATR trailing stop
input double InpTrailStartAtr  = 1.2;        // Start trailing after profit >= ATR x
input double InpTrailAtr       = 2.0;        // Trailing distance = ATR x
input bool   InpUseBreakEven   = true;       // Move SL to break-even
input double InpBreakEvenAtr   = 1.0;        // ...after profit >= ATR x
input bool   InpExitOnFlip     = true;       // Close when trend flips
input double InpMaxHoldHours   = 72.0;       // Hard max holding time (hours, 72 = 3 days)
input int    InpCooldownMin    = 60;         // Cooldown after closing on a symbol (min)

input group "=== Filters ==="
input double InpMaxSpreadAtr   = 0.15;       // Max spread as fraction of ATR
input bool   InpFridayFlat     = true;       // Close everything Friday evening
input int    InpFridayHour     = 21;         // Friday flat hour (server time)

//--- Symbol table -------------------------------------------------------------
struct SymInfo
  {
   string            name;
   int               emaFastH;
   int               emaSlowH;
   int               emaFastHtf;
   int               emaSlowHtf;
   int               adxH;
   int               atrH;
   datetime          lastClose;   // for cooldown
   bool              ok;
  };

struct Candidate
  {
   int               idx;         // index into g_syms
   int               dir;         // +1 / -1
   double            score;
   double            atr;
  };

CTrade    trade;
SymInfo   g_syms[];
double    g_dayStartBal = 0.0;
int       g_lastDay     = -1;
bool      g_dailyStopLogged = false;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpEmaFast >= InpEmaSlow)
     {
      Print("ERROR: Fast EMA must be shorter than slow EMA.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(!BuildSymbolTable())
     {
      Print("ERROR: no tradable symbols found.");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetMarginMode();

   g_dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   g_lastDay = dt.day;

   EventSetTimer(20);   // scan every 20 seconds
   PrintFormat("ScannerBot started: %d symbols, TF=%s, max positions=%d",
               ArraySize(g_syms), EnumToString(InpTF), InpMaxPositions);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   Comment("");
   for(int i = 0; i < ArraySize(g_syms); i++)
     {
      if(g_syms[i].emaFastH  != INVALID_HANDLE) IndicatorRelease(g_syms[i].emaFastH);
      if(g_syms[i].emaSlowH  != INVALID_HANDLE) IndicatorRelease(g_syms[i].emaSlowH);
      if(g_syms[i].emaFastHtf!= INVALID_HANDLE) IndicatorRelease(g_syms[i].emaFastHtf);
      if(g_syms[i].emaSlowHtf!= INVALID_HANDLE) IndicatorRelease(g_syms[i].emaSlowHtf);
      if(g_syms[i].adxH      != INVALID_HANDLE) IndicatorRelease(g_syms[i].adxH);
      if(g_syms[i].atrH      != INVALID_HANDLE) IndicatorRelease(g_syms[i].atrH);
     }
  }

//+------------------------------------------------------------------+
void OnTick()  { /* work is done in OnTimer */ }

//+------------------------------------------------------------------+
void OnTimer()
  {
   CheckNewDay();
   MarkRecentCloses();
   ManagePositions();

   bool weekendFlat = IsWeekendFlatTime();
   if(weekendFlat)
     {
      CloseAllByMagic("weekend flat");
      UpdateComment("Вихідні/п'ятниця вечір — все закрито, нових угод немає.");
      return;
     }

   if(DailyLossHit())
     {
      if(!g_dailyStopLogged)
        {
         Print("Daily loss limit hit — no new trades today.");
         g_dailyStopLogged = true;
        }
      UpdateComment("⛔ Денний ліміт збитку — нові угоди до завтра не відкриваються.");
      return;
     }

   //--- collect candidates
   Candidate cands[];
   int nc = 0;
   ArrayResize(cands, ArraySize(g_syms));

   for(int i = 0; i < ArraySize(g_syms); i++)
     {
      if(!g_syms[i].ok) continue;
      if(HasPosition(g_syms[i].name)) continue;
      if(TimeCurrent() - g_syms[i].lastClose < (datetime)(InpCooldownMin * 60)) continue;

      int dir; double score, atr;
      if(!ScoreSymbol(i, dir, score, atr)) continue;
      if(score < InpMinScore) continue;

      cands[nc].idx = i; cands[nc].dir = dir; cands[nc].score = score; cands[nc].atr = atr;
      nc++;
     }
   ArrayResize(cands, nc);

   //--- sort by score, descending (simple insertion sort — nc is small)
   for(int a = 1; a < nc; a++)
     {
      Candidate key = cands[a];
      int b = a - 1;
      while(b >= 0 && cands[b].score < key.score) { cands[b + 1] = cands[b]; b--; }
      cands[b + 1] = key;
     }

   //--- open best candidates while slots remain
   int open = CountPositions();
   for(int k = 0; k < nc && open < InpMaxPositions; k++)
     {
      if(OpenPosition(cands[k].idx, cands[k].dir, cands[k].atr, cands[k].score))
         open++;
     }

   //--- status on chart
   string top = "";
   for(int k = 0; k < MathMin(nc, 5); k++)
      top += StringFormat("  %s %s score %.1f\n",
             g_syms[cands[k].idx].name, (cands[k].dir > 0 ? "LONG" : "SHORT"), cands[k].score);
   UpdateComment(StringFormat("Позиції: %d/%d | Кандидати: %d\n%s", open, InpMaxPositions, nc, top));
  }

//+------------------------------------------------------------------+
//| Build the list of symbols to scan                                |
//+------------------------------------------------------------------+
bool BuildSymbolTable()
  {
   string names[];
   int n = 0;

   string src = InpSymbols;
   StringTrimLeft(src); StringTrimRight(src);

   if(src == "AUTO" || src == "auto" || src == "")
     {
      int total = SymbolsTotal(true);   // Market Watch
      for(int i = 0; i < total && n < InpMaxScan; i++)
        {
         string s = SymbolName(i, true);
         if(SymbolInfoInteger(s, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL) continue;
         ArrayResize(names, n + 1);
         names[n++] = s;
        }
     }
   else
     {
      string parts[];
      int cnt = StringSplit(src, ',', parts);
      for(int i = 0; i < cnt; i++)
        {
         string s = parts[i];
         StringTrimLeft(s); StringTrimRight(s);
         if(s == "") continue;
         if(!SymbolSelect(s, true)) { PrintFormat("WARN: cannot select %s", s); continue; }
         if(SymbolInfoInteger(s, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL) continue;
         ArrayResize(names, n + 1);
         names[n++] = s;
        }
     }

   if(n == 0) return(false);

   ArrayResize(g_syms, n);
   for(int i = 0; i < n; i++)
     {
      g_syms[i].name       = names[i];
      g_syms[i].lastClose  = 0;
      g_syms[i].emaFastH   = iMA(names[i], InpTF,  InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
      g_syms[i].emaSlowH   = iMA(names[i], InpTF,  InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
      g_syms[i].emaFastHtf = iMA(names[i], InpHTF, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
      g_syms[i].emaSlowHtf = iMA(names[i], InpHTF, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
      g_syms[i].adxH       = iADX(names[i], InpTF, InpAdxPeriod);
      g_syms[i].atrH       = iATR(names[i], InpTF, InpAtrPeriod);
      g_syms[i].ok = (g_syms[i].emaFastH   != INVALID_HANDLE &&
                      g_syms[i].emaSlowH   != INVALID_HANDLE &&
                      g_syms[i].emaFastHtf != INVALID_HANDLE &&
                      g_syms[i].emaSlowHtf != INVALID_HANDLE &&
                      g_syms[i].adxH       != INVALID_HANDLE &&
                      g_syms[i].atrH       != INVALID_HANDLE);
      if(!g_syms[i].ok)
         PrintFormat("WARN: indicator handles failed for %s — skipped", names[i]);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Read one value from an indicator buffer (closed bar)             |
//+------------------------------------------------------------------+
double Buf(int handle, int shift = 1, int bufIdx = 0)
  {
   double b[];
   if(CopyBuffer(handle, bufIdx, shift, 1, b) < 1) return(EMPTY_VALUE);
   return(b[0]);
  }

//+------------------------------------------------------------------+
//| Score a symbol: returns direction, score, atr                    |
//+------------------------------------------------------------------+
bool ScoreSymbol(int i, int &dir, double &score, double &atr)
  {
   double ef  = Buf(g_syms[i].emaFastH);
   double es  = Buf(g_syms[i].emaSlowH);
   double adx = Buf(g_syms[i].adxH);
   atr        = Buf(g_syms[i].atrH);

   if(ef == EMPTY_VALUE || es == EMPTY_VALUE || adx == EMPTY_VALUE ||
      atr == EMPTY_VALUE || atr <= 0)
      return(false);

   dir = (ef > es) ? 1 : (ef < es ? -1 : 0);
   if(dir == 0) return(false);
   if(adx < InpAdxMin) return(false);

   //--- spread filter (relative to volatility)
   double point  = SymbolInfoDouble(g_syms[i].name, SYMBOL_POINT);
   double spread = (double)SymbolInfoInteger(g_syms[i].name, SYMBOL_SPREAD) * point;
   if(spread > InpMaxSpreadAtr * atr) return(false);

   //--- higher-timeframe agreement
   double efh = Buf(g_syms[i].emaFastHtf);
   double esh = Buf(g_syms[i].emaSlowHtf);
   int htfDir = 0;
   if(efh != EMPTY_VALUE && esh != EMPTY_VALUE)
      htfDir = (efh > esh) ? 1 : (efh < esh ? -1 : 0);
   if(InpRequireHTF && htfDir != dir) return(false);

   //--- score: trend strength + EMA separation in ATR units + HTF bonus
   double sep = MathAbs(ef - es) / atr;
   score = adx + sep * 10.0 + (htfDir == dir ? 10.0 : 0.0);
   return(true);
  }

//+------------------------------------------------------------------+
//| Positions helpers                                                |
//+------------------------------------------------------------------+
int CountPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagic) count++;
     }
   return(count);
  }

bool HasPosition(string sym)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) == sym) return(true);
     }
   return(false);
  }

int FindSym(string name)
  {
   for(int i = 0; i < ArraySize(g_syms); i++)
      if(g_syms[i].name == name) return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
//| Manage open positions: max hold, flip exit, BE, trailing         |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   datetime now = TimeCurrent();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      int si = FindSym(sym);

      //--- hard max holding time
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      if(InpMaxHoldHours > 0 && (now - opened) >= (int)(InpMaxHoldHours * 3600))
        {
         if(trade.PositionClose(ticket) && si >= 0) g_syms[si].lastClose = now;
         continue;
        }

      if(si < 0 || !g_syms[si].ok) continue;

      long   type  = PositionGetInteger(POSITION_TYPE);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);

      //--- exit on trend flip
      if(InpExitOnFlip)
        {
         double ef = Buf(g_syms[si].emaFastH);
         double es = Buf(g_syms[si].emaSlowH);
         if(ef != EMPTY_VALUE && es != EMPTY_VALUE)
           {
            bool flipDown = (type == POSITION_TYPE_BUY  && ef < es);
            bool flipUp   = (type == POSITION_TYPE_SELL && ef > es);
            if(flipDown || flipUp)
              {
               if(trade.PositionClose(ticket)) g_syms[si].lastClose = now;
               continue;
              }
           }
        }

      //--- break-even & trailing
      double atr = Buf(g_syms[si].atrH);
      if(atr == EMPTY_VALUE || atr <= 0) continue;

      int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);

      if(type == POSITION_TYPE_BUY)
        {
         double profit = bid - open;
         double newSL  = curSL;
         if(InpUseBreakEven && profit >= InpBreakEvenAtr * atr && (curSL == 0.0 || curSL < open))
            newSL = open;
         if(InpUseTrailing && profit >= InpTrailStartAtr * atr)
           {
            double t = bid - InpTrailAtr * atr;
            if(t > newSL) newSL = t;
           }
         newSL = NormalizeDouble(newSL, digits);
         if(newSL > curSL && newSL < bid)
            trade.PositionModify(ticket, newSL, curTP);
        }
      else if(type == POSITION_TYPE_SELL)
        {
         double profit = open - ask;
         double newSL  = curSL;
         if(InpUseBreakEven && profit >= InpBreakEvenAtr * atr && (curSL == 0.0 || curSL > open))
            newSL = open;
         if(InpUseTrailing && profit >= InpTrailStartAtr * atr)
           {
            double t = ask + InpTrailAtr * atr;
            if(newSL == 0.0 || t < newSL) newSL = t;
           }
         newSL = NormalizeDouble(newSL, digits);
         if((curSL == 0.0 || newSL < curSL) && newSL > ask)
            trade.PositionModify(ticket, newSL, curTP);
        }
     }
  }

//+------------------------------------------------------------------+
//| Close everything owned by this EA                                |
//+------------------------------------------------------------------+
void CloseAllByMagic(string reason)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      if(trade.PositionClose(ticket))
        {
         int si = FindSym(sym);
         if(si >= 0) g_syms[si].lastClose = TimeCurrent();
         PrintFormat("Closed %s (%s)", sym, reason);
        }
     }
  }

//+------------------------------------------------------------------+
//| Open a position on symbol index i                                |
//+------------------------------------------------------------------+
bool OpenPosition(int i, int dir, double atr, double score)
  {
   string sym = g_syms[i].name;
   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double price = (dir > 0) ? ask : bid;
   if(price <= 0) return(false);

   double slDist = InpSlAtrMult * atr;
   double tpDist = InpTpAtrMult * atr;
   double sl = (dir > 0) ? price - slDist : price + slDist;
   double tp = 0.0;
   if(tpDist > 0)
      tp = (dir > 0) ? price + tpDist : price - tpDist;
   sl = NormalizeDouble(sl, digits);
   tp = (tp > 0) ? NormalizeDouble(tp, digits) : 0.0;

   ENUM_ORDER_TYPE type = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double lot = CalcLot(sym, slDist, type, price);
   if(lot <= 0)
     {
      PrintFormat("%s: lot=0 (margin), skip", sym);
      return(false);
     }

   trade.SetTypeFillingBySymbol(sym);
   bool ok = (dir > 0)
             ? trade.Buy(lot, sym, price, sl, tp, InpComment)
             : trade.Sell(lot, sym, price, sl, tp, InpComment);

   if(ok)
      PrintFormat("OPEN %s %s %.2f lot @ %.*f sl=%.*f score=%.1f",
                  (dir > 0 ? "BUY" : "SELL"), sym, lot, digits, price, digits, sl, score);
   else
      PrintFormat("OPEN FAILED %s: %d %s", sym, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   return(ok);
  }

//+------------------------------------------------------------------+
//| Lot: risk-based, shrunk to fit free margin                       |
//+------------------------------------------------------------------+
double CalcLot(string sym, double slDist, ENUM_ORDER_TYPE type, double price)
  {
   double lot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);

   if(slDist > 0)
     {
      double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
      double riskMoney = balance * InpRiskPercent / 100.0;
      double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      if(tickValue > 0 && tickSize > 0)
        {
         double lossPerLot = (slDist / tickSize) * tickValue;
         if(lossPerLot > 0)
            lot = riskMoney / lossPerLot;
        }
     }

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double marginReq = 0.0;
   if(OrderCalcMargin(type, sym, lot, price, marginReq) && marginReq > 0)
     {
      double allowed = freeMargin * InpMaxMarginUse / 100.0;
      if(marginReq > allowed)
         lot = lot * (allowed / marginReq);
     }

   lot = MathMin(lot, InpMaxLot);

   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(step > 0) lot = MathFloor(lot / step) * step;
   if(lot < minLot) return(0.0);
   if(lot > maxLot) lot = maxLot;
   return(NormalizeDouble(lot, 2));
  }

//+------------------------------------------------------------------+
//| Daily loss limit                                                 |
//+------------------------------------------------------------------+
void CheckNewDay()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day != g_lastDay)
     {
      g_lastDay = dt.day;
      g_dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dailyStopLogged = false;
     }
  }

bool DailyLossHit()
  {
   if(InpMaxDailyLoss <= 0 || g_dayStartBal <= 0) return(false);
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   return((g_dayStartBal - eq) / g_dayStartBal * 100.0 >= InpMaxDailyLoss);
  }

//+------------------------------------------------------------------+
//| Weekend / Friday-evening flat                                    |
//+------------------------------------------------------------------+
bool IsWeekendFlatTime()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return(true);
   if(InpFridayFlat && dt.day_of_week == 5 && dt.hour >= InpFridayHour) return(true);
   return(false);
  }

//+------------------------------------------------------------------+
//| Cooldown: mark symbols with recent closes (incl. SL hits)        |
//+------------------------------------------------------------------+
void MarkRecentCloses()
  {
   datetime from = TimeCurrent() - (datetime)(InpCooldownMin * 60);
   if(!HistorySelect(from, TimeCurrent() + 60)) return;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      string s = HistoryDealGetString(d, DEAL_SYMBOL);
      int si = FindSym(s);
      if(si >= 0)
        {
         datetime t = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
         if(t > g_syms[si].lastClose) g_syms[si].lastClose = t;
        }
     }
  }

//+------------------------------------------------------------------+
//| Chart status                                                     |
//+------------------------------------------------------------------+
void UpdateComment(string extra)
  {
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dayPL = (g_dayStartBal > 0) ? (eq - g_dayStartBal) : 0;
   string s = StringFormat(
      "=== MultiSymbol ScannerBot ===\nСимволів у скані: %d | День P/L: %.2f (%.2f%%)\n%s",
      ArraySize(g_syms), dayPL, (g_dayStartBal > 0 ? dayPL / g_dayStartBal * 100.0 : 0.0), extra);
   Comment(s);
  }
//+------------------------------------------------------------------+
