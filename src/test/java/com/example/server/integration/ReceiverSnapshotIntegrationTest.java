package com.example.server.integration;

import com.example.server.api.ApiAuthenticator;
import com.example.server.api.LichessGuardController;
import com.example.server.application.LichessGuardService;
import com.example.server.config.AppConfig;
import com.example.server.config.ReceiverGateConfig;
import com.example.server.domain.EligibilityPolicy;
import com.example.server.domain.LichessGateway;
import com.example.server.domain.GuardModels.LichessStats;
import com.example.server.domain.SignalPolicy;
import com.example.server.state.PassCache;
import com.example.server.state.ReadinessTracker;
import com.example.server.state.ReceiverGateEvaluator;
import com.example.server.state.ReceiverStateStore;
import com.example.server.state.SignalStore;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.javalin.Javalin;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.Locale;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Posts the receiver's JSON through the real HTTP routes and checks the stored gate. */
class ReceiverSnapshotIntegrationTest {
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final String TOKEN = "secret";

    private Javalin app;
    private HttpClient client;

    @BeforeEach
    void startServer() {
        AppConfig config = new AppConfig("127.0.0.1", 0, TOKEN, false, "", "blitz", 1700, 1, 0.0, 30, 200, false);
        LichessGuardService service = new LichessGuardService(
                config,
                unusedLichess(),
                new EligibilityPolicy(config),
                new PassCache(),
                new SignalStore(),
                new SignalPolicy(),
                new ReadinessTracker(),
                new ReceiverStateStore(),
                new ReceiverGateEvaluator(new ReceiverGateConfig(3, 2, 5, 2, 5, true, 5000))
        );
        app = Javalin.create(javalin -> javalin.showJavalinBanner = false);
        new LichessGuardController(service, new ApiAuthenticator(config)).register(app);
        app.start(0);
        client = HttpClient.newHttpClient();
    }

    @AfterEach
    void stopServer() {
        if (app != null) {
            app.stop();
        }
    }

    @Test
    void rejectsASignalUntilTheReceiverPostsASnapshot() throws Exception {
        JsonNode rejected = post("/signal", "{\"side\":\"BUY\",\"symbol\":\"US30\",\"lots\":0.10}", TOKEN);

        assertFalse(rejected.get("ok").asBoolean());
        assertEquals("Receiver state unavailable: No MT5 state snapshot received", rejected.get("reason").asText());
    }

    @Test
    void acceptsTheReceiverJsonAndRefreshesChangedFields() throws Exception {
        String snapshot = receiverJson("20258008", "10000.00", "10000.00", "0.00", 0, 0, -1, true, true);

        JsonNode first = post("/receiver-state", snapshot, TOKEN);
        assertTrue(first.get("ok").asBoolean());
        assertTrue(first.get("gate_ok").asBoolean());
        assertTrue(first.get("changed").asBoolean());
        assertEquals(
                "receiverId,dayStartBalance,currentBalance,dailyClosedNet,lossesToday,spikesToday,secondsSinceLastLoss,scheduleOpen,allPositionsAtBreakEven",
                first.get("changed_summary").asText());
        assertEquals(9, first.get("changed_fields").size());

        JsonNode second = post("/receiver-state", snapshot, TOKEN);
        assertTrue(second.get("gate_ok").asBoolean());
        assertFalse(second.get("changed").asBoolean());
        assertEquals("", second.get("changed_summary").asText());
        assertEquals(0, second.get("changed_fields").size());

        JsonNode spikesAndSchedule = post("/receiver-state",
                receiverJson("20258008", "10000.00", "10000.00", "0.00", 0, 1, -1, false, true), TOKEN);
        assertEquals("spikesToday,scheduleOpen", spikesAndSchedule.get("changed_summary").asText());
        assertFalse(spikesAndSchedule.get("gate_ok").asBoolean());
        assertEquals("Trading Schedule", spikesAndSchedule.get("gate").asText());
    }

    @Test
    void storesAParsedSnapshotThatFailsAGateAndBlocksTheSignal() throws Exception {
        JsonNode closed = post("/receiver-state",
                receiverJson("20258008", "10000.00", "10000.00", "0.00", 5, 0, -1, true, true), TOKEN);

        assertTrue(closed.get("ok").asBoolean());
        assertFalse(closed.get("gate_ok").asBoolean());
        assertEquals("Max Losses Per Day", closed.get("gate").asText());
        assertEquals("5/5", closed.get("reason").asText());

        JsonNode signal = post("/signal", "{\"side\":\"SELL\",\"symbol\":\"US30\",\"lots\":0.10}", TOKEN);
        assertFalse(signal.get("ok").asBoolean());
        assertEquals("Max Losses Per Day: 5/5", signal.get("reason").asText());
    }

