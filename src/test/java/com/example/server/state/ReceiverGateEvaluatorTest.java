package com.example.server.state;

import com.example.server.config.ReceiverGateConfig;
import com.example.server.domain.GuardModels.ReceiverGateDecision;
import com.example.server.domain.GuardModels.ReceiverStateSnapshot;
import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.assertThrows;

class ReceiverGateEvaluatorTest {
    private static final Instant NOW = Instant.parse("2026-10-01T12:00:00Z");
    private static final ReceiverGateConfig CONFIG = new ReceiverGateConfig(3, 2, 5, 2, 5, true, 5000);

    @Test
    void rejectsMissingOrStaleReceiverState() {
        ReceiverGateEvaluator evaluator = new ReceiverGateEvaluator(CONFIG, Clock.fixed(NOW, ZoneOffset.UTC));
        ReceiverGateDecision missing = evaluator.evaluate(null);
        assertFalse(missing.allowed());
        assertEquals("Receiver state unavailable", missing.gate());

        ReceiverStateStore store = new ReceiverStateStore(Clock.fixed(NOW.minusSeconds(6), ZoneOffset.UTC));
        var oldState = store.update(passingSnapshot());
        ReceiverGateDecision stale = evaluator.evaluate(oldState);
        assertFalse(stale.allowed());
        assertEquals("Receiver state stale", stale.gate());
    }

    @Test
    void evaluatesScheduleBalanceProfitLossSpikeCooldownAndBreakEven() {
        ReceiverStateStore store = new ReceiverStateStore(Clock.fixed(NOW, ZoneOffset.UTC));
        ReceiverGateEvaluator evaluator = new ReceiverGateEvaluator(CONFIG, Clock.fixed(NOW, ZoneOffset.UTC));

        assertTrue(evaluator.evaluate(store.update(passingSnapshot())).allowed());
        assertGate(evaluator, store, snapshot(false, 10000, 10000, 0, 0, 0, -1, true), "Trading Schedule");
        assertGate(evaluator, store, snapshot(true, 10000, 9700, 0, 0, 0, -1, true), "Daily Loss Cap");
        assertGate(evaluator, store, snapshot(true, 10000, 10000, 200, 0, 0, -1, true), "Daily Profit Target");
        assertGate(evaluator, store, snapshot(true, 10000, 10000, 0, 5, 0, -1, true), "Max Losses Per Day");
        assertGate(evaluator, store, snapshot(true, 10000, 10000, 0, 0, 2, -1, true), "Max Daily Spikes");
        assertGate(evaluator, store, snapshot(true, 10000, 10000, 0, 0, 0, 299, true), "Cooldown After Loss");
        assertGate(evaluator, store, snapshot(true, 10000, 10000, 0, 0, 0, -1, false), "All Positions Not At BE");

        ReceiverGateDecision cooldownEnded = evaluator.evaluate(store.update(snapshot(true, 10000, 10000, 0, 0, 0, 300, true)));
        assertTrue(cooldownEnded.allowed());
    }

    @Test
    void rejectsMalformedSnapshotAndInvalidGateConfiguration() {
        ReceiverStateStore store = new ReceiverStateStore(Clock.fixed(NOW, ZoneOffset.UTC));
        ReceiverGateEvaluator evaluator = new ReceiverGateEvaluator(CONFIG, Clock.fixed(NOW, ZoneOffset.UTC));
        ReceiverGateDecision invalid = evaluator.evaluate(store.update(
                new ReceiverStateSnapshot("", 10000, 10000, 0, 0, 0, -2, true, true)));

        assertFalse(invalid.allowed());
        assertEquals("Invalid receiver state", invalid.gate());
        assertThrows(IllegalArgumentException.class,
                () -> new ReceiverGateConfig(-1, 2, 5, 2, 5, true, 5000));
    }

    @Test
    void keepsASnapshotFreshAtTheAgeLimitAndBlocksOneMillisecondLater() {
        ReceiverGateDecision atLimit = evaluateAged(5000);
        assertTrue(atLimit.allowed());
        assertEquals(5000, atLimit.snapshotAgeMillis());

        ReceiverGateDecision tooOld = evaluateAged(5001);
        assertFalse(tooOld.allowed());
        assertEquals("Receiver state stale", tooOld.gate());
        assertEquals("MT5 state snapshot is 5001 ms old", tooOld.reason());
    }

    @Test
    void treatsAClockSkewedReceiptAsFresh() {
        ReceiverStateStore store = new ReceiverStateStore(Clock.fixed(NOW.plusSeconds(2), ZoneOffset.UTC));
        ReceiverGateEvaluator evaluator = evaluatorAt(NOW);
        ReceiverGateDecision decision = evaluator.evaluate(store.update(passingSnapshot()));

        assertTrue(decision.allowed());
        assertEquals(0, decision.snapshotAgeMillis());
    }

