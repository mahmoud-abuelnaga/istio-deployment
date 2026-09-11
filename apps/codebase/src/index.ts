// Registers the axios interceptors. Kept here rather than in
// instrumentation.ts so axios loads after the OpenTelemetry SDK has started.
import "./logs/axios-logger.js";
import express from "express";
import { httpLogger, captureResponseBody } from "./logs/http-logger.js";
import { port } from "./global/env-vars.js";
import { errorHandler } from "./middlewares/error-handling.js";
import { shutdown } from "./shutdown.js";
import { logger } from "./logs/logger.js";
import axios from "axios";
import {
  getReplayJob,
  listReplayJobs,
  parseReplayJobRequest,
  snapshotReplayJob,
  startReplayJob,
  stopReplayJob,
} from "./jobs/replay-job.js";

const app = express();

// Starts request timing.
app.use(httpLogger);

// Parses JSON so req.body is available by completion time.
app.use(express.json({ limit: "1mb" }));

// Captures bodies sent through res.json() or res.send().
app.use(captureResponseBody);

// Routes
app.get("/health", (_req, res, _next) => {
  return res.status(200).end();
});

app.get("/random-number", (_req, res, _next) => {
  const randomNumber = Math.floor(Math.random() * 100);
  return res.json({ randomNumber });
});

app.get("/error", (_req, _res, _next) => {
  throw new Error("Test error");
});

app.post("/replay", (req, res, _next) => {
  return res.json({ message: "Replay", data: req.body });
});

app.get("/axios", async (_req, res, _next) => {
  const _ = await axios.get("https://www.google.com");
  return res.json({ message: "Axios request was successful" });
});

// Starts a background load job and returns immediately with its id. The job
// keeps sending until it has dispatched the requested number of requests.
app.post("/replay-extended", (req, res, _next) => {
  const parsed = parseReplayJobRequest(req.body ?? {});

  if (!parsed.ok) {
    return res.status(400).json({ error: parsed.message });
  }

  const job = startReplayJob(parsed.options);

  return res.status(202).json(snapshotReplayJob(job));
});

app.get("/replay-extended", (_req, res, _next) => {
  return res.json({ jobs: listReplayJobs() });
});

app.get("/replay-extended/:jobId", (req, res, _next) => {
  const job = getReplayJob(req.params.jobId);

  if (!job) {
    return res.status(404).json({ error: "Job not found" });
  }

  return res.json(job);
});

app.delete("/replay-extended/:jobId", (req, res, _next) => {
  const job = stopReplayJob(req.params.jobId);

  if (!job) {
    return res.status(404).json({ error: "Job not found" });
  }

  return res.json(snapshotReplayJob(job));
});

app.use((_req, res, _next) => {
  return res.status(404).json({ message: "Not found" });
});

// Error handling
app.use(errorHandler);

const server = app.listen(port, () => {
  logger.info({ port }, `Server is running on port ${port}`);
});

process.once("SIGTERM", () => {
  void shutdown("SIGTERM", server);
});

process.once("SIGINT", () => {
  void shutdown("SIGINT", server);
});
