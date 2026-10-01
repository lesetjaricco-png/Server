//+------------------------------------------------------------------+
//| SignalSenderEA.mq5 |
//| Simple and reliable version with button feedback |
//+------------------------------------------------------------------+
#property strict

// ---- Inputs ----
input string ServerURL = "http://0.0.0.0";  // Base URL
input int TimeoutMs = 8000;
input string AuthToken = ""; // must match Flask AUTH_SHARED if used
input double LotsToSend = 0.10;
input bool UseOverrideSymbol = true;
input string OverrideSymbol = "GER40Cash";

// Warm-up (pre-heat Lichess cache)
input bool EnableWarmup = true; // auto warm-up on attach
input int WarmupRetrySecs = 15; // retry every N secs until cache is warm
input int WarmupGiveUpSecs = 60; // stop trying after N secs (0 = never)
input bool EnableDebugLogging = true; // Enhanced debugging

// ---- UI ----
#define BTN_BUY "BTN_SEND_BUY"
#define BTN_SELL "BTN_SEND_SELL"
#define BTN_WARM "BTN_WARM_UP"

// ---- State ----
datetime g_warmupStart = 0;
bool g_warmDone = false;
string g_lastWarmupResult = "";
bool g_buttonPressed = false;

// ---- Tiny JSON helpers ----
int _Find(const string s,const string pat,const int from=0){ return StringFind(s,pat,from); }

string JStr(const string json,const string k){
  string pat="\""+k+"\":\""; int p=_Find(json,pat); if(p<0) return "";
  p+=(int)StringLen(pat); int n=(int)StringLen(json); int end=-1;
  for(int i=p;i<n;i++){ uchar c=(uchar)json[i]; if(c=='\"'){ if(i>0&&(uchar)json[i-1]=='\\') continue; end=i; break; } }
  if(end<0||end<=p) return ""; return StringSubstr(json,p,end-p);
}

string JBool(const string json,const string k){
  string pat="\""+k+"\":";
  int p=_Find(json,pat); if(p<0) return "";
  p+=(int)StringLen(pat); int n=(int)StringLen(json);
  
  // Skip whitespace
  while(p < n && (json[p] == ' ' || json[p] == '\t' || json[p] == '\r' || json[p] == '\n')) p++;
  
  if(p+4<=n && StringSubstr(json,p,4)=="true") return "true";
  if(p+5<=n && StringSubstr(json,p,5)=="false") return "false";
  return "";
}

string JNum(const string json,const string k){
  string pat="\""+k+"\":"; int p=_Find(json,pat); if(p<0) return "";
  p+=(int)StringLen(pat); int n=(int)StringLen(json);
  while(p<n && (uchar)json[p]==' ') p++;
  int end=p; while(end<n){ uchar c=(uchar)json[end]; if(c==','||c=='}'||c==' '||c=='\r'||c=='\n'||c=='\t') break; end++; }
  if(end<=p) return ""; 
  string raw=StringSubstr(json,p,end-p);
  StringReplace(raw,"\r",""); StringReplace(raw,"\n",""); StringReplace(raw,"\t","");
  return raw;
}

// ---- HTTP ----
bool PostJSONRaw(const string url,const string json,string &resp_body,string &resp_hdrs,bool verbose=true)
{
  string headers="Connection: close\r\nContent-Type: application/json\r\n";
  if(StringLen(AuthToken)>0) headers+="X-Auth-Token: "+AuthToken+"\r\n";

  uchar body[]; ArrayResize(body,(int)StringLen(json));
  StringToCharArray(json,body,0,(int)StringLen(json),CP_UTF8);

  uchar result[]; resp_hdrs=""; ResetLastError();
  int status=WebRequest("POST",url,headers,TimeoutMs,body,result,resp_hdrs);
  int le=GetLastError();
  resp_body=CharArrayToString(result,0,WHOLE_ARRAY,CP_UTF8);

  if(verbose || le != 0 || status != 200)
  {
    PrintFormat("[Sender] HTTP=%d lastError=%d url=%s", status, le, url);
    PrintFormat("[Sender] Request: %s", json);
    if(StringLen(resp_body) > 0) PrintFormat("[Sender] Response: %s", resp_body);
    
    if(le == 4014) {
      Print("[Sender] ERROR: URL not in allowed list. Add it in Tools->Options->Expert Advisors");
    }
  }

  return (status==200);
}

// Send a real signal (buttons BUY/SELL)
bool PostSignal(const string side,const string sym,const double lots,string &out_body)
{
  string endpoint = ServerURL + "/signal";
  string lots_str=DoubleToString(lots,4); StringReplace(lots_str,",",".");
  string json=StringFormat("{\"side\":\"%s\",\"symbol\":\"%s\",\"lots\":%s}", side, sym, lots_str);

  string body, hdr;
  bool http_ok = PostJSONRaw(endpoint, json, body, hdr, true);
  out_body = body;
  return http_ok && StringFind(body,"\"ok\":true")>=0;
}

