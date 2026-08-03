//+------------------------------------------------------------------+
//|                                          RSI_Expert_Advisor.mq5   |
//|                       RSI-based trading bot for MetaTrader 5      |
//|                                                                  |
//|  Signal modes:                                                    |
//|    1) RSI_CROSS  — BUY when RSI crosses UP out of oversold,       |
//|                    SELL when RSI crosses DOWN out of overbought.  |
//|    2) TREND_RSI  — trend by EMA (price > EMA = long bias),        |
//|                    RSI used as overbought/oversold block          |
//|                    (same idea as the Phantom Trader Telegram bot).|
//|                                                                  |
//|  Risk management:                                                 |
//|    - Stop Loss / Take Profit in POINTS or PERCENT (RR 1:4 ready)  |
//|    - Trailing Stop + Break-even                                   |
//|    - Automatic lot sizing by % risk of balance                    |
//|    - Optional EMA trend filter, spread + trading-hours filters    |
//|                                                                  |
//|  Telegram alerts (optional):                                      |
//|    - Sends a message on every open / close via WebRequest.        |
//|    - Requires: Tools > Options > Expert Advisors >                |
//|      "Allow WebRequest for listed URL" > add                      |
//|      https://api.telegram.org                                     |
//+------------------------------------------------------------------+
#property copyright "RSI Expert Advisor"
#property version   "1.10"
#property strict

#include <Trade/Trade.mqh>

//--- Enumerations -------------------------------------------------------------
enum ENUM_LOT_MODE
  {
   LOT_FIXED = 0,   // Fixed lot
   LOT_RISK  = 1    // Risk % of balance
  };

enum ENUM_STOP_MODE
  {
   STOP_POINTS  = 0, // Stops in points
   STOP_PERCENT = 1  // Stops in % of price
  };

enum ENUM_SIGNAL_MODE
  {
   SIGNAL_RSI_CROSS = 0, // RSI crossing out of zones
   SIGNAL_TREND_RSI = 1  // EMA trend + RSI filter (Telegram-bot style)
  };

//--- Input parameters ---------------------------------------------------------
input group "=== General ==="
input long           InpMagicNumber   = 20250731;   // Magic number (unique EA id)
input string         InpTradeComment  = "RSI_EA";   // Order comment
input int            InpSlippage      = 10;         // Max slippage (points)

input group "=== Signal ==="
input ENUM_SIGNAL_MODE InpSignalMode  = SIGNAL_RSI_CROSS; // Signal mode

input group "=== RSI Settings ==="
input int            InpRSIPeriod     = 7;          // RSI period (tuned)
input ENUM_APPLIED_PRICE InpRSIPrice  = PRICE_CLOSE;// RSI applied price
input double         InpRSIOverbought = 70.0;       // Overbought level
input double         InpRSIOversold   = 35.0;       // Oversold level (tuned)

input group "=== Trend Filter (EMA) ==="
input bool           InpUseTrendFilter= true;       // Use EMA trend filter
input int            InpMAPeriod      = 9;          // EMA period (tuned)
input ENUM_MA_METHOD InpMAMethod      = MODE_EMA;   // MA method

input group "=== Money / Risk Management ==="
input ENUM_LOT_MODE  InpLotMode       = LOT_RISK;   // Lot sizing mode
input double         InpFixedLot      = 0.10;       // Fixed lot (if LOT_FIXED)
input double         InpRiskPercent   = 3.0;        // Risk % of balance (tuned)

input group "=== Stops ==="
input ENUM_STOP_MODE InpStopMode      = STOP_PERCENT;// SL/TP mode
input int            InpStopLoss      = 300;        // SL in points  (STOP_POINTS)
input int            InpTakeProfit    = 600;        // TP in points  (STOP_POINTS)
input double         InpStopLossPct   = 1.0;        // SL %          (STOP_PERCENT)
input double         InpTakeProfitPct = 4.0;        // TP %  -> RR 1:4 (STOP_PERCENT)

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

input group "=== Telegram Alerts ==="
input bool           InpUseTelegram   = false;      // Send Telegram notifications
input string         InpTelegramToken = "";         // Bot token (@BotFather)
input string         InpTelegramChat  = "";         // Chat ID

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
   if(InpLotMode == LOT_RISK && InpRiskPercent <= 0.0)
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

   if(InpUseTrendFilter || InpSignalMode == SIGNAL_TREND_RSI)
     {
      maHandle = iMA(_Symbol, _Period, InpMAPeriod, 0, InpMAMethod, PRICE_CLOSE);
      if(maHandle == INVALID_HANDLE)
        {
         Print("ERROR: Failed to create EMA handle.");
         return(INIT_FAILED);
        }
     }

