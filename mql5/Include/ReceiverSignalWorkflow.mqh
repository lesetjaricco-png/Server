#ifndef RECEIVER_SIGNAL_WORKFLOW_MQH
#define RECEIVER_SIGNAL_WORKFLOW_MQH

// Included by Receiver.mq5 after the receiver's helpers and globals are defined.

bool AcknowledgePendingSignal(const string headers)
{
   string responseBody, responseHeaders;
   return HttpGet(URL_ACK(), responseBody, responseHeaders, headers);
}

void ProcessPendingServerSignal()
{
   string body, responseHeaders;
   string headers = "X-Auth-Token: " + AUTH_SHARED;
   if(!HttpGet(URL_NEXT(), body, responseHeaders, headers)) return;
   if(!ReceiverJsonTrue(body, "ok") || ReceiverJsonTrue(body, "empty")) return;

   ReceiverSignal signal;
   if(!ReceiverParseSignal(body, signal))
   {
      if(ReceiverJsonTrue(body, "ok") && !ReceiverJsonTrue(body, "empty"))
      {
         Print("[RX] Invalid signal payload; acknowledging to avoid repeated polling");
         AcknowledgePendingSignal(headers);
      }
      return;
   }
   if(!signal.has_signal) return;

   string signalId = signal.id;
   if(signalId != "" && signalId == g_lastAckedSignalID)
   {
      Print("[DEDUPE] Already processed signal: ", signalId);
      AcknowledgePendingSignal(headers);
      return;
   }

   long ageSeconds = 0;
   if(ReceiverSignalExpired(signal, (long)TimeGMT(), SignalMaxAgeSeconds, ageSeconds))
   {
      NotifyGateBlocked("Signal Expired", StringFormat("Age: %d seconds > %d seconds", ageSeconds, SignalMaxAgeSeconds));
      LogToFile("[SIGNAL_EXPIRED] Age: " + IntegerToString(ageSeconds) + "s");
      AcknowledgePendingSignal(headers);
      return;
   }

   string side = signal.side;
   string symbol = signal.symbol;
   string requestedLots = signal.lots_text;
   PrintFormat("[RX] ======= PROCESSING SIGNAL =======");
   PrintFormat("[RX] Signal: %s %s | Magic: %d", side, symbol, Magic);

   if(!EnsureSymbolInMarketWatch(symbol))
   {
      PrintFormat("[RX] CRITICAL: %s not available in Market Watch. Signal rejected.", symbol);
      AcknowledgePendingSignal(headers);
      return;
   }

   Print("[RX] Processing signal - server gates passed");
   LogToFile("[SIGNAL_RECEIVED] " + side + " " + symbol);

   if(side != "BUY" && side != "SELL")
   {
      Print("[RX] Invalid side: " + side);
      AcknowledgePendingSignal(headers);
      return;
   }
   if(symbol == "")
   {
      Print("[RX] Empty symbol");
      AcknowledgePendingSignal(headers);
      return;
   }
   if(!PrepareSymbol(symbol))
   {
      Print("[RX] Cannot prepare symbol: " + symbol);
      AcknowledgePendingSignal(headers);
      return;
   }

   double dynamicLots = 0.0;
   double stopLossPrice = 0.0;
   double entryPrice = 0.0;
   bool hasDynamicPlan = CalcDynamicLots(symbol, side, dynamicLots, stopLossPrice, entryPrice);

   if(!hasDynamicPlan || dynamicLots <= 0.0)
   {
      Print("[RX] Dynamic lot calculation failed, using fallback");
      if(requestedLots == "")
      {
         Print("[RX] ERROR: Dynamic lots failed and no static lots provided");
         AcknowledgePendingSignal(headers);
         return;
      }

      dynamicLots = StringToDouble(requestedLots);
      if(dynamicLots <= 0.0)
      {
         Print("[RX] ERROR: Invalid static lots: " + requestedLots);
         AcknowledgePendingSignal(headers);
         return;
      }
      if(!SnapLots(symbol, dynamicLots))
      {
         Print("[RX] ERROR: Cannot snap static lots for: " + symbol);
         AcknowledgePendingSignal(headers);
         return;
      }

      MqlTick tick;
      if(!SymbolInfoTick(symbol, tick))
      {
         Print("[RX] ERROR: Cannot get tick data for fallback");
         AcknowledgePendingSignal(headers);
         return;
      }
      entryPrice = side == "BUY" ? tick.ask : tick.bid;

      ENUM_INSTR_TYPE instrumentType = GetInstrumentType(symbol);
      bool isGold = StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0;
      double fixedPoints = ReceiverSelectStopPoints(
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
         GetSafeStopPoints(symbol)
      );
      double pointSize = GetSymbolPoint(symbol);
      double stopDistance = fixedPoints * pointSize;
      stopLossPrice = side == "BUY" ? tick.bid - stopDistance : tick.ask + stopDistance;
   }

   if(stopLossPrice <= 0.0 || entryPrice <= 0.0)
   {
      Print("[RX] CRITICAL: Invalid prices - Entry: ", entryPrice, ", SL: ", stopLossPrice);
      LogToFile("[VALIDATION_FAILED] Invalid prices");
      AcknowledgePendingSignal(headers);
      return;
   }
   if((side == "BUY" && stopLossPrice >= entryPrice) ||
      (side == "SELL" && stopLossPrice <= entryPrice))
   {
      Print("[RX] ERROR: Stop loss is in wrong direction!");
      LogToFile("[VALIDATION_FAILED] Wrong SL direction");
      AcknowledgePendingSignal(headers);
      return;
   }

   if(EnableMinStopDistance)
   {
      double pointSize = GetSymbolPoint(symbol);
      double minimumDistance = MinStopDistancePoints * pointSize;
      if(MathAbs(entryPrice - stopLossPrice) < minimumDistance)
      {
         PrintFormat("[RX] WARNING: SL too close (%.5f price units). Adjusting to minimum %.5f price units.",
                     MathAbs(entryPrice - stopLossPrice), minimumDistance);
         stopLossPrice = side == "BUY" ? entryPrice - minimumDistance : entryPrice + minimumDistance;
      }
   }

   PrintFormat("[RX] Final trade parameters: %s %s Entry=%.5f Lots=%.6f SL=%.5f",
               side, symbol, entryPrice, dynamicLots, stopLossPrice);

   if(!SafeTradeExecute(symbol, side, dynamicLots, stopLossPrice))
   {
      PrintFormat("[RX] Trade failed: ret=%d (%s)", Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
      AcknowledgePendingSignal(headers);
      return;
   }

   Print("[RX] Trade executed successfully with SL");
   LogToFile("[TRADE_EXECUTED] " + side + " " + symbol + " Lots:" + DoubleToString(dynamicLots, 6));
   if(signalId != "") g_lastAckedSignalID = signalId;

   for(int index = 0; index < PositionsTotal(); index++)
   {
      ulong ticket = PositionGetTicket(index);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      long type = (long)PositionGetInteger(POSITION_TYPE);
      double stopLoss = PositionGetDouble(POSITION_SL);
      if(stopLoss > 0.0) ObserveOrSetBoundary(ticket, type, stopLoss);
   }

   g_tradesToday++;
   if(!AcknowledgePendingSignal(headers))
      Print("[RX] WARN: /ack failed (signal may repeat)");
   else
      Print("[RX] Signal processed successfully");
}

#endif