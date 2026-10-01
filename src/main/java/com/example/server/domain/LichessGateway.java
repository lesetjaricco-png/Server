package com.example.server.domain;

import com.example.server.domain.GuardModels.LichessStats;

/** Boundary for retrieving account and recent-game data from Lichess. */
public interface LichessGateway {
    String resolveUsername() throws Exception;

    LichessStats fetchRecentStats(String username, int lookbackMinutes, int maximumGames) throws Exception;
}