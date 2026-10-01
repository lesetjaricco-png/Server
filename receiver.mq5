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

// ---------- State ----------
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
string g_lastProcessedSignal="";
string g_lastAckedSignalID = "";
ulong g_lastSeenDeal = 0;

// Clamped, actually-enforced copies of risk inputs (input vars can't be reassigned)
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

// ---------- FIXED: Daily Loss Cap (uses BALANCE not EQUITY) ----------
bool DailyLossBreached(){ 
    double balance = AccountInfoDouble(ACCOUNT_BALANCE); // FIX: Use BALANCE
    double drop = g_equityAtDayStart - balance; 
    return (drop >= g_equityLossLimit - 1e-6); 
}

bool DailyProfitReached(){ 
    return (g_dailyClosedNet >= g_profitTargetAbs - 1e-6); 
}

bool CooldownActive(){
   if(g_lastLossClose==0) return false;
   long secs=(long)TimeTradeServer()-(long)g_lastLossClose;
   return (secs < (long)CooldownMinsAfterLoss*60);
}

// ---------- FIXED: CheckAllGates (Optimized Order) ----------
bool CheckAllGates(string &gateName, string &gateDetails, const string &side_txt, const string &symbol)
{
    gateName = "";
    gateDetails = "";
   
    // Fast checks first (no position queries)
    if(!IsTradingWindowOpen()){
        gateName = "Trading Schedule";
        MqlDateTime md; TimeToStruct(TimeTradeServer(), md);
        gateDetails = StringFormat("Current: %02d:%02d Day %d", md.hour, md.min, md.day_of_week);
        return false;
    }
   
    if(DailyLossBreached()){
        gateName = "Daily Loss Cap";
        double balance = AccountInfoDouble(ACCOUNT_BALANCE);
        double drop = g_equityAtDayStart - balance;
        gateDetails = StringFormat("Drop: %.2f | Cap: %.2f", drop, g_equityLossLimit);
        return false;
    }
   
    if(DailyProfitReached()){
        gateName = "Daily Profit Target";
        gateDetails = StringFormat("PnL: %.2f | Target: %.2f", g_dailyClosedNet, g_profitTargetAbs);
        return false;
    }
   
    if(g_lossesToday >= g_effMaxLossesPerDay){
        gateName = "Max Losses Per Day";
        gateDetails = StringFormat("Losses: %d/%d", g_lossesToday, g_effMaxLossesPerDay);
        return false;
    }
   
    if(g_spikesToday >= MaxDailySpikes){
        gateName = "Max Daily Spikes";
        gateDetails = StringFormat("Spikes: %d/%d", g_spikesToday, MaxDailySpikes);
        return false;
    }
   
    if(CooldownActive()){
        gateName = "Cooldown After Loss";
        datetime nextTrade = g_lastLossClose + CooldownMinsAfterLoss*60;
        gateDetails = StringFormat("Next: %s", FormatDT(nextTrade));
        return false;
    }
   
    // Slow check last (requires position queries)
    if(RequireAllAtBEToAdd && !AllOurPositionsAtBE()) {
        gateName = "All Positions Not At BE";
        gateDetails = StringFormat("Blocked: %s %s", side_txt, symbol);
        return false;
    }
   
    return true;
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

   if(vstep <= 0.0)
   {
      lots = NormalizeDouble(lots, 2);
      return true;
   }

   double snap = MathFloor((lots + 1e-12) / vstep) * vstep;
   if(snap < vmin) snap = vmin;
   if(snap > vmax) snap = vmax;

   int vol_digits = 0;
   double t = vstep;
   while(t < 1.0 && vol_digits < 10)
   {
      t *= 10.0;
      vol_digits++;
   }

   lots = NormalizeDouble(snap, vol_digits);
   return true;
}

// ---------- FIXED: Day/session (30-Day Compatible) ----------
datetime DayAnchor(datetime t){ MqlDateTime md; TimeToStruct(t,md); md.hour=0; md.min=0; md.sec=0; return StructToTime(md); }

