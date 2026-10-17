import { pinoHttp } from "pino-http";
import { logger } from "./logger.js";
export const captureResponseBody = (_req, res, next) => {
    // explaination
    const originalJson = res.json.bind(res);
    const originalSend = res.send.bind(res);
    res.json = ((body) => {
        res.locals.responseBody = body;
        return originalJson(body);
    });
    res.send = ((body) => {
        if (res.locals.responseBody === undefined) {
            res.locals.responseBody = body;
        }
        return originalSend(body);
    });
    next();
};
export const httpLogger = pinoHttp({
    logger,
    quietReqLogger: true,
    quietResLogger: true,
    // Move pino-http's internal serializers away from "req" and "res".
    // This leaves our custom req/res objects unchanged.
    customAttributeKeys: {
        req: "internalRequest",
        res: "internalResponse",
    },
    autoLogging: {
        ignore(req) {
            const pathname = req.url?.split("?", 1)[0];
            return pathname === "/metrics" || pathname === "/health";
        },
    },
    customSuccessObject(req, res, original) {
        return {
            reqId: req.id,
            responseTime: original.responseTime,
            req: {
                method: req.method,
                url: req.originalUrl,
                headers: req.headers,
                body: req.body,
            },
            res: {
                statusCode: res.statusCode,
                body: res.locals.responseBody,
            },
        };
    },
    customErrorObject(req, res, error, original) {
        return {
            reqId: req.id,
            responseTime: original.responseTime,
            err: error,
            req: {
                method: req.method,
                url: req.originalUrl,
                headers: req.headers,
                body: req.body,
            },
            res: {
                statusCode: res.statusCode,
                body: res.locals.responseBody,
            },
        };
    },
    customLogLevel(_req, res, error) {
        if (error || res.statusCode >= 500) {
            return "error";
        }
        if (res.statusCode >= 400) {
            return "warn";
        }
        return "info";
    },
});
//# sourceMappingURL=http-logger.js.map