//--- configure trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetMarginMode();

   Print("RSI Expert Advisor initialized on ", _Symbol, " ",
         EnumToString((ENUM_TIMEFRAMES)_Period));

   if(InpUseTelegram)
     {
      if(InpTelegramToken == "" || InpTelegramChat == "")
         Print("WARN: Telegram enabled but token/chat is empty.");
      else
         SendTelegram(StringFormat("🤖 <b>RSI EA запущено</b>\nСимвол: <code>%s %s</code>",
                                   _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period)));
     }

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

//--- EMA (needed for trend filter and/or TREND_RSI mode)
   double emaValue = 0.0;
   bool   haveEma  = false;
   if(InpUseTrendFilter || InpSignalMode == SIGNAL_TREND_RSI)
     {
      if(!GetMA(emaValue))
         return;
      haveEma = true;
     }

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool buySignal  = false;
   bool sellSignal = false;

   if(InpSignalMode == SIGNAL_RSI_CROSS)
     {
      buySignal  = (rsiPrev <= InpRSIOversold   && rsiCurr > InpRSIOversold);
      sellSignal = (rsiPrev >= InpRSIOverbought && rsiCurr < InpRSIOverbought);

      // optional EMA trend filter
      if(InpUseTrendFilter && haveEma)
        {
         if(buySignal  && price < emaValue)  buySignal  = false; // buy only above EMA
         if(sellSignal && price > emaValue)  sellSignal = false; // sell only below EMA
        }
     }
   else // SIGNAL_TREND_RSI  (Telegram-bot style)
     {
      bool longBias  = (price > emaValue);
      bool shortBias = (price < emaValue);
      // block against overbought/oversold, same as the Telegram bot
      buySignal  = longBias  && !(rsiCurr > InpRSIOverbought);
      sellSignal = shortBias && !(rsiCurr < InpRSIOversold);
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
   ArraySetAsSeries(buf, true);
   curr = buf[1]; // last fully closed bar
   prev = buf[2]; // bar before it
   return(true);
  }

//+------------------------------------------------------------------+
//| Read EMA value of the last closed bar                            |
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
//| Stop-loss distance in price for the given entry price            |
//+------------------------------------------------------------------+
double StopLossDistance(double price)
  {
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(InpStopMode == STOP_PERCENT)
      return(price * InpStopLossPct / 100.0);
   return(InpStopLoss * point);
  }

//+------------------------------------------------------------------+
//| Take-profit distance in price for the given entry price          |
//+------------------------------------------------------------------+
double TakeProfitDistance(double price)
  {
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(InpStopMode == STOP_PERCENT)
      return(price * InpTakeProfitPct / 100.0);
   return(InpTakeProfit * point);
  }

//+------------------------------------------------------------------+
//| Calculate lot size                                               |
//+------------------------------------------------------------------+
double CalculateLot(double slDistance)
  {
   double lot = InpFixedLot;

   if(InpLotMode == LOT_RISK && slDistance > 0)
     {
      double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
      double riskMoney = balance * InpRiskPercent / 100.0;
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

      if(tickValue <= 0 || tickSize <= 0)
         return(NormalizeLot(InpFixedLot));

      // money lost per 1.0 lot if SL is hit
      double lossPerLot = (slDistance / tickSize) * tickValue;
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
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price = (type == ORDER_TYPE_BUY) ? ask : bid;

   double slDist = StopLossDistance(price);
   double tpDist = TakeProfitDistance(price);

   double sl = 0.0, tp = 0.0;
   if(slDist > 0)
      sl = (type == ORDER_TYPE_BUY) ? price - slDist : price + slDist;
   if(tpDist > 0)
      tp = (type == ORDER_TYPE_BUY) ? price + tpDist : price - tpDist;

   sl = (sl > 0) ? NormalizeDouble(sl, digits) : 0.0;
   tp = (tp > 0) ? NormalizeDouble(tp, digits) : 0.0;

   double lot = CalculateLot(slDist);

   bool ok = (type == ORDER_TYPE_BUY)
             ? trade.Buy(lot, _Symbol, price, sl, tp, InpTradeComment)
             : trade.Sell(lot, _Symbol, price, sl, tp, InpTradeComment);

   if(ok)
     {
      PrintFormat("%s opened: lot=%.2f price=%.*f sl=%.*f tp=%.*f",
                  (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
                  lot, digits, price, digits, sl, digits, tp);
      NotifyOpen(type, lot, price, sl, tp, digits);
     }
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

         if(InpUseBreakEven && profitPts >= InpBreakEvenAfter)
           {
            double be = openPrice + InpBreakEvenLock * point;
            if(be > newSL)
               newSL = be;
           }
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

         if(InpUseBreakEven && profitPts >= InpBreakEvenAfter)
           {
            double be = openPrice - InpBreakEvenLock * point;
            if(curSL == 0.0 || be < newSL)
               newSL = be;
           }
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
//| Trade transaction handler — Telegram close notifications         |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(!InpUseTelegram)
      return;
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong dealTicket = trans.deal;
   if(dealTicket == 0 || !HistoryDealSelect(dealTicket))
      return;
   if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != InpMagicNumber)
      return;
   if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
      return;

   long entry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT)
      return; // only report closes here (opens are reported in OpenTrade)

   double profit  = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
   double volume  = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
   double swap    = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
   double commiss = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
   double net     = profit + swap + commiss;
   string account = AccountInfoString(ACCOUNT_CURRENCY);
   string icon    = (net >= 0) ? "✅" : "🔻";

   SendTelegram(StringFormat(
      "%s <b>ПОЗИЦІЮ ЗАКРИТО</b>\nСимвол: <code>%s</code>\nОбсяг: %.2f\n"
      "Результат: <b>%.2f %s</b>",
      icon, _Symbol, volume, net, account));
  }

