//+------------------------------------------------------------------+
//|                                          RSI_Expert_Advisor.mq5   |
//|                       RSI-based trading bot for MetaTrader 5      |
//|                                                                  |
//|  Strategy:                                                        |
//|    - BUY  when RSI crosses UP out of the oversold zone           |
//|    - SELL when RSI crosses DOWN out of the overbought zone       |
//|                                                                  |
//|  Risk management:                                                 |
//|    - Stop Loss / Take Profit (in points)                          |
//|    - Trailing Stop                                                |
//|    - Break-even                                                   |
//|    - Automatic lot sizing by % risk of balance                    |
//|    - Optional MA trend filter                                     |
//|    - Trading-hours filter and spread filter                       |
//+------------------------------------------------------------------+
#property copyright "RSI Expert Advisor"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//--- Enumerations -------------------------------------------------------------
enum ENUM_LOT_MODE
  {
   LOT_FIXED = 0,   // Fixed lot
   LOT_RISK  = 1    // Risk % of balance
  };

//--- Input parameters ---------------------------------------------------------
input group "=== General ==="
input long           InpMagicNumber   = 20250731;   // Magic number (unique EA id)
input string         InpTradeComment  = "RSI_EA";   // Order comment
input int            InpSlippage      = 10;         // Max slippage (points)

input group "=== RSI Settings ==="
input int            InpRSIPeriod     = 14;         // RSI period
input ENUM_APPLIED_PRICE InpRSIPrice  = PRICE_CLOSE;// RSI applied price
input double         InpRSIOverbought = 70.0;       // Overbought level
input double         InpRSIOversold   = 30.0;       // Oversold level

input group "=== Trend Filter (MA) ==="
input bool           InpUseTrendFilter= true;       // Use MA trend filter
input int            InpMAPeriod      = 200;        // MA period
input ENUM_MA_METHOD InpMAMethod      = MODE_EMA;   // MA method

input group "=== Money / Risk Management ==="
input ENUM_LOT_MODE  InpLotMode       = LOT_RISK;   // Lot sizing mode
input double         InpFixedLot      = 0.10;       // Fixed lot (if LOT_FIXED)
input double         InpRiskPercent   = 1.0;        // Risk % of balance (if LOT_RISK)

input group "=== Stops (in points) ==="
input int            InpStopLoss      = 300;        // Stop Loss (points, 0 = off)
input int            InpTakeProfit    = 600;        // Take Profit (points, 0 = off)

input group "=== Trailing Stop ==="
input bool           InpUseTrailing   = true;       // Use trailing stop
input int            InpTrailingStart = 200;        // Start trailing after (points profit)
input int            InpTrailingStop  = 150;        // Trailing distance (points)
input int            InpTrailingStep  = 20;         // Trailing step (points)

input group "=== Break-even ==="
input bool           InpUseBreakEven  = true;       // Move SL to break-even
input int            InpBreakEvenAfter= 150;        // Trigger after (points profit)
input int            InpBreakEvenLock = 20;         // Lock-in profit (points)

input group "=== Filters ==="
input int            InpMaxPositions  = 1;          // Max simultaneous positions
input int            InpMaxSpread     = 30;         // Max allowed spread (points, 0 = off)
input bool           InpUseTimeFilter = false;      // Use trading-hours filter
input int            InpStartHour     = 8;          // Start hour (server time)
input int            InpEndHour       = 22;         // End hour (server time)

