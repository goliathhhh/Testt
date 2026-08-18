//+------------------------------------------------------------------+
//|                                              ExportHistory.mq5    |
//|  Dumps closed deals to MQL5/Files/trade_history.csv plus a short  |
//|  per-symbol summary, so the bot's real performance can be         |
//|  reviewed outside the terminal.                                   |
//|                                                                  |
//|  Usage: drag onto any chart (it is a Script, runs once).          |
//+------------------------------------------------------------------+
#property copyright "ScannerBot tools"
#property version   "1.00"
#property script_show_inputs
#property strict

input int  InpDaysBack = 30;         // How many days of history
input long InpMagic    = 0;          // Filter by magic (0 = all)

//+------------------------------------------------------------------+
void OnStart()
  {
   datetime from = TimeCurrent() - (datetime)(InpDaysBack * 86400);
   if(!HistorySelect(from, TimeCurrent() + 3600))
     {
      Print("HistorySelect failed");
      return;
     }

   int fh = FileOpen("trade_history.csv", FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(fh == INVALID_HANDLE)
     {
      Print("Cannot create trade_history.csv, error ", GetLastError());
      return;
     }

   FileWrite(fh, "time", "symbol", "type", "volume", "price", "profit", "swap", "commission", "net", "comment");

   //--- per-symbol aggregation
   string  symNames[];
   double  symNet[];
   int     symWins[], symLosses[];
   int     nSym = 0;

   double total = 0.0;
   int    wins = 0, losses = 0;
   double grossWin = 0.0, grossLoss = 0.0;
   double biggestWin = 0.0, biggestLoss = 0.0;
   double maxVolume = 0.0;

   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      if(InpMagic != 0 && HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic) continue;

      string sym  = HistoryDealGetString(d, DEAL_SYMBOL);
      long   type = HistoryDealGetInteger(d, DEAL_TYPE);
      double vol  = HistoryDealGetDouble(d, DEAL_VOLUME);
      double prc  = HistoryDealGetDouble(d, DEAL_PRICE);
      double pr   = HistoryDealGetDouble(d, DEAL_PROFIT);
      double sw   = HistoryDealGetDouble(d, DEAL_SWAP);
      double cm   = HistoryDealGetDouble(d, DEAL_COMMISSION);
      double net  = pr + sw + cm;
      datetime t  = (datetime)HistoryDealGetInteger(d, DEAL_TIME);

      // a closing BUY deal closes a SELL position and vice versa
      string side = (type == DEAL_TYPE_BUY) ? "close_short" : "close_long";

      FileWrite(fh, TimeToString(t, TIME_DATE | TIME_MINUTES), sym, side,
                DoubleToString(vol, 2), DoubleToString(prc, 5),
                DoubleToString(pr, 2), DoubleToString(sw, 2), DoubleToString(cm, 2),
                DoubleToString(net, 2), HistoryDealGetString(d, DEAL_COMMENT));

      total += net;
      if(net >= 0) { wins++; grossWin += net; if(net > biggestWin) biggestWin = net; }
      else         { losses++; grossLoss += net; if(net < biggestLoss) biggestLoss = net; }
      if(vol > maxVolume) maxVolume = vol;

      int si = -1;
      for(int k = 0; k < nSym; k++) if(symNames[k] == sym) { si = k; break; }
      if(si < 0)
        {
         si = nSym++;
         ArrayResize(symNames, nSym); ArrayResize(symNet, nSym);
         ArrayResize(symWins, nSym);  ArrayResize(symLosses, nSym);
         symNames[si] = sym; symNet[si] = 0; symWins[si] = 0; symLosses[si] = 0;
        }
      symNet[si] += net;
      if(net >= 0) symWins[si]++; else symLosses[si]++;
     }

   FileClose(fh);

   //--- summary to the Experts log
   int trades = wins + losses;
   double winRate = (trades > 0) ? (100.0 * wins / trades) : 0.0;
   double pf = (grossLoss != 0.0) ? (grossWin / MathAbs(grossLoss)) : 0.0;
   double avgWin  = (wins   > 0) ? grossWin / wins : 0.0;
   double avgLoss = (losses > 0) ? grossLoss / losses : 0.0;

   Print("===== TRADE SUMMARY (", InpDaysBack, " days) =====");
   PrintFormat("Trades: %d | Wins: %d | Losses: %d | Win rate: %.1f%%", trades, wins, losses, winRate);
   PrintFormat("Net: %.2f | Gross win: %.2f | Gross loss: %.2f | Profit factor: %.2f",
               total, grossWin, grossLoss, pf);
   PrintFormat("Avg win: %.2f | Avg loss: %.2f | Biggest win: %.2f | Biggest loss: %.2f",
               avgWin, avgLoss, biggestWin, biggestLoss);
   PrintFormat("Max volume seen: %.2f lot (watch this for martingale growth)", maxVolume);
   Print("----- per symbol -----");
   for(int k = 0; k < nSym; k++)
      PrintFormat("%-10s net %8.2f  (W:%d L:%d)", symNames[k], symNet[k], symWins[k], symLosses[k]);
   Print("CSV saved: MQL5/Files/trade_history.csv");
  }
//+------------------------------------------------------------------+
