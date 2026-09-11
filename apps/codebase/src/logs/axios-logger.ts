import axios, {
  AxiosError,
  AxiosHeaders,
  type AxiosInstance,
  type AxiosResponse,
  type InternalAxiosRequestConfig,
} from "axios";
import { logger } from "./logger.js";

// Bodies larger than this are dropped instead of logged.
const maxBodyBytes = 2_000;

type LoggedRequest = {
  method: string | undefined;
  url: string | undefined;
  headers: Record<string, unknown>;
  body: unknown;
};

// Per-request state. Keyed by the config object axios threads through the
// whole request, so entries are collected with the request itself.
const pendingRequests = new WeakMap<
  object,
  { startedAt: number; req: LoggedRequest }
>();

// pino's redact paths are matched case sensitively, and axios preserves the
// casing the caller used ("Authorization"). Lowercasing keeps the paths in
// logger.ts effective.
function normalizeHeaders(headers: unknown): Record<string, unknown> {
  if (!headers) {
    return {};
  }

  const plain =
    headers instanceof AxiosHeaders
      ? headers.toJSON()
      : (headers as Record<string, unknown>);

  const normalized: Record<string, unknown> = {};

  for (const [key, value] of Object.entries(plain)) {
    normalized[key.toLowerCase()] = value;
  }

  return normalized;
}

// Objects are passed through untouched so the redact paths can reach into
// them. Anything too large or not serializable is replaced by a summary.
function summarizeBody(body: unknown): unknown {
  if (body === undefined || body === null) {
    return undefined;
  }

  if (typeof body === "string") {
    return body.length > maxBodyBytes
      ? { truncated: true, bytes: body.length }
      : body;
  }

  if (Buffer.isBuffer(body)) {
    return { binary: true, bytes: body.length };
  }

  if (typeof body !== "object") {
    return body;
  }

  // Streams, FormData, URLSearchParams, ...
  if (typeof (body as { pipe?: unknown }).pipe === "function") {
    return { stream: true };
  }

  let serialized: string;

  try {
    serialized = JSON.stringify(body);
  } catch {
    return { unserializable: true };
  }

  if (serialized === undefined || serialized.length > maxBodyBytes) {
    return { truncated: true, bytes: serialized?.length ?? 0 };
  }

  return body;
}

function describeRequest(config: InternalAxiosRequestConfig): LoggedRequest {
  let url: string | undefined;

  try {
    // Resolves baseURL and serializes params.
    url = axios.getUri(config);
  } catch {
    url = config.url;
  }

  return {
    method: config.method?.toUpperCase(),
    url,
    headers: normalizeHeaders(config.headers),
    body: summarizeBody(config.data),
  };
}

function levelFor(statusCode: number | undefined): "info" | "warn" | "error" {
  if (statusCode === undefined || statusCode >= 500) {
    return "error";
  }

  if (statusCode >= 400) {
    return "warn";
  }

  return "info";
}

function finish(config: InternalAxiosRequestConfig | undefined) {
  const pending = config ? pendingRequests.get(config) : undefined;

  if (config) {
    pendingRequests.delete(config);
  }

  return {
    responseTime: pending
      ? Math.round((performance.now() - pending.startedAt) * 100) / 100
      : undefined,

    // Falls back to the post-transform config when the request interceptor
    // never ran (e.g. the error was raised before dispatch).
    req: pending?.req ?? (config ? describeRequest(config) : undefined),
  };
}

function logResponse(response: AxiosResponse): void {
  const { responseTime, req } = finish(
    response.config as InternalAxiosRequestConfig,
  );

  logger[levelFor(response.status)](
    {
      component: "axios",
      responseTime,
      req,
      res: {
        statusCode: response.status,
        headers: normalizeHeaders(response.headers),
        body: summarizeBody(response.data),
      },
    },
    "axios response",
  );
}

// An AxiosError carries config, request and response as own enumerable
// properties, so pino's error serializer would dump the socket, the agent and
// an unredacted copy of the request headers. We log req/res ourselves, so keep
// only the parts of the error that aren't already covered.
function slimError(error: Error): Error {
  if (!(error instanceof AxiosError)) {
    return error;
  }

  const slim = new Error(error.message, { cause: error.cause });
  slim.name = error.name;
  slim.stack = error.stack;

  return slim;
}

function logFailure(thrownValue: unknown): void {
  const error =
    thrownValue instanceof Error ? thrownValue : new Error(String(thrownValue));

  const axiosError = error instanceof AxiosError ? error : undefined;

  const { responseTime, req } = finish(axiosError?.config);
  const response = axiosError?.response;

  logger[levelFor(response?.status)](
    {
      component: "axios",
      responseTime,
      err: slimError(error),
      code: axiosError?.code,
      req,
      res: response
        ? {
            statusCode: response.status,
            headers: normalizeHeaders(response.headers),
            body: summarizeBody(response.data),
          }
        : undefined,
    },
    "axios request failed",
  );
}

export function attachLogging(instance: AxiosInstance): AxiosInstance {
  instance.interceptors.request.use(
    (config) => {
      pendingRequests.set(config, {
        startedAt: performance.now(),
        req: describeRequest(config),
      });

      return config;
    },
    (thrownValue) => {
      logFailure(thrownValue);
      return Promise.reject(thrownValue);
    },
  );

  instance.interceptors.response.use(
    (response) => {
      logResponse(response);
      return response;
    },
    (thrownValue) => {
      logFailure(thrownValue);
      return Promise.reject(thrownValue);
    },
  );

  return instance;
}

// Patches the default axios instance, so plain `axios.get(...)` calls made
// anywhere in the app are logged. Instances built with axios.create() do not
// inherit these interceptors — pass them to attachLogging() individually.
attachLogging(axios);
