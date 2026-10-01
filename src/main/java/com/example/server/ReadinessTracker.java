package com.example.server;

import com.example.server.GuardModels.CheckResult;

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