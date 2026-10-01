package com.example.server.application;

import com.example.server.config.AppConfig;
import com.example.server.domain.EligibilityPolicy;
import com.example.server.domain.GuardModels.CacheStatus;
import com.example.server.domain.GuardModels.CheckResult;
import com.example.server.domain.GuardModels.HealthStatus;
import com.example.server.domain.GuardModels.LichessStats;
import com.example.server.domain.GuardModels.ReceiverGateDecision;
import com.example.server.domain.GuardModels.ReceiverStateReceipt;
import com.example.server.domain.GuardModels.ReceiverStateSnapshot;
import com.example.server.domain.GuardModels.SignalPoll;
import com.example.server.domain.GuardModels.SignalRequest;
import com.example.server.domain.GuardModels.SignalSubmission;
import com.example.server.domain.GuardModels.TradingSignal;
import com.example.server.domain.LichessGateway;
import com.example.server.domain.SignalPolicy;
import com.example.server.state.PassCache;
import com.example.server.state.ReadinessTracker;
import com.example.server.state.ReceiverGateEvaluator;
import com.example.server.state.ReceiverStateStore;
import com.example.server.state.SignalStore;

/** Coordinates application use cases across policy, Lichess, cache, and signal storage. */
public class LichessGuardService {
    private final AppConfig config;
    private final LichessGateway lichess;
    private final EligibilityPolicy eligibility;
    private final PassCache passCache;
    private final SignalStore signals;
    private final SignalPolicy signalPolicy;
    private final ReadinessTracker readiness;
    private final ReceiverStateStore receiverStates;
    private final ReceiverGateEvaluator receiverGates;

    public LichessGuardService(
            AppConfig config,
            LichessGateway lichess,
            EligibilityPolicy eligibility,
            PassCache passCache,
            SignalStore signals,
            SignalPolicy signalPolicy,
            ReadinessTracker readiness,
            ReceiverStateStore receiverStates,
            ReceiverGateEvaluator receiverGates
    ) {
        this.config = config;
        this.lichess = lichess;
        this.eligibility = eligibility;
        this.passCache = passCache;
        this.signals = signals;
        this.signalPolicy = signalPolicy;
        this.readiness = readiness;
        this.receiverStates = receiverStates;
        this.receiverGates = receiverGates;
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

        var receiverGate = currentReceiverGate();
        if (!receiverGate.allowed()) {
            return rejected(receiverGate.gate() + ": " + receiverGate.reason(), null);
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

    public SignalPoll pollNextSignal() {
        var gate = currentReceiverGate();
        if (!gate.allowed()) {
            return new SignalPoll(null, gate);
        }
        return new SignalPoll(signals.getNext(), gate);
    }

    public ReceiverStateReceipt updateReceiverState(ReceiverStateSnapshot snapshot) {
        var received = receiverStates.update(snapshot);
        var decision = receiverGates.evaluate(received);
        return new ReceiverStateReceipt(true, decision, received.receivedAt().toEpochMilli(), received.changedFields());
    }

    public ReceiverGateDecision currentReceiverGate() {
        return receiverGates.evaluate(receiverStates.latest().orElse(null));
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