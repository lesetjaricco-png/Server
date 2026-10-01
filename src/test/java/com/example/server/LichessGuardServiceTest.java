package com.example.server;

import com.example.server.GuardModels.CheckResult;
import com.example.server.GuardModels.LichessStats;
import com.example.server.GuardModels.SignalRequest;
import com.example.server.GuardModels.SignalSubmission;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class LichessGuardServiceTest {

    @Test
    void rejectsInvalidSignalBeforeCallingLichess() {
        AtomicInteger calls = new AtomicInteger();
        AppConfig config = config(true);
        LichessGateway gateway = new LichessGateway() {
            @Override
            public String resolveUsername() {
                calls.incrementAndGet();
                return "player";
            }

            @Override
            public LichessStats fetchRecentStats(String username, int lookbackMinutes, int maximumGames) {
                calls.incrementAndGet();
                return new LichessStats(username, 1800, 2, 1);
            }
        };
        LichessGuardService service = service(config, gateway);

        SignalSubmission result = service.submitSignal(new SignalRequest("HOLD", "BTCUSD", 0.1, 0));

        assertFalse(result.accepted());
        assertEquals("invalid side", result.reason());
        assertEquals(0, calls.get());
    }

    @Test
    void cachesPassingLichessCheckForSubsequentSignal() {
        AtomicInteger statsCalls = new AtomicInteger();
        AppConfig config = config(true);
        LichessGateway gateway = new LichessGateway() {
            @Override
            public String resolveUsername() {
                return "player";
            }

            @Override
            public LichessStats fetchRecentStats(String username, int lookbackMinutes, int maximumGames) {
                statsCalls.incrementAndGet();
                return new LichessStats(username, 1800, 2, 1);
            }
        };
        LichessGuardService service = service(config, gateway);

        SignalSubmission first = service.submitSignal(new SignalRequest("buy", " BTCUSD ", 0.1, 0));
        SignalSubmission second = service.submitSignal(new SignalRequest("SELL", "ETHUSD", 0.2, 0));

        assertTrue(first.accepted());
        assertTrue(second.accepted());
        assertEquals(1, statsCalls.get());
        assertEquals("SELL", service.nextSignal().side());
        assertEquals("ETHUSD", service.nextSignal().symbol());
    }

    @Test
    void checkResultCopiesAndProtectsFailedConditions() {
        List<String> failures = new ArrayList<>(List.of("rating=1600<1700"));
        CheckResult result = new CheckResult(
            "player",
                false,
                "rating below minimum",
                1600,
                2,
                0.5,
                failures,
                1700,
                1,
                0.3
        );

        failures.add("games=0<1");

        assertEquals(List.of("rating=1600<1700"), result.failedConditions());
        assertThrows(UnsupportedOperationException.class, () -> result.failedConditions().add("another failure"));
    }

    private static AppConfig config(boolean enforceLichess) {
        return new AppConfig("127.0.0.1", 5001, "secret", enforceLichess, "token", "blitz", 1700, 1, 0.0, 30, 200, false);
    }

    private static LichessGuardService service(AppConfig config, LichessGateway gateway) {
        return new LichessGuardService(
                config,
                gateway,
                new EligibilityPolicy(config),
                new PassCache(),
                new SignalStore(),
                new SignalPolicy(),
                new ReadinessTracker()
        );
    }
}