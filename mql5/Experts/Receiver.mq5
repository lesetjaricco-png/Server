//+------------------------------------------------------------------+
//| SignalReceiverEA.mq5 — Production Ready for 30-Day Run          |
//| - COMPLETELY CHART-INDEPENDENT - No Symbol() or _Point usage    |
//| - Unified lot calculation for ALL instruments (Forex/Indices/Gold)|
//| - Dynamic ValuePerPoint from broker specs (IC Markets Standard MT5)|
//| - 30-Day Mode: Set EnforceSchedule=false for continuous trading |
//| - All gates fixed for 30-day reliability                        |
//| - Daily reset at server midnight with email notification        |
//| - Emergency stop and self-healing                               |
//| - Comprehensive logging for post-mortem                         |
//| - FIXED: Market Watch initialization ensures fresh data for ALL symbols|
//| - CHANGED: Forex pairs now use "spread multiple" only (2.0 points)|
//| - FIXED: Gold detection now happens BEFORE forex detection      |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
#include "../Include/ReceiverProtocol.mqh"
#include "../Include/ReceiverDecisions.mqh"
CTrade Trade;

// ---------- Instrument Type Enum ----------
enum ENUM_INSTR_TYPE {
   INSTR_TYPE_FOREX,
   INSTR_TYPE_INDEX,
   INSTR_TYPE_COMMODITY,
   INSTR_TYPE_OTHER
};

// ---------- Forward Declarations ----------
ENUM_INSTR_TYPE GetInstrumentType(const string symbol);
string InstrumentTypeToString(ENUM_INSTR_TYPE type);
double GetSafeStopPoints(const string symbol);
bool CalcDynamicLots(const string sym, const string side_txt, double &lots_out, double &sl_price_out, double &entry_prc_out);
double CalculateValuePerPoint(const string symbol); // DYNAMIC calculation for ALL instruments

// ---------- Authentication ----------
input string AUTH_SHARED = "FlokiPAY";  // Must match AUTH_SHARED in your .env file

// ---------- Network ----------
input string BaseURL = "http://127.0.0.1";
input int TimeoutMs = 8000;
input int PollMs = 300; // clamped to >= 100 ms
input int ReceiverStatePublishMs = 1000;
input long Magic = 20258008;
input int Slippage = 10;

// ---------- Risk / session ----------
input double DailyLossCapPct = 3.0; // % of start-of-day equity (downside stop)
input double DailyProfitTargetPct = 2.0; // % of start-of-day equity (stop after win day)
input int MaxLossesPerDay = 5; // Maximum number of losing trades per day
input int CooldownMinsAfterLoss = 5;

// ---------- Emotional spikes (kept, but silent) ----------
input int MaxDailySpikes = 2; // stop day after N spikes
input double SpikeThresholdPct = 1.0; // spike = |net deal| >= X% equity

// ---------- 30-DAY TRADING SCHEDULE OPTIONS ----------
input bool EnforceSchedule = false; // Set FALSE for 30-day continuous trading
input ENUM_DAY_OF_WEEK Slot1Day = MONDAY;
input string Slot1TimeHHMM = "16:30";
input string Slot1EndHHMM = "17:30";
input ENUM_DAY_OF_WEEK Slot2Day = WEDNESDAY;
input string Slot2TimeHHMM = "12:33";
input string Slot2EndHHMM = "13:33";

// ---------- Signal Configuration ----------
input int SignalMaxAgeSeconds = 5;

// ---------- SL / BE ----------
input bool AutoBE_3R_Enable = true; // move SL to BE at +3R
input double AutoBE_Multiplier = 3.0; // R multiplier for moving SL to BE (adjustable)
input bool RequireAllAtBEToAdd = true; // only when all our positions are at BE

// ---------- Dynamic lots ----------
input double RiskPerTradePct = 1.0; // % of equity targeted loss per trade
input double MaxLotsCap = 100.0; // hard cap per order
input bool EnableMinStopDistance = false;
input double MinStopDistancePoints = 10.0;

// ---------- 30-Day Emergency Features ----------
input bool EmergencyStop = false;
input bool EnableSelfHealing = true;
input bool EnableDetailedLogging = true;

// ---------- Notifications ----------
input bool EnablePush = true;
input bool EnableMail = true; // Now used for daily reset email

// ---------- Market Watch Initialization ----------
input string MarketWatchSymbols = "EURUSD,GBPUSD,XAUUSD,US30,NAS100,DAX40"; // ✨ NEW: Pre-load these symbols
input bool AutoAddSignalSymbols = true; // ✨ NEW: Automatically add new signal symbols to Market Watch

// ========== UPDATED: SPREAD MULTIPLE SETTINGS FOR FOREX ==========
input group "=== Forex Spread Multiple Settings ==="
input double ForexSpreadPoints = 2.0; // ✨ NEW: Fixed spread for all forex pairs (2.0 points)
input double ForexSpreadMultiplier = 25.0; // ✨ NEW: Spread multiplier (e.g., 2.0 points * 25 = 50 points SL)

input group "=== Indices Fixed Points Settings ===" 
input double FixedSLPoints_Indices = 100.0;

input group "=== Commodities Fixed Points Settings ==="
input double FixedSLPoints_Commodities = 80.0;

input group "=== Gold/XAUUSD Fixed Points Settings ==="
input bool UseGoldSpecificSettings = true;
input double FixedSLPoints_Gold = 150.0;

input group "=== Other Instruments Fixed Points Settings ==="
input double FixedSLPoints_Other = 60.0;

// ---------- Endpoints ----------
string URL_NEXT(){ return BaseURL + "/next"; }
string URL_ACK (){ return BaseURL + "/ack"; }
string URL_RECEIVER_STATE(){ return BaseURL + "/receiver-state"; }

// ---------- Runtime state ----------
datetime g_dayAnchor = 0;
double g_equityAtDayStart = 0.0;
double g_equityLossLimit = 0.0;
double g_profitTargetAbs = 0.0;
double g_dailyClosedNet = 0.0;
int g_tradesToday = 0;
int g_lossesToday = 0;
int g_spikesToday = 0;
datetime g_lastLossClose = 0;
datetime g_lastRiskNotify = 0;
string g_lastAckedSignalID = "";
ulong g_startupDealWatermark = 0;
ulong g_processedDeals[];

int g_effMaxLossesPerDay = 5;
double g_effRiskPerTradePct = 1.0;