// NEW: Proper warmup using dedicated /warmup endpoint
bool PostWarmup()
{
  string endpoint = ServerURL + "/warmup";
  string json = "{}";  // Empty JSON for warmup
  
  string body, hdr;
  bool http_ok = PostJSONRaw(endpoint, json, body, hdr, EnableDebugLogging);
  
  if(!http_ok) {
    if(EnableDebugLogging) Print("[WARMUP] HTTP request failed");
    return false;
  }
  
  // Parse response
  string ready = JBool(body, "ready");
  string ok = JBool(body, "ok");
  string message = JStr(body, "message");
  string failed_conditions = JStr(body, "failed_conditions");
  string rating = JNum(body, "rating");
  string games = JNum(body, "games");
  string win_rate = JNum(body, "win_rate");
  
  // Store last result for display
  if(StringLen(message) > 0) {
    g_lastWarmupResult = message;
    if(StringLen(failed_conditions) > 0) {
      g_lastWarmupResult += " [" + failed_conditions + "]";
    }
    if(StringLen(rating) > 0 && StringLen(games) > 0 && StringLen(win_rate) > 0) {
      g_lastWarmupResult += StringFormat(" | R:%s G:%s W:%s%%", 
                                        rating, games, win_rate);
    }
  }
  
  if(EnableDebugLogging)
  {
    PrintFormat("  ready=%s, ok=%s", ready, ok);
    PrintFormat("  message=%s", message);
    PrintFormat("  failed_conditions=%s", failed_conditions);
    PrintFormat("  rating=%s, games=%s, win_rate=%s", rating, games, win_rate);
  }
  
  return (ready == "true" || ok == "true");
}

// ---- Build & send (button action) ----
bool SendSignal(string side_text)
{
  string side=side_text; StringToUpper(side);
  if(side!="BUY" && side!="SELL"){ Print("Bad side: ", side_text); return false; }

  string sym=(UseOverrideSymbol && StringLen(OverrideSymbol)>0)?OverrideSymbol:_Symbol;
  string body;
  bool ok = PostSignal(side,sym,LotsToSend,body);

  if(ok){
    PlaySound(side=="BUY"?"buy.wav":"sell.wav");
    return true;
  }

  // friendly failure sounds (optional hint for Lichess block)
  string reason = JStr(body,"reason");
  if(StringLen(reason)>0 && StringFind(reason,"LICHESS")>=0)
       PlaySound("warning.wav");
  else PlaySound("timeout.wav");

  return false;
}

// ---- Manual warm-up button action ----
void DoManualWarmup()
{
  bool ok = PostWarmup();
  if(ok){
    g_warmDone = true;
    Print("[Sender] Manual warm-up: cache ready");
    if(StringLen(g_lastWarmupResult) > 0) {
      Print("[Sender] Result: ", g_lastWarmupResult);
    }
    PlaySound("ok.wav"); // success chirp
  }else{
    Print("[Sender] Manual warm-up: still not ready");
    if(StringLen(g_lastWarmupResult) > 0) {
      Print("[Sender] Result: ", g_lastWarmupResult);
    }
    PlaySound("timeout.wav"); // subtle nudge
  }
}

// ---- Simple button creation ----
void CreateButton(string name, string text, int x, color bgColor, color hoverColor)
{
  if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
  
  // Create the button
  ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
  ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_LOWER);
  ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
  ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 60);
  ObjectSetInteger(0, name, OBJPROP_XSIZE, 130);
  ObjectSetInteger(0, name, OBJPROP_YSIZE, 50);
  ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
  ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
  ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
  ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
  ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrGray);
  ObjectSetInteger(0, name, OBJPROP_STATE, false);
  ObjectSetString(0, name, OBJPROP_TEXT, text);
  ObjectSetString(0, name, OBJPROP_TOOLTIP, "Click to " + text); // Tooltip for hover hint
}

// ---- Lifecycle ----
int OnInit()
{
  Print("Sender: Tools→Options→Expert Advisors→Allow WebRequest add ", ServerURL);
  
  // Create buttons with NO hover - just simple buttons
  CreateButton(BTN_BUY, "SEND BUY", 20, clrLimeGreen, clrGreen);
  CreateButton(BTN_SELL, "SEND SELL", 165, clrCrimson, clrRed);
  CreateButton(BTN_WARM, "WARM-UP", 310, clrDodgerBlue, clrBlue);
  
  // Enable mouse move events for the chart
  ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
  
  // Status label
  ObjectCreate(0, "StatusLabel", OBJ_LABEL, 0, 0, 0);
  ObjectSetInteger(0, "StatusLabel", OBJPROP_CORNER, CORNER_LEFT_LOWER);
  ObjectSetInteger(0, "StatusLabel", OBJPROP_XDISTANCE, 20);
  ObjectSetInteger(0, "StatusLabel", OBJPROP_YDISTANCE, 120);
  ObjectSetInteger(0, "StatusLabel", OBJPROP_COLOR, clrSilver);
  ObjectSetString(0, "StatusLabel", OBJPROP_TEXT, "Signal Sender EA - Buttons work on click");
  ObjectSetInteger(0, "StatusLabel", OBJPROP_FONTSIZE, 8);

  if(EnableWarmup)
  {
    g_warmupStart = TimeCurrent();
    EventSetTimer((WarmupRetrySecs < 5) ? 5 : WarmupRetrySecs);
  }
  
  return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
  EventKillTimer();
  ObjectDelete(0, BTN_BUY);
  ObjectDelete(0, BTN_SELL);
  ObjectDelete(0, BTN_WARM);
  ObjectDelete(0, "StatusLabel");
}

