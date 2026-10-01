package com.example.server;

import com.example.server.GuardModels.CheckResult;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;

class LichessGuardControllerTest {

    @Test
    void mapsPassingCheckToReadyResponse() {
        CheckResult check = new CheckResult(
            "player",
                true,
                "",
                1800,
                2,
                0.5,
                List.of(),
                1700,
                1,
                0.3
        );

        Map<String, Object> response = LichessGuardResponses.check(check);
        Map<?, ?> conditions = (Map<?, ?>) response.get("conditions");

        assertEquals(true, response.get("ok"));
        assertEquals(true, response.get("ready"));
        assertEquals("PASS", response.get("status"));
        assertEquals(1800, response.get("rating"));
        assertEquals(List.of(), response.get("failed_conditions"));
        assertEquals("1800/1700 ✓", conditions.get("rating"));
        assertEquals("50.0%/30.0% ✓", conditions.get("win_rate"));
    }

    @Test
    void mapsFailedCheckToFailureResponse() {
        CheckResult check = new CheckResult(
            "player",
                false,
                "LICHESS: rating=1600<1700",
                1600,
                2,
                0.5,
                List.of("rating=1600<1700"),
                1700,
                1,
                0.3
        );

        Map<String, Object> response = LichessGuardResponses.check(check);
        Map<?, ?> conditions = (Map<?, ?>) response.get("conditions");

        assertEquals(false, response.get("ok"));
        assertEquals(false, response.get("ready"));
        assertEquals("FAIL", response.get("status"));
        assertEquals("LICHESS: rating=1600<1700", response.get("reason"));
        assertEquals(List.of("rating=1600<1700"), response.get("failed_conditions"));
        assertEquals("1600/1700 ✗", conditions.get("rating"));
        assertEquals("50.0%/30.0% ✓", conditions.get("win_rate"));
    }
}