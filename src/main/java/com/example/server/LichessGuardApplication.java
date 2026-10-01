package com.example.server;

import io.javalin.Javalin;

public class LichessGuardApplication {
    /** Starts Javalin and stops it cleanly when the JVM is asked to exit. */
    public static void main(String[] args) {
        AppConfig appConfig = AppConfig.load();
        LichessGateway lichess = new LichessClient(appConfig);
        LichessGuardService service = new LichessGuardService(
            appConfig,
            lichess,
            new EligibilityPolicy(appConfig),
            new PassCache(),
                new SignalStore(),
                new SignalPolicy(),
                new ReadinessTracker()
        );
        LichessGuardController controller = new LichessGuardController(service, new ApiAuthenticator(appConfig));

        Javalin app = Javalin.create(config -> {
            config.showJavalinBanner = false;
            //config.bundledPlugins.enableDevLogging();
        });

        controller.register(app);
        Runtime.getRuntime().addShutdownHook(new Thread(app::stop, "javalin-shutdown"));
        app.start(appConfig.host(), appConfig.port());
    }
}
