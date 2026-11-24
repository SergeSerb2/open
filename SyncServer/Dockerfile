# syntax=docker/dockerfile:1
# Open Sync Server: zero runtime dependencies, Node.js 22+ (uses built-in node:sqlite).

FROM node:22-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
# tsrs (https://github.com/oxc-project/tsrs) type-checks and emits dist/.
RUN npx --yes tsrs -p tsconfig.json

FROM node:22-bookworm-slim
ENV NODE_ENV=production \
    OPEN_SYNC_HOST=0.0.0.0 \
    OPEN_SYNC_PORT=8787 \
    OPEN_SYNC_DATA_DIR=/data
WORKDIR /app
COPY package.json ./
COPY --from=build /app/dist ./dist
RUN mkdir -p /data && chown node:node /data
USER node
VOLUME ["/data"]
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.OPEN_SYNC_PORT||8787)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
# Exec form so SIGTERM reaches node directly (graceful shutdown).
CMD ["node", "--no-warnings", "dist/index.js"]
