import { randomUUID } from "node:crypto";
import { Agent as HttpAgent } from "node:http";
import { Agent as HttpsAgent } from "node:https";
import axios from "axios";
import {
  context,
  metrics,
  ROOT_CONTEXT,
  SpanStatusCode,
  trace,
} from "@opentelemetry/api";
import { logger } from "../logs/logger.js";
import { replayTargetUrl } from "../global/env-vars.js";
import { attachLogging } from "../logs/axios-logger.js";

// The scheduler wakes up on this cadence and dispatches everything that has
// come due, so a late tick catches up instead of drifting behind the rate.
// At 100 req/s this is one request per tick.
const tickIntervalMs = 10;

const defaultRatePerSecond = 100;
const defaultDurationMs = 10_000;

const maxRatePerSecond = 2_000;
const maxDurationMs = 60 * 60 * 1000;
const maxTotalRequests = 1_000_000;

// Requests are fired without waiting for the previous one, so a target slower
// than the send rate would otherwise pile up sockets without bound.
const maxInFlight = 1_000;
const requestTimeoutMs = 10_000;

// Finished jobs stay queryable for a while, then drop out of memory.
const finishedJobRetentionMs = 15 * 60 * 1000;

const allowedMethods = new Set([
  "GET",
  "POST",
  "PUT",
  "PATCH",
  "DELETE",
  "HEAD",
]);

// A dedicated instance so the load traffic is not logged per request by
// axios-logger.ts — 100 lines/s of outbound request logs would drown the real
// application logs. Call attachLogging() on it if you do want them.
const client = axios.create({
  timeout: requestTimeoutMs,
  httpAgent: new HttpAgent({ keepAlive: true, maxSockets: 256 }),
  httpsAgent: new HttpsAgent({ keepAlive: true, maxSockets: 256 }),

  // Status handling is ours; only transport failures and timeouts should throw.
  validateStatus: (status) => status < 400,
});

attachLogging(client);

const tracer = trace.getTracer("replay-job");
const meter = metrics.getMeter("replay-job");

const requestCounter = meter.createCounter("replay_job_requests", {
  description: "Requests sent by replay jobs",
});

const durationHistogram = meter.createHistogram("replay_job_request_duration", {
  description: "Duration of requests sent by replay jobs",
  unit: "ms",
});

type JobStatus = "running" | "stopping" | "completed" | "stopped";

type ReplayJobOptions = {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: unknown;
  ratePerSecond: number;
  totalRequests: number;
};

type ReplayJob = ReplayJobOptions & {
  id: string;
  status: JobStatus;
  createdAt: string;
  finishedAt: string | undefined;

  dispatched: number;
  inFlight: number;
  succeeded: number;
  failed: number;
  skipped: number;
  statusCodes: Record<string, number>;

  latencyCount: number;
  latencySumMs: number;
  latencyMinMs: number;
  latencyMaxMs: number;
  lastError: string | undefined;

  startedAtMonotonic: number;
  timer: NodeJS.Timeout | undefined;
};

const jobs = new Map<string, ReplayJob>();

function isFinished(job: ReplayJob): boolean {
  return job.status === "completed" || job.status === "stopped";
}

// Every job is its own trace: without this the setTimeout chain would inherit
// the context of the POST that created the job (OpenTelemetry propagates it
// through AsyncLocalStorage), hanging thousands of spans off one request.
function detached<T>(run: () => T): T {
  return context.with(ROOT_CONTEXT, run);
}

function recordOutcome(
  job: ReplayJob,
  durationMs: number,
  statusCode: number | undefined,
  error: Error | undefined,
): void {
  job.latencyCount += 1;
  job.latencySumMs += durationMs;
  job.latencyMinMs = Math.min(job.latencyMinMs, durationMs);
  job.latencyMaxMs = Math.max(job.latencyMaxMs, durationMs);

  const key = statusCode === undefined ? "error" : String(statusCode);
  job.statusCodes[key] = (job.statusCodes[key] ?? 0) + 1;

  const ok = statusCode !== undefined && statusCode < 400;

  if (ok) {
    job.succeeded += 1;
  } else {
    job.failed += 1;
    job.lastError = error?.message ?? `HTTP ${key}`;
  }

  // Job ids are deliberately left off the metric attributes: one time series
  // per job would make the cardinality grow without bound.
  const attributes = {
    outcome: ok ? "success" : "failure",
    "http.response.status_code": key,
  };

  requestCounter.add(1, attributes);
  durationHistogram.record(durationMs, attributes);
}

