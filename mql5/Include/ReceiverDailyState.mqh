#ifndef RECEIVER_DAILY_STATE_MQH
#define RECEIVER_DAILY_STATE_MQH

// Tracks the facts posted to /receiver-state. Thresholds that turn those facts
// into allow/block decisions live in the server configuration.

string DayStatePrefix()
{
   return "RX_" + IntegerToString(Magic) + "_";
}

void PersistTradingDay()
{
   string prefix = DayStatePrefix();
   GlobalVariableSet(prefix + "day", (double)g_dayAnchor);
   GlobalVariableSet(prefix + "start", g_equityAtDayStart);
}

void LoadPersistedDay()
{
   string prefix = DayStatePrefix();
   if(!GlobalVariableCheck(prefix + "day") || !GlobalVariableCheck(prefix + "start"))
      return;

   datetime storedDay = (datetime)GlobalVariableGet(prefix + "day");
   double storedStart = GlobalVariableGet(prefix + "start");
   if(storedDay != DayAnchor(TimeTradeServer()) || storedStart <= 0.0)
      return;

   g_dayAnchor = storedDay;
   g_equityAtDayStart = storedStart;
}

void CopyDailyState(ReceiverDailyState &state)
{
   state.day_anchor = (long)g_dayAnchor;
   state.start_balance = g_equityAtDayStart;
   state.closed_net = g_dailyClosedNet;
   state.losses = g_lossesToday;
   state.spikes = g_spikesToday;
   state.last_loss_time = (long)g_lastLossClose;
}

void StoreDailyState(const ReceiverDailyState &state)
{
   g_dayAnchor = (datetime)state.day_anchor;
   g_equityAtDayStart = state.start_balance;
   g_dailyClosedNet = state.closed_net;
   g_lossesToday = state.losses;
   g_spikesToday = state.spikes;
   g_lastLossClose = (datetime)state.last_loss_time;
}

double SpikeThresholdMoney()
{
   if(g_equityAtDayStart <= 0.0 || SpikeThresholdPct <= 0.0)
      return DBL_MAX;
   return g_equityAtDayStart * SpikeThresholdPct / 100.0;
}

bool ReadOurClosingNet(const ulong deal, double &net, long &closeTime)
{
   net = 0.0;
   closeTime = 0;
   if(deal == 0) return false;
   if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != (long)Magic) return false;

   long entry = (long)HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) return false;

   closeTime = (long)HistoryDealGetInteger(deal, DEAL_TIME);
   if(g_dayAnchor > 0 && closeTime > 0 && closeTime < (long)g_dayAnchor) return false;

   net = HistoryDealGetDouble(deal, DEAL_PROFIT)
       + HistoryDealGetDouble(deal, DEAL_COMMISSION)
       + HistoryDealGetDouble(deal, DEAL_SWAP);
   return IsFiniteNumber(net);
}

void ApplyReceiverDealToRuntime(const double net, const long closeTime, bool &wasLoss, bool &wasSpike, const bool announce)
{
   ReceiverDailyState state;
   CopyDailyState(state);
   if(!ReceiverApplyClosedDeal(state, true, true, true, net, SpikeThresholdMoney(), closeTime, 1e-6, wasLoss, wasSpike))
      return;
   StoreDailyState(state);
   if(!announce) return;
   LogToFile(StringFormat("%s %.2f", wasLoss ? "[LOSS]" : "[CLOSE]", net));
}

void RebuildDailyFactsFromHistory()
{
   if(g_equityAtDayStart <= 0.0)
      g_equityAtDayStart = AccountInfoDouble(ACCOUNT_BALANCE);

   datetime from = g_dayAnchor > 0 ? g_dayAnchor : DayAnchor(TimeTradeServer());
   if(!HistorySelect(from, TimeTradeServer()))
      return;

   int total = HistoryDealsTotal();
   if(g_equityAtDayStart <= 0.0)
   {
      double closedNet = 0.0;
      for(int index = 0; index < total; index++)
      {
         double net = 0.0;
         long closeTime = 0;
         if(ReadOurClosingNet(HistoryDealGetTicket(index), net, closeTime))
            closedNet += net;
      }

      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double derived = balance - closedNet;
      g_equityAtDayStart = derived > 0.0 ? derived : balance;
      if(g_equityAtDayStart < 0.0)
         g_equityAtDayStart = 0.0;
   }

   g_dailyClosedNet = 0.0;
   g_lossesToday = 0;
   g_spikesToday = 0;
   g_lastLossClose = 0;
   ArrayResize(g_processedDeals, 0);

   for(int index = 0; index < total; index++)
   {
      ulong deal = HistoryDealGetTicket(index);
      double net = 0.0;
      long closeTime = 0;
      if(!ReadOurClosingNet(deal, net, closeTime)) continue;
      if(!ReceiverMarkDealOnce(g_processedDeals, deal)) continue;

      bool wasLoss = false;
      bool wasSpike = false;
      ApplyReceiverDealToRuntime(net, closeTime, wasLoss, wasSpike, false);
   }
   PersistTradingDay();
}

void RefreshTradingDay(const bool rebuildFacts)
{
   datetime anchor = DayAnchor(TimeTradeServer());
   ReceiverDailyState state;
   CopyDailyState(state);
   long previousAnchor = state.day_anchor;
   bool reset = ReceiverApplyDailyReset(state, (long)anchor, AccountInfoDouble(ACCOUNT_BALANCE));
   if(reset)
      StoreDailyState(state);

   if(rebuildFacts || g_equityAtDayStart <= 0.0)
      RebuildDailyFactsFromHistory();

   if(reset && previousAnchor != 0)
   {
      string message = StringFormat("New trading day. Day-start balance %.2f", g_equityAtDayStart);
      Print("[RX] ", message);
      LogToFile("[NEW_DAY] " + message);
      SendNoticeOnce(message, 1);
   }
}

void OnTradeTransaction(const MqlTradeTransaction &transaction,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(transaction.type != TRADE_TRANSACTION_DEAL_ADD || transaction.deal == 0) return;

   datetime from = g_dayAnchor > 0 ? g_dayAnchor : TimeTradeServer();
   HistorySelect(from, TimeTradeServer());

   double net = 0.0;
   long closeTime = 0;
   if(!ReadOurClosingNet(transaction.deal, net, closeTime)) return;
   if(!ReceiverMarkDealOnce(g_processedDeals, transaction.deal)) return;
   if(closeTime <= 0) closeTime = (long)TimeTradeServer();

   bool wasLoss = false;
   bool wasSpike = false;
   ApplyReceiverDealToRuntime(net, closeTime, wasLoss, wasSpike, true);
}

void PollHistoryForNewCloses()
{
   datetime from = g_dayAnchor > 0 ? g_dayAnchor : DayAnchor(TimeTradeServer());
   if(!HistorySelect(from, TimeTradeServer())) return;

   int total = HistoryDealsTotal();
   for(int index = total - 1; index >= 0 && index >= total - 400; index--)
   {
      ulong deal = HistoryDealGetTicket(index);
      double net = 0.0;
      long closeTime = 0;
      if(!ReadOurClosingNet(deal, net, closeTime)) continue;
      if(!ReceiverMarkDealOnce(g_processedDeals, deal)) continue;
      if(closeTime <= 0) closeTime = (long)TimeTradeServer();

      bool wasLoss = false;
      bool wasSpike = false;
      ApplyReceiverDealToRuntime(net, closeTime, wasLoss, wasSpike, true);
   }
}

#endif
