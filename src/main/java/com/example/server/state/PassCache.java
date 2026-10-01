package com.example.server.state;

import com.example.server.domain.GuardModels.CheckResult;

import java.time.Clock;
import java.util.Locale;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;

/** Stores passing eligibility results for one account and time window. */
public class PassCache {
    private final ConcurrentMap<String, CheckResult> entries = new ConcurrentHashMap<>();
    private final Clock clock;

    public PassCache() {
        this(Clock.systemUTC());
    }

    PassCache(Clock clock) {
        this.clock = clock;
    }

    public CheckResult get(String username, int windowMinutes) {
        return entries.get(key(username, windowMinutes));
    }

    public void put(CheckResult result, int windowMinutes) {
        if (result.passed() && !result.username().isBlank()) {
            entries.put(key(result.username(), windowMinutes), result);
        }
    }

    public boolean hasPass(String username, int windowMinutes) {
        return get(username, windowMinutes) != null;
    }

    public int size() {
        return entries.size();
    }

    public int clear() {
        int previousSize = entries.size();
        entries.clear();
        return previousSize;
    }

    public Double minutesUntilExpiry(int windowMinutes) {
        if (windowMinutes <= 0) {
            return null;
        }
        long windowSeconds = windowMinutes * 60L;
        long now = clock.instant().getEpochSecond();
        long windowEnd = Math.floorDiv(now, windowSeconds) * windowSeconds + windowSeconds;
        return Math.max(0, windowEnd - clock.instant().toEpochMilli() / 1000.0) / 60.0;
    }

    private String key(String username, int windowMinutes) {
        if (username == null || username.isBlank() || windowMinutes <= 0) {
            return "";
        }
        long windowSeconds = windowMinutes * 60L;
        long windowStart = Math.floorDiv(clock.instant().getEpochSecond(), windowSeconds) * windowSeconds;
        return username.toLowerCase(Locale.ROOT) + ":" + windowStart;
    }
}