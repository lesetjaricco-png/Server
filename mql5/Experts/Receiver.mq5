//+------------------------------------------------------------------+
//| Receiver                                                         |
//| Reports account, schedule, and position facts to the guard       |
//| server, then executes signals the server has already released.  |
//| Daily loss, profit, loss-count, spike-count, cooldown, and      |
//| break-even gates are server settings. This EA does not apply    |
//| them again.                                                      |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
#include "../Include/ReceiverProtocol.mqh"
#include "../Include/ReceiverDecisions.mqh"

CTrade Trade;

enum ENUM_INSTR_TYPE {
   INSTR_TYPE_FOREX,
   INSTR_TYPE_INDEX,
   INSTR_TYPE_COMMODITY,
   INSTR_TYPE_OTHER
};

input string AUTH_SHARED = "FlokiPAY"; // Must match AUTH_SHARED on the server
input string BaseURL = "http://127.0.0.1:5001"; // Same base URL as the sender, including the port
input int TimeoutMs = 8000;
input int PollMs = 300;
input int ReceiverStatePublishMs = 1000;
input long Magic = 20258008;
input int Slippage = 10;

input int SignalMaxAgeSeconds = 5;
input double SpikeThresholdPct = 1.0; // |closed net| >= this % of day-start balance counts as one spike

input bool EnforceSchedule = false; // false reports the schedule as open
input ENUM_DAY_OF_WEEK Slot1Day = MONDAY;
input string Slot1TimeHHMM = "16:30";
input string Slot1EndHHMM = "17:30";
input ENUM_DAY_OF_WEEK Slot2Day = WEDNESDAY;
input string Slot2TimeHHMM = "12:33";
input string Slot2EndHHMM = "13:33";

input bool AutoBE_3R_Enable = true;
input double AutoBE_Multiplier = 3.0;

input double RiskPerTradePct = 1.0;
input double MaxLotsCap = 100.0;
input bool EnableMinStopDistance = false;
input double MinStopDistancePoints = 10.0;

input bool EmergencyStop = false;
input bool EnableSelfHealing = true;
input bool EnableDetailedLogging = true;
input bool EnablePush = true;
input bool EnableMail = true;

input string MarketWatchSymbols = "EURUSD,GBPUSD,XAUUSD,US30,NAS100,DAX40";
input bool AutoAddSignalSymbols = true;

input group "Forex stop distance"
input double ForexSpreadPoints = 2.0;
input double ForexSpreadMultiplier = 25.0;

input group "Index stop distance"
input double FixedSLPoints_Indices = 100.0;

input group "Commodity stop distance"
input double FixedSLPoints_Commodities = 80.0;

input group "Gold stop distance"
input bool UseGoldSpecificSettings = true;
input double FixedSLPoints_Gold = 150.0;

input group "Other stop distance"
input double FixedSLPoints_Other = 60.0;

string URL_NEXT(){ return BaseURL + "/next"; }
string URL_ACK(){ return BaseURL + "/ack"; }
string URL_RECEIVER_STATE(){ return BaseURL + "/receiver-state"; }

datetime g_dayAnchor = 0;
double g_equityAtDayStart = 0.0;
double g_dailyClosedNet = 0.0;
int g_lossesToday = 0;
int g_spikesToday = 0;
datetime g_lastLossClose = 0;
string g_lastAckedSignalID = "";
ulong g_processedDeals[];
double g_effRiskPerTradePct = 1.0;

ulong gTickets[];
double gBoundarySL[];
long gTypeOfTicket[];

datetime g_lastNoticeTime = 0;
string g_lastNoticeText = "";
int g_logFileHandle = INVALID_HANDLE;

bool IsFiniteNumber(const double value)
{
   if(value != value) return false;
   if(value > DBL_MAX || value < -DBL_MAX) return false;
   return true;
}

datetime DayAnchor(datetime when)
{
   MqlDateTime parts;
   TimeToStruct(when, parts);
   parts.hour = 0;
   parts.min = 0;
   parts.sec = 0;
   return StructToTime(parts);
}