//+------------------------------------------------------------------+
//| Telegram: open notification                                      |
//+------------------------------------------------------------------+
void NotifyOpen(ENUM_ORDER_TYPE type, double lot, double price,
                double sl, double tp, int digits)
  {
   if(!InpUseTelegram)
      return;

   string dir  = (type == ORDER_TYPE_BUY) ? "BUY 📈" : "SELL 📉";
   string icon = (type == ORDER_TYPE_BUY) ? "🟢" : "🔴";
   string slInfo = (InpStopMode == STOP_PERCENT)
                   ? StringFormat("%.*f  (-%g%%)", digits, sl, InpStopLossPct)
                   : StringFormat("%.*f", digits, sl);
   string tpInfo = (InpStopMode == STOP_PERCENT)
                   ? StringFormat("%.*f  (+%g%%)", digits, tp, InpTakeProfitPct)
                   : StringFormat("%.*f", digits, tp);

   SendTelegram(StringFormat(
      "%s <b>ВІДКРИТО %s</b>\nСимвол: <code>%s %s</code>\n"
      "🎯 Вхід: <code>%.*f</code>\nЛот: %.2f\n"
      "🛑 SL: <code>%s</code>\n✅ TP: <code>%s</code>",
      icon, dir, _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period),
      digits, price, lot, slInfo, tpInfo));
  }

//+------------------------------------------------------------------+
//| Telegram: send a message via WebRequest                          |
//+------------------------------------------------------------------+
void SendTelegram(string message)
  {
   if(!InpUseTelegram)
      return;
   if(InpTelegramToken == "" || InpTelegramChat == "")
      return;

   string url    = "https://api.telegram.org/bot" + InpTelegramToken + "/sendMessage";
   string params = "chat_id=" + InpTelegramChat +
                   "&parse_mode=HTML&text=" + UrlEncode(message);

   char post[], result[];
   int total = StringToCharArray(params, post, 0, WHOLE_ARRAY, CP_UTF8);
   if(total > 0 && post[total - 1] == 0)          // drop terminating null
      ArrayResize(post, total - 1);

   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   string resultHeaders;
   ResetLastError();
   int code = WebRequest("POST", url, headers, 5000, post, result, resultHeaders);

   if(code == -1)
     {
      int err = GetLastError();
      if(err == 4014)
         Print("Telegram: WebRequest not allowed. Add https://api.telegram.org "
               "in Tools > Options > Expert Advisors > Allow WebRequest.");
      else
         PrintFormat("Telegram: WebRequest failed, error=%d", err);
     }
   else if(code != 200)
     {
      PrintFormat("Telegram: HTTP %d — %s", code, CharArrayToString(result));
     }
  }

//+------------------------------------------------------------------+
//| Percent-encode a UTF-8 string for use in a URL / form body       |
//+------------------------------------------------------------------+
string UrlEncode(string text)
  {
   string out = "";
   uchar bytes[];
   int n = StringToCharArray(text, bytes, 0, WHOLE_ARRAY, CP_UTF8);
   for(int i = 0; i < n; i++)
     {
      uchar c = bytes[i];
      if(c == 0)
         continue; // skip terminating null
      if((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
         (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~')
         out += CharToString(c);
      else
         out += StringFormat("%%%02X", c);
     }
   return(out);
  }
//+------------------------------------------------------------------+
