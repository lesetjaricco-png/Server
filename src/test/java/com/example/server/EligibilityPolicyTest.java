package com.example.server;

import com.example.server.GuardModels.CheckResult;
import com.example.server.GuardModels.LichessStats;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class EligibilityPolicyTest {
    private final AppConfig config = new AppConfig(
            "127.0.0.1", 5001, "", true, "token", "blitz", 1700, 2, 0.5, 30, 200, false
    );

    @Test
    void passesWhenAllConfiguredThresholdsAreMet() {
        CheckResult result = new EligibilityPolicy(config).evaluate(new LichessStats("player", 1800, 4, 2));

        assertTrue(result.passed());
        assertEquals(0.5, result.winRate());
        assertTrue(result.failedConditions().isEmpty());
    }

    @Test
    void reportsEveryThresholdThatWasNotMet() {
        CheckResult result = new EligibilityPolicy(config).evaluate(new LichessStats("player", 1600, 1, 0));

        assertFalse(result.passed());
        assertEquals(3, result.failedConditions().size());
        assertEquals("LICHESS: rating=1600<1700, games=1<2, win_rate=0.0%<50.0%", result.reason());
    }
}