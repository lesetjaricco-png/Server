package com.example.server;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

/** Immutable runtime configuration loaded from process variables and an optional .env file. */
public record AppConfig(
        String host,
        int port,
        String authShared,
        boolean enforceLichess,
        String lichessToken,
        String lichessPreference,
        int minimumRating,
        int minimumGames,
        double minimumWinRate,
        int lookbackMinutes,
        int maximumGamesToParse,
        boolean failOpenOnLichessError
) {
    public static AppConfig load() {
        Map<String, String> fileValues = loadDotEnv();
        return new AppConfig(
                get("HOST", "0.0.0.0", fileValues),
                getInt("PORT", 80, fileValues),
                get("AUTH_SHARED", "", fileValues),
                getBoolean("ENFORCE_LICHESS", true, fileValues),
                get("LICHESS_TOKEN", "", fileValues),
                get("LICHESS_PREF", "blitz", fileValues).toLowerCase(Locale.ROOT),
                getInt("LICHESS_MIN_RATING", 1700, fileValues),
                getInt("LICHESS_MIN_GAMES", 1, fileValues),
                getDouble("LICHESS_MIN_WIN_RATE", 0.0, fileValues),
                getInt("LICHESS_LOOKBACK_MIN", 30, fileValues),
                getInt("LICHESS_MAX_GAMES_TO_PARSE", 200, fileValues),
                getBoolean("FAIL_OPEN_ON_LICHESS_ERROR", false, fileValues)
        );
    }

    private static String get(String key, String defaultValue, Map<String, String> fileValues) {
        String processValue = System.getenv(key);
        if (processValue != null && !processValue.isBlank()) {
            return processValue.trim();
        }
        String fileValue = fileValues.get(key);
        return fileValue == null || fileValue.isBlank() ? defaultValue : fileValue.trim();
    }

    private static int getInt(String key, int defaultValue, Map<String, String> fileValues) {
        try {
            return Integer.parseInt(get(key, "", fileValues));
        } catch (NumberFormatException e) {
            return defaultValue;
        }
    }

    private static double getDouble(String key, double defaultValue, Map<String, String> fileValues) {
        try {
            return Double.parseDouble(get(key, "", fileValues));
        } catch (NumberFormatException e) {
            return defaultValue;
        }
    }

    private static boolean getBoolean(String key, boolean defaultValue, Map<String, String> fileValues) {
        String value = get(key, String.valueOf(defaultValue), fileValues).trim().toLowerCase(Locale.ROOT);
        return switch (value) {
            case "1", "true", "yes" -> true;
            case "0", "false", "no" -> false;
            default -> defaultValue;
        };
    }

    private static Map<String, String> loadDotEnv() {
        Map<String, String> values = new HashMap<>();
        Path envFile = Path.of(System.getProperty("user.dir"), ".env");
        if (!Files.exists(envFile)) {
            return values;
        }

        try {
            for (String line : Files.readAllLines(envFile)) {
                if (line.isBlank() || line.trim().startsWith("#")) {
                    continue;
                }
                int delimiter = line.indexOf('=');
                if (delimiter <= 0) {
                    continue;
                }
                String key = line.substring(0, delimiter).trim();
                String value = line.substring(delimiter + 1).trim();
                if (value.length() >= 2 && value.startsWith("\"") && value.endsWith("\"")) {
                    value = value.substring(1, value.length() - 1);
                }
                values.put(key, value);
            }
        } catch (IOException ignored) {
            return Map.of();
        }
        return values;
    }
}