// anti-widen memory
ulong gTickets[];
double gBoundarySL[];
long gTypeOfTicket[];

// debounced notice
datetime g_lastNoticeTime = 0;
string g_lastNoticeText = "";

// 30-Day logging
int g_logFileHandle = INVALID_HANDLE;

// ========== NEW: Symbol-independent point size utility ==========
double GetSymbolPoint(const string symbol)
{
    double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
    if(point == 0) {
        PrintFormat("[WARNING] Zero point size for %s, using 0.00001 as fallback", symbol);
        return 0.00001; // Fallback for major forex
    }
    return point;
}

// ---------- Market Watch Management Functions ----------
void InitializeMarketWatch()
{
    Print("[MARKET_WATCH] ===== Initializing Market Watch =====");
    
    // Log current Market Watch state
    int totalSelected = SymbolsTotal(true);
    PrintFormat("[MARKET_WATCH] Currently selected symbols: %d", totalSelected);
    
    // Log all currently selected symbols
    for(int i = 0; i < totalSelected; i++) {
        string symbolName = SymbolName(i, true);
        PrintFormat("[MARKET_WATCH]   %d. %s", i+1, symbolName);
    }
    
    // Process comma-separated list from input
    string symbolsToAdd[];
    int count = StringSplit(MarketWatchSymbols, ',', symbolsToAdd);
    
    if(count > 0) {
        PrintFormat("[MARKET_WATCH] Processing %d symbols from input list...", count);
        
        for(int i = 0; i < count; i++) {
            string sym = symbolsToAdd[i];
            StringTrimLeft(sym);
            StringTrimRight(sym);
            
            if(sym == "") continue;
            
            // Check if symbol exists with the broker
            if(!SymbolInfoInteger(sym, SYMBOL_SELECT)) {
                if(SymbolSelect(sym, true)) {
                    PrintFormat("[MARKET_WATCH] ✓ Added: %s", sym);
                    Sleep(50); // Small delay to let MT5 process
                } else {
                    PrintFormat("[MARKET_WATCH] ✗ Failed to add: %s (symbol may not exist)", sym);
                }
            } else {
                PrintFormat("[MARKET_WATCH] ✓ Already in Market Watch: %s", sym);
            }
        }
    } else {
        Print("[MARKET_WATCH] No symbols specified in MarketWatchSymbols input");
    }
    
    // Final count
    int finalCount = SymbolsTotal(true);
    PrintFormat("[MARKET_WATCH] Final count: %d symbols in Market Watch", finalCount);
    Print("[MARKET_WATCH] ===== Initialization Complete =====");
}

bool EnsureSymbolInMarketWatch(const string symbol)
{
    if(SymbolInfoInteger(symbol, SYMBOL_SELECT)) {
        return true; // Already selected
    }
    
    if(!AutoAddSignalSymbols) {
        PrintFormat("[MARKET_WATCH] Auto-add disabled. %s not in Market Watch.", symbol);
        return false;
    }
    
    PrintFormat("[MARKET_WATCH] Attempting to add %s to Market Watch...", symbol);
    
    if(SymbolSelect(symbol, true)) {
        PrintFormat("[MARKET_WATCH] ✓ Successfully added %s to Market Watch", symbol);
        
        // Wait for data to initialize
        for(int i = 0; i < 10; i++) {
            MqlTick tick;
            if(SymbolInfoTick(symbol, tick) && tick.time > 0) {
                PrintFormat("[MARKET_WATCH] %s data is now available (Bid: %.5f, Ask: %.5f)", 
                           symbol, tick.bid, tick.ask);
                return true;
            }
            Sleep(50);
        }
        PrintFormat("[MARKET_WATCH] ⚠ %s added but data may be stale", symbol);
        return true;
    } else {
        PrintFormat("[MARKET_WATCH] ✗ Failed to add %s to Market Watch", symbol);
        return false;
    }
}

// ---------- UNIFIED Dynamic Value Calculation (For ALL Instruments) ----------
double CalculateValuePerPoint(const string symbol)
{
    // Ensure symbol is in Market Watch first
    if(!EnsureSymbolInMarketWatch(symbol)) {
        PrintFormat("[TICK_VALUE] WARNING: %s not in Market Watch, calculation may fail", symbol);
    }
    
    string profitCurrency = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);
    string accountCurrency = AccountInfoString(ACCOUNT_CURRENCY);
    double contractSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
    double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
    
    PrintFormat("[TICK_VALUE] %s: ProfitCurrency=%s, AccountCurrency=%s, ContractSize=%.2f, TickSize=%.5f",
                symbol, profitCurrency, accountCurrency, contractSize, tickSize);
    
    if(profitCurrency == accountCurrency)
    {
        double value = contractSize * tickSize;
        PrintFormat("[TICK_VALUE] %s: Currencies match. ValuePerPoint = %.2f %s",
                    symbol, value, accountCurrency);
        return(value);
    }
    
    string conversionSymbol = "";
    if(SymbolSelect(profitCurrency + accountCurrency, true))
    {
        conversionSymbol = profitCurrency + accountCurrency;
        PrintFormat("[TICK_VALUE] %s: Found direct conversion symbol: %s",
                    symbol, conversionSymbol);
    }
    else if(SymbolSelect(accountCurrency + profitCurrency, true))
    {
        conversionSymbol = accountCurrency + profitCurrency;
        PrintFormat("[TICK_VALUE] %s: Found inverse conversion symbol: %s",
                    symbol, conversionSymbol);
    }
    else
    {
        PrintFormat("[TICK_VALUE] ERROR for %s: Cannot find conversion pair for %s to %s. Using fallback.",
                   symbol, profitCurrency, accountCurrency);
        double fallbackValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
        PrintFormat("[TICK_VALUE] %s: Fallback TickValue from broker = %.5f",
                   symbol, fallbackValue);
        return(fallbackValue);
    }
    
    double conversionRate = SymbolInfoDouble(conversionSymbol, SYMBOL_BID);
    if(conversionRate <= 0.0)
    {
        PrintFormat("[TICK_VALUE] ERROR for %s: Invalid conversion rate (%.5f) for %s. Using fallback.",
                   symbol, conversionRate, conversionSymbol);
        return(SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE));
    }
    
    double valueInProfitCurrency = contractSize * tickSize;
    double finalValue = 0.0;
    string convBaseCurrency = SymbolInfoString(conversionSymbol, SYMBOL_CURRENCY_BASE);
    
    if(convBaseCurrency == accountCurrency)
    {
        finalValue = valueInProfitCurrency / conversionRate;
        PrintFormat("[TICK_VALUE] %s: Converted (Div). %s to %s @ Rate=%.5f. Value=%.5f",
                   symbol, profitCurrency, accountCurrency, conversionRate, finalValue);
    }
    else
    {
        finalValue = valueInProfitCurrency * conversionRate;
        PrintFormat("[TICK_VALUE] %s: Converted (Mul). %s to %s @ Rate=%.5f. Value=%.5f",
                   symbol, profitCurrency, accountCurrency, conversionRate, finalValue);
    }
    return(finalValue);
}

