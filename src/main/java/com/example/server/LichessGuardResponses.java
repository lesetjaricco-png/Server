package com.example.server;

import com.example.server.GuardModels.CacheStatus;
import com.example.server.GuardModels.CheckResult;
import com.example.server.GuardModels.SignalSubmission;
import com.example.server.GuardModels.TradingSignal;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/** Maps application outcomes to the server's JSON response contract. */
final class LichessGuardResponses {
    private LichessGuardResponses() {}

    static Map<String, Object> check(CheckResult check) {
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("ok", check.passed());
        response.put("ready", check.passed());
        response.put("status", check.passed() ? "PASS" : "FAIL");
        response.put("message", check.passed() ? "✅ READY TO TRADE" : "⛔ NOT READY - Failed: " + String.join(", ", check.failedConditions()));
        response.put("rating", check.rating());
        response.put("games", check.games());
        response.put("win_rate", check.winRate());
        response.put("failed_conditions", check.passed() ? Collections.emptyList() : check.failedConditions());
        if (!check.passed()) {
            response.put("reason", check.reason());
        }

        Map<String, String> conditions = new LinkedHashMap<>();
        conditions.put("rating", condition(check.rating(), check.minimumRating()));
        conditions.put("games", condition(check.games(), check.minimumGames()));
        conditions.put("win_rate", String.format(Locale.US, "%.1f%%/%.1f%% %s",
                check.winRate() * 100, check.minimumWinRate() * 100,
                check.winRate() >= check.minimumWinRate() ? "✓" : "✗"));
        response.put("conditions", conditions);
        return response;
    }

    static Map<String, Object> cacheStatus(CacheStatus status) {
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("ok", true);
        response.put("has_cached_pass", status.hasCachedPass());
        response.put("ready", status.hasCachedPass());
        response.put("cache_size", status.size());
        response.put("window_minutes", status.windowMinutes());
        response.put("minutes_until_cache_expires", status.minutesUntilExpiry());
        response.put("message", status.hasCachedPass() ? "✅ Cached PASS - Ready to trade" : "⛔ No cached PASS - Need fresh check");
        return response;
    }

    static Map<String, Object> cacheCleared(int clearedEntries) {
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("ok", true);
        response.put("message", "Cache cleared (" + clearedEntries + " PASS entries removed)");
        response.put("cleared_entries", clearedEntries);
        return response;
    }

    static Map<String, Object> health(boolean lichessEnforced, Boolean ready, int cacheSize) {
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("ok", true);
        response.put("lichess_enforced", lichessEnforced);
        response.put("ready", ready);
        response.put("ready_message", ready == null ? "⚠️ Not checked yet" : (ready ? "✅ Ready to trade" : "⛔ Not ready"));
        response.put("cache_system", "pass_once_per_window");
        response.put("cache_size", cacheSize);
        response.put("current_cache_hit", ready != null);
        return response;
    }

    static Map<String, Object> signalSubmission(SignalSubmission submission) {
        if (submission.accepted()) {
            return Map.of("ok", true);
        }
        CheckResult check = submission.checkResult();
        if (check == null) {
            return error(submission.reason());
        }
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("ok", false);
        response.put("reason", check.reason());
        response.put("rating", check.rating());
        response.put("games", check.games());
        response.put("win_rate", check.winRate());
        return response;
    }

    static Map<String, Object> nextSignal(TradingSignal signal) {
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("ok", true);
        response.put("empty", signal == null);
        if (signal != null) {
            response.put("side", signal.side());
            response.put("symbol", signal.symbol());
            response.put("lots", signal.lots());
            response.put("ts", signal.timestamp());
            response.put("created_time", signal.createdTime());
            response.put("expires_at", signal.expiresAt());
        }
        return response;
    }

    static Map<String, Object> error(String reason) {
        return Map.of("ok", false, "reason", reason);
    }

    private static String condition(int value, int minimum) {
        return value + "/" + minimum + (value >= minimum ? " ✓" : " ✗");
    }
}