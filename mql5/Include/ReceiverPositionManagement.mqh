#ifndef RECEIVER_POSITION_MANAGEMENT_MQH
#define RECEIVER_POSITION_MANAGEMENT_MQH

int IndexOfTicket(const ulong ticket)
{
   for(int index = 0; index < ArraySize(gTickets); index++)
      if(gTickets[index] == ticket) return index;
   return -1;
}

void ObserveOrSetBoundary(const ulong ticket, const long type, const double stopLoss)
{
   int index = IndexOfTicket(ticket);
   if(index < 0)
   {
      int count = ArraySize(gTickets);
      ArrayResize(gTickets, count + 1);
      ArrayResize(gBoundarySL, count + 1);
      ArrayResize(gTypeOfTicket, count + 1);
      gTickets[count] = ticket;
      gTypeOfTicket[count] = type;
      gBoundarySL[count] = stopLoss;
      return;
   }

   gTypeOfTicket[index] = type;
   if(type == POSITION_TYPE_BUY)
   {
      if(stopLoss > gBoundarySL[index]) gBoundarySL[index] = stopLoss;
   }
   else if(stopLoss < gBoundarySL[index])
      gBoundarySL[index] = stopLoss;
}

bool CloseIfWidened(const string symbol, const ulong ticket, const long type, const double stopLoss)
{
   int index = IndexOfTicket(ticket);
   if(index < 0)
   {
      if(stopLoss > 0.0) ObserveOrSetBoundary(ticket, type, stopLoss);
      return false;
   }

   double tolerance = 0.5 * GetSymbolPoint(symbol);
   bool widened = type == POSITION_TYPE_BUY
      ? stopLoss <= 0.0 || stopLoss < gBoundarySL[index] - tolerance
      : stopLoss <= 0.0 || stopLoss > gBoundarySL[index] + tolerance;
   if(widened)
   {
      if(!Trade.PositionClose(ticket))
         PrintFormat("[RX] Close FAIL %s #%I64u ret=%d (%s)", symbol, ticket,
                     Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
      return true;
   }

   if(stopLoss > 0.0) ObserveOrSetBoundary(ticket, type, stopLoss);
   return false;
}

void NukeForeignsByMagic()
{
   for(int index = PositionsTotal() - 1; index >= 0; index--)
   {
      ulong ticket = PositionGetTicket(index);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) == Magic) continue;
      string symbol = PositionGetString(POSITION_SYMBOL);
      if(!Trade.PositionClose(ticket))
         PrintFormat("[RX] NUKE FAIL pos %s #%I64u ret=%d (%s)", symbol, ticket,
                     Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
   }
   for(int index = OrdersTotal() - 1; index >= 0; index--)
   {
      ulong ticket = OrderGetTicket(index);
      if(ticket == 0 || !OrderSelect(ticket)) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) == Magic) continue;
      if(!Trade.OrderDelete(ticket))
         PrintFormat("[RX] NUKE FAIL order #%I64u ret=%d (%s)", ticket,
                     Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
   }
}

bool AllOurPositionsAtBE()
{
   bool atBreakEven = true;
   string reason = "";
   for(int index = 0; index < PositionsTotal(); index++)
   {
      ulong ticket = PositionGetTicket(index);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
      {
         atBreakEven = false;
         reason = "position could not be selected";
         break;
      }
      if((long)PositionGetInteger(POSITION_MAGIC) != Magic) continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      long type = (long)PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double stopLoss = PositionGetDouble(POSITION_SL);
      double tolerance = 0.5 * GetSymbolPoint(symbol);
      if(stopLoss <= 0.0 ||
         (type == POSITION_TYPE_BUY && stopLoss < entry - tolerance) ||
         (type == POSITION_TYPE_SELL && stopLoss > entry + tolerance))
      {
         atBreakEven = false;
         reason = StringFormat("%s #%I64u", symbol, ticket);
         break;
      }
   }

   static bool lastResult = true;
   static string lastReason = "";
   if(atBreakEven != lastResult || reason != lastReason)
   {
      if(atBreakEven)
         Print("[RX] Managed positions are at break-even");
      else
         Print("[RX] Break-even open: ", reason);
      lastResult = atBreakEven;
      lastReason = reason;
   }
   return atBreakEven;
}