// ========== UPDATED: Instrument Type Detection (Gold FIRST, then forex) ==========
ENUM_INSTR_TYPE GetInstrumentType(const string symbol)
{
   // First, convert to uppercase for easier matching
   string symUpper = symbol;
   for(int i = 0; i < StringLen(symUpper); i++) {
       ushort char_code = StringGetCharacter(symUpper, i);
       if(char_code >= 97 && char_code <= 122) {
           char_code -= 32;
           StringSetCharacter(symUpper, i, char_code);
       }
   }
   
   // ===== STEP 1: Check for GOLD/COMMODITIES FIRST =====
   if(StringFind(symUpper, "GOLD") >= 0 || StringFind(symUpper, "XAU") >= 0 ||
      StringFind(symUpper, "SILVER") >= 0 || StringFind(symUpper, "XAG") >= 0 ||
      StringFind(symUpper, "OIL") >= 0 || StringFind(symUpper, "BRENT") >= 0 ||
      StringFind(symUpper, "COPPER") >= 0 || StringFind(symUpper, "PLATINUM") >= 0 ||
      StringFind(symUpper, "PALLADIUM") >= 0 || StringFind(symUpper, "NATURALGAS") >= 0 ||
      StringFind(symUpper, "NGAS") >= 0) {
        PrintFormat("[INSTR_TYPE] %s detected as COMMODITY (checked first)", symbol);
        return INSTR_TYPE_COMMODITY;
   }
   
   // ===== STEP 2: Check for INDICES =====
   if(StringFind(symUpper, "30") >= 0 || StringFind(symUpper, "40") >= 0 ||
      StringFind(symUpper, "100") >= 0 || StringFind(symUpper, "500") >= 0 ||
      StringFind(symUpper, "DAX") >= 0 || StringFind(symUpper, "DOW") >= 0 ||
      StringFind(symUpper, "NAS") >= 0 || StringFind(symUpper, "SP") >= 0 ||
      StringFind(symUpper, "FTSE") >= 0 || StringFind(symUpper, "NIKKEI") >= 0 ||
      StringFind(symUpper, "CAC") >= 0) {
        PrintFormat("[INSTR_TYPE] %s detected as INDEX", symbol);
        return INSTR_TYPE_INDEX;
   }
   
   // ===== STEP 3: Check for FOREX =====
   if(StringLen(symbol) == 6) {
        string base = StringSubstr(symbol, 0, 3);
        string quote = StringSubstr(symbol, 3, 3);
        string currencies[] = {"USD", "EUR", "GBP", "JPY", "CHF", "CAD", "AUD", "NZD"};
        
        // Make sure it's not a commodity masquerading as forex
        bool isCommoditySymbol = false;
        string possibleCommoditySymbols[] = {"XAU", "XAG", "OIL", "BRT", "COP", "PLT", "PAL", "NAT", "NG"};
        
        for(int i = 0; i < ArraySize(possibleCommoditySymbols); i++) {
            if(base == possibleCommoditySymbols[i]) {
                isCommoditySymbol = true;
                break;
            }
        }
        
        if(!isCommoditySymbol) {
            for(int i = 0; i < ArraySize(currencies); i++) {
                if(base == currencies[i] || quote == currencies[i]) {
                    PrintFormat("[INSTR_TYPE] %s detected as FOREX (6-char)", symbol);
                    return INSTR_TYPE_FOREX;
                }
            }
        }
   }
   
   // ===== STEP 4: Extended forex check (8 character pairs like EURUSD.a) =====
   if(StringLen(symbol) == 8 && StringFind(symbol, ".") == 6) {
        string base = StringSubstr(symbol, 0, 3);
        string quote = StringSubstr(symbol, 3, 3);
        string currencies[] = {"USD", "EUR", "GBP", "JPY", "CHF", "CAD", "AUD", "NZD"};
        
        for(int i = 0; i < ArraySize(currencies); i++) {
            if(base == currencies[i] || quote == currencies[i]) {
                PrintFormat("[INSTR_TYPE] %s detected as FOREX (8-char with dot)", symbol);
                return INSTR_TYPE_FOREX;
            }
        }
   }
   
   PrintFormat("[INSTR_TYPE] %s detected as OTHER", symbol);
   return INSTR_TYPE_OTHER;
}

string InstrumentTypeToString(ENUM_INSTR_TYPE type)
{
    switch(type) {
        case INSTR_TYPE_FOREX: return "Forex";
        case INSTR_TYPE_INDEX: return "Index";
        case INSTR_TYPE_COMMODITY: return "Commodity";
        default: return "Other";
    }
}

