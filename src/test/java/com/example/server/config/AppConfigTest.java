package com.example.server.config;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

class AppConfigTest {

    @Test
    void stripsTrailingCommentsFromEnvValues() {
        assertEquals("55", AppConfig.stripInlineComment("55 // Block after this many losing closes"));
        assertEquals("3.0", AppConfig.stripInlineComment("3.0 # percent"));
        assertEquals("http://127.0.0.1:5001", AppConfig.stripInlineComment("http://127.0.0.1:5001"));
        assertEquals("\"55 // keep\"", AppConfig.stripInlineComment("\"55 // keep\""));
    }
}
