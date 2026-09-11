import { NodeSDK } from "@opentelemetry/sdk-node";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-proto";
import { getNodeAutoInstrumentations } from "@opentelemetry/auto-instrumentations-node";
import {
  defaultResource,
  resourceFromAttributes,
} from "@opentelemetry/resources";
import { PrometheusExporter } from "@opentelemetry/exporter-prometheus";
import {
  otelServiceName,
  otelServiceVersion,
  prometheusPort,
  prometheusEndpoint,
  prometheusHost,
  otelServiceNamespace,
} from "./global/env-vars.js";
import { logger } from "./logs/logger.js";

const prometheusExporter = new PrometheusExporter(
  {
    port: Number(prometheusPort),
    host: prometheusHost,
    endpoint: prometheusEndpoint,
  },
  (error) => {
    if (!error) {
      logger.info(
        { component: "prometheusExporter" },
        "Prometheus exporter started",
      );
      return;
    }

    logger.error(
      { err: error, component: "prometheusExporter" },
      "Failed to start Prometheus exporter",
    );
  },
);

const sdk = new NodeSDK({
  resource: defaultResource().merge(
    resourceFromAttributes({
      "service.name": otelServiceName,
      "service.version": otelServiceVersion,
      "service.namespace": otelServiceNamespace,
    }),
  ),

  traceExporter: new OTLPTraceExporter(),
  metricReaders: [prometheusExporter],

  instrumentations: [
    getNodeAutoInstrumentations({
      "@opentelemetry/instrumentation-fs": {
        enabled: false,
      },

      "@opentelemetry/instrumentation-http": {
        // Skip traces and HTTP metrics for kube probes and Prometheus scrapes.
        // Returning true also suppressTracing()'s the rest of the request, so
        // Express/router child spans are not created either.
        ignoreIncomingRequestHook(request) {
          const pathname = request.url?.split("?", 1)[0];

          if (pathname === "/health") {
            return true;
          }

          return (
            request.socket.localPort === Number(prometheusPort) &&
            pathname === prometheusEndpoint
          );
        },
      },
    }),
  ],
});

sdk.start();

async function shutdownTelemetry(): Promise<void> {
  try {
    await sdk.shutdown();
    logger.info("OpenTelemetry has shut down successfully");
  } catch (thrownValue) {
    const err =
      thrownValue instanceof Error
        ? thrownValue
        : new Error(String(thrownValue));

    logger.error({ err }, "Failed to shut down OpenTelemetry SDK");
    process.exitCode = 1;
  }
}

// process.once("SIGTERM", shutdown);
// process.once("SIGINT", shutdown);

export { sdk, shutdownTelemetry };