// ========== UPDATED: Forex now uses SPREAD MULTIPLE only ==========
double GetSafeStopPoints(const string symbol)
{
    ENUM_INSTR_TYPE instr_type = GetInstrumentType(symbol);
    bool isGold = (StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0);
    
    switch(instr_type) {
        case INSTR_TYPE_FOREX:
            // ✨ NEW: Forex uses spread multiple calculation
            if(ForexSpreadPoints > 0.0 && ForexSpreadMultiplier > 0.0) {
                double stop_points = ForexSpreadPoints * ForexSpreadMultiplier;
                PrintFormat("[SPREAD_MULT] %s: %.1f points × %.1f multiplier = %.1f points SL",
                           symbol, ForexSpreadPoints, ForexSpreadMultiplier, stop_points);
                return stop_points;
            } else {
                PrintFormat("[SPREAD_MULT] %s: Using fallback 50.0 points", symbol);
                return 50.0; // fallback
            }
            
        case INSTR_TYPE_INDEX:
            if(FixedSLPoints_Indices > 0.0) {
                PrintFormat("[STOP_POINTS] %s: Using Indices SL = %.1f points", symbol, FixedSLPoints_Indices);
                return FixedSLPoints_Indices;
            }
            break;
            
        case INSTR_TYPE_COMMODITY:
            // ✨ IMPROVED: Check if it's gold specifically
            if(isGold && UseGoldSpecificSettings && FixedSLPoints_Gold > 0.0) {
                PrintFormat("[STOP_POINTS] %s: Using Gold-specific SL = %.1f points", symbol, FixedSLPoints_Gold);
                return FixedSLPoints_Gold;
            }
            if(FixedSLPoints_Commodities > 0.0) {
                PrintFormat("[STOP_POINTS] %s: Using Commodities SL = %.1f points", symbol, FixedSLPoints_Commodities);
                return FixedSLPoints_Commodities;
            }
            break;
            
        default:
            if(FixedSLPoints_Other > 0.0) {
                PrintFormat("[STOP_POINTS] %s: Using Other SL = %.1f points", symbol, FixedSLPoints_Other);
                return FixedSLPoints_Other;
            }
            break;
    }
   
    // Fallback defaults
    switch(instr_type) {
        case INSTR_TYPE_FOREX: 
            PrintFormat("[STOP_POINTS] %s: Using default Forex SL = 50.0 points", symbol);
            return 50.0;
        case INSTR_TYPE_INDEX: 
            PrintFormat("[STOP_POINTS] %s: Using default Index SL = 100.0 points", symbol);
            return 100.0;
        case INSTR_TYPE_COMMODITY: 
            if(isGold) {
                PrintFormat("[STOP_POINTS] %s: Using default Gold SL = 150.0 points", symbol);
                return 150.0;
            } else {
                PrintFormat("[STOP_POINTS] %s: Using default Commodity SL = 80.0 points", symbol);
                return 80.0;
            }
        default: 
            PrintFormat("[STOP_POINTS] %s: Using default Other SL = 60.0 points", symbol);
            return 60.0;
    }
}

// ---------- Small utils ----------
int _Find(const string s, const string pat, const int from=0){ return StringFind(s, pat, from); }
string _Trim(const string s){ string t=s; StringTrimLeft(t); StringTrimRight(t); return t; }

// MQL5 has no built-in MathIsFinite; NaN fails self-equality, Inf exceeds DBL_MAX
bool IsFiniteNumber(const double value)
{
   if(value != value) return false;
   if(value > DBL_MAX || value < -DBL_MAX) return false;
   return true;
}

bool ParseHHMM(const string hhmm, int &hh, int &mm){
   int p=StringFind(hhmm,":"); if(p<0) return false;
   string a=StringSubstr(hhmm,0,p), b=StringSubstr(hhmm,p+1);
   hh=(int)StringToInteger(a); mm=(int)StringToInteger(b);
   return !(hh<0||hh>23||mm<0||mm>59);
}

string FormatDT(const datetime t){
   MqlDateTime md; TimeToStruct(t, md);
   return StringFormat("%04d-%02d-%02d %02d:%02d:%02d", md.year, md.mon, md.day, md.hour, md.min, md.sec);
}

// ---------- 30-Day Logging System ----------
void LogToFile(const string message)
{
    if(!EnableDetailedLogging) return;
    
    if(g_logFileHandle == INVALID_HANDLE) {
        string filename = "SignalReceiverEA_" + IntegerToString(Magic) + "_" + 
                         TimeToString(TimeCurrent(), TIME_DATE) + ".log";
        g_logFileHandle = FileOpen(filename, FILE_WRITE|FILE_READ|FILE_TXT|FILE_SHARE_READ);
    }
    
    if(g_logFileHandle != INVALID_HANDLE) {
        FileSeek(g_logFileHandle, 0, SEEK_END);
        FileWrite(g_logFileHandle, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), message);
        FileFlush(g_logFileHandle);
    }
}

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

// ---------- Emergency Stop ----------
void CheckEmergencyStop()
{
    if(EmergencyStop) {
        Print("[EMERGENCY STOP] EA halted by user input!");
        LogToFile("[EMERGENCY STOP] Activated by user");
        
        // Close all positions
        for(int i = PositionsTotal()-1; i >= 0; i--) {
            ulong ticket = PositionGetTicket(i);
            if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == Magic) {
                Trade.PositionClose(ticket);
            }
        }
        
        // Delete pending orders
        for(int j = OrdersTotal()-1; j >= 0; j--) {
            ulong orderTicket = OrderGetTicket(j);
            if(OrderSelect(orderTicket) && OrderGetInteger(ORDER_MAGIC) == Magic) {
                Trade.OrderDelete(orderTicket);
            }
        }
        
        ExpertRemove();
    }
}

// ---------- Notifications ----------
void SendNoticeOnce(const string text, const int min_gap_sec=10){
   datetime now=TimeTradeServer();
   if(text==g_lastNoticeText && (now-g_lastNoticeTime)<min_gap_sec) return;
   g_lastNoticeText=text; g_lastNoticeTime=now;
   if(EnablePush) SendNotification(text);
   if(EnableMail){
      if(!SendMail("SignalReceiver", text))
         Print("[RX] WARN: SendMail() failed. Check Tools→Options→Email and Test.");
   }
}

string BuildRiskLeftMessage(){
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double used = g_equityAtDayStart - balance; if(used < 0) used = 0;
   double left = g_equityLossLimit - used; if(left < 0) left = 0;
   string riskMessage = StringFormat("Risk left today: %.2f (cap %.2f). Losses today: %d/%d",
                       left, g_equityLossLimit, g_lossesToday, g_effMaxLossesPerDay);

   if(CooldownMinsAfterLoss > 0 && g_lastLossClose > 0) {
       datetime next_srv = (datetime)((long)g_lastLossClose + (long)CooldownMinsAfterLoss*60);
       riskMessage += StringFormat(" Next trade at (server) %s", FormatDT(next_srv));
   }
   return riskMessage;
}

void NotifyRiskLeft(){
   datetime now = TimeTradeServer();
   if(now - g_lastRiskNotify < 3) return;
   SendNoticeOnce(BuildRiskLeftMessage(), 1);
   g_lastRiskNotify = now;
}

// ---------- JSON ----------
string JStr(const string json, const string k){
   string pat="\""+k+"\":\""; int p=_Find(json,pat); if(p<0) return "";
   p+=(int)StringLen(pat); int n=(int)StringLen(json); int end=-1;
   for(int i=p;i<n;i++){ uchar c=(uchar)json[i]; if(c=='\"'){ if(i>0&&(uchar)json[i-1]=='\\') continue; end=i; break; } }
   if(end<0||end<=p) return ""; return StringSubstr(json,p,end-p);
}