void ResetDailyIfNeeded()
{
   datetime now=TimeTradeServer(); datetime anchor=DayAnchor(now);
   if(g_dayAnchor!=anchor)
   {
      g_dayAnchor=anchor;
      g_equityAtDayStart=AccountInfoDouble(ACCOUNT_BALANCE); // FIX: Use BALANCE
      g_equityLossLimit =g_equityAtDayStart*(DailyLossCapPct/100.0);
      g_profitTargetAbs =g_equityAtDayStart*(DailyProfitTargetPct/100.0);
      g_dailyClosedNet = 0.0;
      g_tradesToday = 0;
      g_lossesToday = 0;
      g_spikesToday = 0;
      g_lastLossClose = 0; // RESET COOLDOWN AT MIDNIGHT

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

// ---------- Anti-widen ----------
int IndexOfTicket(const ulong ticket){ for(int i=0;i<ArraySize(gTickets);i++) if(gTickets[i]==ticket) return i; return -1; }
void ObserveOrSetBoundary(const ulong ticket,const long type,const double sl)
{
   int idx=IndexOfTicket(ticket);
   if(idx<0){
      int n=ArraySize(gTickets); ArrayResize(gTickets,n+1); ArrayResize(gBoundarySL,n+1); ArrayResize(gTypeOfTicket,n+1);
      gTickets[n]=ticket; gTypeOfTicket[n]=type; gBoundarySL[n]=sl;
   }else{
      gTypeOfTicket[idx]=type;
      if(type==POSITION_TYPE_BUY){ if(sl>gBoundarySL[idx]) gBoundarySL[idx]=sl; }
      else{ if(sl<gBoundarySL[idx]) gBoundarySL[idx]=sl; }
   }
}

// ========== UPDATED: Chart-independent CloseIfWidened ==========
bool CloseIfWidened(const string sym,const ulong ticket,const long type,const double sl)
{
   int idx=IndexOfTicket(ticket);
   if(idx<0){ if(sl>0.0) ObserveOrSetBoundary(ticket,type,sl); return false; }
   
   double point = GetSymbolPoint(sym);
   const double tol = 0.5 * point;
   
   bool widened=false;
   if(type==POSITION_TYPE_BUY){ if(sl <= 0.0 || sl < gBoundarySL[idx]-tol) widened=true; }
   else{ if(sl <= 0.0 || sl > gBoundarySL[idx]+tol) widened=true; }
   
   if(widened){
      if(!Trade.PositionClose(ticket)){
         PrintFormat("[RX] Close FAIL %s #%I64u ret=%d (%s)", sym, ticket, Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
      }
      return true;
   }
   if(sl>0.0) ObserveOrSetBoundary(ticket,type,sl);
   return false;
}

// ---------- Nuke by Magic ONLY ----------
void NukeForeignsByMagic()
{
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) == (long)Magic) continue;
      string ps=PositionGetString(POSITION_SYMBOL);
      if(!Trade.PositionClose(t)){
         PrintFormat("[RX] NUKE FAIL pos %s #%I64u ret=%d (%s)", ps, t, Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
      }
   }
   for(int j=OrdersTotal()-1;j>=0;j--){
      ulong ot=OrderGetTicket(j);
      if(ot==0 || !OrderSelect(ot)) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) == (long)Magic) continue;
      if(!Trade.OrderDelete(ot)){
         PrintFormat("[RX] NUKE FAIL order #%I64u ret=%d (%s)", ot, Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
      }
   }
}

// ========== UPDATED: Chart-independent AllOurPositionsAtBE ==========
bool AllOurPositionsAtBE()
{
   int total = PositionsTotal();
   PrintFormat("[RX] BE-check: total positions=%d (checking Magic=%d)", total, (int)Magic);

   for(int idx = 0; idx < total; ++idx)
   {
      ulong ticket = PositionGetTicket(idx);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
      {
         PrintFormat("[RX] BLOCK: cannot select ticket idx=%d -> fail BE check", idx);
         return false;
      }

      long pos_magic = (long)PositionGetInteger(POSITION_MAGIC);
      if(pos_magic != (long)Magic)
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      long type = (long)PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);

      double point = GetSymbolPoint(sym);
      double eps = 0.5 * point;

      if(sl <= 0.0)
      {
         PrintFormat("[RX] BLOCK: %s #%I64u no SL -> NOT at BE", sym, ticket);
         return false;
      }

      if(type == POSITION_TYPE_BUY && sl < entry - eps)
      {
         PrintFormat("[RX] BLOCK: %s #%I64u BUY sl=%.5f entry=%.5f -> NOT BE",
                     sym, ticket, sl, entry);
         return false;
      }
      if(type == POSITION_TYPE_SELL && sl > entry + eps)
      {
         PrintFormat("[RX] BLOCK: %s #%I64u SELL sl=%.5f entry=%.5f -> NOT BE",
                     sym, ticket, sl, entry);
         return false;
      }

      PrintFormat("[RX] BE-ok: %s #%I64u entry=%.5f sl=%.5f",
                  sym, ticket, entry, sl);
   }

   Print("[RX] BE-check PASSED: all our positions are at BE");
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
   if(g_lastSeenDeal != 0 && trans.deal <= g_lastSeenDeal)
   {
      return;
   }
   if(g_lastSeenDeal < trans.deal)
   {
      g_lastSeenDeal = trans.deal;
   }

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

   g_dailyClosedNet += net;

   // FIX: Use start-of-day equity for spike calculation
   double spikeAbs = g_equityAtDayStart * (SpikeThresholdPct/100.0);
   if(MathAbs(net) >= spikeAbs) g_spikesToday++;

   const double lossTol = 1e-6;
   if(net < -lossTol)
   {
      g_lastLossClose = TimeTradeServer();
      g_lossesToday++;
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

   ulong maxSeen = g_lastSeenDeal;
   if(g_lastSeenDeal == 0){
      maxSeen = 0;
   }

   const double lossTol = 1e-6;
   for(int i = total - 1; i >= 0 && i >= total - 400; --i)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if(deal <= g_lastSeenDeal) break;

      if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != (long)Magic)
      {
         if(deal > maxSeen) maxSeen = deal;
         continue;
      }

      long entry = (long)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT)
      {
         if(deal > maxSeen) maxSeen = deal;
         continue;
      }

      double net = HistoryDealGetDouble(deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(deal, DEAL_COMMISSION)
                 + HistoryDealGetDouble(deal, DEAL_SWAP);

      if(!IsFiniteNumber(net))
      {
         PrintFormat("[RX] WARNING: non-finite historical deal result for deal %I64u", deal);
         if(deal > maxSeen) maxSeen = deal;
         continue;
      }

      g_dailyClosedNet += net;

      // FIX: Use start-of-day equity for spike calculation
      double spikeAbs = g_equityAtDayStart * (SpikeThresholdPct/100.0);
      if(MathAbs(net) >= spikeAbs) g_spikesToday++;

      if(net < -lossTol)
      {
         g_lastLossClose = TimeTradeServer();
         g_lossesToday++;
         NotifyRiskLeft();
      }

      if(deal > maxSeen) maxSeen = deal;
   }
   if(maxSeen > g_lastSeenDeal) g_lastSeenDeal=maxSeen;
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
                 
      if(net < -lossTol) lossesToday++;
   }
   g_lossesToday = lossesToday;
}

