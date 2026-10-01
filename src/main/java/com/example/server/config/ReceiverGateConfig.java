package com.example.server.config;

/** Server-owned thresholds for the receiver-reported trading gates. */
public record ReceiverGateConfig(
        double dailyLossCapPercent,
        double dailyProfitTargetPercent,
        int maximumLossesPerDay,
        int maximumSpikesPerDay,
        int cooldownAfterLossMinutes,
        boolean requireAllPositionsAtBreakEven,
        long maximumSnapshotAgeMillis
) {
    public ReceiverGateConfig {
        if (!Double.isFinite(dailyLossCapPercent) || dailyLossCapPercent <= 0
                || !Double.isFinite(dailyProfitTargetPercent) || dailyProfitTargetPercent <= 0
                || maximumLossesPerDay <= 0 || maximumSpikesPerDay <= 0
                || cooldownAfterLossMinutes < 0 || maximumSnapshotAgeMillis <= 0) {
            throw new IllegalArgumentException("Receiver gate settings must be positive and finite (cooldown may be zero)");
        }
    }

    public static ReceiverGateConfig load() {
        return new ReceiverGateConfig(
                getDouble("RECEIVER_DAILY_LOSS_CAP_PCT", 3.0),
                getDouble("RECEIVER_DAILY_PROFIT_TARGET_PCT", 2.0),
                getInt("RECEIVER_MAX_LOSSES_PER_DAY", 5),
                getInt("RECEIVER_MAX_SPIKES_PER_DAY", 2),
                getInt("RECEIVER_COOLDOWN_AFTER_LOSS_MIN", 5),
                getBoolean("RECEIVER_REQUIRE_ALL_AT_BE", true),
                getLong("RECEIVER_STATE_MAX_AGE_MS", 5000)
        );
    }

    private static String value(String key, String defaultValue) {
        String envValue = System.getenv(key);
        if (envValue != null && !envValue.isBlank()) return envValue.trim();
        return AppConfig.dotEnvValue(key).orElse(defaultValue).trim();
    }

    private static double getDouble(String key, double fallback) {
        try {
            return Double.parseDouble(value(key, String.valueOf(fallback)));
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    private static int getInt(String key, int fallback) {
        try {
            return Integer.parseInt(value(key, String.valueOf(fallback)));
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    private static long getLong(String key, long fallback) {
        try {
            return Long.parseLong(value(key, String.valueOf(fallback)));
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    private static boolean getBoolean(String key, boolean fallback) {
        return switch (value(key, String.valueOf(fallback)).toLowerCase()) {
            case "1", "true", "yes" -> true;
            case "0", "false", "no" -> false;
            default -> fallback;
        };
    }
}