//--- Globals ------------------------------------------------------------------
CTrade         trade;
int            rsiHandle = INVALID_HANDLE;
int            maHandle  = INVALID_HANDLE;
datetime       lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- validate inputs
   if(InpRSIOversold >= InpRSIOverbought)
     {
      Print("ERROR: Oversold level must be lower than overbought level.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpRiskPercent <= 0.0 && InpLotMode == LOT_RISK)
     {
      Print("ERROR: Risk percent must be > 0.");
      return(INIT_PARAMETERS_INCORRECT);
     }

//--- create indicator handles
   rsiHandle = iRSI(_Symbol, _Period, InpRSIPeriod, InpRSIPrice);
   if(rsiHandle == INVALID_HANDLE)
     {
      Print("ERROR: Failed to create RSI handle.");
      return(INIT_FAILED);
     }

   if(InpUseTrendFilter)
     {
      maHandle = iMA(_Symbol, _Period, InpMAPeriod, 0, InpMAMethod, PRICE_CLOSE);
      if(maHandle == INVALID_HANDLE)
        {
         Print("ERROR: Failed to create MA handle.");
         return(INIT_FAILED);
        }
     }

//--- configure trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetMarginMode();

   Print("RSI Expert Advisor initialized on ", _Symbol, " ", EnumToString((ENUM_TIMEFRAMES)_Period));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(rsiHandle != INVALID_HANDLE)
      IndicatorRelease(rsiHandle);
   if(maHandle != INVALID_HANDLE)
      IndicatorRelease(maHandle);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
//--- manage open positions on every tick (trailing / break-even)
   ManageOpenPositions();

//--- act only once per new bar for entries
   if(!IsNewBar())
      return;

//--- filters
   if(!IsSpreadOK())
      return;
   if(InpUseTimeFilter && !IsWithinTradingHours())
      return;

//--- read indicator values
   double rsiCurr, rsiPrev;
   if(!GetRSI(rsiCurr, rsiPrev))
      return;

//--- detect crossing signals
   bool buySignal  = (rsiPrev <= InpRSIOversold   && rsiCurr > InpRSIOversold);
   bool sellSignal = (rsiPrev >= InpRSIOverbought && rsiCurr < InpRSIOverbought);

//--- trend filter
   if(InpUseTrendFilter)
     {
      double maValue;
      if(!GetMA(maValue))
         return;
      double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(buySignal  && price < maValue)  buySignal  = false; // only buy above MA
      if(sellSignal && price > maValue)  sellSignal = false; // only sell below MA
     }

//--- respect max positions limit
   if(CountPositions() >= InpMaxPositions)
      return;

   if(buySignal)
      OpenTrade(ORDER_TYPE_BUY);
   else if(sellSignal)
      OpenTrade(ORDER_TYPE_SELL);
  }

//+------------------------------------------------------------------+
//| Return true once per newly formed bar                            |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t = iTime(_Symbol, _Period, 0);
   if(t != lastBarTime)
     {
      lastBarTime = t;
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Read current and previous (closed bar) RSI values                |
//+------------------------------------------------------------------+
bool GetRSI(double &curr, double &prev)
  {
   double buf[];
   if(CopyBuffer(rsiHandle, 0, 0, 3, buf) < 3)
     {
      Print("WARN: Not enough RSI data yet.");
      return(false);
     }
   // buf[2] = current forming bar, buf[1] = last closed bar, buf[0] = older
   ArraySetAsSeries(buf, true);
   curr = buf[1]; // last fully closed bar
   prev = buf[2]; // bar before it
   return(true);
  }

//+------------------------------------------------------------------+
//| Read MA value of the last closed bar                             |
//+------------------------------------------------------------------+
bool GetMA(double &value)
  {
   double buf[];
   if(CopyBuffer(maHandle, 0, 0, 3, buf) < 3)
      return(false);
   ArraySetAsSeries(buf, true);
   value = buf[1];
   return(true);
  }

//+------------------------------------------------------------------+
//| Spread filter                                                    |
//+------------------------------------------------------------------+
bool IsSpreadOK()
  {
   if(InpMaxSpread <= 0)
      return(true);
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return(spread <= InpMaxSpread);
  }

//+------------------------------------------------------------------+
//| Trading-hours filter                                             |
//+------------------------------------------------------------------+
bool IsWithinTradingHours()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if(InpStartHour <= InpEndHour)
      return(h >= InpStartHour && h < InpEndHour);
   // overnight window (e.g. 22 -> 6)
   return(h >= InpStartHour || h < InpEndHour);
  }

//+------------------------------------------------------------------+
//| Count positions opened by this EA on this symbol                 |
//+------------------------------------------------------------------+
int CountPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| Calculate lot size                                               |
//+------------------------------------------------------------------+
double CalculateLot(double slPoints)
  {
   double lot = InpFixedLot;

   if(InpLotMode == LOT_RISK && slPoints > 0)
     {
      double balance      = AccountInfoDouble(ACCOUNT_BALANCE);
      double riskMoney    = balance * InpRiskPercent / 100.0;
      double tickValue    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double point        = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

      if(tickValue <= 0 || tickSize <= 0 || point <= 0)
         return(NormalizeLot(InpFixedLot));

      // money lost per 1.0 lot if SL is hit
      double lossPerLot = (slPoints * point / tickSize) * tickValue;
      if(lossPerLot <= 0)
         return(NormalizeLot(InpFixedLot));

      lot = riskMoney / lossPerLot;
     }

   return(NormalizeLot(lot));
  }

//+------------------------------------------------------------------+
//| Normalize lot to broker constraints                              |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep > 0)
      lot = MathFloor(lot / lotStep) * lotStep;

   lot = MathMax(minLot, MathMin(maxLot, lot));
   return(NormalizeDouble(lot, 2));
  }