// ========== UPDATED: Chart-independent lot calculation with better gold detection ==========
bool CalcDynamicLots(const string sym, const string side_txt, 
                     double &lots_out, double &sl_price_out, double &entry_prc_out)
{
   lots_out = 0.0; sl_price_out = 0.0; entry_prc_out = 0.0;
   PrintFormat("[LOT_CALC] Starting UNIFIED calculation for %s %s", side_txt, sym);

   // Ensure symbol data is fresh
   if(!EnsureSymbolInMarketWatch(sym)) {
      PrintFormat("[LOT_CALC] WARNING: %s may have stale data", sym);
   }

   MqlTick t;
   if(!SymbolInfoTick(sym,t)) { 
      PrintFormat("[LOT_CALC] FAIL: Cannot get tick data for %s", sym); 
      return false; 
   }

   double entry_prc = (side_txt=="BUY" ? t.ask : t.bid);
   entry_prc_out = entry_prc;
   
   ENUM_INSTR_TYPE instr_type = GetInstrumentType(sym);
   string instr_type_str = InstrumentTypeToString(instr_type);
   bool isGold = (StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0);
   
   PrintFormat("[LOT_CALC] %s: Detected as %s (Gold: %s)", sym, instr_type_str, isGold ? "YES" : "NO");
   
   double stop_points = 0.0;

   // ===== UPDATED: Forex uses SPREAD MULTIPLE calculation =====
   if(instr_type == INSTR_TYPE_FOREX) {
       // ✨ NEW: Forex uses spread multiple calculation
       if(ForexSpreadPoints > 0.0 && ForexSpreadMultiplier > 0.0) {
           stop_points = ForexSpreadPoints * ForexSpreadMultiplier;
           PrintFormat("[LOT_CALC] %s: SPREAD MULTIPLE - %.1f points × %.1f multiplier = %.1f points SL",
                      sym, ForexSpreadPoints, ForexSpreadMultiplier, stop_points);
       } else {
           stop_points = 50.0; // Fallback
           PrintFormat("[LOT_CALC] %s: Using fallback 50.0 points", sym);
       }
   } else if(instr_type == INSTR_TYPE_COMMODITY) {
       // ✨ IMPROVED: Commodities with gold priority
       if(isGold && UseGoldSpecificSettings && FixedSLPoints_Gold > 0.0) {
           stop_points = FixedSLPoints_Gold;
           PrintFormat("[LOT_CALC] %s: Using Gold-specific SL = %.1f points", sym, stop_points);
       } else if(FixedSLPoints_Commodities > 0.0) {
           stop_points = FixedSLPoints_Commodities;
           PrintFormat("[LOT_CALC] %s: Using Commodities SL = %.1f points", sym, stop_points);
       } else {
           stop_points = GetSafeStopPoints(sym);
           PrintFormat("[LOT_CALC] %s: Using GetSafeStopPoints = %.1f points", sym, stop_points);
       }
   } else {
       // Other instruments use their respective fixed points
       switch(instr_type) {
           case INSTR_TYPE_INDEX: 
               stop_points = FixedSLPoints_Indices;
               PrintFormat("[LOT_CALC] %s: Using Indices SL = %.1f points", sym, stop_points);
               break;
           default: 
               stop_points = FixedSLPoints_Other;
               PrintFormat("[LOT_CALC] %s: Using Other SL = %.1f points", sym, stop_points);
               break;
       }
       
       if(stop_points <= 0.0) { 
           stop_points = GetSafeStopPoints(sym); 
           PrintFormat("[LOT_CALC] %s: Fallback to GetSafeStopPoints = %.1f points", sym, stop_points);
       }
   }

   if(stop_points <= 0.0) { 
       PrintFormat("[LOT_CALC] FAIL: stop_points <= 0 for %s", sym); 
       return false; 
   }

   // ===== UPDATED: Use symbol-specific point size =====
   double point = GetSymbolPoint(sym);
   double stop_prc = entry_prc + (side_txt=="BUY" ? -stop_points*point : +stop_points*point);
   sl_price_out = stop_prc;
   PrintFormat("[LOT_CALC] %s: Stop distance = %.1f points (point size = %.5f, SL price = %.5f)", 
               sym, stop_points, point, sl_price_out);

   // STEP 2: DYNAMIC Value Per Point (same for all)
   double value_per_point_per_lot = CalculateValuePerPoint(sym);
   PrintFormat("[LOT_CALC] %s: Dynamic ValuePerPoint = %.5f", sym, value_per_point_per_lot);
   if(value_per_point_per_lot <= 0.0) { PrintFormat("[LOT_CALC] FAIL: value_per_point_per_lot <= 0 for %s", sym); return false; }

   // STEP 3: Calculate lot size based on risk (same for all)
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_target = MathMax(0.0, eq * (g_effRiskPerTradePct/100.0));
   double used = MathMax(0.0, g_equityAtDayStart - eq);
   double left = MathMax(0.0, g_equityLossLimit - used);
   if(left > 0.0) { risk_target = MathMin(risk_target, left); }
   if(risk_target <= 0.0) { Print("[LOT_CALC] FAIL: risk_target <= 0"); return false; }

   double risk_per_lot = stop_points * value_per_point_per_lot;
   PrintFormat("[LOT_CALC] Risk per lot: %.1f pts × %.5f = %.5f", stop_points, value_per_point_per_lot, risk_per_lot);
   if(risk_per_lot <= 0.0) { Print("[LOT_CALC] FAIL: risk_per_lot <= 0"); return false; }

   double lots = risk_target / risk_per_lot;
   PrintFormat("[LOT_CALC] Raw lots: %.5f risk / %.5f per lot = %.6f lots", risk_target, risk_per_lot, lots);

   if(!SnapLots(sym, lots)) { PrintFormat("[LOT_CALC] FAIL: Cannot snap lots for %s", sym); return false; }
   if(lots > MaxLotsCap) { lots = MaxLotsCap; PrintFormat("[LOT_CALC] Lots capped at: %.4f", MaxLotsCap); }

   // STEP 4: Margin check (same for all)
   double marginNeeded = 0.0;
   if(!OrderCalcMargin((side_txt=="BUY" ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), sym, lots, entry_prc, marginNeeded))
   { PrintFormat("[LOT_CALC] FAIL: Margin calculation failed for %s", sym); return false; }

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(marginNeeded > freeMargin)
   {
      double shrink = freeMargin / marginNeeded;
      double old_lots = lots;
      lots *= shrink;
      if(!SnapLots(sym, lots)) { PrintFormat("[LOT_CALC] FAIL: Cannot snap lots after margin adjustment for %s", sym); return false; }
      PrintFormat("[LOT_CALC] Margin adjustment: %.6f → %.6f", old_lots, lots);
   }

   lots_out = lots;
   PrintFormat("[LOT_CALC] SUCCESS: Final lots = %.6f for %s", lots_out, sym);
   LogToFile(StringFormat("[LOT_CALC] %s %s: StopPts=%.1f, ValuePerPoint=%.5f, Lots=%.6f",
                         side_txt, sym, stop_points, value_per_point_per_lot, lots_out));
   return (lots_out > 0.0);
}

