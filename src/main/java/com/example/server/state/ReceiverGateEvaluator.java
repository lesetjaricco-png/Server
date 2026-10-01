package com.example.server.state;

import com.example.server.config.ReceiverGateConfig;
import com.example.server.domain.GuardModels.ReceiverGateDecision;
import com.example.server.domain.GuardModels.ReceiverStateSnapshot;

import java.time.Clock;

/** Evaluates receiver-reported facts against limits owned by the server. */
public class ReceiverGateEvaluator {
    private static final double MONEY_TOLERANCE = 1e-6;

    private final ReceiverGateConfig config;
    private final Clock clock;

    public ReceiverGateEvaluator(ReceiverGateConfig config) {
        this(config, Clock.systemUTC());
    }

    ReceiverGateEvaluator(ReceiverGateConfig config, Clock clock) {
        this.config = config;
        this.clock = clock;
    }

    public ReceiverGateDecision evaluate(ReceiverStateStore.ReceivedState received) {
        if (received == null) {
            return blocked("Receiver state unavailable", "No MT5 state snapshot received", Long.MAX_VALUE);
        }

        long ageMillis = Math.max(0, clock.millis() - received.receivedAt().toEpochMilli());
        if (ageMillis > config.maximumSnapshotAgeMillis()) {
            return blocked("Receiver state stale", "MT5 state snapshot is " + ageMillis + " ms old", ageMillis);
        }

        ReceiverStateSnapshot state = received.snapshot();
        if (state == null || state.receiverId() == null || state.receiverId().isBlank()
            || !finite(state.dayStartBalance()) || !finite(state.currentBalance()) || !finite(state.dailyClosedNet())
                || state.dayStartBalance() <= 0 || state.currentBalance() < 0
            || state.lossesToday() < 0 || state.spikesToday() < 0 || state.secondsSinceLastLoss() < -1) {
            return blocked("Invalid receiver state", "Snapshot contains invalid account or counter values", ageMillis);
        }
        if (!state.scheduleOpen()) {
            return blocked("Trading Schedule", "MT5 reports that the configured schedule is closed", ageMillis);
        }

        double lossLimit = state.dayStartBalance() * config.dailyLossCapPercent() / 100.0;
        double dailyDrop = state.dayStartBalance() - state.currentBalance();
        if (dailyDrop >= lossLimit - MONEY_TOLERANCE) {
            return blocked("Daily Loss Cap", String.format("Drop: %.2f | Cap: %.2f", dailyDrop, lossLimit), ageMillis);
        }

        double profitTarget = state.dayStartBalance() * config.dailyProfitTargetPercent() / 100.0;
        if (state.dailyClosedNet() >= profitTarget - MONEY_TOLERANCE) {
            return blocked("Daily Profit Target", String.format("PnL: %.2f | Target: %.2f", state.dailyClosedNet(), profitTarget), ageMillis);
        }
        if (state.lossesToday() >= config.maximumLossesPerDay()) {
            return blocked("Max Losses Per Day", state.lossesToday() + "/" + config.maximumLossesPerDay(), ageMillis);
        }
        if (state.spikesToday() >= config.maximumSpikesPerDay()) {
            return blocked("Max Daily Spikes", state.spikesToday() + "/" + config.maximumSpikesPerDay(), ageMillis);
        }
        if (state.secondsSinceLastLoss() >= 0
                && state.secondsSinceLastLoss() < config.cooldownAfterLossMinutes() * 60L) {
            long secondsRemaining = config.cooldownAfterLossMinutes() * 60L - state.secondsSinceLastLoss();
            return blocked("Cooldown After Loss", secondsRemaining + " seconds remaining", ageMillis);
        }
        if (config.requireAllPositionsAtBreakEven() && !state.allPositionsAtBreakEven()) {
            return blocked("All Positions Not At BE", "MT5 reports an open position below break-even", ageMillis);
        }
        return new ReceiverGateDecision(true, "", "", ageMillis);
    }

    private ReceiverGateDecision blocked(String gate, String reason, long ageMillis) {
        return new ReceiverGateDecision(false, gate, reason, ageMillis);
    }

    private static boolean finite(double value) {
        return Double.isFinite(value);
    }
}