# syntax=docker/dockerfile:1

FROM node:24-alpine AS builder
WORKDIR /build

COPY package*.json ./
RUN --mount=type=cache,id=npm-cache,target=/root/.npm,sharing=shared \
    npm ci --prefer-offline

COPY . .
RUN npm run build

FROM node:24-alpine
WORKDIR /app

ENV NODE_ENV=production
COPY package*.json ./
RUN --mount=type=cache,id=npm-cache,target=/root/.npm,sharing=shared \
    npm ci --omit=dev --prefer-offline

COPY --from=builder /build/dist ./dist
ENTRYPOINT ["node"]
CMD ["--enable-source-maps", "--import", "./dist/hooks/otel-hook.js", "--import", "./dist/instrumentation.js", "./dist/index.js"]
