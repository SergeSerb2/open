import path from "node:path";

export interface Config {
  host: string;
  port: number;
  dataDir: string;
  maxAccountBlobBytes: number;
  accessTokenTtlMs: number;
  refreshTokenTtlMs: number;
  /** Requests per minute per IP on /v1/auth/*. 0 disables the limiter. */
  authRateLimit: number;
  /** Trust X-Forwarded-For for the rate-limit client address (reverse proxy deployments). */
  trustProxy: boolean;
  /** WebSocket heartbeat ping interval. */
  wsPingIntervalMs: number;
}

function intEnv(
  env: NodeJS.ProcessEnv,
  name: string,
  fallback: number,
  min: number,
  max: number,
): number {
  const raw = env[name];
  if (raw === undefined || raw.trim() === "") return fallback;
  if (!/^\d+$/.test(raw.trim())) {
    throw new Error(`${name} must be a non-negative integer, got "${raw}"`);
  }
  const value = Number(raw.trim());
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw new Error(`${name} must be between ${min} and ${max}, got "${raw}"`);
  }
  return value;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const hasPlatformPort = (env["PORT"] ?? "").trim() !== "";
  const host = (env["OPEN_SYNC_HOST"] ?? "").trim() || (hasPlatformPort ? "0.0.0.0" : "127.0.0.1");
  const defaultPort = intEnv(env, "PORT", 8787, 0, 65535);
  return {
    host,
    port: intEnv(env, "OPEN_SYNC_PORT", defaultPort, 0, 65535),
    dataDir: path.resolve((env["OPEN_SYNC_DATA_DIR"] ?? "").trim() || "./data"),
    maxAccountBlobBytes: intEnv(
      env,
      "OPEN_SYNC_MAX_ACCOUNT_BLOB_BYTES",
      262_144_000,
      1,
      Number.MAX_SAFE_INTEGER,
    ),
    accessTokenTtlMs: intEnv(
      env,
      "OPEN_SYNC_ACCESS_TOKEN_TTL_MS",
      60 * 60 * 1000,
      1,
      365 * 24 * 60 * 60 * 1000,
    ),
    refreshTokenTtlMs: intEnv(
      env,
      "OPEN_SYNC_REFRESH_TOKEN_TTL_MS",
      30 * 24 * 60 * 60 * 1000,
      1,
      5 * 365 * 24 * 60 * 60 * 1000,
    ),
    authRateLimit: intEnv(env, "OPEN_SYNC_AUTH_RATE_LIMIT", 120, 0, 1_000_000),
    trustProxy: ["1", "true", "yes"].includes((env["OPEN_SYNC_TRUST_PROXY"] ?? "").toLowerCase()),
    wsPingIntervalMs: intEnv(env, "OPEN_SYNC_WS_PING_INTERVAL_MS", 30_000, 50, 3_600_000),
  };
}
