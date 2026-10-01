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

The shaded jar is created at `target/server-java-<version>.jar`. Run it from the project root so the service can find an optional `.env` file:

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

## CI/CD

GitHub Actions runs the Java tests. The MT5 scripts stay local; MetaEditor is not part of this pipeline.

**CI** (`.github/workflows/ci.yml`) runs on every push and pull request. It executes `mvn verify` (all Java tests, then the shaded jar) and uploads that jar. `main` accepts updates only through a pull request whose **Test and package** check has passed. After that pull request is merged, the same workflow publishes `ghcr.io/lesetjaricco-png/server:latest` and `ghcr.io/lesetjaricco-png/server:<commit sha>`. Other branches build the image without publishing it.

**Release** (`.github/workflows/release.yml`) is started from the Actions tab on `main`. Enter a version such as `1.2.0`. The workflow runs the tests, sets that version in `pom.xml`, commits it, pushes the annotated tag `v1.2.0`, publishes a GitHub Release with the jar attached, and pushes the image to GitHub Container Registry. A prerelease skips the `latest` image tag. Running the workflow again for a version that already has a tag rebuilds and republishes that tagged commit.

The image name is the repository name in lowercase:

```text
ghcr.io/lesetjaricco-png/server:1.2.0
ghcr.io/lesetjaricco-png/server:v1.2.0
ghcr.io/lesetjaricco-png/server:latest
```

The container listens on port 8080 and reads the same environment variables as the jar. Do not bake `.env` or tokens into the image. Pass them at runtime:

```powershell
docker run --rm -p 5001:8080 `
  -e AUTH_SHARED="your-shared-secret" `
  -e LICHESS_TOKEN="your-lichess-token" `
  ghcr.io/lesetjaricco-png/server:1.2.0