string JNum(const string json, const string k){
   string pat="\""+k+"\":"; int p=_Find(json,pat); if(p<0) return "";
   p+=(int)StringLen(pat); int n=(int)StringLen(json);
   while(p<n && (uchar)json[p]==' ') p++;
   int end=p; while(end<n){ uchar c=(uchar)json[end]; if(c==','||c=='}'||c==' '||c=='\r'||c=='\n'||c=='\t') break; end++; }
   if(end<=p) return ""; return _Trim(StringSubstr(json,p,end-p));
}

// ---------- HTTP ----------
bool HttpGet(const string url, string &result_body, string &result_headers, const string extra_headers = "")
{
   result_headers = "";
   result_body = "";

   if(StringLen(url) <= 0)
   {
      Print("[HttpGet] Empty URL");
      return false;
   }

   string headers = "Connection: keep-alive\r\n";
   if(StringLen(extra_headers) > 0) {
      headers += extra_headers;
      if(StringSubstr(headers, StringLen(headers)-2, 2) != "\r\n")
         headers += "\r\n";
   }

   uchar req[]; ArrayResize(req,0);
   uchar res[];

   ResetLastError();
   int rv = WebRequest("GET", url, headers, 5000, req, res, result_headers);

   if(rv == -1) {
      int err = GetLastError();
      PrintFormat("[HttpGet] WebRequest transport error %d (%s) url=%s", err, err, url);
      return false;
   }

   if(ArraySize(res) <= 0)
   {
      PrintFormat("[HttpGet] Empty body for %s", url);
      return false;
   }

   result_body = CharArrayToString(res, 0, WHOLE_ARRAY, CP_UTF8);
   if(StringLen(result_body) <= 0)
   {
      PrintFormat("[HttpGet] Empty decoded body for %s", url);
      return false;
   }

   return true;
}

bool HttpPostJSON(const string url, const string json, string &result_body, string &result_headers)
{
    result_body = "";
    result_headers = "";
    string headers = "Connection: close\r\nContent-Type: application/json\r\nX-Auth-Token: " + AUTH_SHARED + "\r\n";
    uchar request[];
    ArrayResize(request, (int)StringLen(json));
    StringToCharArray(json, request, 0, (int)StringLen(json), CP_UTF8);
    uchar response[];

    ResetLastError();
    int status = WebRequest("POST", url, headers, TimeoutMs, request, response, result_headers);
    if(status == -1)
    {
        PrintFormat("[HttpPostJSON] WebRequest transport error %d url=%s", GetLastError(), url);
        return false;
    }
    result_body = CharArrayToString(response, 0, WHOLE_ARRAY, CP_UTF8);
    if(status < 200 || status >= 300)
    {
        PrintFormat("[HttpPostJSON] HTTP=%d url=%s body=%s", status, url, result_body);
        return false;
    }
    return true;
}

bool PublishReceiverState()
{
    double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    long secondsSinceLastLoss = g_lastLossClose > 0
                                         ? (long)MathMax(0, (long)TimeTradeServer() - (long)g_lastLossClose)
                                         : -1;
    bool scheduleOpen = IsTradingWindowOpen();
    bool positionsAtBreakEven = !RequireAllAtBEToAdd || AllOurPositionsAtBE();
    string json = ReceiverBuildStateJson(
        IntegerToString(Magic),
        g_equityAtDayStart,
        currentBalance,
        g_dailyClosedNet,
        g_lossesToday,
        g_spikesToday,
        secondsSinceLastLoss,
        scheduleOpen,
        positionsAtBreakEven
    );

    string responseBody, responseHeaders;
    bool posted = HttpPostJSON(URL_RECEIVER_STATE(), json, responseBody, responseHeaders);
    if(posted && EnableDetailedLogging)
    {
        string changedSummary = ReceiverJsonString(responseBody, "changed_summary");
        if(changedSummary != "")
            PrintFormat("[MT5_STATE_CHANGED] %s", changedSummary);
        if(!ReceiverJsonTrue(responseBody, "gate_ok"))
            PrintFormat("[SERVER_GATE] %s: %s", ReceiverJsonString(responseBody, "gate"), ReceiverJsonString(responseBody, "reason"));
    }
    return posted;
}

// ---------- Gate Notification ----------
void NotifyGateBlocked(const string gateName, const string details="")
{
    string msg = "GATE BLOCKED: " + gateName;
    if(details != "") msg += " - " + details;
    SendNoticeOnce(msg,120);
    LogToFile("[GATE_BLOCKED] " + msg);
}

// ---------- FIXED: Trading Schedule (30-Day Compatible) ----------
bool IsTradingWindowOpen()
{
   if(!EnforceSchedule) return true; // 30-DAY CONTINUOUS MODE
   
   datetime now=TimeTradeServer(); 
   MqlDateTime md; TimeToStruct(now, md);
   ENUM_DAY_OF_WEEK dow=(ENUM_DAY_OF_WEEK)md.day_of_week;
   
   int h1=0,m1=0,h1_end=0,m1_end=0;
   int h2=0,m2=0,h2_end=0,m2_end=0;
   
   bool s1 = ParseHHMM(Slot1TimeHHMM, h1, m1) && ParseHHMM(Slot1EndHHMM, h1_end, m1_end);
   bool s2 = ParseHHMM(Slot2TimeHHMM, h2, m2) && ParseHHMM(Slot2EndHHMM, h2_end, m2_end);
   
   if(s1 && dow==Slot1Day) {
       int current_minutes = md.hour * 60 + md.min;
       int start_minutes = h1 * 60 + m1;
       int end_minutes = h1_end * 60 + m1_end;
       
       if(current_minutes >= start_minutes && current_minutes <= end_minutes) {
           return true;
       }
   }
   
   if(s2 && dow==Slot2Day) {
       int current_minutes = md.hour * 60 + md.min;
       int start_minutes = h2 * 60 + m2;
       int end_minutes = h2_end * 60 + m2_end;
       
       if(current_minutes >= start_minutes && current_minutes <= end_minutes) {
           return true;
       }
   }
   
   return false;
}

bool CooldownActive(){
   return ReceiverCooldownIsActive((long)TimeTradeServer(), (long)g_lastLossClose, CooldownMinsAfterLoss);
}

