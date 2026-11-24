import http from "node:http";
import type { IncomingMessage, ServerResponse } from "node:http";
import type { AddressInfo, Socket } from "node:net";
import type { Duplex } from "node:stream";
import * as account from "./account.js";
import * as auth from "./auth.js";
import * as blobs from "./blobs.js";
import type { Config } from "./config.js";
import { Store } from "./db.js";
import { ApiError } from "./errors.js";
import { BASE_HEADERS, Context, drainAndClose, errorBody, hasUnreadBody } from "./http.js";
import type { App } from "./http.js";
import { SlidingWindowLimiter } from "./rateLimit.js";
import * as sync from "./sync.js";
import { isUuid } from "./validation.js";
import { WsHub, checkHandshake } from "./ws.js";

type Handler = (c: Context) => Promise<void> | void;

interface Route {
  method: string;
  pattern: RegExp;
  auth: boolean;
  handler: Handler;
}

const BEARER_RE = /^Bearer ([A-Za-z0-9_-]{16,512})$/i;

const ROUTES: Route[] = [
  {
    method: "GET",
    pattern: /^\/health$/,
    auth: false,
    handler: (c) => c.json(200, { ok: true, service: "open-sync", version: 1 }),
  },
  { method: "POST", pattern: /^\/v1\/auth\/register$/, auth: false, handler: auth.register },
  { method: "POST", pattern: /^\/v1\/auth\/kdf-params$/, auth: false, handler: auth.kdfParams },
  { method: "POST", pattern: /^\/v1\/auth\/login$/, auth: false, handler: auth.login },
  { method: "POST", pattern: /^\/v1\/auth\/refresh$/, auth: false, handler: auth.refresh },
  { method: "POST", pattern: /^\/v1\/auth\/logout$/, auth: true, handler: auth.logout },
  { method: "POST", pattern: /^\/v1\/auth\/change-password$/, auth: true, handler: auth.changePassword },
  { method: "POST", pattern: /^\/v1\/auth\/recovery-challenge$/, auth: false, handler: auth.recoveryChallenge },
  { method: "POST", pattern: /^\/v1\/auth\/recover$/, auth: false, handler: auth.recover },
  { method: "GET", pattern: /^\/v1\/account$/, auth: true, handler: account.getAccount },
  { method: "PATCH", pattern: /^\/v1\/account$/, auth: true, handler: account.patchAccount },
  { method: "DELETE", pattern: /^\/v1\/account$/, auth: true, handler: account.deleteAccount },
  {
    method: "DELETE",
    pattern: /^\/v1\/account\/devices\/(?<deviceId>[^/]+)$/,
    auth: true,
    handler: account.removeDevice,
  },
  { method: "GET", pattern: /^\/v1\/sync\/status$/, auth: true, handler: sync.status },
  { method: "GET", pattern: /^\/v1\/sync\/changes$/, auth: true, handler: sync.changes },
  { method: "POST", pattern: /^\/v1\/sync\/push$/, auth: true, handler: sync.push },
  { method: "PUT", pattern: /^\/v1\/blobs\/(?<blobId>[^/]+)$/, auth: true, handler: blobs.putBlob },
  { method: "GET", pattern: /^\/v1\/blobs\/(?<blobId>[^/]+)$/, auth: true, handler: blobs.getBlob },
  { method: "HEAD", pattern: /^\/v1\/blobs\/(?<blobId>[^/]+)$/, auth: true, handler: blobs.headBlob },
];

export interface RunningServer {
  readonly app: App;
  readonly server: http.Server;
  address(): { host: string; port: number };
  stop(): Promise<void>;
}

function clientIp(config: Config, req: IncomingMessage): string {
  if (config.trustProxy) {
    const forwarded = req.headers["x-forwarded-for"];
    const value = Array.isArray(forwarded) ? forwarded.join(",") : forwarded;
    const last = value?.split(",").pop()?.trim();
    if (last) return last;
  }
  return req.socket.remoteAddress ?? "unknown";
}

function sendError(req: IncomingMessage, res: ServerResponse, error: unknown): void {
  let status = 500;
  let code = "INTERNAL_ERROR";
  let message = "Internal server error.";
  let extra: Record<string, string> = {};
  if (error instanceof ApiError) {
    status = error.status;
    code = error.code;
    message = error.message;
    extra = error.headers;
  } else {
    process.stderr.write(`[open-sync] unhandled error: ${error instanceof Error ? (error.stack ?? error.message) : String(error)}\n`);
  }
  if (res.headersSent) {
    res.destroy();
    return;
  }
  const body = Buffer.from(errorBody(code, message), "utf8");
  const headers: Record<string, string | number> = {
    ...BASE_HEADERS,
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": body.length,
    ...extra,
  };
  if (hasUnreadBody(req)) headers["Connection"] = "close";
  res.writeHead(status, headers);
  res.end(body);
  drainAndClose(req, res);
}

function rejectUpgrade(socket: Duplex, status: number, reason: string, code: string, message: string): void {
  const body = errorBody(code, message);
  socket.end(
    [
      `HTTP/1.1 ${status} ${reason}`,
      "Content-Type: application/json; charset=utf-8",
      `Content-Length: ${Buffer.byteLength(body)}`,
      "Connection: close",
      "X-Content-Type-Options: nosniff",
      "Cache-Control: no-store",
      ...(status === 401 ? ['WWW-Authenticate: Bearer realm="open-sync"'] : []),
      "",
      body,
    ].join("\r\n"),
  );
}

function bearerToken(req: IncomingMessage): string | undefined {
  const header = req.headers["authorization"];
  if (typeof header !== "string") return undefined;
  return BEARER_RE.exec(header)?.[1];
}