void MaintainPositions()
{
   for(int index = 0; index < PositionsTotal(); index++)
   {
      ulong ticket = PositionGetTicket(index);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != Magic) continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      long type = (long)PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double stopLoss = PositionGetDouble(POSITION_SL);
      if(CloseIfWidened(symbol, ticket, type, stopLoss)) continue;
      if(!AutoBE_3R_Enable)
      {
         if(stopLoss > 0.0) ObserveOrSetBoundary(ticket, type, stopLoss);
         continue;
      }

      double point = GetSymbolPoint(symbol);
      double stopDistance = stopLoss > 0.0 ? MathAbs(entry - stopLoss) / point : 0.0;
      double riskPoints = stopDistance > 0.0 ? stopDistance : GetSafeStopPoints(symbol);

      if(riskPoints <= 0.0)
      {
         if(stopLoss > 0.0) ObserveOrSetBoundary(ticket, type, stopLoss);
         continue;
      }

      MqlTick tick;
      if(!SymbolInfoTick(symbol, tick))
      {
         PrintFormat("[AUTO-BE] WARN: Cannot get tick data for %s", symbol);
         if(stopLoss > 0.0) ObserveOrSetBoundary(ticket, type, stopLoss);
         continue;
      }
      double current = type == POSITION_TYPE_BUY ? tick.bid : tick.ask;
      double movePoints = MathAbs(current - entry) / point;
      if(movePoints >= AutoBE_Multiplier * riskPoints - 0.5)
      {
         double desiredStop = entry;
         double tolerance = 0.5 * point;
         bool needsModify = stopLoss == 0.0 ||
            (type == POSITION_TYPE_BUY && stopLoss < desiredStop - tolerance) ||
            (type == POSITION_TYPE_SELL && stopLoss > desiredStop + tolerance);
         if(needsModify)
         {
            double takeProfit = PositionGetDouble(POSITION_TP);
            if(Trade.PositionModify(ticket, desiredStop, takeProfit))
            {
               PrintFormat("[AUTO-BE] SUCCESS: Moved SL to BE at +%.1fR (%.5f) for %s #%I64u",
                           AutoBE_Multiplier, desiredStop, symbol, ticket);
               ObserveOrSetBoundary(ticket, type, desiredStop);
               LogToFile("[AUTO-BE] Moved to BE: " + symbol + " #" + IntegerToString(ticket));
            }
            else
            {
               PrintFormat("[AUTO-BE] FAILED: Modify error %d (%s) for %s #%I64u",
                           Trade.ResultRetcode(), Trade.ResultRetcodeDescription(), symbol, ticket);
            }
         }
      }
      if(stopLoss > 0.0) ObserveOrSetBoundary(ticket, type, stopLoss);
   }
}

void CheckAndRepairState()
{
   if(!EnableSelfHealing) return;
   static datetime lastCheck = 0;
   if(TimeCurrent() - lastCheck < 3600) return;
   lastCheck = TimeCurrent();

   int removed = 0;
   for(int index = ArraySize(gTickets) - 1; index >= 0; index--)
   {
      if(PositionSelectByTicket(gTickets[index])) continue;
      ArrayRemove(gTickets, index, 1);
      ArrayRemove(gBoundarySL, index, 1);
      ArrayRemove(gTypeOfTicket, index, 1);
      removed++;
   }
   if(removed > 0)
   {
      PrintFormat("[SELF-HEAL] Removed %d orphaned anti-widen entries", removed);
      LogToFile("[SELF-HEAL] Cleaned " + IntegerToString(removed) + " orphaned entries");
   }

   if(AccountInfoDouble(ACCOUNT_EQUITY) <= 0.0)
   {
      Print("[SELF-HEAL] CRITICAL: Zero equity detected!");
      LogToFile("[SELF-HEAL] Zero equity emergency");
   }
}

#endif