    @Test
    void allowsFactsJustInsideEveryLimit() {
        ReceiverGateEvaluator evaluator = evaluatorAt(NOW);
        ReceiverStateStore store = storeAt(NOW);

        assertTrue(evaluator.evaluate(store.update(snapshot(true, 10000, 9700.01, 199.99, 4, 1, -1, true))).allowed());
        assertTrue(evaluator.evaluate(store.update(snapshot(true, 10000, 10000, 0, 0, 0, -1, true))).allowed());
    }

    @Test
    void blocksOnEachLimitAndReportsTheMeasuredValues() {
        ReceiverGateEvaluator evaluator = evaluatorAt(NOW);
        ReceiverStateStore store = storeAt(NOW);

        assertReason(evaluator, store, snapshot(true, 10000, 9700, 0, 0, 0, -1, true),
                "Daily Loss Cap", String.format("Drop: %.2f | Cap: %.2f", 300.0, 300.0));
        assertReason(evaluator, store, snapshot(true, 10000, 10000, 200, 0, 0, -1, true),
                "Daily Profit Target", String.format("PnL: %.2f | Target: %.2f", 200.0, 200.0));
        assertReason(evaluator, store, snapshot(true, 10000, 10000, 0, 5, 0, -1, true),
                "Max Losses Per Day", "5/5");
        assertReason(evaluator, store, snapshot(true, 10000, 10000, 0, 0, 2, -1, true),
                "Max Daily Spikes", "2/2");
        assertReason(evaluator, store, snapshot(true, 10000, 10000, 0, 0, 0, 0, true),
                "Cooldown After Loss", "300 seconds remaining");
        assertReason(evaluator, store, snapshot(true, 10000, 10000, 0, 0, 0, 299, true),
                "Cooldown After Loss", "1 seconds remaining");
    }

    @Test
    void reportsTheFirstClosedGateWhenSeveralLimitsFail() {
        ReceiverGateEvaluator evaluator = evaluatorAt(NOW);
        ReceiverStateStore store = storeAt(NOW);

        assertGate(evaluator, store, snapshot(false, 10000, 9000, 500, 9, 9, 0, false), "Trading Schedule");
        assertGate(evaluator, store, snapshot(true, 10000, 9000, 500, 9, 9, 0, false), "Daily Loss Cap");
        assertGate(evaluator, store, snapshot(true, 10000, 10000, 500, 9, 9, 0, false), "Daily Profit Target");
        assertGate(evaluator, store, snapshot(true, 10000, 10000, 0, 9, 9, 0, false), "Max Losses Per Day");
        assertGate(evaluator, store, snapshot(true, 10000, 10000, 0, 0, 9, 0, false), "Max Daily Spikes");
        assertGate(evaluator, store, snapshot(true, 10000, 10000, 0, 0, 0, 0, false), "Cooldown After Loss");
        assertGate(evaluator, store, snapshot(true, 10000, 10000, 0, 0, 0, -1, false), "All Positions Not At BE");
    }

    @Test
    void optionalGatesStayOpenWhenTurnedOff() {
        ReceiverGateConfig optionalGatesOff = new ReceiverGateConfig(3, 2, 5, 2, 0, false, 5000);
        ReceiverGateEvaluator evaluator = new ReceiverGateEvaluator(optionalGatesOff, Clock.fixed(NOW, ZoneOffset.UTC));
        ReceiverStateStore store = storeAt(NOW);

        ReceiverGateDecision decision = evaluator.evaluate(store.update(
                snapshot(true, 10000, 10000, 0, 0, 0, 0, false)));
        assertTrue(decision.allowed());
    }

    @Test
    void rejectsEachMalformedSnapshotField() {
        ReceiverGateEvaluator evaluator = evaluatorAt(NOW);
        assertInvalid(evaluator, new ReceiverStateStore.ReceivedState(null, NOW, List.of()));
        assertInvalid(evaluator, received(new ReceiverStateSnapshot(null, 10000, 10000, 0, 0, 0, -1, true, true)));
        assertInvalid(evaluator, received(new ReceiverStateSnapshot("   ", 10000, 10000, 0, 0, 0, -1, true, true)));
        assertInvalid(evaluator, received(new ReceiverStateSnapshot("test-receiver", Double.NaN, 10000, 0, 0, 0, -1, true, true)));
        assertInvalid(evaluator, received(new ReceiverStateSnapshot("test-receiver", 10000, Double.POSITIVE_INFINITY, 0, 0, 0, -1, true, true)));
        assertInvalid(evaluator, received(new ReceiverStateSnapshot("test-receiver", 10000, 10000, Double.NaN, 0, 0, -1, true, true)));
        assertInvalid(evaluator, received(new ReceiverStateSnapshot("test-receiver", 0, 10000, 0, 0, 0, -1, true, true)));
        assertInvalid(evaluator, received(new ReceiverStateSnapshot("test-receiver", -1, 10000, 0, 0, 0, -1, true, true)));
        assertInvalid(evaluator, received(new ReceiverStateSnapshot("test-receiver", 10000, -0.01, 0, 0, 0, -1, true, true)));
        assertInvalid(evaluator, received(new ReceiverStateSnapshot("test-receiver", 10000, 10000, 0, -1, 0, -1, true, true)));
        assertInvalid(evaluator, received(new ReceiverStateSnapshot("test-receiver", 10000, 10000, 0, 0, -1, -1, true, true)));
        assertInvalid(evaluator, received(new ReceiverStateSnapshot("test-receiver", 10000, 10000, 0, 0, 0, -2, true, true)));
    }