bool ParseHHMM(const string hhmm, int &hour, int &minute)
{
   int separator = StringFind(hhmm, ":");
   if(separator < 0) return false;
   hour = (int)StringToInteger(StringSubstr(hhmm, 0, separator));
   minute = (int)StringToInteger(StringSubstr(hhmm, separator + 1));
   return hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59;
}

void LogToFile(const string message)
{
   if(!EnableDetailedLogging) return;
   if(g_logFileHandle == INVALID_HANDLE)
   {
      string filename = "SignalReceiverEA_" + IntegerToString(Magic) + "_" +
                        TimeToString(TimeCurrent(), TIME_DATE) + ".log";
      g_logFileHandle = FileOpen(filename, FILE_WRITE | FILE_READ | FILE_TXT | FILE_SHARE_READ);
   }
   if(g_logFileHandle == INVALID_HANDLE) return;
   FileSeek(g_logFileHandle, 0, SEEK_END);
   FileWrite(g_logFileHandle, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), message);
   FileFlush(g_logFileHandle);
}

void SendNoticeOnce(const string text, const int minGapSeconds = 10)
{
   datetime now = TimeTradeServer();
   if(text == g_lastNoticeText && (now - g_lastNoticeTime) < minGapSeconds) return;
   g_lastNoticeText = text;
   g_lastNoticeTime = now;
   if(EnablePush) SendNotification(text);
   if(EnableMail && !SendMail("SignalReceiver", text))
      Print("[RX] SendMail failed");
}

double GetSymbolPoint(const string symbol)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   return point > 0.0 ? point : 0.00001;
}

string ClassificationSymbol(const string symbol)
{
   string upper = symbol;
   StringToUpper(upper);
   int dot = StringFind(upper, ".");
   if(dot > 0) upper = StringSubstr(upper, 0, dot);
   return upper;
}

bool IsGoldSymbol(const string symbol)
{
   string upper = ClassificationSymbol(symbol);
   return StringFind(upper, "XAU") >= 0 || StringFind(upper, "GOLD") >= 0;
}

bool ListedCurrency(const string code)
{
   string currencies[8] = {"USD", "EUR", "GBP", "JPY", "CHF", "CAD", "AUD", "NZD"};
   for(int index = 0; index < 8; index++)
      if(code == currencies[index]) return true;
   return false;
}

ENUM_INSTR_TYPE GetInstrumentType(const string symbol)
{
   string upper = ClassificationSymbol(symbol);
   if(StringFind(upper, "GOLD") >= 0 || StringFind(upper, "XAU") >= 0 ||
      StringFind(upper, "SILVER") >= 0 || StringFind(upper, "XAG") >= 0 ||
      StringFind(upper, "OIL") >= 0 || StringFind(upper, "BRENT") >= 0 ||
      StringFind(upper, "COPPER") >= 0 || StringFind(upper, "PLATINUM") >= 0 ||
      StringFind(upper, "PALLADIUM") >= 0 || StringFind(upper, "NATURALGAS") >= 0 ||
      StringFind(upper, "NGAS") >= 0)
      return INSTR_TYPE_COMMODITY;

   if(StringFind(upper, "30") >= 0 || StringFind(upper, "40") >= 0 ||
      StringFind(upper, "100") >= 0 || StringFind(upper, "500") >= 0 ||
      StringFind(upper, "DAX") >= 0 || StringFind(upper, "DOW") >= 0 ||
      StringFind(upper, "NAS") >= 0 || StringFind(upper, "SP") >= 0 ||
      StringFind(upper, "FTSE") >= 0 || StringFind(upper, "NIKKEI") >= 0 ||
      StringFind(upper, "CAC") >= 0)
      return INSTR_TYPE_INDEX;

   if(StringLen(upper) == 6)
   {
      string base = StringSubstr(upper, 0, 3);
      string quote = StringSubstr(upper, 3, 3);
      string commodityBases[9] = {"XAU", "XAG", "OIL", "BRT", "COP", "PLT", "PAL", "NAT", "NG"};
      bool commodityBase = false;
      for(int index = 0; index < 9; index++)
         if(base == commodityBases[index]) commodityBase = true;
      if(!commodityBase && (ListedCurrency(base) || ListedCurrency(quote)))
         return INSTR_TYPE_FOREX;
   }

   return INSTR_TYPE_OTHER;
}

