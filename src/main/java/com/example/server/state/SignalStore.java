package com.example.server.state;

import com.example.server.domain.GuardModels.TradingSignal;

import java.time.Clock;

/** Thread-safe in-memory storage for the single pending signal. */
public class SignalStore {
    private static final long SIGNAL_TTL_SECONDS = 300;

    private final Clock clock;
    private TradingSignal pendingSignal;

    public SignalStore() {
        this(Clock.systemUTC());
    }

    SignalStore(Clock clock) {
        this.clock = clock;
    }

    public synchronized TradingSignal save(String side, String symbol, double lots, long timestamp) {
        long nowMillis = clock.millis();
        long signalTimestamp = timestamp > 0 ? timestamp : nowMillis / 1000L;
        double createdTime = nowMillis / 1000.0;
        pendingSignal = new TradingSignal(side, symbol, lots, signalTimestamp, createdTime, createdTime + SIGNAL_TTL_SECONDS);
        return pendingSignal;
    }

    public synchronized TradingSignal getNext() {
        if (pendingSignal != null && pendingSignal.expiresAt() < clock.millis() / 1000.0) {
            pendingSignal = null;
        }
        return pendingSignal;
    }

    public synchronized void clear() {
        pendingSignal = null;
    }
}