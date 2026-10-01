#ifndef RECEIVER_DAILY_STATE_MQH
#define RECEIVER_DAILY_STATE_MQH

void LogGateStatus()
{
   string status = StringFormat(
      "[GATE_STATUS] Losses: %d/%d | Spikes: %d/%d | LossCap: %.2f/%.2f | Profit: %.2f/%.2f | Cooldown: %s",
      g_lossesToday, g_effMaxLossesPerDay,
      g_spikesToday, MaxDailySpikes,
      g_equityAtDayStart - AccountInfoDouble(ACCOUNT_BALANCE), g_equityLossLimit,
      g_dailyClosedNet, g_profitTargetAbs,
      CooldownActive() ? "ACTIVE" : "INACTIVE"
   );
   Print(status);
   LogToFile(status);
}

string BuildRiskLeftMessage()
{
   double used = MathMax(0.0, g_equityAtDayStart - AccountInfoDouble(ACCOUNT_BALANCE));
   double remaining = MathMax(0.0, g_equityLossLimit - used);
   string message = StringFormat("Risk left today: %.2f (cap %.2f). Losses today: %d/%d",
                                 remaining, g_equityLossLimit, g_lossesToday, g_effMaxLossesPerDay);
   if(CooldownMinsAfterLoss > 0 && g_lastLossClose > 0)
   {
      datetime nextTrade = (datetime)((long)g_lastLossClose + (long)CooldownMinsAfterLoss * 60);
      message += StringFormat(" Next trade at (server) %s", FormatDT(nextTrade));
   }
   return message;
}

void NotifyRiskLeft()
{
   datetime now = TimeTradeServer();
   if(now - g_lastRiskNotify < 3) return;
   SendNoticeOnce(BuildRiskLeftMessage(), 1);
   g_lastRiskNotify = now;
}

void ResetDailyIfNeeded()
{
   datetime now = TimeTradeServer();
   datetime anchor = DayAnchor(now);
   ReceiverDailyState state;
   state.day_anchor = (long)g_dayAnchor;
   state.start_balance = g_equityAtDayStart;
   state.loss_limit = g_equityLossLimit;
   state.profit_target = g_profitTargetAbs;
   state.closed_net = g_dailyClosedNet;
   state.trades = g_tradesToday;
   state.losses = g_lossesToday;
   state.spikes = g_spikesToday;
   state.last_loss_time = (long)g_lastLossClose;

   if(!ReceiverApplyDailyReset(state, (long)anchor, AccountInfoDouble(ACCOUNT_BALANCE),
                               DailyLossCapPct, DailyProfitTargetPct))
      return;

   g_dayAnchor = (datetime)state.day_anchor;
   g_equityAtDayStart = state.start_balance;
   g_equityLossLimit = state.loss_limit;
   g_profitTargetAbs = state.profit_target;
   g_dailyClosedNet = state.closed_net;
   g_tradesToday = state.trades;
   g_lossesToday = state.losses;
   g_spikesToday = state.spikes;
   g_lastLossClose = (datetime)state.last_loss_time;

   string message = StringFormat("New day - BalanceStart: %.2f | LossCap: %.2f (%.2f%%) | ProfitTarget: %.2f (%.2f%%) | MaxLosses: %d",
                                 g_equityAtDayStart, g_equityLossLimit, DailyLossCapPct,
                                 g_profitTargetAbs, DailyProfitTargetPct, g_effMaxLossesPerDay);
   SendNoticeOnce(message, 1);
   SendDailyResetEmail(now);
   LogToFile("[NEW_DAY] " + message);
   LogGateStatusOncePerHour();
}

void SendDailyResetEmail(const datetime serverTime)
{
   if(!EnableMail) return;
   string subject = StringFormat("New Trading Day Started - EA #%d", Magic);
   string body = StringFormat(
      "=== NEW TRADING DAY STARTED ===\n\n"
      "Account: %s\n"
      "EA Magic: %d\n"
      "Server Time: %s\n\n"
      "--- DAILY SETTINGS ---\n"
      "Starting Balance: $%.2f\n"
      "Daily Loss Cap: $%.2f (%.1f%%)\n"
      "Daily Profit Target: $%.2f (%.1f%%)\n"
      "Max Losses Per Day: %d\n"
      "Cooldown After Loss: %d minutes\n\n"
      "--- INSTRUMENT SETTINGS ---\n"
      "Forex Spread: %.1f points\n"
      "Forex Spread Multiplier: %.1f\n"
      "Forex SL Points: %.1f (%.1f x %.1f)\n"
      "Indices SL Points: %.1f\n"
      "Gold SL Points: %.1f\n"
      "Commodities SL Points: %.1f\n"
      "Other SL Points: %.1f\n\n"
      "Risk Per Trade: %.1f%%\n"
      "30-Day Mode: %s\n"
      "Auto-BE at %.1fR: %s\n\n"
      "=== Trading Day Active ===\n",
      AccountInfoString(ACCOUNT_NAME), Magic, TimeToString(serverTime, TIME_DATE | TIME_SECONDS),
      g_equityAtDayStart, g_equityLossLimit, DailyLossCapPct,
      g_profitTargetAbs, DailyProfitTargetPct, g_effMaxLossesPerDay,
      CooldownMinsAfterLoss, ForexSpreadPoints, ForexSpreadMultiplier,
      ForexSpreadPoints * ForexSpreadMultiplier, ForexSpreadPoints, ForexSpreadMultiplier,
      FixedSLPoints_Indices, FixedSLPoints_Gold, FixedSLPoints_Commodities, FixedSLPoints_Other,
      g_effRiskPerTradePct, EnforceSchedule ? "SCHEDULED" : "CONTINUOUS",
      AutoBE_Multiplier, AutoBE_3R_Enable ? "ENABLED" : "DISABLED"
   );
   if(!SendMail(subject, body))
      Print("[NEW_DAY] WARNING: Failed to send new day email");
   else
      Print("[NEW_DAY] New day email sent successfully");
}