    @Test
    void rejectsGateSettingsThatAreNotPositive() {
        assertThrows(IllegalArgumentException.class, () -> new ReceiverGateConfig(0, 2, 5, 2, 5, true, 5000));
        assertThrows(IllegalArgumentException.class, () -> new ReceiverGateConfig(Double.NaN, 2, 5, 2, 5, true, 5000));
        assertThrows(IllegalArgumentException.class, () -> new ReceiverGateConfig(3, 0, 5, 2, 5, true, 5000));
        assertThrows(IllegalArgumentException.class, () -> new ReceiverGateConfig(3, Double.NEGATIVE_INFINITY, 5, 2, 5, true, 5000));
        assertThrows(IllegalArgumentException.class, () -> new ReceiverGateConfig(3, 2, 0, 2, 5, true, 5000));
        assertThrows(IllegalArgumentException.class, () -> new ReceiverGateConfig(3, 2, 5, 0, 5, true, 5000));
        assertThrows(IllegalArgumentException.class, () -> new ReceiverGateConfig(3, 2, 5, 2, -1, true, 5000));
        assertThrows(IllegalArgumentException.class, () -> new ReceiverGateConfig(3, 2, 5, 2, 5, true, 0));
    }

    private static ReceiverGateDecision evaluateAged(long ageMillis) {
        ReceiverStateStore store = new ReceiverStateStore(Clock.fixed(NOW.minusMillis(ageMillis), ZoneOffset.UTC));
        return evaluatorAt(NOW).evaluate(store.update(passingSnapshot()));
    }

    private static void assertReason(ReceiverGateEvaluator evaluator, ReceiverStateStore store,
                                     ReceiverStateSnapshot snapshot, String expectedGate, String expectedReason) {
        ReceiverGateDecision result = evaluator.evaluate(store.update(snapshot));
        assertFalse(result.allowed());
        assertEquals(expectedGate, result.gate());
        assertEquals(expectedReason, result.reason());
    }

    private static void assertInvalid(ReceiverGateEvaluator evaluator, ReceiverStateStore.ReceivedState received) {
        ReceiverGateDecision result = evaluator.evaluate(received);
        assertFalse(result.allowed());
        assertEquals("Invalid receiver state", result.gate());
        assertEquals("Snapshot contains invalid account or counter values", result.reason());
    }

    private static ReceiverStateStore.ReceivedState received(ReceiverStateSnapshot snapshot) {
        return new ReceiverStateStore.ReceivedState(snapshot, NOW, List.of());
    }

    private static ReceiverGateEvaluator evaluatorAt(Instant now) {
        return new ReceiverGateEvaluator(CONFIG, Clock.fixed(now, ZoneOffset.UTC));
    }

    private static ReceiverStateStore storeAt(Instant now) {
        return new ReceiverStateStore(Clock.fixed(now, ZoneOffset.UTC));
    }

    private static void assertGate(ReceiverGateEvaluator evaluator, ReceiverStateStore store,
                                   ReceiverStateSnapshot snapshot, String expectedGate) {
        ReceiverGateDecision result = evaluator.evaluate(store.update(snapshot));
        assertFalse(result.allowed());
        assertEquals(expectedGate, result.gate());
    }

    private static ReceiverStateSnapshot passingSnapshot() {
        return snapshot(true, 10000, 10000, 0, 0, 0, -1, true);
    }

    private static ReceiverStateSnapshot snapshot(boolean scheduleOpen, double startBalance, double balance,
                                                  double closedNet, int losses, int spikes,
                                                  long secondsSinceLoss, boolean atBreakEven) {
        return new ReceiverStateSnapshot("test-receiver", startBalance, balance, closedNet,
                losses, spikes, secondsSinceLoss, scheduleOpen, atBreakEven);
    }
}