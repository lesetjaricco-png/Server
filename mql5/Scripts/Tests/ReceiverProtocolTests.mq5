#property strict
#include "../../Include/ReceiverProtocol.mqh"
#include "../../Include/ReceiverDecisions.mqh"

int g_assertions = 0;
int g_failures = 0;

void AssertTrue(const bool condition, const string name)
{
   g_assertions++;
   if(condition)
      Print("PASS: ", name);
   else
   {
      g_failures++;
      Print("FAIL: ", name);
   }
}

void TestParsesSignalAndBuildsFallbackId()
{
   ReceiverSignal signal;
   string json = "{ \"ok\" : true, \"empty\" : false, \"side\" : \"sell\", \"symbol\" : \" GER40Cash \", \"lots\" : 0.10, \"ts\" : 1712345678 }";
   bool parsed = ReceiverParseSignal(json, signal);

   AssertTrue(parsed, "parse valid signal with JSON whitespace");
   AssertTrue(signal.has_signal, "valid response has a signal");
   AssertTrue(signal.side == "SELL", "normalize side to uppercase");
   AssertTrue(signal.symbol == "GER40Cash", "trim symbol whitespace");
   AssertTrue(MathAbs(signal.lots - 0.10) < 0.000001, "parse lots");
   AssertTrue(signal.timestamp == 1712345678, "parse timestamp");
   AssertTrue(signal.id == "1712345678|SELL|GER40Cash|0.10", "build fallback dedupe ID");
}

void TestUsesExplicitIdAndCreatedTimeFallback()
{
   ReceiverSignal signal;
   string json = "{\"ok\":true,\"empty\":false,\"id\":\"signal-42\",\"side\":\"BUY\",\"symbol\":\"EURUSD\",\"lots\":0.2,\"created_time\":1712345678}";
   bool parsed = ReceiverParseSignal(json, signal);

   AssertTrue(parsed, "parse signal using created_time fallback");
   AssertTrue(signal.timestamp == 1712345678, "use created_time as timestamp fallback");
   AssertTrue(signal.id == "signal-42", "preserve explicit signal ID");
}

void TestHandlesEmptyAndInvalidResponses()
{
   ReceiverSignal signal;
   AssertTrue(ReceiverJsonTrue("{ \"ok\" : true }", "ok"), "parse boolean with surrounding whitespace");
   bool emptyParsed = ReceiverParseSignal("{\"ok\":true,\"empty\":true}", signal);
   AssertTrue(emptyParsed && !signal.has_signal, "accept empty signal response");

   bool badSideParsed = ReceiverParseSignal("{\"ok\":true,\"empty\":false,\"side\":\"HOLD\",\"symbol\":\"EURUSD\",\"lots\":1,\"ts\":1712345678}", signal);
   AssertTrue(!badSideParsed, "reject unsupported side");

   bool badLotsParsed = ReceiverParseSignal("{\"ok\":true,\"empty\":false,\"side\":\"BUY\",\"symbol\":\"EURUSD\",\"lots\":0,\"ts\":1712345678}", signal);
   AssertTrue(!badLotsParsed, "reject non-positive lots");

   bool deniedParsed = ReceiverParseSignal("{\"ok\":false,\"reason\":\"AUTH\"}", signal);
   AssertTrue(!deniedParsed, "reject unsuccessful server response");
}

void TestSignalAgeBoundaries()
{
   ReceiverSignal signal;
   signal.timestamp = 1000;
   long age = 0;

   AssertTrue(!ReceiverSignalExpired(signal, 1005, 5, age) && age == 5, "signal at max age remains valid");
   AssertTrue(ReceiverSignalExpired(signal, 1006, 5, age) && age == 6, "signal over max age expires");

   signal.timestamp = 0;
   AssertTrue(ReceiverSignalExpired(signal, 1000, 5, age), "missing timestamp expires safely");
}