void OnTimer()
{
  if(!EnableWarmup || g_warmDone) 
  {
    EventKillTimer();
    return;
  }
  
  if(WarmupGiveUpSecs > 0 && (TimeCurrent() - g_warmupStart) >= WarmupGiveUpSecs)
  {
    Print("[Sender] Warmup: giving up (time budget exceeded)");
    g_warmDone = true;
    EventKillTimer();
    return;
  }
  
  bool ok = PostWarmup();
  
  if(ok)
  { 
    g_warmDone = true; 
    Print("[Sender] Warmup: Lichess cache ready"); 
    if(StringLen(g_lastWarmupResult) > 0) 
    {
      Print("[Sender] Result: ", g_lastWarmupResult);
    }
    EventKillTimer();
  } 
  else 
  {
    Print("[Sender] Warmup: Still waiting for cache...");
  }
}

// ---- Handle button clicks with VISUAL feedback ----
void HandleButtonClick(string buttonName)
{
  if(buttonName == BTN_BUY)
  {
    // VISUAL FEEDBACK: Change button appearance when pressed
    ObjectSetInteger(0, BTN_BUY, OBJPROP_BGCOLOR, clrGreen); // Darker green when pressed
    ObjectSetInteger(0, BTN_BUY, OBJPROP_BORDER_COLOR, clrWhite); // White border
    ObjectSetInteger(0, BTN_BUY, OBJPROP_FONTSIZE, 11); // Larger text
    ChartRedraw(); // Force immediate redraw
    
    // Send the signal
    SendSignal("BUY");
    
    // Reset button appearance after delay
    Sleep(300); // 300ms delay so user can see the feedback
    ObjectSetInteger(0, BTN_BUY, OBJPROP_BGCOLOR, clrLimeGreen);
    ObjectSetInteger(0, BTN_BUY, OBJPROP_BORDER_COLOR, clrGray);
    ObjectSetInteger(0, BTN_BUY, OBJPROP_FONTSIZE, 10);
    ChartRedraw();
  }
  else if(buttonName == BTN_SELL)
  {
    ObjectSetInteger(0, BTN_SELL, OBJPROP_BGCOLOR, clrRed);
    ObjectSetInteger(0, BTN_SELL, OBJPROP_BORDER_COLOR, clrWhite);
    ObjectSetInteger(0, BTN_SELL, OBJPROP_FONTSIZE, 11);
    ChartRedraw();
    
    SendSignal("SELL");
    
    Sleep(300);
    ObjectSetInteger(0, BTN_SELL, OBJPROP_BGCOLOR, clrCrimson);
    ObjectSetInteger(0, BTN_SELL, OBJPROP_BORDER_COLOR, clrGray);
    ObjectSetInteger(0, BTN_SELL, OBJPROP_FONTSIZE, 10);
    ChartRedraw();
  }
  else if(buttonName == BTN_WARM)
  {
    ObjectSetInteger(0, BTN_WARM, OBJPROP_BGCOLOR, clrBlue);
    ObjectSetInteger(0, BTN_WARM, OBJPROP_BORDER_COLOR, clrWhite);
    ObjectSetInteger(0, BTN_WARM, OBJPROP_FONTSIZE, 11);
    ChartRedraw();
    
    DoManualWarmup();
    
    Sleep(300);
    ObjectSetInteger(0, BTN_WARM, OBJPROP_BGCOLOR, clrDodgerBlue);
    ObjectSetInteger(0, BTN_WARM, OBJPROP_BORDER_COLOR, clrGray);
    ObjectSetInteger(0, BTN_WARM, OBJPROP_FONTSIZE, 10);
    ChartRedraw();
  }
}

// ---- Simple event handler ----
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
  // Handle button clicks - SIMPLE AND RELIABLE
  if(id == CHARTEVENT_OBJECT_CLICK)
  {
    string name = sparam;
    
    if(name == BTN_BUY || name == BTN_SELL || name == BTN_WARM)
    {
      g_buttonPressed = true;
      HandleButtonClick(name);
      g_buttonPressed = false;
    }
  }
  
  // SIMPLE hover feedback - only works when mouse button is down in MQL5
  if(id == CHARTEVENT_MOUSE_MOVE && g_buttonPressed == false)
  {
    // MQL5 mouse move only triggers when mouse button is pressed
    // So we'll keep this simple
    static long last_x = 0;
    static long last_y = 0;
    
    if(last_x != lparam || last_y != (long)dparam)
    {
      last_x = lparam;
      last_y = (long)dparam;
      
      // Optional: You could add a subtle tooltip or status update here
      // For now, we'll keep it minimal since MQL5 mouse tracking is limited
    }
  }
}