double GetSafeStopPoints(const string symbol)
{
   ENUM_INSTR_TYPE type = GetInstrumentType(symbol);
   bool isGold = IsGoldSymbol(symbol);
   double fallback = 60.0;
   if(type == INSTR_TYPE_FOREX) fallback = 50.0;
   else if(type == INSTR_TYPE_INDEX) fallback = 100.0;
   else if(type == INSTR_TYPE_COMMODITY) fallback = isGold ? 150.0 : 80.0;

   return ReceiverSelectStopPoints(
      type == INSTR_TYPE_FOREX,
      type == INSTR_TYPE_COMMODITY,
      isGold,
      type == INSTR_TYPE_INDEX,
      UseGoldSpecificSettings,
      ForexSpreadPoints,
      ForexSpreadMultiplier,
      FixedSLPoints_Gold,
      FixedSLPoints_Commodities,
      FixedSLPoints_Indices,
      FixedSLPoints_Other,
      fallback);
}

void InitializeMarketWatch()
{
   string symbols[];
   int count = StringSplit(MarketWatchSymbols, ',', symbols);
   int added = 0;
   for(int index = 0; index < count; index++)
   {
      string symbol = symbols[index];
      StringTrimLeft(symbol);
      StringTrimRight(symbol);
      if(symbol == "" || SymbolInfoInteger(symbol, SYMBOL_SELECT)) continue;
      if(SymbolSelect(symbol, true)) added++;
      else PrintFormat("[RX] Market Watch could not add %s", symbol);
   }
   if(added > 0)
      PrintFormat("[RX] Added %d symbols to Market Watch", added);
}

bool EnsureSymbolInMarketWatch(const string symbol)
{
   if(SymbolInfoInteger(symbol, SYMBOL_SELECT)) return true;
   if(!AutoAddSignalSymbols)
   {
      PrintFormat("[RX] %s is not in Market Watch", symbol);
      return false;
   }
   if(!SymbolSelect(symbol, true))
   {
      PrintFormat("[RX] Could not add %s to Market Watch", symbol);
      return false;
   }
   for(int attempt = 0; attempt < 10; attempt++)
   {
      MqlTick tick;
      if(SymbolInfoTick(symbol, tick) && tick.time > 0) return true;
      Sleep(50);
   }
   return true;
}

double CalculateValuePerPoint(const string symbol)
{
   EnsureSymbolInMarketWatch(symbol);
   string profitCurrency = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);
   string accountCurrency = AccountInfoString(ACCOUNT_CURRENCY);
   double contractSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(profitCurrency == accountCurrency)
      return contractSize * tickSize;

   string conversionSymbol = "";
   if(SymbolSelect(profitCurrency + accountCurrency, true))
      conversionSymbol = profitCurrency + accountCurrency;
   else if(SymbolSelect(accountCurrency + profitCurrency, true))
      conversionSymbol = accountCurrency + profitCurrency;
   else
      return SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);

   double conversionRate = SymbolInfoDouble(conversionSymbol, SYMBOL_BID);
   if(conversionRate <= 0.0)
      return SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);

   double valueInProfitCurrency = contractSize * tickSize;
   string conversionBase = SymbolInfoString(conversionSymbol, SYMBOL_CURRENCY_BASE);
   if(conversionBase == accountCurrency)
      return valueInProfitCurrency / conversionRate;
   return valueInProfitCurrency * conversionRate;
}

bool SlotIsOpen(const ENUM_DAY_OF_WEEK day, const string startText, const string endText, const MqlDateTime &now)
{
   if((ENUM_DAY_OF_WEEK)now.day_of_week != day) return false;
   int startHour, startMinute, endHour, endMinute;
   if(!ParseHHMM(startText, startHour, startMinute) || !ParseHHMM(endText, endHour, endMinute))
      return false;
   int current = now.hour * 60 + now.min;
   return current >= startHour * 60 + startMinute && current <= endHour * 60 + endMinute;
}

