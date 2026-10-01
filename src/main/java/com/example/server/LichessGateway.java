package com.example.server;

import com.example.server.GuardModels.LichessStats;

/** Boundary for retrieving account and recent-game data from Lichess. */
public interface LichessGateway {
    String resolveUsername() throws Exception;

    LichessStats fetchRecentStats(String username, int lookbackMinutes, int maximumGames) throws Exception;
}