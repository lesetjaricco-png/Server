package com.example.server.application;

import com.example.server.config.AppConfig;
import com.example.server.config.ReceiverGateConfig;
import com.example.server.domain.EligibilityPolicy;
import com.example.server.domain.GuardModels.CheckResult;
import com.example.server.domain.GuardModels.LichessStats;
import com.example.server.domain.GuardModels.ReceiverStateSnapshot;
import com.example.server.domain.GuardModels.SignalRequest;
import com.example.server.domain.GuardModels.SignalSubmission;
import com.example.server.domain.LichessGateway;
import com.example.server.domain.SignalPolicy;
import com.example.server.state.PassCache;
import com.example.server.state.ReadinessTracker;
import com.example.server.state.ReceiverGateEvaluator;
import com.example.server.state.ReceiverStateStore;
import com.example.server.state.SignalStore;
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
    void rejectsSignalWhenReceiverGateFailsWithoutCallingLichess() {
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
        ReceiverStateSnapshot blockedState = new ReceiverStateSnapshot(
                "demo", 10000, 10000, 0, 5, 0, -1, true, true
        );
        LichessGuardService service = service(config, gateway, blockedState);

        SignalSubmission result = service.submitSignal(new SignalRequest("BUY", "EURUSD", 0.1, 0));

        assertFalse(result.accepted());
        assertTrue(result.reason().contains("Max Losses Per Day"));
        assertEquals(0, calls.get());
    }

    @Test
    void withholdsQueuedSignalWhenReceiverGateClosesBeforeDelivery() {
        AppConfig config = config(false);
        ReceiverStateStore receiverStates = new ReceiverStateStore();
        receiverStates.update(new ReceiverStateSnapshot("demo", 10000, 10000, 0, 0, 0, -1, true, true));
        LichessGuardService service = new LichessGuardService(
                config,
                unusedGateway(),
                new EligibilityPolicy(config),
                new PassCache(),
                new SignalStore(),
                new SignalPolicy(),
                new ReadinessTracker(),
                receiverStates,
                new ReceiverGateEvaluator(new ReceiverGateConfig(3, 2, 5, 2, 5, true, 5000))
        );
        assertTrue(service.submitSignal(new SignalRequest("BUY", "EURUSD", 0.1, 0)).accepted());

        receiverStates.update(new ReceiverStateSnapshot("demo", 10000, 10000, 0, 0, 0, -1, false, true));

        assertEquals(null, service.pollNextSignal().signal());
        assertEquals("Trading Schedule", service.pollNextSignal().receiverGate().gate());
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
        ReceiverStateStore receiverStates = new ReceiverStateStore();
        receiverStates.update(new ReceiverStateSnapshot("test-receiver", 10000, 10000, 0, 0, 0, -1, true, true));
        return service(config, gateway, receiverStates);
    }

    private static LichessGuardService service(AppConfig config, LichessGateway gateway, ReceiverStateSnapshot snapshot) {
        ReceiverStateStore receiverStates = new ReceiverStateStore();
        receiverStates.update(snapshot);
        return service(config, gateway, receiverStates);
    }

    private static LichessGuardService service(AppConfig config, LichessGateway gateway, ReceiverStateStore receiverStates) {
        ReceiverGateConfig gateConfig = new ReceiverGateConfig(3, 2, 5, 2, 5, true, 5000);
        return new LichessGuardService(
                config,
                gateway,
                new EligibilityPolicy(config),
                new PassCache(),
                new SignalStore(),
                new SignalPolicy(),
                new ReadinessTracker(),
                receiverStates,
                new ReceiverGateEvaluator(gateConfig)
        );
    }

    private static LichessGateway unusedGateway() {
        return new LichessGateway() {
            @Override
            public String resolveUsername() {
                throw new AssertionError("Lichess should be disabled for this test");
            }

            @Override
            public LichessStats fetchRecentStats(String username, int lookbackMinutes, int maximumGames) {
                throw new AssertionError("Lichess should be disabled for this test");
            }
        };
    }
}