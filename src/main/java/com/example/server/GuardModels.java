package com.example.server;

import java.util.List;

/** Immutable domain values shared between application components. */
public final class GuardModels {
    private GuardModels() {}

    public record LichessStats(String username, int rating, int games, int wins) {}

    public record CheckResult(
            String username,
            boolean passed,
            String reason,
            int rating,
            int games,
            double winRate,
            List<String> failedConditions,
            int minimumRating,
            int minimumGames,
            double minimumWinRate
    ) {
        public CheckResult {
            failedConditions = List.copyOf(failedConditions);
        }
    }

    public record SignalRequest(String side, String symbol, double lots, long timestamp) {}

    public record TradingSignal(String side, String symbol, double lots, long timestamp, double createdTime, double expiresAt) {}

    public record SignalSubmission(boolean accepted, String reason, CheckResult checkResult, TradingSignal signal) {}

    public record CacheStatus(boolean hasCachedPass, int size, int windowMinutes, Double minutesUntilExpiry) {}

    public record HealthStatus(boolean lichessEnforced, Boolean ready, int cacheSize) {}
}