bool IsTradingWindowOpen()
{
   if(!EnforceSchedule) return true;
   MqlDateTime now;
   TimeToStruct(TimeTradeServer(), now);
   return SlotIsOpen(Slot1Day, Slot1TimeHHMM, Slot1EndHHMM, now) ||
          SlotIsOpen(Slot2Day, Slot2TimeHHMM, Slot2EndHHMM, now);
}

bool HttpGet(const string url, string &resultBody, string &resultHeaders, const string extraHeaders = "")
{
   resultHeaders = "";
   resultBody = "";
   if(StringLen(url) <= 0) return false;

   string headers = "Connection: keep-alive\r\n";
   if(StringLen(extraHeaders) > 0)
   {
      headers += extraHeaders;
      if(StringSubstr(headers, StringLen(headers) - 2, 2) != "\r\n")
         headers += "\r\n";
   }

   uchar request[];
   uchar response[];
   ResetLastError();
   int status = WebRequest("GET", url, headers, TimeoutMs, request, response, resultHeaders);
   if(status == -1)
   {
      PrintFormat("[RX] GET failed (%d) %s", GetLastError(), url);
      return false;
   }
   resultBody = CharArrayToString(response, 0, WHOLE_ARRAY, CP_UTF8);
   return StringLen(resultBody) > 0;
}

bool HttpPostJSON(const string url, const string json, string &resultBody, string &resultHeaders)
{
   resultBody = "";
   resultHeaders = "";
   string headers = "Connection: close\r\nContent-Type: application/json\r\nX-Auth-Token: " + AUTH_SHARED + "\r\n";
   uchar request[];
   int jsonLength = StringLen(json);
   ArrayResize(request, jsonLength);
   StringToCharArray(json, request, 0, jsonLength, CP_UTF8);
   uchar response[];
   ResetLastError();
   int status = WebRequest("POST", url, headers, TimeoutMs, request, response, resultHeaders);
   if(status == -1)
   {
      PrintFormat("[RX] POST failed (%d) %s", GetLastError(), url);
      return false;
   }
   resultBody = CharArrayToString(response, 0, WHOLE_ARRAY, CP_UTF8);
   if(status < 200 || status >= 300)
   {
      PrintFormat("[RX] POST HTTP %d %s", status, resultBody);
      return false;
   }
   return true;
}

bool PrepareSymbol(string &symbol)
{
   if(StringLen(symbol) <= 0) return false;
   string lower = symbol;
   StringToLower(lower);
   string bases[2];
   bases[0] = symbol;
   bases[1] = lower;
   string suffixes[5] = {"", ".pro", ".c", ".cash", ".f"};

   for(int baseIndex = 0; baseIndex < 2; baseIndex++)
   {
      for(int suffixIndex = 0; suffixIndex < 5; suffixIndex++)
      {
         string candidate = bases[baseIndex] + suffixes[suffixIndex];
         if(candidate == "" || !SymbolSelect(candidate, true)) continue;
         if(SymbolInfoInteger(candidate, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL) continue;
         MqlTick tick;
         if(!SymbolInfoTick(candidate, tick) || tick.time <= 0) continue;
         symbol = candidate;
         return true;
      }
   }
   PrintFormat("[RX] No tradable symbol for %s", symbol);
   return false;
}

bool SnapLots(const string symbol, double &lots)
{
   double minimum = 0.0, maximum = 0.0, step = 0.0;
   if(lots <= 0.0) return false;
   if(!SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN, minimum)) return false;
   if(!SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX, maximum)) return false;
   if(!SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP, step)) return false;
   double snapped = 0.0;
   if(!ReceiverSnapLots(lots, minimum, maximum, step, snapped)) return false;
   lots = snapped;
   return true;
}

void CheckEmergencyStop()
{
   if(!EmergencyStop) return;
   Print("[RX] Emergency stop");
   LogToFile("[EMERGENCY STOP]");
   for(int index = PositionsTotal() - 1; index >= 0; index--)
   {
      ulong ticket = PositionGetTicket(index);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == Magic)
         Trade.PositionClose(ticket);
   }
   for(int index = OrdersTotal() - 1; index >= 0; index--)
   {
      ulong ticket = OrderGetTicket(index);
      if(OrderSelect(ticket) && OrderGetInteger(ORDER_MAGIC) == Magic)
         Trade.OrderDelete(ticket);
   }
   ExpertRemove();
}

