package com.example.server.state;

import com.example.server.domain.GuardModels.ReceiverStateSnapshot;

import java.time.Clock;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

/** Stores the most recently received MT5 state snapshot with server receipt time. */
public class ReceiverStateStore {
    private final Clock clock;
    private volatile ReceivedState latest;

    public ReceiverStateStore() {
        this(Clock.systemUTC());
    }

    ReceiverStateStore(Clock clock) {
        this.clock = clock;
    }

    public ReceivedState update(ReceiverStateSnapshot snapshot) {
        ReceivedState previous = latest;
        List<String> changes = changedFields(previous == null ? null : previous.snapshot(), snapshot);
        ReceivedState received = new ReceivedState(snapshot, clock.instant(), changes);
        latest = received;
        return received;
    }

    public Optional<ReceivedState> latest() {
        return Optional.ofNullable(latest);
    }

    private List<String> changedFields(ReceiverStateSnapshot previous, ReceiverStateSnapshot current) {
        List<String> changes = new ArrayList<>();
        if (previous == null) {
            return List.of("receiverId", "dayStartBalance", "currentBalance", "dailyClosedNet", "lossesToday",
                    "spikesToday", "secondsSinceLastLoss", "scheduleOpen", "allPositionsAtBreakEven");
        }
        if (!java.util.Objects.equals(previous.receiverId(), current.receiverId())) changes.add("receiverId");
        if (Double.compare(previous.dayStartBalance(), current.dayStartBalance()) != 0) changes.add("dayStartBalance");
        if (Double.compare(previous.currentBalance(), current.currentBalance()) != 0) changes.add("currentBalance");
        if (Double.compare(previous.dailyClosedNet(), current.dailyClosedNet()) != 0) changes.add("dailyClosedNet");
        if (previous.lossesToday() != current.lossesToday()) changes.add("lossesToday");
        if (previous.spikesToday() != current.spikesToday()) changes.add("spikesToday");
        if (previous.secondsSinceLastLoss() != current.secondsSinceLastLoss()) changes.add("secondsSinceLastLoss");
        if (previous.scheduleOpen() != current.scheduleOpen()) changes.add("scheduleOpen");
        if (previous.allPositionsAtBreakEven() != current.allPositionsAtBreakEven()) changes.add("allPositionsAtBreakEven");
        return List.copyOf(changes);
    }

    public record ReceivedState(ReceiverStateSnapshot snapshot, Instant receivedAt, List<String> changedFields) {
        public ReceivedState {
            changedFields = List.copyOf(changedFields);
        }
    }
}