#ifndef RECEIVER_PROTOCOL_MQH
#define RECEIVER_PROTOCOL_MQH

struct ReceiverSignal
{
   bool has_signal;
   string id;
   string side;
   string symbol;
   string lots_text;
   double lots;
   long timestamp;
};

int ReceiverFindValueStart(const string json, const string key)
{
   string pattern = "\"" + key + "\"";
   int position = StringFind(json, pattern);
   if(position < 0) return -1;
   position += StringLen(pattern);
   int length = StringLen(json);

   while(position < length && StringGetCharacter(json, position) <= 32) position++;
   if(position >= length || StringGetCharacter(json, position) != ':') return -1;
   position++;
   while(position < length && StringGetCharacter(json, position) <= 32) position++;
   return position < length ? position : -1;
}

string ReceiverJsonString(const string json, const string key)
{
   int position = ReceiverFindValueStart(json, key);
   if(position < 0 || StringGetCharacter(json, position) != '"') return "";
   position++;
   string value = "";
   bool escaped = false;
   int length = StringLen(json);
   for(int index = position; index < length; index++)
   {
      ushort character = StringGetCharacter(json, index);
      if(escaped)
      {
         value += StringSubstr(json, index, 1);
         escaped = false;
      }
      else if(character == '\\')
      {
         escaped = true;
      }
      else if(character == '"')
      {
         return value;
      }
      else
      {
         value += StringSubstr(json, index, 1);
      }
   }
   return "";
}

string ReceiverJsonNumber(const string json, const string key)
{
   int position = ReceiverFindValueStart(json, key);
   if(position < 0) return "";
   int length = StringLen(json);
   int end = position;
   while(end < length)
   {
      ushort character = StringGetCharacter(json, end);
      if((character >= '0' && character <= '9') || character == '-' || character == '+' ||
         character == '.' || character == 'e' || character == 'E')
         end++;
      else
         break;
   }
   if(end == position) return "";
   return StringSubstr(json, position, end - position);
}

bool ReceiverJsonTrue(const string json, const string key)
{
   int position = ReceiverFindValueStart(json, key);
   return position >= 0 && StringSubstr(json, position, 4) == "true";
}

string ReceiverBuildStateJson(
   const string receiver_id,
   const double day_start_balance,
   const double current_balance,
   const double daily_closed_net,
   const int losses_today,
   const int spikes_today,
   const long seconds_since_last_loss,
   const bool schedule_open,
   const bool all_positions_at_break_even
)
{
   return StringFormat(
      "{\"receiverId\":\"%s\",\"dayStartBalance\":%s,\"currentBalance\":%s,\"dailyClosedNet\":%s,\"lossesToday\":%d,\"spikesToday\":%d,\"secondsSinceLastLoss\":%I64d,\"scheduleOpen\":%s,\"allPositionsAtBreakEven\":%s}",
      receiver_id,
      DoubleToString(day_start_balance, 2),
      DoubleToString(current_balance, 2),
      DoubleToString(daily_closed_net, 2),
      losses_today,
      spikes_today,
      seconds_since_last_loss,
      schedule_open ? "true" : "false",
      all_positions_at_break_even ? "true" : "false"
   );
}

bool ReceiverParseSignal(const string json, ReceiverSignal &signal)
{
   signal.has_signal = false;
   signal.id = "";
   signal.side = "";
   signal.symbol = "";
   signal.lots_text = "";
   signal.lots = 0.0;
   signal.timestamp = 0;

   if(!ReceiverJsonTrue(json, "ok")) return false;
   if(ReceiverJsonTrue(json, "empty")) return true;

   signal.side = ReceiverJsonString(json, "side");
   signal.symbol = ReceiverJsonString(json, "symbol");
   signal.lots_text = ReceiverJsonNumber(json, "lots");
   string timestamp_text = ReceiverJsonNumber(json, "ts");
   if(timestamp_text == "") timestamp_text = ReceiverJsonNumber(json, "created_time");

   StringToUpper(signal.side);
   StringTrimLeft(signal.symbol);
   StringTrimRight(signal.symbol);
   if(signal.side != "BUY" && signal.side != "SELL") return false;
   if(signal.symbol == "" || signal.lots_text == "") return false;

   signal.lots = StringToDouble(signal.lots_text);
   if(signal.lots <= 0.0) return false;
   if(timestamp_text != "") signal.timestamp = (long)StringToInteger(timestamp_text);

   signal.id = ReceiverJsonString(json, "id");
   if(signal.id == "")
   {
      if(timestamp_text == "") timestamp_text = "0";
      signal.id = timestamp_text + "|" + signal.side + "|" + signal.symbol + "|" + signal.lots_text;
   }
   signal.has_signal = true;
   return true;
}

bool ReceiverSignalExpired(const ReceiverSignal &signal, const long now_utc, const int max_age_seconds, long &age_seconds)
{
   age_seconds = signal.timestamp > 0 ? now_utc - signal.timestamp : max_age_seconds + 1;
   if(signal.timestamp <= 0) return true;
   return age_seconds > max_age_seconds;
}

#endif