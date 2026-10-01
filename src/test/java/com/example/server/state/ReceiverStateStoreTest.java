package com.example.server.state;

import com.example.server.domain.GuardModels.ReceiverStateSnapshot;
import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ReceiverStateStoreTest {
    @Test
    void reportsAllFieldsForFirstSnapshotThenOnlyChangedFields() {
        ReceiverStateStore store = new ReceiverStateStore(Clock.fixed(
                Instant.parse("2026-10-01T12:00:00Z"), ZoneOffset.UTC));
        ReceiverStateSnapshot initial = new ReceiverStateSnapshot(
                "demo-1", 10000, 10000, 0, 0, 0, -1, true, true);

        var first = store.update(initial);
        assertEquals(9, first.changedFields().size());
        assertTrue(first.changedFields().contains("currentBalance"));

        var unchanged = store.update(initial);
        assertTrue(unchanged.changedFields().isEmpty());

        ReceiverStateSnapshot changed = new ReceiverStateSnapshot(
                "demo-1", 10000, 9900, -100, 1, 0, 15, true, false);
        var update = store.update(changed);
        assertEquals(List.of("currentBalance", "dailyClosedNet", "lossesToday",
                "secondsSinceLastLoss", "allPositionsAtBreakEven"), update.changedFields());
    }
}