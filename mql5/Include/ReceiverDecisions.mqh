#ifndef RECEIVER_DECISIONS_MQH
#define RECEIVER_DECISIONS_MQH

// Pure order-sizing and daily-fact helpers. Loss, profit, cooldown, spike-count,
// and break-even gates are evaluated by the server from the facts the EA reports.

struct ReceiverLotPlan
{
   bool valid;
   string failure;
   double risk_budget;
   double risk_per_lot;
   double raw_lots;
   double lots;
};

struct ReceiverDailyState
{
   long day_anchor;
   double start_balance;
   double closed_net;
   int losses;
   int spikes;
   long last_loss_time;
};

bool ReceiverIsLosingClosedDeal(
   const bool belongs_to_receiver,
   const bool is_closing_deal,
   const bool net_is_finite,
   const double net,
   const double loss_tolerance
)
{
   return belongs_to_receiver && is_closing_deal && net_is_finite && net < -loss_tolerance;
}

bool ReceiverMarkDealOnce(ulong &processed_tickets[], const ulong deal_ticket)
{
   if(deal_ticket == 0) return false;
   for(int index = 0; index < ArraySize(processed_tickets); index++)
      if(processed_tickets[index] == deal_ticket)
         return false;

   int count = ArraySize(processed_tickets);
   if(ArrayResize(processed_tickets, count + 1) != count + 1)
      return false;
   processed_tickets[count] = deal_ticket;
   return true;
}

bool ReceiverApplyClosedDeal(
   ReceiverDailyState &state,
   const bool belongs_to_receiver,
   const bool is_closing_deal,
   const bool net_is_finite,
   const double net,
   const double spike_threshold,
   const long close_time,
   const double loss_tolerance,
   bool &was_loss,
   bool &was_spike
)
{
   was_loss = false;
   was_spike = false;
   if(!belongs_to_receiver || !is_closing_deal || !net_is_finite)
      return false;

   state.closed_net += net;
   was_spike = spike_threshold > 0.0 && spike_threshold < DBL_MAX && MathAbs(net) >= spike_threshold;
   if(was_spike)
      state.spikes++;

   was_loss = ReceiverIsLosingClosedDeal(true, true, true, net, loss_tolerance);
   if(was_loss)
   {
      state.losses++;
      if(close_time > state.last_loss_time)
         state.last_loss_time = close_time;
   }
   return true;
}

double ReceiverSelectStopPoints(
   const bool is_forex,
   const bool is_commodity,
   const bool is_gold,
   const bool is_index,
   const bool use_gold_settings,
   const double forex_spread_points,
   const double forex_spread_multiplier,
   const double gold_points,
   const double commodity_points,
   const double index_points,
   const double other_points,
   const double safe_fallback_points
)
{
   double stop_points = 0.0;
   if(is_forex)
      stop_points = forex_spread_points > 0.0 && forex_spread_multiplier > 0.0
                    ? forex_spread_points * forex_spread_multiplier : 50.0;
   else if(is_commodity)
   {
      if(is_gold && use_gold_settings && gold_points > 0.0)
         stop_points = gold_points;
      else if(commodity_points > 0.0)
         stop_points = commodity_points;
      else
         stop_points = safe_fallback_points;
   }
   else
   {
      stop_points = is_index ? index_points : other_points;
      if(stop_points <= 0.0) stop_points = safe_fallback_points;
   }
   return stop_points;
}

bool ReceiverSnapLots(
   const double requested_lots,
   const double minimum_lots,
   const double maximum_lots,
   const double volume_step,
   double &snapped_lots
)
{
   snapped_lots = 0.0;
   if(requested_lots <= 0.0 || minimum_lots <= 0.0 || maximum_lots < minimum_lots)
      return false;

   if(volume_step <= 0.0)
   {
      snapped_lots = NormalizeDouble(requested_lots, 2);
      return snapped_lots > 0.0;
   }

   double value = MathFloor((requested_lots + 1e-12) / volume_step) * volume_step;
   if(value < minimum_lots) value = minimum_lots;
   if(value > maximum_lots) value = maximum_lots;

   int digits = 0;
   double scaled_step = volume_step;
   while(scaled_step < 1.0 && digits < 10)
   {
      scaled_step *= 10.0;
      digits++;
   }
   snapped_lots = NormalizeDouble(value, digits);
   return snapped_lots > 0.0;
}

