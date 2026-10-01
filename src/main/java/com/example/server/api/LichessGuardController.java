package com.example.server.api;

import com.example.server.application.LichessGuardService;
import com.example.server.domain.GuardModels;
import com.example.server.domain.GuardModels.HealthStatus;
import com.example.server.domain.GuardModels.SignalRequest;
import io.javalin.Javalin;
import io.javalin.http.Context;

import java.util.Map;

/** HTTP adapter for route registration, request parsing, and status codes. */
public class LichessGuardController {
    private final LichessGuardService service;
    private final ApiAuthenticator authenticator;

    public LichessGuardController(LichessGuardService service, ApiAuthenticator authenticator) {
        this.service = service;
        this.authenticator = authenticator;
    }

    public void register(Javalin app) {
        app.post("/warmup", this::warmup);
        app.get("/clear-cache", this::clearCache);
        app.get("/cache-status", this::cacheStatus);
        app.post("/receiver-state", this::receiverState);
        app.post("/signal", this::signal);
        app.get("/next", this::nextSignal);
        app.get("/ack", this::ackSignal);
        app.get("/health", this::health);
    }

    private void warmup(Context ctx) {
        if (authorize(ctx)) {
            ctx.json(LichessGuardResponses.check(service.warmup()));
        }
    }

    private void clearCache(Context ctx) {
        if (authorize(ctx)) {
            ctx.json(LichessGuardResponses.cacheCleared(service.clearCache()));
        }
    }

    private void cacheStatus(Context ctx) {
        if (authorize(ctx)) {
            ctx.json(LichessGuardResponses.cacheStatus(service.cacheStatus()));
        }
    }

    private void receiverState(Context ctx) {
        if (!authorize(ctx)) return;
        try {
            var snapshot = ctx.bodyAsClass(GuardModels.ReceiverStateSnapshot.class);
            var receipt = service.updateReceiverState(snapshot);
            ctx.json(LichessGuardResponses.receiverState(receipt));
        } catch (Exception e) {
            ctx.status(400).json(LichessGuardResponses.error("invalid receiver state"));
        }
    }

    private void signal(Context ctx) {
        if (!authorize(ctx)) {
            return;
        }
        try {
            Map<?, ?> body = ctx.bodyAsClass(Map.class);
            SignalRequest request = new SignalRequest(
                    stringValue(body.get("side")),
                    stringValue(body.get("symbol")),
                    doubleValue(body.get("lots")),
                    longValue(body.get("ts"))
            );
            ctx.json(LichessGuardResponses.signalSubmission(service.submitSignal(request)));
        } catch (RuntimeException e) {
            ctx.status(400).json(LichessGuardResponses.error("invalid signal request"));
        }
    }

    private void nextSignal(Context ctx) {
        if (authorize(ctx)) {
            ctx.json(LichessGuardResponses.nextSignal(service.pollNextSignal()));
        }
    }

    private void ackSignal(Context ctx) {
        if (authorize(ctx)) {
            service.acknowledgeSignal();
            ctx.json(Map.of("ok", true));
        }
    }

    private void health(Context ctx) {
        HealthStatus status = service.healthStatus();
        ctx.json(LichessGuardResponses.health(status.lichessEnforced(), status.ready(), status.cacheSize()));
    }

    private boolean authorize(Context ctx) {
        if (authenticator.isAuthorized(ctx.header("X-Auth-Token"))) {
            return true;
        }
        ctx.status(403).json(LichessGuardResponses.error("AUTH"));
        return false;
    }

    private String stringValue(Object value) {
        return value == null ? "" : String.valueOf(value);
    }

    private double doubleValue(Object value) {
        if (value == null) {
            return 0.0;
        }
        try {
            return Double.parseDouble(String.valueOf(value));
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException("invalid numeric value", e);
        }
    }

    private long longValue(Object value) {
        if (value == null) {
            return 0L;
        }
        try {
            return Long.parseLong(String.valueOf(value));
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException("invalid timestamp", e);
        }
    }
}