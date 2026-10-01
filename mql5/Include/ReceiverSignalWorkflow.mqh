#ifndef RECEIVER_SIGNAL_WORKFLOW_MQH
#define RECEIVER_SIGNAL_WORKFLOW_MQH

// Polls /next and executes a signal the server has already released.

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
   if(!ReceiverParseSignal(body, signal) || !signal.has_signal)
   {
      Print("[RX] Invalid signal payload; acknowledging so it is not polled again");
      AcknowledgePendingSignal(headers);
      return;
   }

   if(signal.id != "" && signal.id == g_lastAckedSignalID)
   {
      AcknowledgePendingSignal(headers);
      return;
   }

   long ageSeconds = 0;
   if(ReceiverSignalExpired(signal, (long)TimeGMT(), SignalMaxAgeSeconds, ageSeconds))
   {
      PrintFormat("[RX] Signal expired (%d s old, max %d s)", ageSeconds, SignalMaxAgeSeconds);
      LogToFile("[SIGNAL_EXPIRED] Age: " + IntegerToString(ageSeconds) + "s");
      AcknowledgePendingSignal(headers);
      return;
   }

   string side = signal.side;
   string symbol = signal.symbol;
   PrintFormat("[RX] Signal %s %s", side, symbol);
   LogToFile("[SIGNAL_RECEIVED] " + side + " " + symbol);

   if(!EnsureSymbolInMarketWatch(symbol) || !PrepareSymbol(symbol))
   {
      PrintFormat("[RX] Symbol unavailable: %s", symbol);
      AcknowledgePendingSignal(headers);
      return;
   }

   double lots = 0.0;
   double stopLossPrice = 0.0;
   double entryPrice = 0.0;
   if(!CalcDynamicLots(symbol, side, lots, stopLossPrice, entryPrice))
   {
      lots = signal.lots;
      if(!SnapLots(symbol, lots))
      {
         Print("[RX] Lot calculation failed");
         AcknowledgePendingSignal(headers);
         return;
      }

      MqlTick tick;
      if(!SymbolInfoTick(symbol, tick))
      {
         Print("[RX] No tick for fallback stop");
         AcknowledgePendingSignal(headers);
         return;
      }
      entryPrice = side == "BUY" ? tick.ask : tick.bid;
      if(!ReceiverCalculateStopPrice(side == "BUY", entryPrice, GetSafeStopPoints(symbol), GetSymbolPoint(symbol), stopLossPrice))
      {
         Print("[RX] Fallback stop price failed");
         AcknowledgePendingSignal(headers);
         return;
      }
   }

   if(stopLossPrice <= 0.0 || entryPrice <= 0.0 ||
      (side == "BUY" && stopLossPrice >= entryPrice) ||
      (side == "SELL" && stopLossPrice <= entryPrice))
   {
      PrintFormat("[RX] Invalid trade prices entry=%.5f sl=%.5f", entryPrice, stopLossPrice);
      LogToFile("[VALIDATION_FAILED] Invalid prices");
      AcknowledgePendingSignal(headers);
      return;
   }

   if(EnableMinStopDistance)
   {
      double minimumDistance = MinStopDistancePoints * GetSymbolPoint(symbol);
      if(MathAbs(entryPrice - stopLossPrice) < minimumDistance)
         stopLossPrice = side == "BUY" ? entryPrice - minimumDistance : entryPrice + minimumDistance;
   }

   PrintFormat("[RX] %s %s lots=%.6f entry=%.5f sl=%.5f", side, symbol, lots, entryPrice, stopLossPrice);
   if(!SafeTradeExecute(symbol, side, lots, stopLossPrice))
   {
      PrintFormat("[RX] Trade failed: ret=%d (%s)", Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
      AcknowledgePendingSignal(headers);
      return;
   }

   LogToFile("[TRADE_EXECUTED] " + side + " " + symbol + " Lots:" + DoubleToString(lots, 6));
   if(signal.id != "") g_lastAckedSignalID = signal.id;

   for(int index = 0; index < PositionsTotal(); index++)
   {
      ulong ticket = PositionGetTicket(index);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      double stopLoss = PositionGetDouble(POSITION_SL);
      if(stopLoss > 0.0)
         ObserveOrSetBoundary(ticket, (long)PositionGetInteger(POSITION_TYPE), stopLoss);
   }

   if(!AcknowledgePendingSignal(headers))
      Print("[RX] /ack failed; the signal may be offered again");
}

#endif
