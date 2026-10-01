package com.example.server.state;

import com.example.server.domain.GuardModels.CheckResult;

/** Tracks the latest readiness outcome for the health endpoint. */
public class ReadinessTracker {
    private volatile Boolean ready;

    public void record(CheckResult result) {
        ready = result.passed();
    }

    public Boolean current() {
        return ready;
    }
}