package com.example.server.integration.lichess;

import com.example.server.config.AppConfig;
import com.example.server.domain.GuardModels.LichessStats;
import com.example.server.domain.LichessGateway;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Map;

/** HTTP adapter for the Lichess account and recent-games APIs. */
public class LichessClient implements LichessGateway {
    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final long USERNAME_CACHE_MILLIS = Duration.ofHours(1).toMillis();

    private final AppConfig config;
    private final HttpClient httpClient;
    private volatile CachedUsername cachedUsername;

    public LichessClient(AppConfig config) {
        this(config, HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(3)).build());
    }

    LichessClient(AppConfig config, HttpClient httpClient) {
        this.config = config;
        this.httpClient = httpClient;
    }

    @Override
    public String resolveUsername() throws IOException, InterruptedException {
        if (config.lichessToken().isBlank()) {
            throw new IllegalStateException("LICHESS: missing token");
        }

        CachedUsername cached = cachedUsername;
        long now = System.currentTimeMillis();
        if (cached != null && now - cached.resolvedAtMillis() < USERNAME_CACHE_MILLIS) {
            return cached.username();
        }

        synchronized (this) {
            cached = cachedUsername;
            now = System.currentTimeMillis();
            if (cached != null && now - cached.resolvedAtMillis() < USERNAME_CACHE_MILLIS) {
                return cached.username();
            }
            JsonNode account = fetchJson("https://lichess.org/api/account", authorizationHeaders());
            String username = account.path("username").asText();
            if (username.isBlank()) {
                throw new IOException("Lichess account response did not include a username");
            }
            cachedUsername = new CachedUsername(username.toLowerCase(java.util.Locale.ROOT), now);
            return cachedUsername.username();
        }
    }

    @Override
    public LichessStats fetchRecentStats(String username, int lookbackMinutes, int maximumGames) throws IOException, InterruptedException {
        JsonNode account = fetchJson("https://lichess.org/api/account", authorizationHeaders());
        int rating = account.path("perfs").path(config.lichessPreference()).path("rating").asInt(0);

        long sinceMillis = (System.currentTimeMillis() / 1000L - lookbackMinutes * 60L) * 1000L;
        Map<String, String> query = new LinkedHashMap<>();
        query.put("since", String.valueOf(sinceMillis));
        query.put("perf", config.lichessPreference());
        query.put("max", String.valueOf(maximumGames));
        query.put("moves", "false");

        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(buildUrl("https://lichess.org/api/games/user/" + username, query)))
                .header("Authorization", "Bearer " + config.lichessToken())
                .header("Accept", "application/x-ndjson")
                .GET()
                .build();
        HttpResponse<InputStream> response = httpClient.send(request, HttpResponse.BodyHandlers.ofInputStream());
        if (response.statusCode() >= 400) {
            throw new IOException("Lichess status " + response.statusCode());
        }

        int games = 0;
        int wins = 0;
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(response.body(), StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                if (line.isBlank()) {
                    continue;
                }
                games++;
                try {
                    JsonNode game = MAPPER.readTree(line);
                    JsonNode players = game.path("players");
                    String winner = game.path("winner").asText();
                    String whiteUser = players.path("white").path("user").path("name").asText();
                    String blackUser = players.path("black").path("user").path("name").asText();
                    String userColor = username.equalsIgnoreCase(whiteUser) ? "white"
                            : username.equalsIgnoreCase(blackUser) ? "black" : "";
                    if (!userColor.isEmpty() && userColor.equalsIgnoreCase(winner)) {
                        wins++;
                    }
                } catch (IOException ignored) {
                    // Skip malformed NDJSON records, as the API stream may contain partial rows.
                }
            }
        }
        return new LichessStats(username, rating, games, wins);
    }

    private Map<String, String> authorizationHeaders() {
        return Map.of("Authorization", "Bearer " + config.lichessToken());
    }

    private JsonNode fetchJson(String url, Map<String, String> headers) throws IOException, InterruptedException {
        HttpRequest.Builder request = HttpRequest.newBuilder().uri(URI.create(url)).GET();
        headers.forEach(request::header);
        HttpResponse<String> response = httpClient.send(request.build(), HttpResponse.BodyHandlers.ofString());
        if (response.statusCode() >= 400) {
            throw new IOException("HTTP " + response.statusCode() + " for " + url);
        }
        return MAPPER.readTree(response.body());
    }

    private String buildUrl(String baseUrl, Map<String, String> params) {
        StringBuilder url = new StringBuilder(baseUrl);
        boolean first = true;
        for (Map.Entry<String, String> param : params.entrySet()) {
            url.append(first ? '?' : '&');
            url.append(URLEncoder.encode(param.getKey(), StandardCharsets.UTF_8));
            url.append('=');
            url.append(URLEncoder.encode(param.getValue(), StandardCharsets.UTF_8));
            first = false;
        }
        return url.toString();
    }

    private record CachedUsername(String username, long resolvedAtMillis) {}
}