package com.example.server;

/** Validates the shared token used by protected HTTP routes. */
public class ApiAuthenticator {
    private final String sharedToken;

    public ApiAuthenticator(AppConfig config) {
        sharedToken = config.authShared().trim();
    }

    public boolean isAuthorized(String token) {
        return sharedToken.isBlank() || sharedToken.equals(token);
    }
}