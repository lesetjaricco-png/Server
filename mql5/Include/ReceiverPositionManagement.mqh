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
   int total = PositionsTotal();
   PrintFormat("[RX] BE-check: total positions=%d (checking Magic=%d)", total, (int)Magic);
   for(int index = 0; index < total; index++)
   {
      ulong ticket = PositionGetTicket(index);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
      {
         PrintFormat("[RX] BLOCK: cannot select ticket idx=%d -> fail BE check", index);
         return false;
      }
      if((long)PositionGetInteger(POSITION_MAGIC) != Magic) continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      long type = (long)PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double stopLoss = PositionGetDouble(POSITION_SL);
      double tolerance = 0.5 * GetSymbolPoint(symbol);
      if(stopLoss <= 0.0)
      {
         PrintFormat("[RX] BLOCK: %s #%I64u no SL -> NOT at BE", symbol, ticket);
         return false;
      }
      if(type == POSITION_TYPE_BUY && stopLoss < entry - tolerance)
      {
         PrintFormat("[RX] BLOCK: %s #%I64u BUY sl=%.5f entry=%.5f -> NOT BE", symbol, ticket, stopLoss, entry);
         return false;
      }
      if(type == POSITION_TYPE_SELL && stopLoss > entry + tolerance)
      {
         PrintFormat("[RX] BLOCK: %s #%I64u SELL sl=%.5f entry=%.5f -> NOT BE", symbol, ticket, stopLoss, entry);
         return false;
      }
      PrintFormat("[RX] BE-ok: %s #%I64u entry=%.5f sl=%.5f", symbol, ticket, entry, stopLoss);
   }
   Print("[RX] BE-check PASSED: all our positions are at BE");
   return true;
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
      double stopDistance = MathAbs(entry - stopLoss) / point;
      double riskPoints = 0.0;
      if(stopLoss > 0.0 && stopDistance > 0.0)
      {
         riskPoints = stopDistance;
         PrintFormat("[AUTO-BE] %s #%I64u: Current SL distance = %.1f points (R)", symbol, ticket, riskPoints);
      }
      else
      {
         ENUM_INSTR_TYPE instrumentType = GetInstrumentType(symbol);
         bool isGold = StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0;
         if(instrumentType == INSTR_TYPE_FOREX)
         {
            riskPoints = ForexSpreadPoints > 0.0 && ForexSpreadMultiplier > 0.0
               ? ForexSpreadPoints * ForexSpreadMultiplier : 50.0;
         }
         else if(instrumentType == INSTR_TYPE_COMMODITY)
         {
            if(isGold && UseGoldSpecificSettings && FixedSLPoints_Gold > 0.0)
               riskPoints = FixedSLPoints_Gold;
            else if(FixedSLPoints_Commodities > 0.0)
               riskPoints = FixedSLPoints_Commodities;
            else
               riskPoints = GetSafeStopPoints(symbol);
         }
         else
         {
            riskPoints = instrumentType == INSTR_TYPE_INDEX ? FixedSLPoints_Indices : FixedSLPoints_Other;
            if(riskPoints <= 0.0) riskPoints = GetSafeStopPoints(symbol);
         }
      }

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
      PrintFormat("[AUTO-BE] %s #%I64u: Move = %.1f pts, %.1fR = %.1f pts, SL=%.5f",
                  symbol, ticket, movePoints, AutoBE_Multiplier, AutoBE_Multiplier * riskPoints, stopLoss);

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
         else
            PrintFormat("[AUTO-BE] %s #%I64u: Already at BE or better", symbol, ticket);
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