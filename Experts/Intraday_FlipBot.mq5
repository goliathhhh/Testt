//+------------------------------------------------------------------+
//|                                            Intraday_FlipBot.mq5   |
//|         "Always-in-market" intraday trend-flip bot for MT5        |
//|                                                                  |
//|  Idea (honest):                                                   |
//|    - Direction from a fast/slow EMA relationship (trend).         |
//|    - Always holds a position in the trend direction and FLIPS     |
//|      LONG<->SHORT when the trend flips  (set & forget).           |
//|    - INTRADAY only: closes everything by a set hour and never     |
//|      holds longer than a configured number of hours (no          |
//|      overnight risk).                                             |
//|    - Optional ADX filter to skip dead/flat markets (recommended:  |
//|      flipping on every wiggle loses to the spread).               |
//|                                                                  |
//|  Leverage-agnostic sizing:                                        |
//|    - Lot from risk % of balance using an ATR stop, THEN shrunk    |
//|      via OrderCalcMargin to fit free margin — so you do NOT need  |
//|      to know the account leverage.                                |
//|                                                                  |
//|  Works on Hedge or Netting accounts (it closes its own opposite   |
//|  position before flipping).                                       |
//|                                                                  |
//|  NOTE: No strategy guarantees profit. Test on DEMO first.         |
//+------------------------------------------------------------------+
#property copyright "Intraday FlipBot"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//--- Inputs -------------------------------------------------------------------
input group "=== General ==="
input long   InpMagic        = 20250808;   // Magic number
input string InpComment       = "FlipBot";  // Order comment
input int    InpSlippage      = 20;         // Max slippage (points)

input group "=== Signal (trend) ==="
input int    InpEmaFast       = 12;         // Fast EMA period
input int    InpEmaSlow       = 48;         // Slow EMA period
input bool   InpAlwaysInMarket= true;       // Always hold a position (flip on trend change)

input group "=== Whipsaw filter (recommended) ==="
input bool   InpUseAdx        = true;       // Use ADX trend-strength filter
input int    InpAdxPeriod     = 14;         // ADX period
input double InpAdxMin        = 20.0;       // Min ADX to trade (skip flat markets)

input group "=== Stops (ATR) ==="
input int    InpAtrPeriod     = 14;         // ATR period
input double InpSlAtrMult     = 2.0;        // Stop-Loss = ATR x
input double InpTpAtrMult     = 0.0;        // Take-Profit = ATR x (0 = none, exit on flip)

input group "=== Trailing (ride the move) ==="
input bool   InpUseTrailing   = true;       // Trailing stop
input double InpTrailStartAtr = 1.0;        // Start trailing after profit >= ATR x
input double InpTrailAtr       = 1.5;       // Trailing distance = ATR x

input group "=== Risk / sizing (leverage-agnostic) ==="
input double InpRiskPercent   = 1.0;        // Risk % of balance per trade
input double InpMaxMarginUse  = 20.0;       // Max % of FREE margin per position
input double InpMaxLot         = 5.0;       // Hard lot cap

input group "=== Intraday control ==="
input int    InpSessionStart  = 7;          // Session start hour (server time)
input int    InpNoNewAfter     = 21;         // Stop OPENING new trades after this hour
input int    InpDayCloseHour   = 23;         // Close ALL positions at this hour
input int    InpDayCloseMin     = 30;         // ...and minute
input double InpMaxHoldHours    = 24.0;       // Hard max holding time (hours)
input bool   InpCloseFriday     = true;       // Force-close earlier on Friday
input int    InpFridayCloseHour = 20;         // Friday close hour

input group "=== Other filters ==="
input int    InpMaxSpread      = 40;         // Max spread (points, 0 = off)