// ========== UPDATED: Chart-independent Auto-BE with better gold detection ==========
void MaintainPositions()
{
   for(int i=0;i<PositionsTotal();i++){
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=(long)Magic) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      long type =(long)PositionGetInteger(POSITION_TYPE);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl =PositionGetDouble(POSITION_SL);

      if(CloseIfWidened(sym, ticket, type, sl)) continue;

      if(!AutoBE_3R_Enable){ 
         if(sl>0.0) ObserveOrSetBoundary(ticket,type,sl); 
         continue; 
      }

      // Calculate R points (stop distance in points)
      double R_pts = 0.0;
      double point = GetSymbolPoint(sym);
      double stop_distance = MathAbs(entry - sl) / point;
      
      // If SL is set, use the actual stop distance as R
      if(sl > 0.0 && stop_distance > 0.0) {
         R_pts = stop_distance;
         PrintFormat("[AUTO-BE] %s #%I64u: Current SL distance = %.1f points (R)", 
                    sym, ticket, R_pts);
      } else {
         // If no SL or zero SL, calculate R based on instrument type
         ENUM_INSTR_TYPE instr_type = GetInstrumentType(sym);
         bool isGold = (StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0);
         
         // ===== UPDATED: Forex uses SPREAD MULTIPLE for Auto-BE =====
         if(instr_type == INSTR_TYPE_FOREX) {
             if(ForexSpreadPoints > 0.0 && ForexSpreadMultiplier > 0.0) {
                 R_pts = ForexSpreadPoints * ForexSpreadMultiplier;
                 PrintFormat("[AUTO-BE] %s #%I64u: Using spread multiple R = %.1f points (%.1f × %.1f)", 
                            sym, ticket, R_pts, ForexSpreadPoints, ForexSpreadMultiplier);
             } else {
                 R_pts = 50.0; // Fallback
                 PrintFormat("[AUTO-BE] %s #%I64u: Using fallback R = 50.0 points", sym, ticket);
             }
         } else if(instr_type == INSTR_TYPE_COMMODITY) {
             // ✨ IMPROVED: Commodities with gold priority
             if(isGold && UseGoldSpecificSettings && FixedSLPoints_Gold > 0.0) {
                 R_pts = FixedSLPoints_Gold;
                 PrintFormat("[AUTO-BE] %s #%I64u: Using Gold-specific R = %.1f points", sym, ticket, R_pts);
             } else if(FixedSLPoints_Commodities > 0.0) {
                 R_pts = FixedSLPoints_Commodities;
                 PrintFormat("[AUTO-BE] %s #%I64u: Using Commodities R = %.1f points", sym, ticket, R_pts);
             } else {
                 R_pts = GetSafeStopPoints(sym);
                 PrintFormat("[AUTO-BE] %s #%I64u: Using GetSafeStopPoints R = %.1f points", sym, ticket, R_pts);
             }
         } else {
             // Other instruments use their respective fixed points
             switch(instr_type) {
                 case INSTR_TYPE_INDEX:
                     R_pts = FixedSLPoints_Indices;
                     PrintFormat("[AUTO-BE] %s #%I64u: Using Indices R = %.1f points", sym, ticket, R_pts);
                     break;
                 default:
                     R_pts = FixedSLPoints_Other;
                     PrintFormat("[AUTO-BE] %s #%I64u: Using Other R = %.1f points", sym, ticket, R_pts);
                     break;
             }
             
             if(R_pts <= 0.0) {
                 R_pts = GetSafeStopPoints(sym);
                 PrintFormat("[AUTO-BE] %s #%I64u: Fallback to GetSafeStopPoints R = %.1f points", sym, ticket, R_pts);
             }
         }
      }

      if(R_pts <= 0.0){ 
         if(sl>0.0) ObserveOrSetBoundary(ticket,type,sl); 
         continue; 
      }

      // Get current price
      MqlTick tx; 
      if(!SymbolInfoTick(sym,tx)){ 
         PrintFormat("[AUTO-BE] WARN: Cannot get tick data for %s", sym);
         if(sl>0.0) ObserveOrSetBoundary(ticket,type,sl); 
         continue; 
      }
      
      double cur = (type==POSITION_TYPE_BUY ? tx.bid : tx.ask);
      double movePts = MathAbs(cur - entry) / point;
      
      PrintFormat("[AUTO-BE] %s #%I64u: Move = %.1f pts, %.1fR = %.1f pts, SL=%.5f",
                 sym, ticket, movePts, AutoBE_Multiplier, AutoBE_Multiplier*R_pts, sl);

      // 🔧 UPDATED: Check if we've reached the adjustable multiplier
      if(movePts >= AutoBE_Multiplier*R_pts - 0.5) { // -0.5 for tolerance
         double desiredSL = entry;
         bool needsModify = false;
         
         double eps = 0.5 * point;
         
         if(sl == 0.0) {
            needsModify = true;
            PrintFormat("[AUTO-BE] %s #%I64u: No SL, moving to BE at entry", sym, ticket);
         } else {
            // Check if SL is not already at BE (within tolerance)
            if(type == POSITION_TYPE_BUY && sl < desiredSL - eps) {
               needsModify = true;
               PrintFormat("[AUTO-BE] %s #%I64u: BUY SL (%.5f) < entry (%.5f), moving to BE",
                          sym, ticket, sl, desiredSL);
            } else if(type == POSITION_TYPE_SELL && sl > desiredSL + eps) {
               needsModify = true;
               PrintFormat("[AUTO-BE] %s #%I64u: SELL SL (%.5f) > entry (%.5f), moving to BE",
                          sym, ticket, sl, desiredSL);
            }
         }
         
         if(needsModify) {
            double tp = PositionGetDouble(POSITION_TP);
            if(Trade.PositionModify(ticket, desiredSL, tp)) {
               PrintFormat("[AUTO-BE] SUCCESS: Moved SL to BE at +%.1fR (%.5f) for %s #%I64u",
                          AutoBE_Multiplier, desiredSL, sym, ticket);
               ObserveOrSetBoundary(ticket, type, desiredSL);
               LogToFile("[AUTO-BE] Moved to BE: " + sym + " #" + IntegerToString(ticket));
            } else {
               PrintFormat("[AUTO-BE] FAILED: Modify error %d (%s) for %s #%I64u",
                          Trade.ResultRetcode(), Trade.ResultRetcodeDescription(), sym, ticket);
            }
         } else {
            PrintFormat("[AUTO-BE] %s #%I64u: Already at BE or better", sym, ticket);
         }
      }
      
      if(sl > 0.0) ObserveOrSetBoundary(ticket, type, sl);
   }
}