// ---------- FIXED: Symbol Preparation (Chart-Independent) ----------
bool PrepareSymbol(string &sym)
{
   if(StringLen(sym) <= 0)
   {
      Print("[PREPARE] Empty symbol requested");
      return false;
   }

   PrintFormat("[PREPARE] Resolving: %s", sym);

   string base = sym;
   string lower = base;
   StringToLower(lower);

   string variants[];
   int idx = 0;
   ArrayResize(variants, 14);
   variants[idx++] = base;
   variants[idx++] = lower;
   variants[idx++] = base + ".pro";
   variants[idx++] = lower + ".pro";
   variants[idx++] = base + ".c";
   variants[idx++] = lower + ".c";
   variants[idx++] = base + ".cash";
   variants[idx++] = lower + ".cash";
   variants[idx++] = base + ".f";
   variants[idx++] = lower + ".f";
   variants[idx++] = "GBPUSD";
   variants[idx++] = "gbpusd";
   variants[idx++] = base;

   for(int i = 0; i < ArraySize(variants); i++)
   {
      string test = variants[i];
      if(test == "") continue;

      PrintFormat("[PREPARE] Trying: %s", test);
      if(!SymbolSelect(test, true))
      {
         PrintFormat("[PREPARE] ✗ %s not selectable", test);
         continue;
      }

      long mode = SymbolInfoInteger(test, SYMBOL_TRADE_MODE);
      if(mode != SYMBOL_TRADE_MODE_FULL)
      {
         PrintFormat("[PREPARE] ⚠ %s exists but trade mode = %d (not full)", test, mode);
         continue;
      }

      MqlTick tick;
      if(!SymbolInfoTick(test, tick) || tick.time <= 0)
      {
         PrintFormat("[PREPARE] ⚠ %s selected but tick data unavailable", test);
         continue;
      }

      sym = test;
      PrintFormat("[PREPARE] ✅ SUCCESS: Using %s (TradeMode=%d)", test, mode);
      return true;
   }

   PrintFormat("[PREPARE] ❌ FAIL: No variant works for %s", sym);
   return false;
}

bool SnapLots(const string sym, double &lots)
{
   if(StringLen(sym) <= 0 || lots <= 0.0)
   {
      Print("[SNAP_LOTS] Invalid symbol or lot size");
      return false;
   }

   double vmin = 0.0, vmax = 0.0, vstep = 0.0;
   if(!SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN, vmin)) return false;
   if(!SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX, vmax)) return false;
   if(!SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP, vstep)) return false;

    double snapped = 0.0;
    if(!ReceiverSnapLots(lots, vmin, vmax, vstep, snapped)) return false;
    lots = snapped;
    return true;
}

// ---------- FIXED: Day/session (30-Day Compatible) ----------
datetime DayAnchor(datetime t){ MqlDateTime md; TimeToStruct(t,md); md.hour=0; md.min=0; md.sec=0; return StructToTime(md); }

void ResetDailyIfNeeded()
{
   datetime now=TimeTradeServer(); datetime anchor=DayAnchor(now);
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

    if(ReceiverApplyDailyReset(state, (long)anchor, AccountInfoDouble(ACCOUNT_BALANCE), DailyLossCapPct, DailyProfitTargetPct))
   {
        g_dayAnchor = (datetime)state.day_anchor;
        g_equityAtDayStart = state.start_balance;
        g_equityLossLimit = state.loss_limit;
        g_profitTargetAbs = state.profit_target;
        g_dailyClosedNet = state.closed_net;
        g_tradesToday = state.trades;
        g_lossesToday = state.losses;
        g_spikesToday = state.spikes;
        g_lastLossClose = (datetime)state.last_loss_time;

      string msg = StringFormat("New day — BalanceStart: %.2f | LossCap: %.2f (%.2f%%) | ProfitTarget: %.2f (%.2f%%) | MaxLosses: %d",
                                g_equityAtDayStart, g_equityLossLimit, DailyLossCapPct,
                                g_profitTargetAbs, DailyProfitTargetPct, g_effMaxLossesPerDay);
      SendNoticeOnce(msg, 1);
      
      // ✨ NEW DAY EMAIL NOTIFICATION
      if(EnableMail) {
         string emailSubject = StringFormat("New Trading Day Started - EA #%d", Magic);
         string emailBody = StringFormat(
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
            "Forex SL Points: %.1f (%.1f × %.1f)\n"
            "Indices SL Points: %.1f\n"
            "Gold SL Points: %.1f\n"
            "Commodities SL Points: %.1f\n"
            "Other SL Points: %.1f\n\n"
            "Risk Per Trade: %.1f%%\n"
            "30-Day Mode: %s\n"
            "Auto-BE at %.1fR: %s\n\n"
            "=== Trading Day Active ===\n",
            AccountInfoString(ACCOUNT_NAME),
            Magic,
            TimeToString(now, TIME_DATE|TIME_SECONDS),
            g_equityAtDayStart,
            g_equityLossLimit, DailyLossCapPct,
            g_profitTargetAbs, DailyProfitTargetPct,
            g_effMaxLossesPerDay,
            CooldownMinsAfterLoss,
            ForexSpreadPoints,
            ForexSpreadMultiplier,
            ForexSpreadPoints * ForexSpreadMultiplier,
            ForexSpreadPoints, ForexSpreadMultiplier,
            FixedSLPoints_Indices,
            FixedSLPoints_Gold,
            FixedSLPoints_Commodities,
            FixedSLPoints_Other,
            g_effRiskPerTradePct,
            EnforceSchedule ? "SCHEDULED" : "CONTINUOUS",
            AutoBE_Multiplier,
            AutoBE_3R_Enable ? "ENABLED" : "DISABLED"
         );
         
         if(!SendMail(emailSubject, emailBody)) {
            Print("[NEW_DAY] WARNING: Failed to send new day email");
         } else {
            Print("[NEW_DAY] New day email sent successfully");
         }
      }
      
      LogToFile("[NEW_DAY] " + msg);
      
      // Log gate status at day start
      static datetime lastGateLog = 0;
      if(TimeCurrent() - lastGateLog > 3600) {
          LogGateStatus();
          lastGateLog = TimeCurrent();
      }
   }
}

