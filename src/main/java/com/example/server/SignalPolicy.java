package com.example.server;

import com.example.server.GuardModels.SignalRequest;

import java.util.Locale;

/** Validates and normalizes incoming trading signal values. */
public class SignalPolicy {
    public ValidationResult validate(SignalRequest request) {
        String side = request.side() == null ? "" : request.side().trim().toUpperCase(Locale.ROOT);
        String symbol = request.symbol() == null ? "" : request.symbol().trim();
        if (!side.equals("BUY") && !side.equals("SELL")) {
            return ValidationResult.invalid("invalid side");
        }
        if (symbol.isBlank()) {
            return ValidationResult.invalid("missing symbol");
        }
        if (!Double.isFinite(request.lots()) || request.lots() <= 0) {
            return ValidationResult.invalid("invalid lots");
        }
        return ValidationResult.valid(new SignalRequest(side, symbol, request.lots(), request.timestamp()));
    }

    public record ValidationResult(boolean valid, String reason, SignalRequest request) {
        static ValidationResult valid(SignalRequest request) {
            return new ValidationResult(true, "", request);
        }

        static ValidationResult invalid(String reason) {
            return new ValidationResult(false, reason, null);
        }
    }
}