async function sendOne(job: ReplayJob, sequence: number): Promise<void> {
  const startedAt = performance.now();

  await tracer.startActiveSpan(
    "replay-job request",
    {
      attributes: {
        "replay.job_id": job.id,
        "replay.sequence": sequence,
        "http.request.method": job.method,
        "url.full": job.url,
      },
    },
    async (span) => {
      try {
        const response = await client.request({
          url: job.url,
          method: job.method,
          headers: job.headers,
          data: job.body,
        });

        span.setAttribute("http.response.status_code", response.status);

        recordOutcome(
          job,
          performance.now() - startedAt,
          response.status,
          undefined,
        );
      } catch (thrownValue) {
        const error =
          thrownValue instanceof Error
            ? thrownValue
            : new Error(String(thrownValue));

        const statusCode =
          axios.isAxiosError(thrownValue) && thrownValue.response
            ? thrownValue.response.status
            : undefined;

        span.recordException(error);
        span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });
        recordOutcome(job, performance.now() - startedAt, statusCode, error);
      } finally {
        span.end();
      }
    },
  );
}

function finalize(job: ReplayJob): void {
  if (isFinished(job)) return;

  job.status = job.status === "stopping" ? "stopped" : "completed";
  job.finishedAt = new Date().toISOString();

  logger.info(
    {
      component: "replay-job",
      jobId: job.id,
      status: job.status,
      dispatched: job.dispatched,
      succeeded: job.succeeded,
      failed: job.failed,
      skipped: job.skipped,
    },
    "replay job finished",
  );

  const cleanup = setTimeout(() => jobs.delete(job.id), finishedJobRetentionMs);
  cleanup.unref();
}

function dispatch(job: ReplayJob, sequence: number): void {
  job.inFlight += 1;

  void sendOne(job, sequence).finally(() => {
    job.inFlight -= 1;

    // The last response of a job that has already stopped scheduling.
    if (job.timer === undefined && job.inFlight === 0) {
      finalize(job);
    }
  });
}

function tick(job: ReplayJob): void {
  const elapsedMs = performance.now() - job.startedAtMonotonic;

  // Derived from elapsed time rather than incremented per tick, so timer
  // jitter and event loop lag do not accumulate into a slower send rate.
  const due = Math.min(
    Math.floor((elapsedMs * job.ratePerSecond) / 1000),
    job.totalRequests,
  );

  while (job.dispatched < due) {
    if (job.inFlight >= maxInFlight) {
      // The target cannot keep up. Drop the backlog instead of queueing it.
      job.skipped += due - job.dispatched;
      job.dispatched = due;
      break;
    }

    job.dispatched += 1;
    dispatch(job, job.dispatched);
  }

  if (job.dispatched >= job.totalRequests) {
    clearTimeout(job.timer);
    job.timer = undefined;

    if (job.inFlight === 0) {
      finalize(job);
    }

    return;
  }

  job.timer = setTimeout(() => tick(job), tickIntervalMs);
  job.timer.unref();
}

function startReplayJob(options: ReplayJobOptions): ReplayJob {
  const job: ReplayJob = {
    ...options,
    id: randomUUID(),
    status: "running",
    createdAt: new Date().toISOString(),
    finishedAt: undefined,

    dispatched: 0,
    inFlight: 0,
    succeeded: 0,
    failed: 0,
    skipped: 0,
    statusCodes: {},

    latencyCount: 0,
    latencySumMs: 0,
    latencyMinMs: Number.POSITIVE_INFINITY,
    latencyMaxMs: 0,
    lastError: undefined,

    startedAtMonotonic: performance.now(),
    timer: undefined,
  };

  jobs.set(job.id, job);

  logger.info(
    {
      component: "replay-job",
      jobId: job.id,
      url: job.url,
      method: job.method,
      ratePerSecond: job.ratePerSecond,
      totalRequests: job.totalRequests,
    },
    "replay job started",
  );

  detached(() => tick(job));

  return job;
}

function stopReplayJob(id: string): ReplayJob | undefined {
  const job = jobs.get(id);

  if (!job || isFinished(job)) {
    return job;
  }

  clearTimeout(job.timer);
  job.timer = undefined;
  job.status = "stopping";

  if (job.inFlight === 0) {
    finalize(job);
  }

  return job;
}

function stopAllReplayJobs(): void {
  for (const job of jobs.values()) {
    stopReplayJob(job.id);
  }
}

