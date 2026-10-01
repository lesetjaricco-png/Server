package com.example.server;

import com.example.server.GuardModels.CacheStatus;
import com.example.server.GuardModels.CheckResult;
import com.example.server.GuardModels.HealthStatus;
import com.example.server.GuardModels.LichessStats;
import com.example.server.GuardModels.SignalRequest;
import com.example.server.GuardModels.SignalSubmission;
import com.example.server.GuardModels.TradingSignal;

/** Coordinates application use cases across policy, Lichess, cache, and signal storage. */
public class LichessGuardService {
    private final AppConfig config;
    private final LichessGateway lichess;
    private final EligibilityPolicy eligibility;
    private final PassCache passCache;
    private final SignalStore signals;
    private final SignalPolicy signalPolicy;
    private final ReadinessTracker readiness;

    public LichessGuardService(
            AppConfig config,
            LichessGateway lichess,
            EligibilityPolicy eligibility,
            PassCache passCache,
            SignalStore signals,
            SignalPolicy signalPolicy,
            ReadinessTracker readiness
    ) {
        this.config = config;
        this.lichess = lichess;
        this.eligibility = eligibility;
        this.passCache = passCache;
        this.signals = signals;
        this.signalPolicy = signalPolicy;
        this.readiness = readiness;
    }

    public CheckResult warmup() {
        CheckResult result = checkNow();
        if (result.passed()) {
            passCache.put(result, config.lookbackMinutes());
        }
        return result;
    }

    public CheckResult checkCached() {
        if (!config.enforceLichess()) {
            return eligibility.disabled();
        }
        if (config.lichessToken().isBlank()) {
            return record(eligibility.error("missing token", false));
        }
        try {
            String username = lichess.resolveUsername();
            CheckResult cached = passCache.get(username, config.lookbackMinutes());
            if (cached != null) {
                readiness.record(cached);
                return cached;
            }
            return checkAndCache(username);
        } catch (Exception e) {
            return record(eligibility.error("error " + e.getMessage(), config.failOpenOnLichessError()));
        }
    }

    public CheckResult checkNow() {
        if (!config.enforceLichess()) {
            return eligibility.disabled();
        }
        if (config.lichessToken().isBlank()) {
            return record(eligibility.error("missing token", false));
        }
        try {
            return checkAndCache(lichess.resolveUsername(), false);
        } catch (Exception e) {
            return record(eligibility.error("error " + e.getMessage(), config.failOpenOnLichessError()));
        }
    }

    private CheckResult checkAndCache(String username) {
        return checkAndCache(username, true);
    }

    private CheckResult checkAndCache(String username, boolean cachePass) {
        try {
            LichessStats stats = lichess.fetchRecentStats(username, config.lookbackMinutes(), config.maximumGamesToParse());
            CheckResult result = record(eligibility.evaluate(stats));
            if (cachePass && result.passed()) {
                passCache.put(result, config.lookbackMinutes());
            }
            return result;
        } catch (Exception e) {
            return record(eligibility.error("error " + e.getMessage(), config.failOpenOnLichessError()));
        }
    }

    public int clearCache() {
        return passCache.clear();
    }

    public CacheStatus cacheStatus() {
        String username = "";
        if (config.enforceLichess() && !config.lichessToken().isBlank()) {
            try {
                username = lichess.resolveUsername();
            } catch (Exception ignored) {
                username = "";
            }
        }
        return new CacheStatus(
                passCache.hasPass(username, config.lookbackMinutes()),
                passCache.size(),
                config.lookbackMinutes(),
                username.isBlank() ? null : passCache.minutesUntilExpiry(config.lookbackMinutes())
        );
    }

    public SignalSubmission submitSignal(SignalRequest request) {
        SignalPolicy.ValidationResult validation = signalPolicy.validate(request);
        if (!validation.valid()) {
            return rejected(validation.reason(), null);
        }

        CheckResult check = checkCached();
        if (!check.passed()) {
            return rejected(check.reason(), check);
        }
        SignalRequest normalized = validation.request();
        TradingSignal signal = signals.save(normalized.side(), normalized.symbol(), normalized.lots(), normalized.timestamp());
        return new SignalSubmission(true, "", check, signal);
    }

    public TradingSignal nextSignal() {
        return signals.getNext();
    }

    public void acknowledgeSignal() {
        signals.clear();
    }

    public boolean isLichessEnforced() {
        return config.enforceLichess();
    }

    public int cacheSize() {
        return passCache.size();
    }

    public HealthStatus healthStatus() {
        return new HealthStatus(config.enforceLichess(), readiness.current(), passCache.size());
    }

    private CheckResult record(CheckResult result) {
        readiness.record(result);
        return result;
    }

    private SignalSubmission rejected(String reason, CheckResult check) {
        return new SignalSubmission(false, reason, check, null);
    }
}