// ---------- 30-Day Self-Healing ----------
void CheckAndRepairState()
{
    if(!EnableSelfHealing) return;
    
    static datetime lastCheck = 0;
    if(TimeCurrent() - lastCheck < 3600) return; // Check hourly
    lastCheck = TimeCurrent();
    
    // Clean orphaned anti-widen entries
    int removed = 0;
    for(int i = ArraySize(gTickets)-1; i >= 0; i--) {
        if(!PositionSelectByTicket(gTickets[i])) {
            // Remove orphaned ticket
            ArrayRemove(gTickets, i, 1);
            ArrayRemove(gBoundarySL, i, 1);
            ArrayRemove(gTypeOfTicket, i, 1);
            removed++;
        }
    }
    
    if(removed > 0) {
        PrintFormat("[SELF-HEAL] Removed %d orphaned anti-widen entries", removed);
        LogToFile("[SELF-HEAL] Cleaned " + IntegerToString(removed) + " orphaned entries");
    }
    
    // Check account health
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    if(equity <= 0) {
        Print("[SELF-HEAL] CRITICAL: Zero equity detected!");
        LogToFile("[SELF-HEAL] Zero equity emergency");
    }
}

// ---------- Signal Age Check ----------
bool IsSignalExpired(const string &body)
{
    string tsStr = JNum(body, "ts");
    if(tsStr == "") {
        tsStr = JNum(body, "created_time");
        if(tsStr == "") return true;
    }
   
    long signalTime = (long)StringToInteger(tsStr);
    long currentTime = (long)TimeGMT(); // GMT to match the sender's UTC epoch timestamp
   
    bool expired = (currentTime - signalTime) > SignalMaxAgeSeconds;
   
    if(expired) {
        PrintFormat("[RX] Signal expired: age %d seconds > %d seconds",
                   (currentTime - signalTime), SignalMaxAgeSeconds);
    }
   
    return expired;
}