//--- Globals ------------------------------------------------------------------
CTrade   trade;
int      emaFastH = INVALID_HANDLE, emaSlowH = INVALID_HANDLE;
int      adxH = INVALID_HANDLE, atrH = INVALID_HANDLE;
datetime lastBar = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpEmaFast >= InpEmaSlow)
     {
      Print("ERROR: Fast EMA must be shorter than slow EMA.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   emaFastH = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowH = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   atrH     = iATR(_Symbol, _Period, InpAtrPeriod);
   if(InpUseAdx)
      adxH = iADX(_Symbol, _Period, InpAdxPeriod);

   if(emaFastH == INVALID_HANDLE || emaSlowH == INVALID_HANDLE || atrH == INVALID_HANDLE ||
      (InpUseAdx && adxH == INVALID_HANDLE))
     {
      Print("ERROR: indicator handle creation failed.");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetMarginMode();

   PrintFormat("Intraday FlipBot on %s %s | always-in=%s | ADX filter=%s",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period),
               (InpAlwaysInMarket ? "yes" : "no"), (InpUseAdx ? "yes" : "no"));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(emaFastH != INVALID_HANDLE) IndicatorRelease(emaFastH);
   if(emaSlowH != INVALID_HANDLE) IndicatorRelease(emaSlowH);
   if(adxH     != INVALID_HANDLE) IndicatorRelease(adxH);
   if(atrH     != INVALID_HANDLE) IndicatorRelease(atrH);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
//--- always: manage exits (time / trailing) on every tick
   ManageExits();

//--- if it's day-close time (or weekend approaching) -> flat, no new trades
   if(IsFlatTime())
     {
      CloseAllByMagic();
      return;
     }

//--- entries only once per new bar
   if(!IsNewBar())
      return;

   if(!SpreadOK())
      return;

   double atr = GetATR();
   if(atr <= 0)
      return;

   int desired = DesiredDir();     // +1 long, -1 short, 0 none
   int cur     = CurrentDir();     // +1 long, -1 short, 0 flat

//--- allowed to OPEN now? (inside session, before no-new-after)
   bool canOpen = CanOpenNow();

   if(InpAlwaysInMarket)
     {
      // if the filter is undecided, keep the current side rather than going flat
      if(desired == 0)
         desired = cur;
      if(desired != 0 && cur != desired && canOpen)
        {
         CloseAllByMagic();
         OpenPosition(desired > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, atr);
        }
     }
   else
     {
      if(desired == 0)
        {
         if(cur != 0) CloseAllByMagic();          // filter says stand aside
        }
      else if(cur != desired && canOpen)
        {
         CloseAllByMagic();
         OpenPosition(desired > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, atr);
        }
     }
  }

//+------------------------------------------------------------------+
//| Desired direction from EMA (+ optional ADX filter)               |
//+------------------------------------------------------------------+
int DesiredDir()
  {
   double f[], s[];
   if(CopyBuffer(emaFastH, 0, 1, 1, f) < 1) return(0);
   if(CopyBuffer(emaSlowH, 0, 1, 1, s) < 1) return(0);

   int dir = 0;
   if(f[0] > s[0]) dir = 1;
   else if(f[0] < s[0]) dir = -1;

   if(InpUseAdx && dir != 0)
     {
      double a[];
      if(CopyBuffer(adxH, 0, 1, 1, a) < 1) return(0);
      if(a[0] < InpAdxMin) dir = 0;   // trend too weak -> stand aside
     }
   return(dir);
  }

//+------------------------------------------------------------------+
//| Current net direction of this EA's positions                     |
//+------------------------------------------------------------------+
int CurrentDir()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      return(type == POSITION_TYPE_BUY ? 1 : -1);
     }
   return(0);
  }

//+------------------------------------------------------------------+
double GetATR()
  {
   double a[];
   if(CopyBuffer(atrH, 0, 1, 1, a) < 1) return(0);
   return(a[0]);
  }

//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t = iTime(_Symbol, _Period, 0);
   if(t != lastBar) { lastBar = t; return(true); }
   return(false);
  }

bool SpreadOK()
  {
   if(InpMaxSpread <= 0) return(true);
   return(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpread);
  }

//+------------------------------------------------------------------+
//| Inside the session and allowed to open new trades?               |
//+------------------------------------------------------------------+
bool CanOpenNow()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return(false); // weekend
   if(dt.hour < InpSessionStart) return(false);
   if(dt.hour >= InpNoNewAfter) return(false);
   if(InpCloseFriday && dt.day_of_week == 5 && dt.hour >= InpFridayCloseHour) return(false);
   return(true);
  }

//+------------------------------------------------------------------+
//| Time to be flat (end of day / Friday)                            |
//+------------------------------------------------------------------+
bool IsFlatTime()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return(true);
   if(InpCloseFriday && dt.day_of_week == 5 && dt.hour >= InpFridayCloseHour) return(true);
   if(dt.hour > InpDayCloseHour) return(true);
   if(dt.hour == InpDayCloseHour && dt.min >= InpDayCloseMin) return(true);
   return(false);
  }