#include "../Include/ReceiverDailyState.mqh"
#include "../Include/ReceiverPositionManagement.mqh"
#include "../Include/ReceiverOrderExecution.mqh"
#include "../Include/ReceiverSignalWorkflow.mqh"

bool PublishReceiverState()
{
   if(g_equityAtDayStart <= 0.0)
      g_equityAtDayStart = AccountInfoDouble(ACCOUNT_BALANCE);
   if(g_equityAtDayStart <= 0.0)
   {
      Print("[RX] No account balance yet, so no state snapshot was sent");
      return false;
   }

   long secondsSinceLastLoss = g_lastLossClose > 0
      ? (long)MathMax(0, (long)TimeTradeServer() - (long)g_lastLossClose)
      : -1;
   string json = ReceiverBuildStateJson(
      IntegerToString(Magic),
      g_equityAtDayStart,
      AccountInfoDouble(ACCOUNT_BALANCE),
      g_dailyClosedNet,
      g_lossesToday,
      g_spikesToday,
      secondsSinceLastLoss,
      IsTradingWindowOpen(),
      AllOurPositionsAtBE());

   string responseBody, responseHeaders;
   if(!HttpPostJSON(URL_RECEIVER_STATE(), json, responseBody, responseHeaders))
      return false;

   string changedSummary = ReceiverJsonString(responseBody, "changed_summary");
   if(changedSummary != "")
      Print("[RX] State changed: ", changedSummary);

   static string lastGate = "";
   if(ReceiverJsonTrue(responseBody, "gate_ok"))
      lastGate = "";
   else
   {
      string gateText = ReceiverJsonString(responseBody, "gate") + ": " + ReceiverJsonString(responseBody, "reason");
      if(gateText != lastGate)
      {
         Print("[RX] Server gate closed: ", gateText);
         lastGate = gateText;
      }
   }
   return true;
}

int OnInit()
{
   g_effRiskPerTradePct = RiskPerTradePct;
   if(g_effRiskPerTradePct <= 0.0 || g_effRiskPerTradePct > 10.0)
   {
      Print("[RX] RiskPerTradePct must be between 0 and 10. Using 1%.");
      g_effRiskPerTradePct = 1.0;
   }

   Trade.SetExpertMagicNumber(Magic);
   Trade.SetDeviationInPoints(Slippage);
   EventSetMillisecondTimer(PollMs < 100 ? 100 : PollMs);
   InitializeMarketWatch();
   LoadPersistedDay();
   RefreshTradingDay(true);
   PublishReceiverState();

   PrintFormat("[RX] Ready. Magic=%I64d risk=%.2f%% schedule=%s auto-BE=%s state=%s",
               Magic, g_effRiskPerTradePct,
               EnforceSchedule ? "slots" : "open",
               AutoBE_3R_Enable ? "on" : "off",
               URL_RECEIVER_STATE());
   LogToFile("[INIT] Receiver attached");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   LogToFile("[DEINIT] " + IntegerToString(reason));
   if(g_logFileHandle != INVALID_HANDLE)
   {
      FileClose(g_logFileHandle);
      g_logFileHandle = INVALID_HANDLE;
   }
}

void OnTimer()
{
   if(EmergencyStop)
   {
      CheckEmergencyStop();
      return;
   }
   RefreshTradingDay(false);
   CheckAndRepairState();
   NukeForeignsByMagic();
   MaintainPositions();
   PollHistoryForNewCloses();

   static ulong lastPublishMs = 0;
   ulong nowMs = GetTickCount64();
   int publishIntervalMs = ReceiverStatePublishMs < 250 ? 250 : ReceiverStatePublishMs;
   if(lastPublishMs == 0 || nowMs - lastPublishMs >= (ulong)publishIntervalMs)
   {
      lastPublishMs = nowMs;
      if(!PublishReceiverState()) return;
   }
   ProcessPendingServerSignal();
}
