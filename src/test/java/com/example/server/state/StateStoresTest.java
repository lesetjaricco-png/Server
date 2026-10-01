package com.example.server.state;

import com.example.server.domain.GuardModels.CheckResult;
import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class StateStoresTest {
    @Test
    void passCacheStoresOnlyPassingResultsForCurrentWindow() {
        Clock clock = Clock.fixed(Instant.ofEpochSecond(1800), ZoneOffset.UTC);
        PassCache cache = new PassCache(clock);
        CheckResult pass = new CheckResult("player", true, "", 1800, 2, 0.5, List.of(), 1700, 1, 0.0);
        CheckResult fail = new CheckResult("other", false, "fail", 1600, 0, 0.0, List.of("rating"), 1700, 1, 0.0);

        cache.put(pass, 30);
        cache.put(fail, 30);

        assertTrue(cache.hasPass("player", 30));
        assertFalse(cache.hasPass("other", 30));
        assertEquals(1, cache.size());
        assertEquals(1, cache.clear());
        assertEquals(0, cache.size());
    }

    @Test
    void signalStoreExpiresPendingSignal() {
        AdjustableClock clock = new AdjustableClock(1000);
        SignalStore store = new SignalStore(clock);
        store.save("BUY", "BTCUSD", 0.1, 999);

        assertEquals("BTCUSD", store.getNext().symbol());
        clock.advanceSeconds(301);
        assertNull(store.getNext());
    }

    @Test
    void signalStoreCanAcknowledgePendingSignal() {
        Clock clock = Clock.fixed(Instant.ofEpochSecond(1000), ZoneOffset.UTC);
        SignalStore store = new SignalStore(clock);
        store.save("BUY", "BTCUSD", 0.1, 999);

        store.clear();
        assertNull(store.getNext());
    }

    private static class AdjustableClock extends Clock {
        private final AtomicLong epochMillis;

        private AdjustableClock(long epochSeconds) {
            epochMillis = new AtomicLong(epochSeconds * 1000L);
        }

        void advanceSeconds(long seconds) {
            epochMillis.addAndGet(seconds * 1000L);
        }

        @Override
        public ZoneId getZone() {
            return ZoneOffset.UTC;
        }

        @Override
        public Clock withZone(ZoneId zone) {
            return this;
        }

        @Override
        public Instant instant() {
            return Instant.ofEpochMilli(epochMillis.get());
        }
    }
}