#ifndef RECEIVER_ORDER_EXECUTION_MQH
#define RECEIVER_ORDER_EXECUTION_MQH

bool CalcDynamicLots(const string symbol, const string side,
                     double &lots_out, double &stop_loss_out, double &entry_price_out)
{
   lots_out = 0.0;
   stop_loss_out = 0.0;
   entry_price_out = 0.0;
   PrintFormat("[LOT_CALC] Starting calculation for %s %s", side, symbol);

   if(!EnsureSymbolInMarketWatch(symbol))
      PrintFormat("[LOT_CALC] WARNING: %s may have stale data", symbol);

   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick))
   {
      PrintFormat("[LOT_CALC] FAIL: Cannot get tick data for %s", symbol);
      return false;
   }

   double entryPrice = side == "BUY" ? tick.ask : tick.bid;
   entry_price_out = entryPrice;

   ENUM_INSTR_TYPE instrumentType = GetInstrumentType(symbol);
   bool isGold = IsGoldSymbol(symbol);
   double stopPoints = ReceiverSelectStopPoints(
      instrumentType == INSTR_TYPE_FOREX,
      instrumentType == INSTR_TYPE_COMMODITY,
      isGold,
      instrumentType == INSTR_TYPE_INDEX,
      UseGoldSpecificSettings,
      ForexSpreadPoints,
      ForexSpreadMultiplier,
      FixedSLPoints_Gold,
      FixedSLPoints_Commodities,
      FixedSLPoints_Indices,
      FixedSLPoints_Other,
      0.0
   );
   if(stopPoints <= 0.0)
      stopPoints = GetSafeStopPoints(symbol);
   if(stopPoints <= 0.0)
   {
      PrintFormat("[LOT_CALC] FAIL: Invalid stop distance for %s", symbol);
      return false;
   }

   double pointSize = GetSymbolPoint(symbol);
   if(!ReceiverCalculateStopPrice(side == "BUY", entryPrice, stopPoints, pointSize, stop_loss_out))
   {
      PrintFormat("[LOT_CALC] FAIL: Invalid stop price inputs for %s", symbol);
      return false;
   }

   double valuePerPoint = CalculateValuePerPoint(symbol);
   if(valuePerPoint <= 0.0)
   {
      PrintFormat("[LOT_CALC] FAIL: Invalid value per point for %s", symbol);
      return false;
   }

   double volumeMin = 0.0;
   double volumeMax = 0.0;
   double volumeStep = 0.0;
   if(!SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN, volumeMin) ||
      !SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX, volumeMax) ||
      !SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP, volumeStep))
   {
      PrintFormat("[LOT_CALC] FAIL: Cannot read volume constraints for %s", symbol);
      return false;
   }

   ReceiverLotPlan plan = ReceiverCalculateLotPlan(
      AccountInfoDouble(ACCOUNT_EQUITY),
      g_effRiskPerTradePct,
      stopPoints,
      valuePerPoint,
      volumeMin,
      volumeMax,
      volumeStep,
      MaxLotsCap
   );
   if(!plan.valid)
   {
      PrintFormat("[LOT_CALC] FAIL: %s", plan.failure);
      return false;
   }

   double lots = plan.lots;
   ENUM_ORDER_TYPE orderType = side == "BUY" ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double marginNeeded = 0.0;
   if(!OrderCalcMargin(orderType, symbol, lots, entryPrice, marginNeeded))
   {
      PrintFormat("[LOT_CALC] FAIL: Margin calculation failed for %s", symbol);
      return false;
   }

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(marginNeeded > freeMargin)
   {
      double previousLots = lots;
      if(!ReceiverAdjustLotsForMargin(lots, marginNeeded, freeMargin,
                                      volumeMin, volumeMax, volumeStep, lots))
      {
         PrintFormat("[LOT_CALC] FAIL: Cannot fit volume to available margin for %s", symbol);
         return false;
      }

      double adjustedMargin = 0.0;
      if(!OrderCalcMargin(orderType, symbol, lots, entryPrice, adjustedMargin) || adjustedMargin > freeMargin)
      {
         PrintFormat("[LOT_CALC] FAIL: Adjusted volume still exceeds free margin for %s", symbol);
         return false;
      }
      PrintFormat("[LOT_CALC] Margin adjustment: %.6f -> %.6f", previousLots, lots);
   }

   lots_out = lots;
   PrintFormat("[LOT_CALC] SUCCESS: Final lots = %.6f for %s", lots_out, symbol);
   LogToFile(StringFormat("[LOT_CALC] %s %s: StopPts=%.1f, ValuePerPoint=%.5f, Lots=%.6f",
                          side, symbol, stopPoints, valuePerPoint, lots_out));
   return lots_out > 0.0;
}

bool SafeTradeExecute(const string symbol, const string side, double lots, double stopLossPrice)
{
   string logMessage = StringFormat("[SAFE_TRADE] %s %s Lots=%.6f SL=%.5f",
                                    side, symbol, lots, stopLossPrice);
   Print(logMessage);
   LogToFile(logMessage);

   bool success = side == "BUY"
      ? Trade.Buy(lots, symbol, 0.0, stopLossPrice, 0.0)
      : Trade.Sell(lots, symbol, 0.0, stopLossPrice, 0.0);
   if(success) return true;

   uint retcode = Trade.ResultRetcode();
   string errorMessage = StringFormat("[SAFE_TRADE_FAILED] ret=%d (%s)",
                                      retcode, Trade.ResultRetcodeDescription());
   Print(errorMessage);
   LogToFile(errorMessage);
   if(retcode != 10016) return false;

   Print("[SAFE_TRADE] Invalid stops. Retrying once with increased stop distance.");
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick)) return false;

   double entry = side == "BUY" ? tick.ask : tick.bid;
   double point = GetSymbolPoint(symbol);
   double newDistance = MathMax(MathAbs(entry - stopLossPrice) * 1.5, 50.0 * point);
   double adjustedStop = side == "BUY" ? entry - newDistance : entry + newDistance;
   success = side == "BUY"
      ? Trade.Buy(lots, symbol, 0.0, adjustedStop, 0.0)
      : Trade.Sell(lots, symbol, 0.0, adjustedStop, 0.0);

   if(success)
   {
      Print("[SAFE_TRADE] Success after stop adjustment");
      LogToFile("[SAFE_TRADE] Success after adjustment");
   }
   return success;
}

#endif