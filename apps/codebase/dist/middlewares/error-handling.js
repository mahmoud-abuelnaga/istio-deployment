const errorHandler = (thrownValue, _req, res, next) => {
    const error = thrownValue instanceof Error
        ? thrownValue
        : new Error(String(thrownValue));
    // Let pino-http access the original error when the response finishes.
    res.err = error;
    if (res.headersSent) {
        next(error);
        return;
    }
    return res.status(500).json({
        error: "Internal server error",
    });
};
export { errorHandler };
//# sourceMappingURL=error-handling.js.map