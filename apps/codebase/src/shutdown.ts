import type { Server } from "node:http";
import { shutdownTelemetry } from "./instrumentation.js";
import { logger } from "./logs/logger.js";
import { shutdownGracePeriod } from "./global/env-vars.js";
import { stopAllReplayJobs } from "./jobs/replay-job.js";

let isShuttingDown = false;

async function closeHttpServer(server: Server): Promise<void> {
    await new Promise<void>((resolve) => {
        const forceShutdownTimer = setTimeout(
            () => {
                logger.error(
                    "Graceful shutdown timed out. Forcing TCP connections to close.",
                );

                server.closeAllConnections();
                process.exitCode = 1;
            },
            Number(shutdownGracePeriod) * 1000,
        );

        forceShutdownTimer.unref();

        server.close((error) => {
            clearTimeout(forceShutdownTimer);

            if (error) {
                logger.error({ err: error }, "HTTP server shutdown failed");
                process.exitCode = 1;
            } else {
                logger.info("HTTP server shutdown successfully");
            }

            resolve();
        });
    });
}

async function shutdown(signal: NodeJS.Signals, server: Server): Promise<void> {
    if (isShuttingDown) return;
    isShuttingDown = true;

    logger.info({ signal }, `${signal} received; shutting down`);

    try {
        // Stop generating outbound load before anything else; otherwise the
        // server would keep waiting on replay traffic it is about to drop.
        stopAllReplayJobs();

        // Finish active HTTP requests first.
        await closeHttpServer(server);
    } finally {
        // Flush and stop telemetry last.
        await shutdownTelemetry();
    }
}

export { shutdown };
