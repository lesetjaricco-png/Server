# Lichess Guard Server

A small Java HTTP service built with Javalin. It checks a configured Lichess account's rating and recent games, caches successful checks by time window, and accepts short-lived trading signals only when the configured checks pass.

## Requirements

- Java 17 or newer
- Maven 3.9 or newer
- A Lichess API token if Lichess enforcement is enabled

## Build and run

From the project root, build the executable jar:

```powershell
mvn clean package
```

The jar is created at `target/server-java-1.0.0.jar`. Run it from the project root so the service can find an optional `.env` file:

```powershell
java -jar target/server-java-1.0.0.jar
```

Stop the server with `Ctrl+C` in the terminal where it is running. In VS Code, use the Stop button in the Run and Debug toolbar when you launched it with the Java debugger. The application registers a JVM shutdown hook to stop Javalin cleanly when the process receives a normal termination signal.

By default the server listens on `0.0.0.0:80`. To run locally on port 5001 instead, set process environment variables before starting it:

```powershell
$env:HOST = "127.0.0.1"
$env:PORT = "5001"
java -jar target/server-java-1.0.0.jar
```

The same variables can be set in Command Prompt with `set HOST=127.0.0.1` and `set PORT=5001`, or in a Unix-like shell with `export HOST=127.0.0.1` and `export PORT=5001`.

## Configuration

Copy `.env.example` to `.env`, then replace the example values with your own settings. `.env` is ignored by Git. Never commit real Lichess tokens or shared authentication secrets.

Settings are read in this order: process environment, `.env` in the current working directory, then the default shown below. `.env.example` is only a template; copy it to `.env` and edit `.env`. Restart the server after changing settings. A process environment variable overrides the corresponding `.env` value.

| Setting | Default | Description |
| --- | --- | --- |
| `HOST` | `0.0.0.0` | Interface address for the HTTP server. Prefer `127.0.0.1` for local-only use. |
| `PORT` | `80` | HTTP listening port. |
| `AUTH_SHARED` | empty | Shared secret expected in the `X-Auth-Token` header. **An empty value disables route authentication.** |
| `ENFORCE_LICHESS` | `true` | Require a successful Lichess check before accepting a signal. |
| `LICHESS_TOKEN` | empty | Lichess API token used to read account and game data. |
| `LICHESS_PREF` | `blitz` | Lichess performance category to check. |
| `LICHESS_MIN_RATING` | `1700` | Minimum rating required for a pass. |
| `LICHESS_MIN_GAMES` | `1` | Minimum number of games in the lookback period. |
| `LICHESS_MIN_WIN_RATE` | `0.0` | Minimum win rate from `0.0` to `1.0`. |
| `LICHESS_LOOKBACK_MIN` | `30` | Recent-game and cache-window duration in minutes. |
| `LICHESS_MAX_GAMES_TO_PARSE` | `200` | Maximum number of recent games requested from Lichess. |
| `FAIL_OPEN_ON_LICHESS_ERROR` | `0` | When true (`1`, `true`, or `yes`), treat Lichess request errors as a pass. Keep disabled unless fail-open behavior is intentional. |

## HTTP API

All responses are JSON. Routes marked **authenticated** require the configured `X-Auth-Token` header. If `AUTH_SHARED` is blank, authentication is disabled.

| Method and path | Authentication | Purpose |
| --- | --- | --- |
| `GET /health` | No | Returns basic health, last readiness state, and cache information. |
| `POST /warmup` | Yes | Runs a Lichess check immediately and caches a successful result for the current window. |
| `GET /cache-status` | Yes | Returns cache state and time remaining in the current window. |
| `GET /clear-cache` | Yes | Clears all cached PASS entries. |
| `POST /signal` | Yes | Validates and stores a signal if the Lichess gate passes. |
| `GET /next` | Yes | Reads the pending signal. It does not remove it. |
| `GET /ack` | Yes | Clears the pending signal. |

`POST /signal` expects a JSON body with `side` (`BUY` or `SELL`), `symbol`, and positive `lots`. `ts` is optional and defaults to the current Unix timestamp in seconds.

Example PowerShell request:

```powershell
$headers = @{ "X-Auth-Token" = "your-shared-secret" }
$body = @{ side = "BUY"; symbol = "BTCUSD"; lots = 0.01 } | ConvertTo-Json
Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:5001/signal" -Headers $headers -ContentType "application/json" -Body $body
```

Signals expire after five minutes. A successful signal is held as the single pending signal until acknowledged or expired.

## Security notes

- Set a strong, private `AUTH_SHARED` secret. With the current implementation, a blank secret allows protected routes without a token.
- Use `HOST=127.0.0.1` unless remote access is required. Binding to `0.0.0.0` listens on all network interfaces.
- This service uses plain HTTP. Do not expose it directly to the public internet; put it behind an appropriately configured TLS reverse proxy and restrict network access.
- Treat Lichess API tokens and shared secrets as credentials. Do not put real credentials in source control or share terminal logs containing them.

## Project layout

- `src/main/java/com/example/server/LichessGuardApplication.java` loads configuration, assembles dependencies, starts Javalin, and handles process shutdown.
- `src/main/java/com/example/server/LichessGuardController.java` registers HTTP routes, parses request data, and sets HTTP statuses.
- `src/main/java/com/example/server/LichessGuardResponses.java` maps application outcomes to the JSON API contract.
- `src/main/java/com/example/server/LichessGuardService.java` orchestrates application use cases.
- `src/main/java/com/example/server/AppConfig.java` loads runtime configuration from process variables and `.env`.
- `src/main/java/com/example/server/LichessClient.java` calls Lichess and parses account/game data through the `LichessGateway` interface.
- `src/main/java/com/example/server/EligibilityPolicy.java` applies rating, game-count, and win-rate requirements.
- `src/main/java/com/example/server/ApiAuthenticator.java` checks the shared route token.
- `src/main/java/com/example/server/PassCache.java` stores successful Lichess checks by account and time window.
- `src/main/java/com/example/server/SignalPolicy.java` validates and normalizes signal values.
- `src/main/java/com/example/server/SignalStore.java` stores, expires, and acknowledges the pending signal.
- `src/main/java/com/example/server/ReadinessTracker.java` tracks the latest check result for health reporting.
- `src/main/java/com/example/server/GuardModels.java` contains immutable values exchanged between these components.
- `s.py` is the original Python server implementation.