void TestReceiverStateJsonContract()
{
   string json = ReceiverBuildStateJson("demo-7", 10000.0, 9700.0, -125.5, 4, 1, 120, true, false);
   AssertTrue(ReceiverJsonString(json, "receiverId") == "demo-7", "state JSON includes receiver ID");
   AssertTrue(ReceiverJsonNumber(json, "dayStartBalance") == "10000.00", "state JSON includes day-start balance");
   AssertTrue(ReceiverJsonNumber(json, "currentBalance") == "9700.00", "state JSON includes current balance");
   AssertTrue(ReceiverJsonNumber(json, "dailyClosedNet") == "-125.50", "state JSON includes closed daily net");
   AssertTrue(ReceiverJsonNumber(json, "lossesToday") == "4", "state JSON includes daily losses");
   AssertTrue(ReceiverJsonNumber(json, "spikesToday") == "1", "state JSON includes daily spikes");
   AssertTrue(ReceiverJsonNumber(json, "secondsSinceLastLoss") == "120", "state JSON includes elapsed cooldown seconds");
   AssertTrue(ReceiverJsonTrue(json, "scheduleOpen"), "state JSON includes open schedule boolean");
   AssertTrue(!ReceiverJsonTrue(json, "allPositionsAtBreakEven"), "state JSON includes break-even boolean");
}

void TestCooldownBoundary()
{
   AssertTrue(ReceiverCooldownIsActive(10000, 9701, 5), "cooldown blocks immediately before boundary");
   AssertTrue(!ReceiverCooldownIsActive(10001, 9701, 5), "cooldown opens exactly at boundary");
}

void TestLossDealAccountingAndDeduplication()
{
   ReceiverDailyState daily;
   daily.day_anchor = 0;
   daily.start_balance = 10000.0;
   daily.loss_limit = 300.0;
   daily.profit_target = 200.0;
   daily.closed_net = 0.0;
   daily.trades = 0;
   daily.losses = 0;
   daily.spikes = 0;
   daily.last_loss_time = 0;
   bool wasLoss = false;
   bool wasSpike = false;
   ulong processed_tickets[];
   ulong losing_tickets[5] = {104, 102, 103, 101, 105};

   for(int index = 0; index < 5; index++)
   {
      ulong ticket = losing_tickets[index];
      if(ReceiverMarkDealOnce(processed_tickets, ticket))
         ReceiverApplyClosedDeal(daily, true, true, true, -10.0, 1000.0,
                                 100 + index, 1e-6, wasLoss, wasSpike);
   }
   AssertTrue(daily.losses == 5, "five out-of-order closing losses are counted");
   AssertTrue(!ReceiverMarkDealOnce(processed_tickets, 102), "duplicate closing deal notification is ignored");

   int lossesBeforeIgnored = daily.losses;
   ReceiverApplyClosedDeal(daily, false, true, true, -50.0, 1000.0, 106, 1e-6, wasLoss, wasSpike);
   ReceiverApplyClosedDeal(daily, true, false, true, -50.0, 1000.0, 107, 1e-6, wasLoss, wasSpike);
   ReceiverApplyClosedDeal(daily, true, true, true, -0.000001, 1000.0, 108, 1e-6, wasLoss, wasSpike);
   ReceiverApplyClosedDeal(daily, true, true, false, -50.0, 1000.0, 109, 1e-6, wasLoss, wasSpike);
   AssertTrue(daily.losses == lossesBeforeIgnored, "foreign, non-closing, tolerance, and invalid deals do not count");
}

void TestStopSelectionAndPrice()
{
   double points = ReceiverSelectStopPoints(true, false, false, false, true, 2.0, 25.0, 150.0, 80.0, 100.0, 60.0, 45.0);
   AssertTrue(points == 50.0, "forex stop uses spread multiple");

   points = ReceiverSelectStopPoints(true, false, false, false, true, 0.0, 25.0, 150.0, 80.0, 100.0, 60.0, 45.0);
   AssertTrue(points == 50.0, "invalid forex spread settings use fallback");

   points = ReceiverSelectStopPoints(false, true, true, false, true, 2.0, 25.0, 150.0, 80.0, 100.0, 60.0, 45.0);
   AssertTrue(points == 150.0, "gold-specific stop takes commodity priority");

   double stop = 0.0;
   AssertTrue(ReceiverCalculateStopPrice(true, 1.1000, 50.0, 0.0001, stop) && MathAbs(stop - 1.0950) < 1e-8,
              "buy stop is below entry");
   AssertTrue(ReceiverCalculateStopPrice(false, 1.1000, 50.0, 0.0001, stop) && MathAbs(stop - 1.1050) < 1e-8,
              "sell stop is above entry");
   AssertTrue(!ReceiverCalculateStopPrice(true, 1.1, 50.0, 0.0, stop), "reject invalid point size");
}