ReceiverLotPlan ReceiverCalculateLotPlan(
   const double equity,
   const double risk_percent,
   const double stop_points,
   const double value_per_point_per_lot,
   const double minimum_lots,
   const double maximum_lots,
   const double volume_step,
   const double maximum_lots_cap
)
{
   ReceiverLotPlan result;
   result.valid = false;
   result.failure = "invalid inputs";
   result.risk_budget = 0.0;
   result.risk_per_lot = 0.0;
   result.raw_lots = 0.0;
   result.lots = 0.0;

   if(equity <= 0.0 || risk_percent <= 0.0 || stop_points <= 0.0 ||
      value_per_point_per_lot <= 0.0 || minimum_lots <= 0.0 || maximum_lots < minimum_lots)
      return result;

   result.risk_budget = equity * risk_percent / 100.0;
   if(result.risk_budget <= 0.0)
   {
      result.failure = "risk budget exhausted";
      return result;
   }

   result.risk_per_lot = stop_points * value_per_point_per_lot;
   if(result.risk_per_lot <= 0.0)
   {
      result.failure = "invalid risk per lot";
      return result;
   }

   result.raw_lots = result.risk_budget / result.risk_per_lot;
   if(result.raw_lots < minimum_lots)
   {
      result.failure = "risk budget below minimum volume";
      return result;
   }
   if(!ReceiverSnapLots(result.raw_lots, minimum_lots, maximum_lots, volume_step, result.lots))
   {
      result.failure = "volume normalization failed";
      return result;
   }
   if(maximum_lots_cap > 0.0 && result.lots > maximum_lots_cap)
      result.lots = maximum_lots_cap;

   result.valid = result.lots > 0.0;
   result.failure = result.valid ? "" : "no valid volume";
   return result;
}

bool ReceiverAdjustLotsForMargin(
   const double initial_lots,
   const double margin_needed,
   const double free_margin,
   const double minimum_lots,
   const double maximum_lots,
   const double volume_step,
   double &adjusted_lots
)
{
   adjusted_lots = initial_lots;
   if(initial_lots <= 0.0 || margin_needed < 0.0 || free_margin < 0.0)
      return false;
   if(margin_needed <= free_margin)
      return true;
   if(margin_needed <= 0.0 || free_margin <= 0.0)
      return false;

   double reduced_lots = initial_lots * free_margin / margin_needed;
   if(reduced_lots < minimum_lots)
      return false;
   return ReceiverSnapLots(reduced_lots, minimum_lots, maximum_lots, volume_step, adjusted_lots);
}

bool ReceiverCalculateStopPrice(
   const bool is_buy,
   const double entry_price,
   const double stop_points,
   const double point_size,
   double &stop_price
)
{
   stop_price = 0.0;
   if(entry_price <= 0.0 || stop_points <= 0.0 || point_size <= 0.0)
      return false;
   stop_price = entry_price + (is_buy ? -1.0 : 1.0) * stop_points * point_size;
   return stop_price > 0.0;
}

bool ReceiverApplyDailyReset(
   ReceiverDailyState &state,
   const long current_day_anchor,
   const double start_balance
)
{
   if(current_day_anchor == state.day_anchor)
      return false;

   state.day_anchor = current_day_anchor;
   state.start_balance = start_balance;
   state.closed_net = 0.0;
   state.losses = 0;
   state.spikes = 0;
   state.last_loss_time = 0;
   return true;
}

#endif
