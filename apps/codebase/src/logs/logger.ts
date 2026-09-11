import { trace } from "@opentelemetry/api";
import { pino } from "pino";
import { otelServiceName, nodeEnv, logLevel } from "../global/env-vars.js";

function currentTraceFields() {
  const span = trace.getActiveSpan();

  if (!span) {
    return {};
  }

  const spanContext = span.spanContext();

  return {
    trace_id: spanContext.traceId,
    span_id: spanContext.spanId,
    trace_flags: spanContext.traceFlags.toString(16).padStart(2, "0"),
  };
}

export const logger = pino({
  level: logLevel,

  base: {
    service: otelServiceName,
    environment: nodeEnv,
  },

  // Executed for every log record.
  mixin: currentTraceFields,

  formatters: {
    level(label) {
      return { level: label };
    },
  },

  redact: {
    paths: [
      "req.headers.authorization",
      "req.headers.cookie",
      'req.headers["proxy-authorization"]',
      'req.headers["x-api-key"]',

      "req.body.password",
      "req.body.token",
      "req.body.accessToken",
      "req.body.refreshToken",

      // 'res.body.password',
      "res.body.token",
      "res.body.accessToken",
      "res.body.refreshToken",
      "res.body.apiKey",

      // Outbound responses logged by axios-logger.ts.
      'res.headers["set-cookie"]',
    ],
    censor: "[REDACTED]",
  },
});
