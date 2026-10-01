package com.example.server;

import com.example.server.GuardModels.CheckResult;
import com.example.server.GuardModels.LichessStats;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/** Applies the configured rating, activity, and win-rate requirements. */
public class EligibilityPolicy {
    private final AppConfig config;

    public EligibilityPolicy(AppConfig config) {
        this.config = config;
    }

    public CheckResult evaluate(LichessStats stats) {
        double winRate = stats.games() > 0 ? stats.wins() / (double) stats.games() : 0.0;
        List<String> failures = new ArrayList<>();
        if (stats.rating() < config.minimumRating()) {
            failures.add("rating=" + stats.rating() + "<" + config.minimumRating());
        }
        if (stats.games() < config.minimumGames()) {
            failures.add("games=" + stats.games() + "<" + config.minimumGames());
        }
        if (winRate < config.minimumWinRate()) {
            failures.add("win_rate=" + String.format(Locale.US, "%.1f%%", winRate * 100)
                    + "<" + String.format(Locale.US, "%.1f%%", config.minimumWinRate() * 100));
        }

        boolean passed = failures.isEmpty();
        String reason = passed ? "" : "LICHESS: " + String.join(", ", failures);
        return new CheckResult(stats.username(), passed, reason, stats.rating(), stats.games(), winRate, failures,
                config.minimumRating(), config.minimumGames(), config.minimumWinRate());
    }

    public CheckResult error(String message, boolean failOpen) {
        String reason = "LICHESS: " + message + (failOpen ? "; fail-open" : "");
        return new CheckResult("", failOpen, reason, 0, 0, 0.0, List.of(reason),
                config.minimumRating(), config.minimumGames(), config.minimumWinRate());
    }

    public CheckResult disabled() {
        return new CheckResult("", true, "", 0, 0, 0.0, List.of(),
                config.minimumRating(), config.minimumGames(), config.minimumWinRate());
    }
}