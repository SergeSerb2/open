import type { IncomingMessage, ServerResponse } from "node:http";
import type { Config } from "./config.js";
import type { AuthenticatedSession, Store } from "./db.js";
import { ApiError, validationError } from "./errors.js";
import type { SlidingWindowLimiter } from "./rateLimit.js";
import { LIMITS, parseJsonObject } from "./validation.js";
import type { JsonObject } from "./validation.js";
import type { WsHub } from "./ws.js";

export interface App {
  config: Config;
  store: Store;
  hub: WsHub;
  authLimiter: SlidingWindowLimiter;
}

/** Headers set on every response. */
export const BASE_HEADERS: Record<string, string> = {
  "X-Content-Type-Options": "nosniff",
  "Cache-Control": "no-store",
};

export function errorBody(code: string, message: string): string {
  return JSON.stringify({ error: { code, message } });
}

export class Context {
  readonly app: App;
  readonly req: IncomingMessage;
  readonly res: ServerResponse;
  readonly url: URL;
  readonly ip: string;
  params: Record<string, string> = {};
  session: AuthenticatedSession | undefined;

  constructor(app: App, req: IncomingMessage, res: ServerResponse, url: URL, ip: string) {
    this.app = app;
    this.req = req;
    this.res = res;
    this.url = url;
    this.ip = ip;
  }

  get store(): Store {
    return this.app.store;
  }

  /** Authenticated session; only valid inside handlers registered with `auth: true`. */
  get auth(): AuthenticatedSession {
    if (!this.session) throw new ApiError(401, "UNAUTHORIZED", "Missing or invalid access token.");
    return this.session;
  }

  json(status: number, body: unknown): void {
    const payload = Buffer.from(JSON.stringify(body), "utf8");
    this.res.writeHead(status, {
      ...BASE_HEADERS,
      "Content-Type": "application/json; charset=utf-8",
      "Content-Length": payload.length,
    });
    this.res.end(payload);
  }

  async readJson(options: { allowEmpty?: boolean } = {}): Promise<JsonObject> {
    const raw = await readBody(this.req, LIMITS.maxJsonBodyBytes);
    if (raw.length === 0 && options.allowEmpty) return {};
    return parseJsonObject(raw);
  }
}

/** Reads a request body, rejecting (without destroying the socket) once it exceeds `limit`. */
export function readBody(req: IncomingMessage, limit: number): Promise<Buffer> {
  const declared = req.headers["content-length"];
  if (declared !== undefined) {
    if (!/^\d+$/.test(declared)) return Promise.reject(validationError("Invalid Content-Length."));
    if (Number(declared) > limit) {
      return Promise.reject(validationError(`Request body exceeds ${limit} bytes.`));
    }
  }
  return new Promise<Buffer>((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    const cleanup = (): void => {
      req.off("data", onData);
      req.off("end", onEnd);
      req.off("error", onError);
      req.off("aborted", onAborted);
    };
    const onData = (chunk: Buffer): void => {
      size += chunk.length;
      if (size > limit) {
        cleanup();
        req.pause();
        reject(validationError(`Request body exceeds ${limit} bytes.`));
        return;
      }
      chunks.push(chunk);
    };
    const onEnd = (): void => {
      cleanup();
      resolve(Buffer.concat(chunks));
    };
    const onError = (error: Error): void => {
      cleanup();
      reject(error);
    };
    const onAborted = (): void => {
      cleanup();
      reject(new Error("request aborted"));
    };
    req.on("data", onData);
    req.on("end", onEnd);
    req.on("error", onError);
    req.on("aborted", onAborted);
  });
}

/** True while the client may still be sending a request body we have not consumed. */
export function hasUnreadBody(req: IncomingMessage): boolean {
  if (req.complete) return false;
  if (req.headers["transfer-encoding"] !== undefined) return true;
  return Number(req.headers["content-length"] ?? 0) > 0;
}

/**
 * After an early error response while the client is still uploading, keep
 * reading (and discarding) a bounded amount so the client can read our reply.
 */
export function drainAndClose(req: IncomingMessage, res: ServerResponse, maxBytes = 64 * 1024 * 1024): void {
  if (!hasUnreadBody(req)) return;
  let seen = 0;
  const socket = req.socket;
  const timer = setTimeout(() => socket.destroy(), 15_000);
  timer.unref();
  const done = (): void => {
    clearTimeout(timer);
    req.off("data", onData);
  };
  const onData = (chunk: Buffer): void => {
    seen += chunk.length;
    if (seen > maxBytes) {
      done();
      socket.destroy();
    }
  };
  req.on("data", onData);
  req.once("end", done);
  req.once("error", done);
  res.once("close", done);
  req.resume();
}
