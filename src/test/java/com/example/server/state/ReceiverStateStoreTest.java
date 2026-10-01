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
    private static final Instant NOW = Instant.parse("2026-10-01T12:00:00Z");

    @Test
    void reportsAllFieldsForFirstSnapshotThenOnlyChangedFields() {
        ReceiverStateStore store = store();
        ReceiverStateSnapshot initial = base();

        assertTrue(store.latest().isEmpty());

        var first = store.update(initial);
        assertEquals(List.of(
                "receiverId", "dayStartBalance", "currentBalance", "dailyClosedNet", "lossesToday",
                "spikesToday", "secondsSinceLastLoss", "scheduleOpen", "allPositionsAtBreakEven"
        ), first.changedFields());
        assertEquals(NOW, first.receivedAt());
        assertEquals(initial, store.latest().orElseThrow().snapshot());

        var unchanged = store.update(initial);
        assertTrue(unchanged.changedFields().isEmpty());

        ReceiverStateSnapshot changed = new ReceiverStateSnapshot(
                "demo-1", 10000, 9900, -100, 1, 0, 15, true, false);
        var update = store.update(changed);
        assertEquals(List.of("currentBalance", "dailyClosedNet", "lossesToday",
                "secondsSinceLastLoss", "allPositionsAtBreakEven"), update.changedFields());
        assertEquals(changed, store.latest().orElseThrow().snapshot());
    }

    @Test
    void reportsReceiverIdDayStartSpikesAndScheduleWhenEachChangesAlone() {
        ReceiverStateStore store = store();
        store.update(base());

        assertEquals(List.of("receiverId"), store.update(new ReceiverStateSnapshot(
                "demo-2", 10000, 10000, 0, 0, 0, -1, true, true)).changedFields());
        assertEquals(List.of("dayStartBalance"), store.update(new ReceiverStateSnapshot(
                "demo-2", 11000, 10000, 0, 0, 0, -1, true, true)).changedFields());
        assertEquals(List.of("spikesToday"), store.update(new ReceiverStateSnapshot(
                "demo-2", 11000, 10000, 0, 0, 1, -1, true, true)).changedFields());
        assertEquals(List.of("scheduleOpen"), store.update(new ReceiverStateSnapshot(
                "demo-2", 11000, 10000, 0, 0, 1, -1, false, true)).changedFields());

        ReceiverStateSnapshot latest = store.latest().orElseThrow().snapshot();
        assertEquals("demo-2", latest.receiverId());
        assertEquals(11000, latest.dayStartBalance());
        assertEquals(1, latest.spikesToday());
        assertEquals(false, latest.scheduleOpen());
    }

    private static ReceiverStateStore store() {
        return new ReceiverStateStore(Clock.fixed(NOW, ZoneOffset.UTC));
    }

    private static ReceiverStateSnapshot base() {
        return new ReceiverStateSnapshot("demo-1", 10000, 10000, 0, 0, 0, -1, true, true);
    }
}