# Open Sync Server

Self-hosted, zero-knowledge sync server for the Open browser. It implements
[`docs/sync-protocol.md`](../docs/sync-protocol.md) (protocol v1) exactly.

- The server only ever sees ciphertext. Passwords, vault keys and plaintext data
  never leave the client. The server stores `scrypt(authVerifier)`, not the verifier.
- **No runtime dependencies.** Node.js 22.13+ only: `node:http`, `node:crypto`,
  `node:sqlite`, `node:fs`. The WebSocket server is a small RFC 6455 implementation
  in `src/ws.ts`.
- One process, one SQLite file (WAL) plus a directory of encrypted blob files.

## One-prompt setup (AI coding agent)

Paste this prompt into **Claude Code, Cursor, Codex, Antigravity, T3 Code, Windsurf**, or any AI coding agent to have it deploy your own private Open Sync Server and hand you back your `https://...` URL (also available via **Copy Agent Prompt** inside **Open ▸ Settings ▸ Account & Sync**):

```text
Set up a private Open Sync Server for my Open browser from https://github.com/SergeSerb2/open (the `SyncServer/` folder).

First, check which deployment tools I already have authenticated (such as `railway`, `flyctl`, `docker`, or `node`), or ask me where I want to host it:
- Railway (recommended easiest cloud setup)
- Fly.io
- Render
- Docker on a VPS / NAS / home server
- Local Mac (optionally over Tailscale)

Requirements:
1. Build and run `SyncServer/` using its `Dockerfile` (zero runtime dependencies, Node.js 22+ built-in SQLite + WebSockets). Do not modify server code unless required.
2. Run a single instance/replica only (SQLite WAL uses one writer).
3. Attach persistent storage mounted at `/data` and set `OPEN_SYNC_DATA_DIR=/data`.
   - On Railway: also set `RAILWAY_RUN_UID=0` (the entrypoint fixes `/data` ownership and drops back to unprivileged `node`).
   - Railway/Fly/Render `PORT` is supported automatically when `OPEN_SYNC_PORT` is unset.
4. Expose HTTPS with WebSocket upgrades forwarded on `/v1/sync/ws`, and set `OPEN_SYNC_TRUST_PROXY=1` whenever behind a reverse proxy or cloud edge.
5. Verify the live server before finishing:
   - `GET <url>/health` returns HTTP 200 with `{"ok":true,"service":"open-sync","version":1}`
   - Confirm `/v1/sync/ws` reaches the server (an unauthenticated upgrade returns HTTP 401, not 404/502)
   - Leave the database clean (delete any temporary test account).
6. Reply with my final `https://...` server URL so I can paste it into Open -> Settings -> Account & Sync -> Sync server.
```

## Quick start (manual)

```sh
cd SyncServer
npm install                      # dev only: @types/node
npx --yes tsrs -p tsconfig.json  # type-check + emit dist/ (tsrs, not tsc)
OPEN_SYNC_DATA_DIR=./data node --no-warnings dist/index.js
# stdout: OPEN_SYNC_LISTENING {"host":"127.0.0.1","port":8787}
```

`--no-warnings` only hides Node's "SQLite is experimental" notice.

### Docker

```sh
docker compose up -d --build     # listens on 127.0.0.1:8787, data in the open-sync-data volume
```

The image runs as the unprivileged `node` user and has a `/health` healthcheck.
If started as root (for example with `RAILWAY_RUN_UID=0` on a Railway volume),
the entrypoint fixes ownership on `OPEN_SYNC_DATA_DIR` and drops privileges to
`node` via `setpriv` before `exec`ing Node.

### Railway

`railway.toml` configures a Dockerfile build with `/health` healthchecks. Mount
a persistent volume at `/data` and set `OPEN_SYNC_DATA_DIR=/data`,
`OPEN_SYNC_TRUST_PROXY=1`, and `RAILWAY_RUN_UID=0`. Railway's `PORT` variable is
honored automatically when `OPEN_SYNC_PORT` is unset.

### TLS

The server speaks plain HTTP. Always put it behind a TLS-terminating reverse proxy
when it is reachable from outside your machine, and forward WebSocket upgrades on
`/v1/sync/ws`. Set `OPEN_SYNC_TRUST_PROXY=1` so the rate limiter uses the
`X-Forwarded-For` address (the last entry, appended by your proxy) instead of the
proxy's address. Do not set it when the server is directly exposed.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `OPEN_SYNC_HOST` | `127.0.0.1` | Bind address. |
| `OPEN_SYNC_PORT` | `8787` | Port. `0` picks an ephemeral port; the real one is printed (see below). |
| `OPEN_SYNC_DATA_DIR` | `./data` | Holds `open-sync.sqlite` and `blobs/<accountId>/<blobId>`. |
| `OPEN_SYNC_MAX_ACCOUNT_BLOB_BYTES` | `262144000` (250 MiB) | Total blob quota per account. |
| `OPEN_SYNC_ACCESS_TOKEN_TTL_MS` | `3600000` (1 h) | Access token lifetime. |
| `OPEN_SYNC_REFRESH_TOKEN_TTL_MS` | `2592000000` (30 d) | Refresh token lifetime (renewed on every rotation). |
| `OPEN_SYNC_AUTH_RATE_LIMIT` | `120` | Max requests per minute per IP on `/v1/auth/*`. `0` disables. |
| `OPEN_SYNC_TRUST_PROXY` | off | Use `X-Forwarded-For` for the client IP. |
| `OPEN_SYNC_WS_PING_INTERVAL_MS` | `30000` | WebSocket heartbeat interval. A client that sends nothing for two intervals is dropped. |

Once listening, the server prints exactly one machine-readable line on stdout:

```
OPEN_SYNC_LISTENING {"host":"127.0.0.1","port":54321}
```

Logs go to stderr. `SIGINT`/`SIGTERM` close WebSockets (code 1001), stop the HTTP
server, checkpoint and close SQLite, then exit 0 (forced exit after 10 s).

## Layout

| File | Role |
|---|---|
| `src/index.ts` | CLI entry, signal handling. |
| `src/config.ts` | Environment parsing. |
| `src/server.ts` | Router, auth, WebSocket upgrade, lifecycle. |
| `src/auth.ts`, `account.ts`, `sync.ts`, `blobs.ts` | Endpoint handlers. |
| `src/db.ts` | SQLite schema and all queries; `BEGIN IMMEDIATE` transactions. |
| `src/validation.ts` | Strict request validation and all hard limits. |
| `src/security.ts` | scrypt verifier hashing, token hashing, dummy KDF salt. |
| `src/rateLimit.ts` | Sliding-window limiter. |
| `src/ws.ts` | RFC 6455 server and connection hub. |
| `scripts/e2e-server-test.mjs` | Real end-to-end test (see below). |

Tables: `server_meta`, `accounts`, `devices`, `sessions`, `recovery_tickets`,
`sync_records`, `sync_blobs`. Tokens and recovery tickets are stored only as
SHA-256 hashes. The 32-byte HMAC secret for the non-enumerating `kdf-params`
response is created on first start and kept in `server_meta`, so dummy salts
survive restarts.

## Behaviour that the protocol leaves open

These choices are made by this server. Clients should not depend on more than the
protocol text, but they are stable:

- **Revisions** are per account and advance by one for each *accepted* mutation.
  `replaceCloud` advances the revision once for the wipe (that value becomes
  `resetRevision`) and then once per inserted record. `nextSince` is the last
  returned revision when `hasMore` is true, otherwise `currentRevision`.
- **Last-writer-wins**: a mutation is a conflict when its `clientUpdatedAt` is lower
  than the stored one. Equal timestamps are accepted. An exact replay of the stored
  record is accepted without consuming a revision.
- **`fullResyncRequired`** is also returned when `since` is greater than
  `currentRevision` (for example after a server restore).
- A `/v1/sync/changes` page is capped at 8 MiB of ciphertext (at least one record is
  always returned); use `hasMore`/`nextSince`.
- `hasCloudData` and `collectionCounts` count live records only, not tombstones.
- `recordId` is validated with the section 3 regex only, not per collection.
- Bodies over 8 MiB and blobs over 20 MiB get `400 VALIDATION_ERROR`
  (section 3). A blob over the account quota gets `413 QUOTA_EXCEEDED`.
- `deviceId` in `push` must equal the authenticated device. IDs are stored and
  echoed exactly as sent (case preserved).
- A new login from a device ID revokes that device's older sessions. Refresh,
  change-password (`revokeOtherSessions`, default `true`), recovery, logout and
  device removal close the affected WebSockets with code `4001` `session_revoked`.
- Access tokens from a rotated refresh token stay valid until their own expiry;
  reusing a rotated *refresh* token revokes the whole family.
- Extra error codes: `UNAUTHORIZED` (401), `INVALID_REFRESH_TOKEN` (401),
  `INVALID_RECOVERY_TICKET` (401), `NOT_FOUND` (404), `METHOD_NOT_ALLOWED` (405),
  `DEVICE_LIMIT_REACHED` (409), `QUOTA_EXCEEDED` (413), `RATE_LIMITED` (429, with
  `Retry-After`), `INTERNAL_ERROR` (500).
- `DELETE /v1/account/devices/:deviceId` returns `{ "ok": true, "removed": false }`
  for an unknown device.

## End-to-end test

The test spawns the real compiled server on an ephemeral port with a temporary data
directory, then drives it over real HTTP and WebSocket connections with client-side
PBKDF2, HKDF and AES-256-GCM written from the protocol document. It also runs a
hand-written RFC 6455 client for protocol edge cases, plus extra server instances
for quotas, token expiry, restart persistence and rate limiting. It removes all
temp files and processes when it ends.

```sh
npx --yes tsrs -p SyncServer/tsconfig.json
node SyncServer/scripts/e2e-server-test.mjs
```

There are no unit tests by design.