//+------------------------------------------------------------------+
//| Open a market order with SL / TP                                 |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type)
  {
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double price = (type == ORDER_TYPE_BUY) ? ask : bid;
   double sl = 0.0, tp = 0.0;

   if(InpStopLoss > 0)
      sl = (type == ORDER_TYPE_BUY) ? price - InpStopLoss * point
                                    : price + InpStopLoss * point;
   if(InpTakeProfit > 0)
      tp = (type == ORDER_TYPE_BUY) ? price + InpTakeProfit * point
                                    : price - InpTakeProfit * point;

   sl = (sl > 0) ? NormalizeDouble(sl, digits) : 0.0;
   tp = (tp > 0) ? NormalizeDouble(tp, digits) : 0.0;

   double lot = CalculateLot(InpStopLoss);

   bool ok = (type == ORDER_TYPE_BUY)
             ? trade.Buy(lot, _Symbol, price, sl, tp, InpTradeComment)
             : trade.Sell(lot, _Symbol, price, sl, tp, InpTradeComment);

   if(ok)
      PrintFormat("%s opened: lot=%.2f price=%.*f sl=%.*f tp=%.*f",
                  (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
                  lot, digits, price, digits, sl, digits, tp);
   else
      PrintFormat("Order FAILED: retcode=%d %s", trade.ResultRetcode(),
                  trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Manage open positions: break-even + trailing stop               |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   if(!InpUseTrailing && !InpUseBreakEven)
      return;

   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      long   type      = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL     = PositionGetDouble(POSITION_SL);
      double curTP     = PositionGetDouble(POSITION_TP);

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double newSL = curSL;

      if(type == POSITION_TYPE_BUY)
        {
         double profitPts = (bid - openPrice) / point;

         //--- break-even
         if(InpUseBreakEven && profitPts >= InpBreakEvenAfter)
           {
            double be = openPrice + InpBreakEvenLock * point;
            if(be > newSL)
               newSL = be;
           }
         //--- trailing
         if(InpUseTrailing && profitPts >= InpTrailingStart)
           {
            double trail = bid - InpTrailingStop * point;
            if(trail > newSL + InpTrailingStep * point)
               newSL = trail;
           }

         newSL = NormalizeDouble(newSL, digits);
         if(newSL > curSL && newSL < bid)
            trade.PositionModify(ticket, newSL, curTP);
        }
      else if(type == POSITION_TYPE_SELL)
        {
         double profitPts = (openPrice - ask) / point;

         //--- break-even
         if(InpUseBreakEven && profitPts >= InpBreakEvenAfter)
           {
            double be = openPrice - InpBreakEvenLock * point;
            if(curSL == 0.0 || be < newSL)
               newSL = be;
           }
         //--- trailing
         if(InpUseTrailing && profitPts >= InpTrailingStart)
           {
            double trail = ask + InpTrailingStop * point;
            if(curSL == 0.0 || trail < newSL - InpTrailingStep * point)
               newSL = trail;
           }

         newSL = NormalizeDouble(newSL, digits);
         if((curSL == 0.0 || newSL < curSL) && newSL > ask)
            trade.PositionModify(ticket, newSL, curTP);
        }
     }
  }
//+------------------------------------------------------------------+