//+------------------------------------------------------------------+
//| Manage exits: hard max-hold + ATR trailing                       |
//+------------------------------------------------------------------+
void ManageExits()
  {
   double atr = GetATR();
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   datetime now = TimeCurrent();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      // hard max holding time
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      if(InpMaxHoldHours > 0 && (now - opened) >= (int)(InpMaxHoldHours * 3600))
        {
         trade.PositionClose(ticket);
         continue;
        }

      if(!InpUseTrailing || atr <= 0) continue;

      long   type   = PositionGetInteger(POSITION_TYPE);
      double open   = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL  = PositionGetDouble(POSITION_SL);
      double curTP  = PositionGetDouble(POSITION_TP);
      double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(type == POSITION_TYPE_BUY)
        {
         if(bid - open >= InpTrailStartAtr * atr)
           {
            double newSL = NormalizeDouble(bid - InpTrailAtr * atr, digits);
            if(newSL > curSL && newSL < bid)
               trade.PositionModify(ticket, newSL, curTP);
           }
        }
      else if(type == POSITION_TYPE_SELL)
        {
         if(open - ask >= InpTrailStartAtr * atr)
           {
            double newSL = NormalizeDouble(ask + InpTrailAtr * atr, digits);
            if((curSL == 0.0 || newSL < curSL) && newSL > ask)
               trade.PositionModify(ticket, newSL, curTP);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Close all positions of this EA (hedge-safe)                      |
//+------------------------------------------------------------------+
void CloseAllByMagic()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      trade.PositionClose(ticket);
     }
  }

//+------------------------------------------------------------------+
//| Open a position with ATR-based SL/TP and leverage-fit lot        |
//+------------------------------------------------------------------+
void OpenPosition(ENUM_ORDER_TYPE type, double atr)
  {
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price = (type == ORDER_TYPE_BUY) ? ask : bid;

   double slDist = InpSlAtrMult * atr;
   double tpDist = InpTpAtrMult * atr;
   double sl = 0.0, tp = 0.0;
   if(slDist > 0)
      sl = (type == ORDER_TYPE_BUY) ? price - slDist : price + slDist;
   if(tpDist > 0)
      tp = (type == ORDER_TYPE_BUY) ? price + tpDist : price - tpDist;
   sl = (sl > 0) ? NormalizeDouble(sl, digits) : 0.0;
   tp = (tp > 0) ? NormalizeDouble(tp, digits) : 0.0;

   double lot = CalcLot(slDist, type, price);
   if(lot <= 0)
     {
      Print("Lot = 0 (not enough free margin). Skipping.");
      return;
     }

   bool ok = (type == ORDER_TYPE_BUY)
             ? trade.Buy(lot, _Symbol, price, sl, tp, InpComment)
             : trade.Sell(lot, _Symbol, price, sl, tp, InpComment);

   if(ok)
      PrintFormat("%s %.2f lot @ %.*f  sl=%.*f tp=%.*f",
                  (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
                  lot, digits, price, digits, sl, digits, tp);
   else
      PrintFormat("Order failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Lot: risk %, then shrunk to fit free margin (leverage-agnostic)  |
//+------------------------------------------------------------------+
double CalcLot(double slDist, ENUM_ORDER_TYPE type, double price)
  {
   double lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   // 1) risk-based lot from the ATR stop
   if(slDist > 0)
     {
      double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
      double riskMoney = balance * InpRiskPercent / 100.0;
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickValue > 0 && tickSize > 0)
        {
         double lossPerLot = (slDist / tickSize) * tickValue;
         if(lossPerLot > 0)
            lot = riskMoney / lossPerLot;
        }
     }

   // 2) shrink to fit free margin — works whatever the leverage is
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double marginReq = 0.0;
   if(OrderCalcMargin(type, _Symbol, lot, price, marginReq) && marginReq > 0)
     {
      double allowed = freeMargin * InpMaxMarginUse / 100.0;
      if(marginReq > allowed)
         lot = lot * (allowed / marginReq);
     }

   // 3) apply hard cap and broker constraints
   lot = MathMin(lot, InpMaxLot);
   return(NormalizeLot(lot));
  }

//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step > 0) lot = MathFloor(lot / step) * step;
   if(lot < minLot) return(0.0);              // can't afford even the minimum
   if(lot > maxLot) lot = maxLot;
   return(NormalizeDouble(lot, 2));
  }
//+------------------------------------------------------------------+
