package com.example.server.bootstrap;

import com.example.server.api.ApiAuthenticator;
import com.example.server.api.LichessGuardController;
import com.example.server.application.LichessGuardService;
import com.example.server.config.AppConfig;
import com.example.server.config.ReceiverGateConfig;
import com.example.server.domain.EligibilityPolicy;
import com.example.server.domain.LichessGateway;
import com.example.server.domain.SignalPolicy;
import com.example.server.integration.lichess.LichessClient;
import com.example.server.state.PassCache;
import com.example.server.state.ReadinessTracker;
import com.example.server.state.ReceiverGateEvaluator;
import com.example.server.state.ReceiverStateStore;
import com.example.server.state.SignalStore;
import io.javalin.Javalin;

public class LichessGuardApplication {
    /** Starts Javalin and stops it cleanly when the JVM is asked to exit. */
    public static void main(String[] args) {
        AppConfig appConfig = AppConfig.load();
        ReceiverGateConfig receiverGateConfig = ReceiverGateConfig.load();
        LichessGateway lichess = new LichessClient(appConfig);
        LichessGuardService service = new LichessGuardService(
            appConfig,
            lichess,
            new EligibilityPolicy(appConfig),
            new PassCache(),
                new SignalStore(),
                new SignalPolicy(),
                new ReadinessTracker(),
                new ReceiverStateStore(),
                new ReceiverGateEvaluator(receiverGateConfig)
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