bool ApplyReceiverDealToRuntime(
    const bool belongs_to_receiver,
    const bool is_closing_deal,
    const bool net_is_finite,
    const double net,
    const long close_time,
    bool &was_loss,
    bool &was_spike
)
{
    ReceiverDailyState day_state;
    day_state.day_anchor = (long)g_dayAnchor;
    day_state.start_balance = g_equityAtDayStart;
    day_state.loss_limit = g_equityLossLimit;
    day_state.profit_target = g_profitTargetAbs;
    day_state.closed_net = g_dailyClosedNet;
    day_state.trades = g_tradesToday;
    day_state.losses = g_lossesToday;
    day_state.spikes = g_spikesToday;
    day_state.last_loss_time = (long)g_lastLossClose;

    bool applied = ReceiverApplyClosedDeal(
        day_state,
        belongs_to_receiver,
        is_closing_deal,
        net_is_finite,
        net,
        g_equityAtDayStart * (SpikeThresholdPct / 100.0),
        close_time,
        1e-6,
        was_loss,
        was_spike
    );
    if(!applied) return false;

    g_dailyClosedNet = day_state.closed_net;
    g_lossesToday = day_state.losses;
    g_spikesToday = day_state.spikes;
    g_lastLossClose = (datetime)day_state.last_loss_time;
    return true;
}

// ---------- FIXED: Deals tracking (uses start-of-day equity for spikes) ----------
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.deal == 0) return;

   // Prevent double-counting if the same deal is seen again later.
    if(trans.deal <= g_startupDealWatermark)
        return;

   long entry = (long)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != (long)Magic) return;

   double net = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
              + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION)
              + HistoryDealGetDouble(trans.deal, DEAL_SWAP);

   // Guard against bad/empty history reads.
   if(!IsFiniteNumber(net))
   {
      PrintFormat("[RX] WARNING: non-finite deal result for deal %I64u", trans.deal);
      return;
   }

    if(!ReceiverMarkDealOnce(g_processedDeals, trans.deal))
        return;

    bool wasLoss = false;
    bool wasSpike = false;
    ApplyReceiverDealToRuntime(
        true,
        true,
        true,
        net,
        (long)TimeTradeServer(),
        wasLoss,
        wasSpike
    );

    if(wasLoss)
   {
      NotifyRiskLeft();
      LogToFile("[LOSS] " + DoubleToString(net, 2));
   }
   else
   {
      LogToFile("[PROFIT] " + DoubleToString(net, 2));
   }
}

void PollHistoryForLoss()
{
   datetime from = g_dayAnchor > 0 ? g_dayAnchor : (TimeTradeServer() - 3*24*60*60);
   HistorySelect(from, TimeTradeServer());

   int total = HistoryDealsTotal();
   if(total <= 0) return;

   const double lossTol = 1e-6;
   for(int i = total - 1; i >= 0 && i >= total - 400; --i)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
    if(deal <= g_startupDealWatermark) continue;

      if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != (long)Magic)
      {
         continue;
      }

      long entry = (long)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT)
      {
         continue;
      }

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
        ApplyReceiverDealToRuntime(
            true,
            true,
            true,
            net,
            (long)TimeTradeServer(),
            wasLoss,
            wasSpike
        );

        if(wasLoss)
      {
         NotifyRiskLeft();
      }

   }
}

void RecomputeDailyLosses()
{
   const double lossTol = 1e-6;
   datetime from = g_dayAnchor > 0 ? g_dayAnchor : (TimeTradeServer() - 3*24*60*60);
   HistorySelect(from, TimeTradeServer());
   int total = HistoryDealsTotal(); if(total<=0){ g_lossesToday=0; return; }

   int lossesToday = 0;
   for(int i=total-1;i>=0;i--){
      ulong d=HistoryDealGetTicket(i); if(d==0) continue;
      if((long)HistoryDealGetInteger(d, DEAL_MAGIC)!=(long)Magic) continue;
      long entry=(long)HistoryDealGetInteger(d, DEAL_ENTRY);
      if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_INOUT) continue;
      
      double net = HistoryDealGetDouble(d, DEAL_PROFIT)
                 + HistoryDealGetDouble(d, DEAL_COMMISSION)
                 + HistoryDealGetDouble(d, DEAL_SWAP);
                 
    if(ReceiverIsLosingClosedDeal(
        true,
        entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT,
        IsFiniteNumber(net),
        net,
        lossTol))
       lossesToday++;
   }
   g_lossesToday = lossesToday;
}

// ---------- Auto-BE Test Function ----------
void TestAutoBE()
{
   Print("=== Testing Auto-BE with SPREAD MULTIPLE for Forex ===");
   Print("AutoBE_3R_Enable = ", AutoBE_3R_Enable);
   Print("AutoBE_Multiplier = ", AutoBE_Multiplier, "R");
   Print("Forex Spread Points = ", ForexSpreadPoints);
   Print("Forex Spread Multiplier = ", ForexSpreadMultiplier);
   Print("Forex SL Points = ", ForexSpreadPoints * ForexSpreadMultiplier);
   
   // Test fixed points for different instruments
   string testSymbols[] = {"EURUSD", "XAUUSD", "US30", "BTCUSD"};
   
   for(int i = 0; i < ArraySize(testSymbols); i++) {
      string sym = testSymbols[i];
      if(SymbolSelect(sym, true)) {
         ENUM_INSTR_TYPE instr_type = GetInstrumentType(sym);
         string instr_type_str = InstrumentTypeToString(instr_type);
         bool isGold = (StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0);
         double calculated_points = 0.0;
         
         // Get fixed points as the function would
         if(instr_type == INSTR_TYPE_FOREX) {
             calculated_points = ForexSpreadPoints * ForexSpreadMultiplier;
         } else if(instr_type == INSTR_TYPE_COMMODITY) {
             if(isGold && UseGoldSpecificSettings && FixedSLPoints_Gold > 0.0) {
                 calculated_points = FixedSLPoints_Gold;
             } else {
                 calculated_points = FixedSLPoints_Commodities;
             }
         } else if(instr_type == INSTR_TYPE_INDEX) {
             calculated_points = FixedSLPoints_Indices;
         } else {
             calculated_points = FixedSLPoints_Other;
         }
         
         double point = GetSymbolPoint(sym);
         PrintFormat("%s: Type=%s, Gold=%s, Calculated Points = %.1f, Point Size = %.5f, %.1fR = %.5f price units",
                    sym, instr_type_str, isGold ? "YES" : "NO",
                    calculated_points, point, AutoBE_Multiplier, AutoBE_Multiplier*calculated_points*point);
      }
   }
}