void LogGateStatusOncePerHour()
{
   static datetime lastGateLog = 0;
   if(TimeCurrent() - lastGateLog <= 3600) return;
   LogGateStatus();
   lastGateLog = TimeCurrent();
}

bool ApplyReceiverDealToRuntime(
   const bool belongsToReceiver,
   const bool isClosingDeal,
   const bool netIsFinite,
   const double net,
   const long closeTime,
   bool &wasLoss,
   bool &wasSpike
)
{
   ReceiverDailyState state;
   state.day_anchor = (long)g_dayAnchor;
   state.start_balance = g_equityAtDayStart;
   state.loss_limit = g_equityLossLimit;
   state.profit_target = g_profitTargetAbs;
   state.closed_net = g_dailyClosedNet;
   state.trades = g_tradesToday;
   state.losses = g_lossesToday;
   state.spikes = g_spikesToday;
   state.last_loss_time = (long)g_lastLossClose;

   if(!ReceiverApplyClosedDeal(state, belongsToReceiver, isClosingDeal, netIsFinite, net,
                               g_equityAtDayStart * (SpikeThresholdPct / 100.0),
                               closeTime, 1e-6, wasLoss, wasSpike))
      return false;

   g_dailyClosedNet = state.closed_net;
   g_lossesToday = state.losses;
   g_spikesToday = state.spikes;
   g_lastLossClose = (datetime)state.last_loss_time;
   return true;
}

void OnTradeTransaction(const MqlTradeTransaction &transaction,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(transaction.type != TRADE_TRANSACTION_DEAL_ADD || transaction.deal == 0) return;
   if(transaction.deal <= g_startupDealWatermark) return;

   long entry = (long)HistoryDealGetInteger(transaction.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) return;
   if(HistoryDealGetInteger(transaction.deal, DEAL_MAGIC) != (long)Magic) return;

   double net = HistoryDealGetDouble(transaction.deal, DEAL_PROFIT)
              + HistoryDealGetDouble(transaction.deal, DEAL_COMMISSION)
              + HistoryDealGetDouble(transaction.deal, DEAL_SWAP);
   if(!IsFiniteNumber(net))
   {
      PrintFormat("[RX] WARNING: non-finite deal result for deal %I64u", transaction.deal);
      return;
   }
   if(!ReceiverMarkDealOnce(g_processedDeals, transaction.deal)) return;

   bool wasLoss = false;
   bool wasSpike = false;
   ApplyReceiverDealToRuntime(true, true, true, net, (long)TimeTradeServer(), wasLoss, wasSpike);
   if(wasLoss)
   {
      NotifyRiskLeft();
      LogToFile("[LOSS] " + DoubleToString(net, 2));
   }
   else
      LogToFile("[PROFIT] " + DoubleToString(net, 2));
}

void PollHistoryForLoss()
{
   datetime from = g_dayAnchor > 0 ? g_dayAnchor : TimeTradeServer() - 3 * 24 * 60 * 60;
   HistorySelect(from, TimeTradeServer());
   int total = HistoryDealsTotal();
   if(total <= 0) return;

   for(int index = total - 1; index >= 0 && index >= total - 400; index--)
   {
      ulong deal = HistoryDealGetTicket(index);
      if(deal == 0 || deal <= g_startupDealWatermark) continue;
      if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != (long)Magic) continue;
      long entry = (long)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;

      double net = HistoryDealGetDouble(deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(deal, DEAL_COMMISSION)
                 + HistoryDealGetDouble(deal, DEAL_SWAP);
      if(!IsFiniteNumber(net))
      {
         PrintFormat("[RX] WARNING: non-finite historical deal result for deal %I64u", deal);
         continue;
      }
      if(!ReceiverMarkDealOnce(g_processedDeals, deal)) continue;

      bool wasLoss = false;
      bool wasSpike = false;
      ApplyReceiverDealToRuntime(true, true, true, net, (long)TimeTradeServer(), wasLoss, wasSpike);
      if(wasLoss) NotifyRiskLeft();
   }
}

void RecomputeDailyLosses()
{
   datetime from = g_dayAnchor > 0 ? g_dayAnchor : TimeTradeServer() - 3 * 24 * 60 * 60;
   HistorySelect(from, TimeTradeServer());
   int total = HistoryDealsTotal();
   int lossesToday = 0;
   for(int index = total - 1; index >= 0; index--)
   {
      ulong deal = HistoryDealGetTicket(index);
      if(deal == 0 || (long)HistoryDealGetInteger(deal, DEAL_MAGIC) != (long)Magic) continue;
      long entry = (long)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;

      double net = HistoryDealGetDouble(deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(deal, DEAL_COMMISSION)
                 + HistoryDealGetDouble(deal, DEAL_SWAP);
      if(ReceiverIsLosingClosedDeal(true, true, IsFiniteNumber(net), net, 1e-6))
         lossesToday++;
   }
   g_lossesToday = lossesToday;
}

#endif