export function startServer(config: Config): Promise<RunningServer> {
  const store = new Store(config.dataDir);
  const hub = new WsHub({
    isFamilyActive: (family) => store.isFamilyActive(family),
    pingIntervalMs: config.wsPingIntervalMs,
  });
  const authLimiter = new SlidingWindowLimiter(config.authRateLimit);
  const app: App = { config, store, hub, authLimiter };

  store.purgeExpired(Date.now());
  const purgeTimer = setInterval(() => {
    try {
      store.purgeExpired(Date.now());
    } catch (error) {
      process.stderr.write(`[open-sync] purge failed: ${String(error)}\n`);
    }
  }, 60 * 60 * 1000);
  purgeTimer.unref();

  const handle = async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
    try {
      const rawUrl = req.url ?? "/";
      if (!rawUrl.startsWith("/")) throw new ApiError(400, "VALIDATION_ERROR", "Malformed request target.");
      let url: URL;
      try {
        url = new URL(`http://localhost${rawUrl}`);
      } catch {
        throw new ApiError(400, "VALIDATION_ERROR", "Malformed request target.");
      }
      const ip = clientIp(config, req);
      const method = req.method ?? "GET";
      const pathname = url.pathname;

      if (pathname.startsWith("/v1/auth/")) {
        const verdict = authLimiter.hit(ip);
        if (!verdict.allowed) {
          throw new ApiError(429, "RATE_LIMITED", "Too many authentication requests; slow down.", {
            "Retry-After": String(Math.ceil(verdict.retryAfterMs / 1000)),
          });
        }
      }

      let route: Route | undefined;
      let params: Record<string, string> = {};
      const allowed: string[] = [];
      for (const candidate of ROUTES) {
        const match = candidate.pattern.exec(pathname);
        if (!match) continue;
        allowed.push(candidate.method);
        if (candidate.method === method) {
          route = candidate;
          params = { ...(match.groups ?? {}) };
        }
      }
      if (!route) {
        if (allowed.length > 0) {
          throw new ApiError(405, "METHOD_NOT_ALLOWED", `Use ${allowed.join(", ")} for this path.`, {
            Allow: allowed.join(", "),
          });
        }
        throw new ApiError(404, "NOT_FOUND", "No such endpoint.");
      }

      const context = new Context(app, req, res, url, ip);
      context.params = params;
      if (route.auth) {
        const token = bearerToken(req);
        const session = token ? store.authenticate(token, Date.now()) : undefined;
        if (!session) {
          throw new ApiError(401, "UNAUTHORIZED", "Missing or invalid access token.", {
            "WWW-Authenticate": 'Bearer realm="open-sync"',
          });
        }
        store.touchDevice(session.accountId, session.deviceId, Date.now());
        context.session = session;
      }
      await route.handler(context);
    } catch (error) {
      sendError(req, res, error);
    }
  };

  const server = http.createServer((req, res) => {
    void handle(req, res);
  });
  server.headersTimeout = 30_000;
  server.keepAliveTimeout = 5_000;

  server.on("upgrade", (req: IncomingMessage, socket: Duplex, head: Buffer) => {
    socket.on("error", () => socket.destroy());
    const pathname = (req.url ?? "").split("?")[0];
    if (pathname !== "/v1/sync/ws") {
      rejectUpgrade(socket, 404, "Not Found", "NOT_FOUND", "No such endpoint.");
      return;
    }
    const handshake = checkHandshake(req);
    if ("error" in handshake) {
      rejectUpgrade(socket, 400, "Bad Request", "VALIDATION_ERROR", handshake.error);
      return;
    }
    const token = bearerToken(req);
    const session = token ? store.authenticate(token, Date.now()) : undefined;
    if (!session) {
      rejectUpgrade(socket, 401, "Unauthorized", "UNAUTHORIZED", "Missing or invalid access token.");
      return;
    }
    const headerDevice = req.headers["x-open-device-id"];
    if (headerDevice !== undefined) {
      if (typeof headerDevice !== "string" || !isUuid(headerDevice) || headerDevice.toLowerCase() !== session.deviceId.toLowerCase()) {
        rejectUpgrade(socket, 400, "Bad Request", "VALIDATION_ERROR", "X-Open-Device-Id does not match the authenticated device.");
        return;
      }
    }
    store.touchDevice(session.accountId, session.deviceId, Date.now());
    const state = store.accountState(session.accountId);
    const conn = hub.accept(
      req,
      socket as Socket,
      handshake.key,
      { accountId: session.accountId, deviceId: session.deviceId, family: session.family },
      { type: "connected", serverRevision: state.serverRevision, resetRevision: state.resetRevision },
    );
    if (head.length > 0) conn.feed(head);
  });

  let stopped: Promise<void> | undefined;
  const stop = (): Promise<void> => {
    stopped ??= (async () => {
      clearInterval(purgeTimer);
      hub.closeAll(1001, "server_shutdown");
      await new Promise<void>((resolve) => {
        server.close(() => resolve());
        server.closeIdleConnections();
        setTimeout(() => {
          hub.terminateAll();
          server.closeAllConnections();
        }, 1_500).unref();
      });
      hub.dispose();
      authLimiter.close();
      store.close();
    })();
    return stopped;
  };

  return new Promise<RunningServer>((resolve, reject) => {
    server.once("error", (error) => {
      clearInterval(purgeTimer);
      hub.dispose();
      authLimiter.close();
      store.close();
      reject(error);
    });
    server.listen(config.port, config.host, () => {
      resolve({
        app,
        server,
        address: () => {
          const info = server.address() as AddressInfo;
          return { host: config.host, port: info.port };
        },
        stop,
      });
    });
  });
}