// ---------- Lifecycle ----------
int OnInit()
{
   // Input validation - actually clamp to safe values (input vars are read-only)
   g_effMaxLossesPerDay = MaxLossesPerDay;
   if(g_effMaxLossesPerDay <= 0) {
      Print("[ERROR] MaxLossesPerDay must be > 0. Using 5.");
      g_effMaxLossesPerDay = 5;
   }
   g_effRiskPerTradePct = RiskPerTradePct;
   if(g_effRiskPerTradePct <= 0 || g_effRiskPerTradePct > 10) {
      Print("[ERROR] RiskPerTradePct must be 0-10%. Using 1%.");
      g_effRiskPerTradePct = 1.0;
   }
   
   Trade.SetExpertMagicNumber(Magic);
   Trade.SetDeviationInPoints(Slippage);

   int poll_ms = (PollMs < 100 ? 100 : PollMs);
   if(poll_ms != PollMs) PrintFormat("[RX] Poll clamped to %d ms", poll_ms);
   EventSetMillisecondTimer(poll_ms);

   // ✨ NEW: Market Watch Initialization (CRITICAL FIX)
   InitializeMarketWatch();
   
   ResetDailyIfNeeded();

   HistorySelect(TimeTradeServer() - 3*24*60*60, TimeTradeServer());
   int total = HistoryDealsTotal();
   if(total > 0){
      ulong last = HistoryDealGetTicket(total - 1);
    if(last > 0) g_startupDealWatermark = last;
   }
   RecomputeDailyLosses();
   
   // Test Auto-BE functionality
   TestAutoBE();
   
   Print("=== SignalReceiverEA Initialized ===");
   Print("COMPLETELY CHART-INDEPENDENT - No chart symbol dependency");
   Print("Gold detection happens BEFORE forex detection (FIXED)");
   Print("30-Day Mode: ", EnforceSchedule ? "SCHEDULED" : "CONTINUOUS");
   Print("Magic Number: ", Magic);
   Print("Risk per trade: ", g_effRiskPerTradePct, "%");
   Print("Auto-BE Enabled: ", AutoBE_3R_Enable);
   Print("Auto-BE Multiplier: ", AutoBE_Multiplier, "R");
   Print("Using SPREAD MULTIPLE for Forex pairs:");
   Print("  - Forex Spread: ", ForexSpreadPoints, " points");
   Print("  - Forex Spread Multiplier: ", ForexSpreadMultiplier);
   Print("  - Forex SL Points: ", ForexSpreadPoints * ForexSpreadMultiplier, " points");
   Print("Gold SL Points: ", FixedSLPoints_Gold);
   Print("Commodities SL Points: ", FixedSLPoints_Commodities);
   Print("Indices SL Points: ", FixedSLPoints_Indices);
   Print("Other SL Points: ", FixedSLPoints_Other);
   Print("Market Watch Symbols: ", MarketWatchSymbols);
   Print("Auto-add new symbols: ", AutoAddSignalSymbols ? "ENABLED" : "DISABLED");
   
   LogToFile("[INIT] EA Initialized - COMPLETELY CHART-INDEPENDENT");
   LogToFile("[INIT] Gold detection happens BEFORE forex (FIXED)");
   LogToFile("[INIT] Auto-BE: " + string(AutoBE_3R_Enable ? "ENABLED" : "DISABLED") + " Multiplier: " + DoubleToString(AutoBE_Multiplier));
   LogToFile("[INIT] Forex Spread Settings - Spread:" + DoubleToString(ForexSpreadPoints) + 
             " Multiplier:" + DoubleToString(ForexSpreadMultiplier) + 
             " SL:" + DoubleToString(ForexSpreadPoints * ForexSpreadMultiplier));
   LogToFile("[INIT] Gold SL: " + DoubleToString(FixedSLPoints_Gold) + 
             " Commodities: " + DoubleToString(FixedSLPoints_Commodities) +
             " Indices: " + DoubleToString(FixedSLPoints_Indices) +
             " Other: " + DoubleToString(FixedSLPoints_Other));
   LogToFile("[INIT] Market Watch Symbols: " + MarketWatchSymbols);

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_logFileHandle != INVALID_HANDLE) {
      FileClose(g_logFileHandle);
      g_logFileHandle = INVALID_HANDLE;
   }
   
   string deinitReason;
   switch(reason) {
      case REASON_PROGRAM: deinitReason = "Program terminated"; break;
      case REASON_REMOVE: deinitReason = "EA removed from chart"; break;
      case REASON_RECOMPILE: deinitReason = "EA recompiled"; break;
      case REASON_CHARTCHANGE: deinitReason = "Symbol or timeframe changed"; break;
      case REASON_CHARTCLOSE: deinitReason = "Chart closed"; break;
      case REASON_PARAMETERS: deinitReason = "Input parameters changed"; break;
      case REASON_ACCOUNT: deinitReason = "Account changed"; break;
      case REASON_TEMPLATE: deinitReason = "New template applied"; break;
      case REASON_INITFAILED: deinitReason = "Initialization failed"; break;
      case REASON_CLOSE: deinitReason = "Terminal closed"; break;
      default: deinitReason = "Unknown reason";
   }
   
   LogToFile("[DEINIT] " + deinitReason + " (code: " + IntegerToString(reason) + ")");
}

// ---------- Main Timer Loop ----------
#include "../Include/ReceiverPositionManagement.mqh"
#include "../Include/ReceiverOrderExecution.mqh"
#include "../Include/ReceiverSignalWorkflow.mqh"

void OnTimer()
{
   // Emergency stop check
   CheckEmergencyStop();
   
   // Reset daily state
   ResetDailyIfNeeded();
   
   // Self-healing
   CheckAndRepairState();
   
    // Maintain receiver-owned state before reporting it to the server.
   NukeForeignsByMagic();
   MaintainPositions();
   PollHistoryForLoss();
   
   // Periodic logging
   static datetime lastStatusLog = 0;
   if(TimeCurrent() - lastStatusLog > 1800) { // Every 30 minutes
      LogGateStatus();
      lastStatusLog = TimeCurrent();
   }

   // Publish state, then let the isolated signal workflow handle polling/execution.
   static ulong lastStatePublishMs = 0;
   ulong currentTickMs = GetTickCount64();
   int publishIntervalMs = ReceiverStatePublishMs < 250 ? 250 : ReceiverStatePublishMs;
   if(lastStatePublishMs == 0 || currentTickMs - lastStatePublishMs >= (ulong)publishIntervalMs)
   {
      lastStatePublishMs = currentTickMs;
      if(!PublishReceiverState()) return;
   }

   ProcessPendingServerSignal();
}