void TestLotRiskAndMarginPlanning()
{
   ReceiverLotPlan plan = ReceiverCalculateLotPlan(10000.0, 1.0, 10000.0, 300.0, 50.0, 10.0,
                                                   0.01, 100.0, 0.01, 100.0);
   AssertTrue(plan.valid && MathAbs(plan.risk_budget - 100.0) < 1e-8, "risk budget uses configured equity percentage");
   AssertTrue(MathAbs(plan.raw_lots - 0.2) < 1e-8 && MathAbs(plan.lots - 0.2) < 1e-8,
              "calculate and normalize risk-based lots");

   plan = ReceiverCalculateLotPlan(100.0, 0.1, 100.0, 100.0, 500.0, 10.0,
                                   0.01, 100.0, 0.01, 100.0);
   AssertTrue(!plan.valid && plan.failure == "risk budget below minimum volume",
              "reject minimum lot when it would exceed risk budget");

   plan = ReceiverCalculateLotPlan(9900.0, 5.0, 10000.0, 300.0, 50.0, 10.0,
                                   0.01, 100.0, 0.01, 100.0);
   AssertTrue(MathAbs(plan.risk_budget - 200.0) < 1e-8, "remaining daily-loss room caps per-trade risk budget");

   plan = ReceiverCalculateLotPlan(9800.0, 1.0, 10000.0, 300.0, 50.0, 10.0,
                                   0.01, 100.0, 0.01, 100.0);
   AssertTrue(MathAbs(plan.risk_budget - 98.0) < 1e-8, "risk budget remains below daily loss room");

   plan = ReceiverCalculateLotPlan(9700.0, 1.0, 10000.0, 300.0, 50.0, 10.0,
                                   0.01, 100.0, 0.01, 100.0);
   AssertTrue(!plan.valid && plan.failure == "risk budget exhausted", "reject when daily loss room is exhausted");

   double snapped = 0.0;
   AssertTrue(ReceiverSnapLots(0.127, 0.01, 10.0, 0.01, snapped) && MathAbs(snapped - 0.12) < 1e-8,
              "snap volumes down to broker step");
   AssertTrue(ReceiverSnapLots(0.001, 0.01, 10.0, 0.01, snapped) && MathAbs(snapped - 0.01) < 1e-8,
              "floor subminimum volume at broker minimum as existing receiver does");

   double adjusted = 0.0;
   AssertTrue(ReceiverAdjustLotsForMargin(1.0, 1000.0, 500.0, 0.01, 10.0, 0.01, adjusted) &&
              MathAbs(adjusted - 0.5) < 1e-8, "shrink and normalize lot size to available margin");
   AssertTrue(!ReceiverAdjustLotsForMargin(1.0, 1000.0, 0.0, 0.01, 10.0, 0.01, adjusted),
              "reject margin adjustment when no free margin remains");
   AssertTrue(!ReceiverAdjustLotsForMargin(1.0, 1000.0, 5.0, 0.01, 10.0, 0.01, adjusted),
              "reject minimum lot when margin reduction would round volume back up");
}

void TestDailyResetTransitions()
{
   ReceiverDailyState state;
   state.day_anchor = 100;
   state.start_balance = 10000.0;
   state.loss_limit = 300.0;
   state.profit_target = 200.0;
   state.closed_net = 75.0;
   state.trades = 3;
   state.losses = 1;
   state.spikes = 1;
   state.last_loss_time = 150;

   AssertTrue(!ReceiverApplyDailyReset(state, 100, 11000.0, 3.0, 2.0), "same-day update does not reset state");
   AssertTrue(state.trades == 3 && state.closed_net == 75.0, "same-day state remains unchanged");

   AssertTrue(ReceiverApplyDailyReset(state, 200, 12000.0, 3.0, 2.0), "new day triggers reset");
   AssertTrue(state.day_anchor == 200 && state.start_balance == 12000.0, "new day sets anchor and balance");
   AssertTrue(state.loss_limit == 360.0 && state.profit_target == 240.0, "new day recalculates risk thresholds");
   AssertTrue(state.closed_net == 0.0 && state.trades == 0 && state.losses == 0 && state.spikes == 0 && state.last_loss_time == 0,
              "new day clears daily counters and cooldown");
}

void OnStart()
{
   TestParsesSignalAndBuildsFallbackId();
   TestUsesExplicitIdAndCreatedTimeFallback();
   TestHandlesEmptyAndInvalidResponses();
   TestSignalAgeBoundaries();
   TestReceiverStateJsonContract();
   TestCooldownBoundary();
   TestLossDealAccountingAndDeduplication();
   TestStopSelectionAndPrice();
   TestLotRiskAndMarginPlanning();
   TestDailyResetTransitions();

   PrintFormat("ReceiverProtocolTests: %d assertions, %d failures", g_assertions, g_failures);
}