function snapshotReplayJob(job: ReplayJob) {
  const elapsedMs = job.finishedAt
    ? Date.parse(job.finishedAt) - Date.parse(job.createdAt)
    : performance.now() - job.startedAtMonotonic;

  return {
    jobId: job.id,
    status: job.status,

    request: {
      url: job.url,
      method: job.method,
      headers: job.headers,
      body: job.body,
    },

    ratePerSecond: job.ratePerSecond,
    totalRequests: job.totalRequests,
    createdAt: job.createdAt,
    finishedAt: job.finishedAt,
    elapsedMs: Math.round(elapsedMs),

    progress: {
      dispatched: job.dispatched,
      remaining: job.totalRequests - job.dispatched,
      inFlight: job.inFlight,
      succeeded: job.succeeded,
      failed: job.failed,
      skipped: job.skipped,
      actualRatePerSecond:
        elapsedMs > 0
          ? Math.round((job.dispatched / elapsedMs) * 1000 * 10) / 10
          : 0,
    },

    statusCodes: job.statusCodes,

    latencyMs: {
      min: job.latencyCount > 0 ? Math.round(job.latencyMinMs) : null,
      avg:
        job.latencyCount > 0
          ? Math.round(job.latencySumMs / job.latencyCount)
          : null,
      max: job.latencyCount > 0 ? Math.round(job.latencyMaxMs) : null,
    },

    lastError: job.lastError,
  };
}

function getReplayJob(id: string) {
  const job = jobs.get(id);
  return job ? snapshotReplayJob(job) : undefined;
}

function listReplayJobs() {
  return [...jobs.values()].map((job) => ({
    jobId: job.id,
    status: job.status,
    url: job.url,
    createdAt: job.createdAt,
    dispatched: job.dispatched,
    totalRequests: job.totalRequests,
  }));
}

type ParseResult =
  { ok: true; options: ReplayJobOptions } | { ok: false; message: string };

function parseHeaders(value: unknown): Record<string, string> | undefined {
  if (value === undefined) return {};
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return undefined;
  }

  const headers: Record<string, string> = {};

  for (const [key, headerValue] of Object.entries(value)) {
    if (typeof headerValue !== "string") return undefined;
    headers[key] = headerValue;
  }

  return headers;
}

function parseReplayJobRequest(input: unknown): ParseResult {
  if (typeof input !== "object" || input === null || Array.isArray(input)) {
    return { ok: false, message: "Request body must be a JSON object" };
  }

  const {
    url = replayTargetUrl,
    method = "POST",
    headers,
    body,
    ratePerSecond = defaultRatePerSecond,
    durationMs = defaultDurationMs,
    totalRequests,
  } = input as Record<string, unknown>;

  if (typeof url !== "string" || !URL.canParse(url)) {
    return { ok: false, message: "url must be an absolute URL" };
  }

  const protocol = new URL(url).protocol;

  if (protocol !== "http:" && protocol !== "https:") {
    return { ok: false, message: "url must use http or https" };
  }

  if (typeof method !== "string" || !allowedMethods.has(method.toUpperCase())) {
    return {
      ok: false,
      message: `method must be one of ${[...allowedMethods].join(", ")}`,
    };
  }

  const parsedHeaders = parseHeaders(headers);

  if (!parsedHeaders) {
    return { ok: false, message: "headers must be an object of strings" };
  }

  if (
    typeof ratePerSecond !== "number" ||
    !Number.isFinite(ratePerSecond) ||
    ratePerSecond <= 0 ||
    ratePerSecond > maxRatePerSecond
  ) {
    return {
      ok: false,
      message: `ratePerSecond must be a number between 1 and ${maxRatePerSecond}`,
    };
  }

  let planned: number;

  if (totalRequests === undefined) {
    if (
      typeof durationMs !== "number" ||
      !Number.isFinite(durationMs) ||
      durationMs <= 0 ||
      durationMs > maxDurationMs
    ) {
      return {
        ok: false,
        message: `durationMs must be a number between 1 and ${maxDurationMs}`,
      };
    }

    planned = Math.ceil((ratePerSecond * durationMs) / 1000);
  } else {
    if (
      typeof totalRequests !== "number" ||
      !Number.isInteger(totalRequests) ||
      totalRequests <= 0
    ) {
      return { ok: false, message: "totalRequests must be a positive integer" };
    }

    planned = totalRequests;
  }

  if (planned > maxTotalRequests) {
    return {
      ok: false,
      message: `the job would send ${planned} requests, the limit is ${maxTotalRequests}`,
    };
  }

  return {
    ok: true,
    options: {
      url,
      method: method.toUpperCase(),
      headers: parsedHeaders,
      body,
      ratePerSecond,
      totalRequests: planned,
    },
  };
}

export {
  parseReplayJobRequest,
  startReplayJob,
  snapshotReplayJob,
  getReplayJob,
  listReplayJobs,
  stopReplayJob,
  stopAllReplayJobs,
};