// ========== UPDATED: Chart-independent trade execution ==========
bool SafeTradeExecute(const string symbol, const string side, double lots, double sl_price)
{
    string logMsg = StringFormat("[SAFE_TRADE] %s %s Lots=%.6f SL=%.5f", 
                                 side, symbol, lots, sl_price);
    Print(logMsg);
    LogToFile(logMsg);
    
    bool ok = (side=="BUY")
        ? Trade.Buy(lots, symbol, 0.0, sl_price, 0.0)
        : Trade.Sell(lots, symbol, 0.0, sl_price, 0.0);

    if(!ok) {
        uint retcode = Trade.ResultRetcode();
        string errMsg = StringFormat("[SAFE_TRADE_FAILED] ret=%d (%s)", 
                                     retcode, Trade.ResultRetcodeDescription());
        Print(errMsg);
        LogToFile(errMsg);
        
        // Handle specific errors
        if(retcode == 10016) { // Invalid stops
            Print("[SAFE_TRADE] Invalid stops error. Trying with increased stop distance...");
            MqlTick t;
            if(SymbolInfoTick(symbol, t)) {
                double entry = (side=="BUY") ? t.ask : t.bid;
                double point = GetSymbolPoint(symbol);
                double new_distance = MathMax(MathAbs(entry - sl_price) * 1.5, 50 * point);
                sl_price = (side=="BUY") ? (entry - new_distance) : (entry + new_distance);
                
                // Retry once
                ok = (side=="BUY")
                    ? Trade.Buy(lots, symbol, 0.0, sl_price, 0.0)
                    : Trade.Sell(lots, symbol, 0.0, sl_price, 0.0);
                    
                if(ok) {
                    Print("[SAFE_TRADE] Success after stop adjustment");
                    LogToFile("[SAFE_TRADE] Success after adjustment");
                }
            }
        }
    }
    
    return ok;
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
      if(last > 0) g_lastSeenDeal = last;
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
void OnTimer()
{
   // Emergency stop check
   CheckEmergencyStop();
   
   // Reset daily state
   ResetDailyIfNeeded();
   
   // Self-healing
   CheckAndRepairState();
   
   // Maintenance
   NukeForeignsByMagic();
   MaintainPositions();
   PollHistoryForLoss();
   
   // Periodic logging
   static datetime lastStatusLog = 0;
   if(TimeCurrent() - lastStatusLog > 1800) { // Every 30 minutes
      LogGateStatus();
      lastStatusLog = TimeCurrent();
   }

   // Poll Flask for signals
   string body, hdr;
   string headers = "X-Auth-Token: " + AUTH_SHARED;

   if(!HttpGet(URL_NEXT(), body, hdr, headers)) return;
   if(StringFind(body,"\"ok\":true") < 0) return;
   if(StringFind(body,"\"empty\":true") >= 0) return;

   // Signal deduplication - build a composite key since /next may omit "id"
   string signalID = JStr(body, "id");
   if(signalID == "") {
      string idTs = JNum(body, "ts");
      if(idTs == "") idTs = JNum(body, "created_time");
      signalID = idTs + "|" + JStr(body,"side") + "|" + JStr(body,"symbol") + "|" + JNum(body,"lots");
   }
   if(signalID != "" && signalID == g_lastAckedSignalID) {
      Print("[DEDUPE] Already processed signal: ", signalID);
      string ackB, ackH;
      HttpGet(URL_ACK(), ackB, ackH, headers);
      return;
   }

   // Check signal expiry
   if(IsSignalExpired(body)) {
      string tsStr = JNum(body, "ts");
      long signalTime = (tsStr == "") ? 0 : (long)StringToInteger(tsStr);
      long currentTime = (long)TimeGMT();
      long ageSeconds = currentTime - signalTime;
     
      NotifyGateBlocked("Signal Expired", StringFormat("Age: %d seconds > %d seconds", ageSeconds, SignalMaxAgeSeconds));
      LogToFile("[SIGNAL_EXPIRED] Age: " + IntegerToString(ageSeconds) + "s");
     
      string ackB, ackH;
      HttpGet(URL_ACK(), ackB, ackH, headers);
      return;
   }

   // Extract signal
   string side_txt = JStr(body,"side");
   string symbol = JStr(body,"symbol");
   string sLots = JNum(body,"lots");
   // Convert side to uppercase
   for(int i = 0; i < StringLen(side_txt); i++) {
       ushort char_code = StringGetCharacter(side_txt, i);
       if(char_code >= 97 && char_code <= 122) {
           char_code -= 32;
           StringSetCharacter(side_txt, i, char_code);
       }
   }

   // 🛠️ DEBUG: Log signal info
   PrintFormat("[RX] ======= PROCESSING SIGNAL =======");
   PrintFormat("[RX] Signal: %s %s | Magic: %d", side_txt, symbol, Magic);

   // ✨ NEW: Ensure symbol is in Market Watch before proceeding
   if(!EnsureSymbolInMarketWatch(symbol)) {
      PrintFormat("[RX] CRITICAL: %s not available in Market Watch. Signal rejected.", symbol);
      string ackB, ackH;
      HttpGet(URL_ACK(), ackB, ackH, headers);
      return;
   }

   // Check all gates
   string blockedGateName, blockedGateDetails;
   if(!CheckAllGates(blockedGateName, blockedGateDetails, side_txt, symbol)) {
      Print("[RX] Blocked by: " + blockedGateName);
      NotifyGateBlocked(blockedGateName, blockedGateDetails);
      LogToFile("[GATE_BLOCKED] " + blockedGateName + " - " + blockedGateDetails);
     
      string ackB, ackH;
      HttpGet(URL_ACK(), ackB, ackH, headers);
      return;
   }
   
   Print("[RX] Processing signal - passed all gates");
   LogToFile("[SIGNAL_RECEIVED] " + side_txt + " " + symbol);

   // Validate side
   if(!(side_txt=="BUY" || side_txt=="SELL")){
      Print("[RX] Invalid side: " + side_txt);
      string b,h; HttpGet(URL_ACK(),b,h,headers);
      return;
   }
   if(symbol==""){
      Print("[RX] Empty symbol");
      string b,h; HttpGet(URL_ACK(),b,h,headers);
      return;
   }
   if(!PrepareSymbol(symbol)){
      Print("[RX] Cannot prepare symbol: " + symbol);
      string b,h; HttpGet(URL_ACK(),b,h,headers);
      return;
   }
   
   // Dynamic lot calculation
   double dynLots=0.0, sl_price=0.0, entry_prc=0.0;
   bool haveDyn = CalcDynamicLots(symbol, side_txt, dynLots, sl_price, entry_prc);
  
   if(!haveDyn || dynLots<=0.0){
      Print("[RX] Dynamic lot calculation failed, using fallback");
     
      if(sLots==""){
         Print("[RX] ERROR: Dynamic lots failed and no static lots provided");
         string b,h; HttpGet(URL_ACK(),b,h);
         return;
      }
     
      dynLots = StringToDouble(sLots);
      if(dynLots<=0){
         Print("[RX] ERROR: Invalid static lots: " + sLots);
         string b,h; HttpGet(URL_ACK(),b,h);
         return;
      }
     
      if(!SnapLots(symbol,dynLots)){
         Print("[RX] ERROR: Cannot snap static lots for: " + symbol);
         string b,h; HttpGet(URL_ACK(),b,h);
         return;
      }
     
      MqlTick t;
      if(!SymbolInfoTick(symbol,t)) {
          Print("[RX] ERROR: Cannot get tick data for fallback");
          string b,h; HttpGet(URL_ACK(),b,h);
          return;
      }
     
      entry_prc = (side_txt=="BUY") ? t.ask : t.bid;
     
      // Fallback: Use fixed points for SL
      ENUM_INSTR_TYPE instr_type = GetInstrumentType(symbol);
      bool isGold = (StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0);
      double fixed_points = 0.0;
      
      // ===== UPDATED: Forex uses SPREAD MULTIPLE in fallback =====
      if(instr_type == INSTR_TYPE_FOREX) {
          if(ForexSpreadPoints > 0.0 && ForexSpreadMultiplier > 0.0) {
              fixed_points = ForexSpreadPoints * ForexSpreadMultiplier;
          } else {
              fixed_points = 50.0; // Fallback
          }
      } else if(instr_type == INSTR_TYPE_COMMODITY) {
          if(isGold && UseGoldSpecificSettings && FixedSLPoints_Gold > 0.0) {
              fixed_points = FixedSLPoints_Gold;
          } else {
              fixed_points = FixedSLPoints_Commodities;
          }
      } else if(instr_type == INSTR_TYPE_INDEX) {
          fixed_points = FixedSLPoints_Indices;
      } else {
          fixed_points = FixedSLPoints_Other;
      }
      
      if(fixed_points <= 0.0) {
          fixed_points = GetSafeStopPoints(symbol);
      }
      
      double point = GetSymbolPoint(symbol);
      double R_prc = fixed_points * point;
      sl_price = (side_txt=="BUY") ? (t.bid - R_prc) : (t.ask + R_prc);
   }

   // ---------- CRITICAL VALIDATION BEFORE TRADE ----------
   if(sl_price <= 0 || entry_prc <= 0) {
       Print("[RX] CRITICAL: Invalid prices - Entry: ", entry_prc, ", SL: ", sl_price);
       LogToFile("[VALIDATION_FAILED] Invalid prices");
       string b,h; HttpGet(URL_ACK(),b,h,headers);
       return;
   }

   // Validate stop loss direction
   if((side_txt == "BUY" && sl_price >= entry_prc) ||
      (side_txt == "SELL" && sl_price <= entry_prc)) {
       Print("[RX] ERROR: Stop loss is in wrong direction!");
       LogToFile("[VALIDATION_FAILED] Wrong SL direction");
       string b,h; HttpGet(URL_ACK(),b,h,headers);
       return;
   }

   // Optional minimum stop distance
   if(EnableMinStopDistance) {
       double point = GetSymbolPoint(symbol);
       double min_distance = MinStopDistancePoints * point;
       if(MathAbs(entry_prc - sl_price) < min_distance) {
           PrintFormat("[RX] WARNING: SL too close (%.5f price units). Adjusting to minimum %.5f price units.",
                      MathAbs(entry_prc - sl_price), min_distance);
           
           sl_price = (side_txt=="BUY") ? (entry_prc - min_distance) : (entry_prc + min_distance);
       }
   }

   // Final validation
   PrintFormat("[RX] Final trade parameters: %s %s Entry=%.5f Lots=%.6f SL=%.5f",
               side_txt, symbol, entry_prc, dynLots, sl_price);

   // Execute trade
   bool ok = SafeTradeExecute(symbol, side_txt, dynLots, sl_price);

   if(!ok){
      PrintFormat("[RX] Trade failed: ret=%d (%s)",
                  Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
      string b,h; HttpGet(URL_ACK(),b,h,headers);
      return;
   } else {
      Print("[RX] Trade executed successfully with SL");
      LogToFile("[TRADE_EXECUTED] " + side_txt + " " + symbol + " Lots:" + DoubleToString(dynLots, 6));
   }
   
   // Store signal ID to prevent reprocessing
   if(signalID != "") {
       g_lastAckedSignalID = signalID;
   }
   
   // Register boundary for anti-widen
   for(int i=0;i<PositionsTotal();i++){
      ulong t=PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t)) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=(long)Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)==symbol){
         long typ=(long)PositionGetInteger(POSITION_TYPE);
         double sl=PositionGetDouble(POSITION_SL);
         if(sl>0.0) ObserveOrSetBoundary(t,typ,sl);
      }
   }

   g_tradesToday++;
  
   // ACK after success
   string ackB, ackH;
   if(!HttpGet(URL_ACK(), ackB, ackH, headers))
      Print("[RX] WARN: /ack failed (signal may repeat)");
   else
      Print("[RX] Signal processed successfully");
}