    @Test
    void keepsAQueuedSignalUntilTheGateOpensAgain() throws Exception {
        String open = receiverJson("20258008", "10000.00", "9800.00", "-125.50", 4, 1, -1, true, true);
        post("/receiver-state", open, TOKEN);
        JsonNode accepted = post("/signal", "{\"side\":\"BUY\",\"symbol\":\"US30\",\"lots\":0.10}", TOKEN);
        assertTrue(accepted.get("ok").asBoolean());

        post("/receiver-state", receiverJson("20258008", "10000.00", "9800.00", "-125.50", 4, 1, -1, false, true), TOKEN);
        JsonNode blocked = get("/next", TOKEN);
        assertTrue(blocked.get("ok").asBoolean());
        assertTrue(blocked.get("empty").asBoolean());
        assertTrue(blocked.get("gate_blocked").asBoolean());
        assertEquals("Trading Schedule", blocked.get("gate").asText());

        post("/receiver-state", open, TOKEN);
        JsonNode delivered = get("/next", TOKEN);
        assertFalse(delivered.get("empty").asBoolean());
        assertEquals("BUY", delivered.get("side").asText());
        assertEquals("US30", delivered.get("symbol").asText());
        assertEquals(0.10, delivered.get("lots").asDouble());
        assertFalse(delivered.has("gate_blocked"));

        JsonNode acked = get("/ack", TOKEN);
        assertTrue(acked.get("ok").asBoolean());
        assertTrue(get("/next", TOKEN).get("empty").asBoolean());
    }

    @Test
    void leavesThePreviousSnapshotInPlaceWhenTheBodyCannotBeRead() throws Exception {
        post("/receiver-state", receiverJson("20258008", "10000.00", "10000.00", "0.00", 0, 0, -1, true, true), TOKEN);
        post("/signal", "{\"side\":\"BUY\",\"symbol\":\"EURUSD\",\"lots\":0.01}", TOKEN);

        HttpResponse<String> broken = send("POST", "/receiver-state", "{\"receiverId\":", TOKEN);
        assertEquals(400, broken.statusCode());
        JsonNode error = JSON.readTree(broken.body());
        assertFalse(error.get("ok").asBoolean());
        assertEquals("invalid receiver state", error.get("reason").asText());

        JsonNode stillQueued = get("/next", TOKEN);
        assertFalse(stillQueued.get("empty").asBoolean());
        assertEquals("BUY", stillQueued.get("side").asText());
        assertFalse(stillQueued.has("gate_blocked"));
    }

    @Test
    void ignoresAnUnauthenticatedSnapshotAndKeepsTheOpenGate() throws Exception {
        post("/receiver-state", receiverJson("20258008", "10000.00", "10000.00", "0.00", 0, 0, -1, true, true), TOKEN);

        HttpResponse<String> denied = send("POST", "/receiver-state",
                receiverJson("20258008", "10000.00", "10000.00", "0.00", 0, 0, -1, false, true), "wrong-token");
        assertEquals(403, denied.statusCode());
        assertEquals("AUTH", JSON.readTree(denied.body()).get("reason").asText());

        JsonNode accepted = post("/signal", "{\"side\":\"BUY\",\"symbol\":\"EURUSD\",\"lots\":0.01}", TOKEN);
        assertTrue(accepted.get("ok").asBoolean());
    }

    private static String receiverJson(String receiverId, String dayStart, String balance, String closedNet,
                                       int losses, int spikes, long secondsSinceLastLoss,
                                       boolean scheduleOpen, boolean atBreakEven) {
        return String.format(Locale.US,
                "{\"receiverId\":\"%s\",\"dayStartBalance\":%s,\"currentBalance\":%s,\"dailyClosedNet\":%s,\"lossesToday\":%d,\"spikesToday\":%d,\"secondsSinceLastLoss\":%d,\"scheduleOpen\":%s,\"allPositionsAtBreakEven\":%s}",
                receiverId, dayStart, balance, closedNet, losses, spikes, secondsSinceLastLoss,
                scheduleOpen, atBreakEven);
    }

    private JsonNode post(String path, String body, String token) throws Exception {
        HttpResponse<String> response = send("POST", path, body, token);
        assertEquals(200, response.statusCode(), response.body());
        return JSON.readTree(response.body());
    }

    private JsonNode get(String path, String token) throws Exception {
        HttpResponse<String> response = send("GET", path, null, token);
        assertEquals(200, response.statusCode(), response.body());
        return JSON.readTree(response.body());
    }

    private HttpResponse<String> send(String method, String path, String body, String token) throws Exception {
        HttpRequest.Builder request = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + app.port() + path))
                .header("X-Auth-Token", token);
        if ("POST".equals(method)) {
            request.header("Content-Type", "application/json")
                    .POST(HttpRequest.BodyPublishers.ofString(body));
        } else {
            request.GET();
        }
        return client.send(request.build(), HttpResponse.BodyHandlers.ofString());
    }

    private static LichessGateway unusedLichess() {
        return new LichessGateway() {
            @Override
            public String resolveUsername() {
                throw new AssertionError("Lichess is disabled for snapshot integration tests");
            }

            @Override
            public LichessStats fetchRecentStats(String username, int lookbackMinutes, int maximumGames) {
                throw new AssertionError("Lichess is disabled for snapshot integration tests");
            }
        };
    }
}