```

Before the first release, open the repository on GitHub and set **Settings → Actions → General → Workflow permissions** to **Read and write permissions**. The release job uses that permission to push the version commit, the git tag, the GitHub Release, and the container image. The package inherits this repository's visibility; change it later under **Packages** if you want a different audience.

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
| `RECEIVER_DAILY_LOSS_CAP_PCT` | `3.0` | Server-side daily balance drawdown limit as a percentage of the receiver's reported day-start balance. |
| `RECEIVER_DAILY_PROFIT_TARGET_PCT` | `2.0` | Server-side daily closed-profit target as a percentage of day-start balance. |
| `RECEIVER_MAX_LOSSES_PER_DAY` | `5` | Maximum counted losing closing deals reported by MT5. |
| `RECEIVER_MAX_SPIKES_PER_DAY` | `2` | Maximum daily spikes reported by MT5. |
| `RECEIVER_COOLDOWN_AFTER_LOSS_MIN` | `5` | Server-enforced cooldown duration after the latest reported losing close. |
| `RECEIVER_REQUIRE_ALL_AT_BE` | `true` | Require the receiver to report all managed positions at break-even. |
| `RECEIVER_STATE_MAX_AGE_MS` | `5000` | Maximum server receipt age for the MT5 state snapshot. Older/missing snapshots fail closed. |

## HTTP API

All responses are JSON. Routes marked **authenticated** require the configured `X-Auth-Token` header. If `AUTH_SHARED` is blank, authentication is disabled.

| Method and path | Authentication | Purpose |
| --- | --- | --- |
| `GET /health` | No | Returns basic health, last readiness state, and cache information. |
| `POST /warmup` | Yes | Runs a Lichess check immediately and caches a successful result for the current window. |
| `POST /receiver-state` | Yes | Publishes the latest MT5 account, daily-risk, schedule, cooldown, and position facts for server-side gate evaluation. |
| `GET /cache-status` | Yes | Returns cache state and time remaining in the current window. |
| `GET /clear-cache` | Yes | Clears all cached PASS entries. |
| `POST /signal` | Yes | Validates and stores a signal if the Lichess gate passes. |
| `GET /next` | Yes | Reads the pending signal. It does not remove it. |
| `GET /ack` | Yes | Clears the pending signal. |

The receiver posts state to `/receiver-state` about once per second and continues polling `/next`. The snapshot contains `receiverId`, `dayStartBalance`, `currentBalance`, `dailyClosedNet`, `lossesToday`, `spikesToday`, `secondsSinceLastLoss` (`-1` means no loss today), `scheduleOpen`, and `allPositionsAtBreakEven`. The server caches the latest snapshot and returns `changed_fields`/`changed_summary` on each post; the receiver logs only changed parameters, while unchanged posts still refresh the freshness timer. `/signal` is rejected unless a recent receiver snapshot passes the server-configured gates and the Lichess check passes. `/next` re-evaluates the latest receiver state before returning a queued signal; when state is stale or a gate is closed it returns an empty result and does not acknowledge the queued signal. Keep the receiver attached and publishing state before submitting signals.
////////////////////////////////////////////////////////////////////////mmmmmmmmm
The `RECEIVER_*` limits are enforced only by the server. The receiver reports account, schedule, and position facts and sizes orders from its own risk and stop-distance inputs. `SpikeThresholdPct` on the receiver defines which closes increment `spikesToday`. Schedule windows are evaluated in MT5 and reported as `scheduleOpen`. The server timestamps snapshots when received and fails closed after `RECEIVER_STATE_MAX_AGE_MS`.

`POST /signal` expects a JSON body with `side` (`BUY` or `SELL`), `symbol`, and positive `lots`. `ts` is optional and defaults to the current Unix timestamp in seconds.
/////////////////////////////////kokoko
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
- Receiver-state values are reported by the authenticated MT5 client. The server validates their shape and freshness and applies its own thresholds, but cannot independently prove that a client-reported balance or position state is truthful. Use this only with a trusted terminal and protect the shared token and network path.

## Project layout

- `src/main/java/com/example/server/bootstrap` loads configuration, assembles dependencies, and starts/stops Javalin.
- `src/main/java/com/example/server/api` owns Javalin routes, authentication, HTTP statuses, and JSON response mapping.
- `src/main/java/com/example/server/application` coordinates use cases across the domain and state components.
- `src/main/java/com/example/server/config` loads runtime settings from process variables and `.env`.
- `src/main/java/com/example/server/domain` contains immutable models, signal/eligibility policies, and the Lichess gateway interface.
- `src/main/java/com/example/server/integration/lichess` implements external Lichess API calls and response parsing.
- `src/main/java/com/example/server/state` owns caches, signal storage, readiness, receiver snapshots, and gate evaluation.
- `src/test/java/com/example/server` mirrors the production package groupings for focused tests.
- `legacy/python/s.py` is the original Python server implementation.

## Receiver protocol tests

`mql5/Include/ReceiverProtocol.mqh` contains the receiver's pure `/next` response parser, receiver-state JSON serializer, and signal-age rules. `mql5/Include/ReceiverDecisions.mqh` contains pure lot planning, margin fitting, deal accounting, and daily-reset transitions. The production EA is `mql5/Experts/Receiver.mq5`; it reports facts and executes released signals. The EA and `mql5/Scripts/Tests/ReceiverProtocolTests.mq5` include the same pure helpers, so tests exercise production logic without accessing an account, broker data, network, or trade APIs.

Compile `mql5/Scripts/Tests/ReceiverProtocolTests.mq5` with MetaEditor. Copy the resulting `ReceiverProtocolTests.ex5` into the terminal data folder's `MQL5/Scripts/UnitTests` directory, refresh the MT5 Navigator, then run **ReceiverProtocolTests** from Scripts. The test script prints each assertion and a final failure count in the terminal's Experts log. These are native MQL5 tests; they are separate from `mvn test`.

The MT5 source is organized as `mql5/Experts` (Sender and Receiver EAs), `mql5/Include` (shared protocol and decision logic), and `mql5/Scripts/Tests` (native unit-test script). The server remains a Maven project at the repository root, with Java sources under `src/`.