package com.example.server.state;

import com.example.server.config.ReceiverGateConfig;
import com.example.server.domain.GuardModels.ReceiverGateDecision;
import com.example.server.domain.GuardModels.ReceiverStateSnapshot;
import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;

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