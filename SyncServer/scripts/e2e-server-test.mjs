#!/usr/bin/env node
/**
 * Real end-to-end test for the Open Sync Server.
 *
 * Spawns the REAL compiled server (`node --no-warnings dist/index.js`) on an
 * ephemeral port with a temporary data directory, then drives it over real HTTP
 * and WebSocket connections using client-side crypto written from
 * docs/sync-protocol.md (PBKDF2 / HKDF / AES-256-GCM). No mocks.
 *
 * Usage: node SyncServer/scripts/e2e-server-test.mjs   (after building dist/)
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import crypto from "node:crypto";
import { existsSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

process.removeAllListeners("warning"); // node:sqlite prints an ExperimentalWarning on first load
const here = path.dirname(fileURLToPath(import.meta.url));
const serverEntry = path.resolve(here, "../dist/index.js");
if (!existsSync(serverEntry)) {
  console.error(`Missing ${serverEntry}. Build first: npx tsrs -p SyncServer/tsconfig.json`);
  process.exit(2);
}

// ---------------------------------------------------------------------------
// Tiny test harness
// ---------------------------------------------------------------------------
const results = [];
let currentSection = "";
async function step(name, fn) {
  const started = Date.now();
  try {
    await fn();
    results.push({ name, ok: true, ms: Date.now() - started });
    console.log(`  PASS  ${name} (${Date.now() - started} ms)`);
  } catch (error) {
    results.push({ name, ok: false, ms: Date.now() - started, error });
    console.log(`  FAIL  ${name}`);
    console.log(String(error?.stack ?? error).split("\n").map((l) => `        ${l}`).join("\n"));
    throw new Error(`step failed: ${name}`);
  }
}
function section(title) {
  currentSection = title;
  console.log(`\n== ${title}`);
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ---------------------------------------------------------------------------
// Client-side crypto (docs/sync-protocol.md section 1)
// ---------------------------------------------------------------------------
const utf8 = (s) => Buffer.from(s, "utf8");
const hkdf = (ikm, info) => Buffer.from(crypto.hkdfSync("sha256", ikm, Buffer.alloc(0), utf8(info), 32));
const normalizeEmail = (email) => email.trim().toLowerCase();

const masterKeyCache = new Map();
function deriveMasterKey(password, email, kdfSalt, iterations) {
  const cacheKey = [password, email, kdfSalt.toString("hex"), iterations].join("\u0000");
  let key = masterKeyCache.get(cacheKey);
  if (!key) {
    const salt = Buffer.concat([kdfSalt, utf8("open-sync-v1:"), utf8(email)]);
    key = crypto.pbkdf2Sync(utf8(password), salt, iterations, 32, "sha256");
    masterKeyCache.set(cacheKey, key);
  }
  return key;
}
function passwordKeys(password, email, kdfSalt, iterations) {
  const master = deriveMasterKey(password, email, kdfSalt, iterations);
  return { authKey: hkdf(master, "open-sync-auth-v1"), passwordWrapKey: hkdf(master, "open-sync-wrap-v1") };
}
function recoveryKeys(recoveryKeyBytes) {
  return {
    recoveryAuthKey: hkdf(recoveryKeyBytes, "open-sync-recovery-auth-v1"),
    recoveryWrapKey: hkdf(recoveryKeyBytes, "open-sync-recovery-wrap-v1"),
  };
}
function vaultKeys(vaultKey) {
  return {
    recordEncKey: hkdf(vaultKey, "open-sync-record-enc-v1"),
    blobEncKey: hkdf(vaultKey, "open-sync-blob-enc-v1"),
    payloadHashKey: hkdf(vaultKey, "open-sync-payload-hash-v1"),
    blobIdKey: hkdf(vaultKey, "open-sync-blob-id-v1"),
  };
}
/** nonce(12) || ciphertext || tag(16) */
function gcmSeal(key, plaintext, aad) {
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", key, nonce);
  cipher.setAAD(utf8(aad));
  const ct = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return Buffer.concat([nonce, ct, cipher.getAuthTag()]);
}
function gcmOpen(key, combined, aad) {
  const nonce = combined.subarray(0, 12);
  const tag = combined.subarray(combined.length - 16);
  const ct = combined.subarray(12, combined.length - 16);
  const decipher = crypto.createDecipheriv("aes-256-gcm", key, nonce);
  decipher.setAAD(utf8(aad));
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(ct), decipher.final()]);
}

const B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
function base32Encode(bytes) {
  let bits = 0;
  let value = 0;
  let out = "";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += B32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31];
  return out;
}
function base32Decode(text) {
  let bits = 0;
  let value = 0;
  const out = [];
  for (const ch of text) {
    const idx = B32.indexOf(ch);
    assert.ok(idx >= 0, `bad base32 char ${ch}`);
    value = (value << 5) | idx;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 255);
      bits -= 8;
    }
  }
  assert.equal(value & ((1 << bits) - 1), 0, "non-zero padding bits");
  return Buffer.from(out);
}
function formatRecoveryKey(bytes) {
  const b32 = base32Encode(bytes);
  assert.equal(b32.length, 52);
  return `OPEN-${b32.match(/.{4}/g).join("-")}`;
}
function parseRecoveryKey(text) {
  let cleaned = text.replace(/[\s-]/g, "").toUpperCase();
  if (cleaned.startsWith("OPEN")) cleaned = cleaned.slice(4);
  assert.equal(cleaned.length, 52, "recovery key must be 52 base32 chars");
  const bytes = base32Decode(cleaned);
  assert.equal(bytes.length, 32);
  return bytes;
}

const b64 = (buf) => Buffer.from(buf).toString("base64");
const fromB64 = (s) => Buffer.from(s, "base64");

function wrapAad(kind, email) {
  return `open-sync-v1|${kind}|${email}`;
}
function recordAad(accountId, collection, recordId, deleted) {
  return `open-sync-v1|rec|${accountId}|${collection}|${recordId}|${deleted ? "1" : "0"}`;
}
function blobAad(accountId, blobId) {
  return `open-sync-v1|blob|${accountId}|${blobId}`;
}

/** Builds everything a fresh client needs for registration. */
function newAccountMaterial(password, rawEmail, iterations = 600000) {
  const email = normalizeEmail(rawEmail);
  const kdfSalt = crypto.randomBytes(32);
  const vaultKey = crypto.randomBytes(32);
  const recoveryKeyBytes = crypto.randomBytes(32);
  const pw = passwordKeys(password, email, kdfSalt, iterations);
  const rec = recoveryKeys(recoveryKeyBytes);
  return {
    email,
    password,
    iterations,
    kdfSalt,
    vaultKey,
    vault: vaultKeys(vaultKey),
    recoveryKeyBytes,
    recoveryKeyString: formatRecoveryKey(recoveryKeyBytes),
    authKey: pw.authKey,
    passwordWrapKey: pw.passwordWrapKey,
    recoveryAuthKey: rec.recoveryAuthKey,
    recoveryWrapKey: rec.recoveryWrapKey,
    wrappedByPassword: gcmSeal(pw.passwordWrapKey, vaultKey, wrapAad("vault-pw", email)),
    wrappedByRecovery: gcmSeal(rec.recoveryWrapKey, vaultKey, wrapAad("vault-rec", email)),
  };
}
const kdfParamsJson = (m) => ({ algorithm: "pbkdf2-sha256", iterations: m.iterations, saltBase64: b64(m.kdfSalt) });

// ---------------------------------------------------------------------------
// Server process management
// ---------------------------------------------------------------------------
async function startServer(extraEnv = {}, dataDir) {
  const tmp = dataDir ?? (await mkdtemp(path.join(os.tmpdir(), "open-sync-e2e-")));
  const env = {
    PATH: process.env.PATH,
    HOME: process.env.HOME,
    OPEN_SYNC_HOST: "127.0.0.1",
    OPEN_SYNC_PORT: "0",
    OPEN_SYNC_DATA_DIR: tmp,
    ...extraEnv,
  };
  const proc = spawn(process.execPath, ["--no-warnings", serverEntry], { env, stdio: ["ignore", "pipe", "pipe"] });
  let stderr = "";
  proc.stderr.on("data", (d) => (stderr += d));
  const exited = new Promise((resolve) => proc.once("exit", (code, signal) => resolve({ code, signal })));
  const info = await new Promise((resolve, reject) => {
    let buf = "";
    const timer = setTimeout(() => reject(new Error(`server did not start. stderr: ${stderr}`)), 15000);
    proc.stdout.on("data", (d) => {
      buf += d;
      const m = /OPEN_SYNC_LISTENING (\{.*\})/.exec(buf);
      if (m) {
        clearTimeout(timer);
        resolve(JSON.parse(m[1]));
      }
    });
    proc.once("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`server exited early (${code}). stderr: ${stderr}`));
    });
  });
  return {
    proc,
    dataDir: tmp,
    host: info.host,
    port: info.port,
    base: `http://${info.host}:${info.port}`,
    stderr: () => stderr,
    exited,
    async stop() {
      if (proc.exitCode === null && proc.signalCode === null) proc.kill("SIGTERM");
      return Promise.race([exited, sleep(8000).then(() => ({ code: "timeout" }))]);
    },
  };
}

let main; // primary server
const extraServers = [];

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------
async function api(server, method, pathname, { token, body, raw, headers = {} } = {}) {
  const h = { ...headers };
  if (token) h["Authorization"] = `Bearer ${token}`;
  let payload;
  if (raw !== undefined) {
    payload = raw;
  } else if (body !== undefined) {
    h["Content-Type"] = "application/json";
    payload = typeof body === "string" ? body : JSON.stringify(body);
  }
  const res = await fetch(server.base + pathname, { method, headers: h, body: payload });
  const bytes = Buffer.from(await res.arrayBuffer());
  let json;
  const type = res.headers.get("content-type") ?? "";
  if (type.includes("application/json") && bytes.length > 0) json = JSON.parse(bytes.toString("utf8"));
  return { status: res.status, headers: res.headers, json, bytes };
}
function assertError(res, status, code) {
  assert.equal(res.status, status, `expected HTTP ${status}, got ${res.status}: ${res.bytes.toString("utf8").slice(0, 300)}`);
  assert.equal(res.json?.error?.code, code, `expected error code ${code}, got ${JSON.stringify(res.json)}`);
  assert.equal(typeof res.json.error.message, "string");
  assertSecurityHeaders(res);
}
function assertSecurityHeaders(res) {
  assert.equal(res.headers.get("x-content-type-options"), "nosniff");
  assert.equal(res.headers.get("cache-control"), "no-store");
}

// ---------------------------------------------------------------------------
// A "device": one signed-in client with its own tokens and keys
// ---------------------------------------------------------------------------
class Device {
  constructor(label, server) {
    this.label = label;
    this.server = server;
    this.wireId = crypto.randomUUID().toUpperCase(); // what the client sends: Swift's UUID().uuidString casing
    this.deviceId = this.wireId.toLowerCase(); // what the server stores and returns (canonical lowercase)
    this.deviceName = `${label} (e2e)`;
  }
  get auth() {
    return { token: this.accessToken };
  }
  adopt(session) {
    this.accountId = session.accountId;
    this.accessToken = session.accessToken;
    this.refreshToken = session.refreshToken;
    this.accessExpiresAt = session.accessTokenExpiresAt;
  }
  async register(material, displayName) {
    this.material = material;
    const res = await api(this.server, "POST", "/v1/auth/register", {
      body: {
        email: ` ${material.email.toUpperCase()} `, // server must normalize (trim + lowercase)
        displayName,
        kdfParams: kdfParamsJson(material),
        authVerifier: b64(material.authKey),
        recoveryAuthVerifier: b64(material.recoveryAuthKey),
        wrappedVaultKeyByPassword: b64(material.wrappedByPassword),
        wrappedVaultKeyByRecovery: b64(material.wrappedByRecovery),
        deviceId: this.wireId,
        deviceName: this.deviceName,
        platform: "macos",
      },
    });
    return res;
  }
  /** Full client sign-in: kdf-params -> PBKDF2/HKDF -> login -> unwrap vault key. */
  async signIn(email, password) {
    const kdfRes = await api(this.server, "POST", "/v1/auth/kdf-params", { body: { email } });
    assert.equal(kdfRes.status, 200);
    const params = kdfRes.json.kdfParams;
    const normalized = normalizeEmail(email);
    const keys = passwordKeys(password, normalized, fromB64(params.saltBase64), params.iterations);
    const res = await api(this.server, "POST", "/v1/auth/login", {
      body: {
        email,
        authVerifier: b64(keys.authKey),
        deviceId: this.wireId,
        deviceName: this.deviceName,
        platform: "macos",
      },
    });
    if (res.status !== 200) return { res };
    this.adopt(res.json);
    this.email = normalized;
    this.vaultKey = gcmOpen(keys.passwordWrapKey, fromB64(res.json.wrappedVaultKeyByPassword), wrapAad("vault-pw", normalized));
    this.vault = vaultKeys(this.vaultKey);
    return { res, keys };
  }
  seal(collection, recordId, deleted, plaintextObject) {
    const pt = deleted ? utf8('{"t":1}') : utf8(JSON.stringify(plaintextObject));
    return b64(gcmSeal(this.vault.recordEncKey, pt, recordAad(this.accountId, collection, recordId, deleted)));
  }
  mutation(collection, recordId, plaintextObject, clientUpdatedAt, deleted = false) {
    return {
      collection,
      recordId,
      deleted,
      clientUpdatedAt,
      ciphertext: this.seal(collection, recordId, deleted, plaintextObject),
    };
  }
  open(record) {
    const pt = gcmOpen(
      this.vault.recordEncKey,
      fromB64(record.ciphertext),
      recordAad(this.accountId, record.collection, record.recordId, record.deleted),
    );
    return JSON.parse(pt.toString("utf8"));
  }
  push(mutations, { mode = "delta", baseRevision = 0, extra = {} } = {}) {
    return api(this.server, "POST", "/v1/sync/push", {
      ...this.auth,
      body: { deviceId: this.wireId, mode, baseRevision, mutations, ...extra },
    });
  }
  changes(query = "") {
    return api(this.server, "GET", `/v1/sync/changes${query}`, this.auth);
  }
  /** Pulls everything after `since`, following pagination. */
  async pullAll(since = 0, limit = 200) {
    const records = [];
    let cursor = since;
    let first;
    for (let i = 0; i < 100; i += 1) {
      const res = await this.changes(`?since=${cursor}&limit=${limit}`);
      assert.equal(res.status, 200, JSON.stringify(res.json));
      first ??= res.json;
      records.push(...res.json.records);
      cursor = res.json.nextSince;
      if (!res.json.hasMore) return { records, first, last: res.json };
    }
    throw new Error("pagination did not terminate");
  }
}

// ---------------------------------------------------------------------------
// WebSocket helpers
// ---------------------------------------------------------------------------
function openWs(server, device, { token = device.accessToken, headers = {} } = {}) {
  const ws = new WebSocket(`ws://${server.host}:${server.port}/v1/sync/ws`, {
    headers: { Authorization: `Bearer ${token}`, "X-Open-Device-Id": device.wireId ?? device.deviceId, ...headers },
  });
  const messages = [];
  let notify = () => {};
  ws.addEventListener("message", (ev) => {
    messages.push(JSON.parse(String(ev.data)));
    notify();
  });
  const closed = new Promise((resolve) =>
    ws.addEventListener("close", (ev) => {
      resolve({ code: ev.code, reason: ev.reason });
      notify();
    }),
  );
  const opened = new Promise((resolve, reject) => {
    ws.addEventListener("open", () => resolve());
    ws.addEventListener("error", () => reject(new Error("websocket error before open")));
  });
  const api = {
    ws,
    messages,
    opened,
    closed,
    async waitFor(predicate, timeoutMs = 5000) {
      const deadline = Date.now() + timeoutMs;
      for (;;) {
        const idx = messages.findIndex(predicate);
        if (idx >= 0) return messages.splice(idx, 1)[0];
        const remaining = deadline - Date.now();
        if (remaining <= 0) throw new Error(`timed out waiting for websocket message; have ${JSON.stringify(messages)}`);
        await new Promise((resolve) => {
          notify = resolve;
          setTimeout(resolve, Math.min(remaining, 100));
        });
      }
    },
    async expectNone(predicate, windowMs = 400) {
      await sleep(windowMs);
      assert.equal(messages.findIndex(predicate), -1, `unexpected websocket message: ${JSON.stringify(messages)}`);
    },
    async waitClosed(timeoutMs = 5000) {
      return Promise.race([closed, sleep(timeoutMs).then(() => Promise.reject(new Error("websocket did not close")))]);
    },
  };
  return api;
}

/** Hand-rolled RFC 6455 client over a raw TCP socket, for protocol edge cases. */
async function rawWs(server, { token, deviceId, key, extraHeaders = [], version = "13", path: wsPath = "/v1/sync/ws" } = {}) {
  const socket = net.connect(server.port, server.host);
  await new Promise((resolve, reject) => {
    socket.once("connect", resolve);
    socket.once("error", reject);
  });
  const clientKey = key ?? crypto.randomBytes(16).toString("base64");
  const lines = [
    `GET ${wsPath} HTTP/1.1`,
    `Host: ${server.host}:${server.port}`,
    "Upgrade: websocket",
    "Connection: Upgrade",
    `Sec-WebSocket-Key: ${clientKey}`,
    `Sec-WebSocket-Version: ${version}`,
    ...(token ? [`Authorization: Bearer ${token}`] : []),
    ...(deviceId ? [`X-Open-Device-Id: ${deviceId}`] : []),
    ...extraHeaders,
    "",
    "",
  ];
  socket.write(lines.join("\r\n"));
  let buffer = Buffer.alloc(0);
  let ended = false;
  let wake = () => {};
  socket.on("data", (d) => {
    buffer = Buffer.concat([buffer, d]);
    wake();
  });
  socket.on("close", () => {
    ended = true;
    wake();
  });
  socket.on("error", () => {});
  const waitData = (ms) => new Promise((resolve) => { wake = resolve; setTimeout(resolve, ms); });

  // Read HTTP response head.
  const deadline = Date.now() + 5000;
  while (buffer.indexOf("\r\n\r\n") < 0) {
    if (ended || Date.now() > deadline) break;
    await waitData(100);
  }
  const headEnd = buffer.indexOf("\r\n\r\n");
  assert.ok(headEnd >= 0, "no HTTP response head");
  const head = buffer.subarray(0, headEnd).toString("utf8");
  buffer = buffer.subarray(headEnd + 4);
  const status = Number(/^HTTP\/1\.1 (\d{3})/.exec(head)?.[1]);
  const headers = Object.fromEntries(
    head.split("\r\n").slice(1).map((l) => [l.slice(0, l.indexOf(":")).toLowerCase(), l.slice(l.indexOf(":") + 1).trim()]),
  );

  const client = {
    status,
    headers,
    headText: head,
    body: () => buffer.toString("utf8"),
    socket,
    get ended() { return ended; },
    send(opcode, payload = Buffer.alloc(0), { mask = true, fin = true, rsv = 0, declaredLength } = {}) {
      const len = declaredLength ?? payload.length;
      let header;
      if (len < 126) header = Buffer.from([(fin ? 0x80 : 0) | rsv | opcode, (mask ? 0x80 : 0) | len]);
      else if (len <= 0xffff) {
        header = Buffer.alloc(4);
        header[0] = (fin ? 0x80 : 0) | rsv | opcode;
        header[1] = (mask ? 0x80 : 0) | 126;
        header.writeUInt16BE(len, 2);
      } else {
        header = Buffer.alloc(10);
        header[0] = (fin ? 0x80 : 0) | rsv | opcode;
        header[1] = (mask ? 0x80 : 0) | 127;
        header.writeBigUInt64BE(BigInt(len), 2);
      }
      let body = payload;
      const parts = [header];
      if (mask) {
        const m = crypto.randomBytes(4);
        parts.push(m);
        body = Buffer.from(payload);
        for (let i = 0; i < body.length; i += 1) body[i] ^= m[i & 3];
      }
      parts.push(body);
      socket.write(Buffer.concat(parts));
    },
    sendText(text, opts) {
      client.send(0x1, utf8(text), opts);
    },
    async nextFrame(timeoutMs = 3000) {
      const end = Date.now() + timeoutMs;
      for (;;) {
        if (buffer.length >= 2) {
          const b0 = buffer[0];
          const b1 = buffer[1];
          assert.equal(b1 & 0x80, 0, "server frames must not be masked");
          let len = b1 & 0x7f;
          let off = 2;
          if (len === 126 && buffer.length >= 4) { len = buffer.readUInt16BE(2); off = 4; }
          else if (len === 127 && buffer.length >= 10) { len = Number(buffer.readBigUInt64BE(2)); off = 10; }
          else if (len === 126 || len === 127) { /* need more bytes */ len = -1; }
          if (len >= 0 && buffer.length >= off + len) {
            const frame = { fin: (b0 & 0x80) !== 0, opcode: b0 & 0x0f, payload: buffer.subarray(off, off + len) };
            buffer = buffer.subarray(off + len);
            return frame;
          }
        }
        if (ended && buffer.length === 0) return undefined;
        if (Date.now() > end) throw new Error("timed out waiting for websocket frame");
        await waitData(100);
      }
    },
    /** Next frame that is not a heartbeat ping (auto-answers pings optionally). */
    async nextDataFrame(timeoutMs = 3000) {
      for (;;) {
        const f = await client.nextFrame(timeoutMs);
        if (f && f.opcode === 0x9) continue;
        return f;
      }
    },
    async waitEnded(timeoutMs = 4000) {
      const end = Date.now() + timeoutMs;
      while (!ended && Date.now() < end) await waitData(100);
      return ended;
    },
    destroy() {
      socket.destroy();
    },
  };
  return client;
}
const closeCodeOf = (frame) => (frame.payload.length >= 2 ? frame.payload.readUInt16BE(0) : 1005);

// ---------------------------------------------------------------------------
// The test run
// ---------------------------------------------------------------------------
const PASSWORD = "correct horse battery staple";
const NEW_PASSWORD = "Tr0ub4dor&3-new-password";
const RECOVERED_PASSWORD = "after-recovery-passphrase-42";
const EMAIL_RAW = "  Alex.E2E+Sync@Example.COM ";
const EMAIL = normalizeEmail(EMAIL_RAW);

const uuid = () => crypto.randomUUID().toUpperCase();
const SPACE_ID = uuid();
const SPACE2_ID = uuid();
const PROFILE_ID = uuid();
const EASEL_ID = uuid();
const TODAY_ID = uuid();
const BOOST_ID = `${PROFILE_ID}:${uuid()}`;

const T0 = 1_795_450_000_000;

const spaceV1 = { name: "Work", icon: "briefcase", pinned: [{ id: "t1", url: "https://example.com/日本語" }], unicode: "héllo ✓ 🙂" };
const metaV1 = { profileIDs: [PROFILE_ID], spaceIDs: [SPACE_ID], defaultDestination: "space" };
const prefsV1 = { "open.sidebar.width": 280, "open.theme": "dark" };
const credsV1 = { logins: [{ site: "https://example.com", user: "alex", password: "s3cr3t-☃" }], cards: [] };
const easelV1 = { id: EASEL_ID, blobIds: [], title: "Sketch" };

let A; // account A material
let d1, d2, d3; // devices of account A
let B; // account B material
let bDevice;
let blobPlain, blobId, blobCipher;
let accountA;

async function run() {
  section("Server start-up");
  await step("spawn real server on OPEN_SYNC_PORT=0 and read OPEN_SYNC_LISTENING", async () => {
    // High auth rate limit: this run issues far more than 120 auth calls/min; limiting is tested on its own server below.
    main = await startServer({ OPEN_SYNC_WS_PING_INTERVAL_MS: "300", OPEN_SYNC_AUTH_RATE_LIMIT: "100000" });
    assert.ok(main.port > 0 && main.port < 65536);
    assert.equal(main.host, "127.0.0.1");
  });

  await step("GET /health", async () => {
    const res = await api(main, "GET", "/health");
    assert.equal(res.status, 200);
    assert.deepEqual(res.json, { ok: true, service: "open-sync", version: 1 });
    assertSecurityHeaders(res);
  });

  await step("unknown route -> 404, wrong method -> 405", async () => {
    assertError(await api(main, "GET", "/v1/nope"), 404, "NOT_FOUND");
    const res = await api(main, "GET", "/v1/auth/login");
    assertError(res, 405, "METHOD_NOT_ALLOWED");
    assert.ok((res.headers.get("allow") ?? "").includes("POST"));
  });

  section("Non-enumerating kdf-params");
  await step("unknown email gets a deterministic dummy salt (32 bytes, same across calls, differs per email)", async () => {
    const unknown = "nobody-here@example.com";
    const r1 = await api(main, "POST", "/v1/auth/kdf-params", { body: { email: unknown } });
    const r2 = await api(main, "POST", "/v1/auth/kdf-params", { body: { email: ` ${unknown.toUpperCase()} ` } });
    const r3 = await api(main, "POST", "/v1/auth/kdf-params", { body: { email: "someone-else@example.com" } });
    for (const r of [r1, r2, r3]) {
      assert.equal(r.status, 200);
      assert.equal(r.json.kdfParams.algorithm, "pbkdf2-sha256");
      assert.equal(r.json.kdfParams.iterations, 600000);
      assert.equal(fromB64(r.json.kdfParams.saltBase64).length, 32);
      assertSecurityHeaders(r);
    }
    assert.equal(r1.json.kdfParams.saltBase64, r2.json.kdfParams.saltBase64, "dummy salt must be deterministic + email-normalized");
    assert.notEqual(r1.json.kdfParams.saltBase64, r3.json.kdfParams.saltBase64);
  });

  section("Registration");
  A = newAccountMaterial(PASSWORD, EMAIL_RAW);
  d1 = new Device("Device 1", main);
  await step("register Account A on Device 1 -> 201 with full response shape", async () => {
    const res = await d1.register(A, "Alex");
    assert.equal(res.status, 201, JSON.stringify(res.json));
    assertSecurityHeaders(res);
    const j = res.json;
    assert.deepEqual(
      Object.keys(j).sort(),
      [
        "accessToken", "accessTokenExpiresAt", "accountId", "collectionCounts", "deviceId", "displayName",
        "email", "hasCloudData", "refreshToken", "resetRevision", "serverRevision", "wrappedVaultKeyByPassword",
      ].sort(),
    );
    assert.equal(j.email, EMAIL, "server returns the normalized email");
    assert.equal(j.displayName, "Alex");
    assert.equal(j.deviceId, d1.deviceId, "deviceId is canonicalized to lowercase (client sent uppercase)");
    assert.notEqual(d1.wireId, d1.deviceId);
    assert.equal(j.serverRevision, 0);
    assert.equal(j.resetRevision, 0);
    assert.equal(j.hasCloudData, false);
    assert.deepEqual(j.collectionCounts, {});
    assert.equal(j.wrappedVaultKeyByPassword, b64(A.wrappedByPassword));
    assert.ok(j.accessTokenExpiresAt > Date.now() + 50 * 60 * 1000 && j.accessTokenExpiresAt < Date.now() + 70 * 60 * 1000, "default access TTL ~1h");
    assert.match(j.accessToken, /^[A-Za-z0-9_-]{32,}$/);
    assert.notEqual(j.accessToken, j.refreshToken);
    d1.adopt(j);
    d1.email = EMAIL;
    d1.vaultKey = A.vaultKey;
    d1.vault = A.vault;
    accountA = j.accountId;
  });

  await step("duplicate email (different casing) -> 409 EMAIL_TAKEN", async () => {
    const other = new Device("Imposter", main);
    const res = await other.register(newAccountMaterial("another", EMAIL), "Eve");
    assertError(res, 409, "EMAIL_TAKEN");
  });

  await step("kdf-params for the registered email returns the real salt", async () => {
    const res = await api(main, "POST", "/v1/auth/kdf-params", { body: { email: EMAIL } });
    assert.equal(res.json.kdfParams.saltBase64, b64(A.kdfSalt));
    assert.equal(res.json.kdfParams.iterations, 600000);
  });

  section("Login failures and auth enforcement");
  await step("wrong password -> 401 INVALID_CREDENTIALS (known and unknown email look identical)", async () => {
    const dev = new Device("Attacker", main);
    const wrong = passwordKeys("not the password", EMAIL, A.kdfSalt, 600000);
    const res = await api(main, "POST", "/v1/auth/login", {
      body: { email: EMAIL, authVerifier: b64(wrong.authKey), deviceId: dev.deviceId, deviceName: "x", platform: "macos" },
    });
    assertError(res, 401, "INVALID_CREDENTIALS");
    const res2 = await api(main, "POST", "/v1/auth/login", {
      body: { email: "ghost@example.com", authVerifier: b64(wrong.authKey), deviceId: dev.deviceId, deviceName: "x", platform: "macos" },
    });
    assertError(res2, 401, "INVALID_CREDENTIALS");
    assert.equal(res.json.error.message, res2.json.error.message);
  });

  await step("authenticated endpoints reject missing / garbage / malformed bearer tokens with 401", async () => {
    assertError(await api(main, "GET", "/v1/account"), 401, "UNAUTHORIZED");
    assertError(await api(main, "GET", "/v1/account", { token: "x".repeat(43) }), 401, "UNAUTHORIZED");
    assertError(await api(main, "GET", "/v1/sync/status", { headers: { Authorization: "Basic abc" } }), 401, "UNAUTHORIZED");
    assertError(await api(main, "POST", "/v1/sync/push", { body: {} }), 401, "UNAUTHORIZED");
    assertError(await api(main, "GET", `/v1/blobs/${"a".repeat(64)}`), 401, "UNAUTHORIZED");
  });

  section("Device 1 encrypts and pushes records + blob");
  await step("push records across workspace.meta, workspace.space, settings.preferences, credentials.profile (+ profile, easel, boost)", async () => {
    const mutations = [
      d1.mutation("workspace.meta", "global", metaV1, T0),
      d1.mutation("workspace.space", SPACE_ID, spaceV1, T0 + 1),
      d1.mutation("settings.preferences", "global", prefsV1, T0 + 2),
      d1.mutation("credentials.profile", PROFILE_ID, credsV1, T0 + 3),
      d1.mutation("workspace.profile", PROFILE_ID, { name: "Personal" }, T0 + 4),
      d1.mutation("workspace.today", TODAY_ID, { nodes: [{ id: "tab-1" }] }, T0 + 5),
    ];
    const res = await d1.push(mutations, { baseRevision: 0 });
    assert.equal(res.status, 200, JSON.stringify(res.json));
    assertSecurityHeaders(res);
    assert.deepEqual(res.json, { currentRevision: 6, resetRevision: 0, acceptedCount: 6, conflicts: [] });
  });

  await step("PUT /v1/blobs/:blobId stores an encrypted blob (idempotent); GET/HEAD return it", async () => {
    blobPlain = crypto.randomBytes(150_000);
    blobId = crypto.createHmac("sha256", A.vault.blobIdKey).update(blobPlain).digest("hex");
    blobCipher = gcmSeal(A.vault.blobEncKey, blobPlain, blobAad(accountA, blobId));
    const put = await api(main, "PUT", `/v1/blobs/${blobId}`, { ...d1.auth, raw: blobCipher, headers: { "Content-Type": "application/octet-stream" } });
    assert.equal(put.status, 200, JSON.stringify(put.json));
    assert.deepEqual(put.json, { ok: true, blobId, sizeBytes: blobCipher.length, created: true });
    const again = await api(main, "PUT", `/v1/blobs/${blobId}`, { ...d1.auth, raw: blobCipher, headers: { "Content-Type": "application/octet-stream" } });
    assert.deepEqual(again.json, { ok: true, blobId, sizeBytes: blobCipher.length, created: false });

    const head = await api(main, "HEAD", `/v1/blobs/${blobId}`, d1.auth);
    assert.equal(head.status, 200);
    assert.equal(head.headers.get("content-length"), String(blobCipher.length));
    assertSecurityHeaders(head);
    const missingHead = await api(main, "HEAD", `/v1/blobs/${"0".repeat(64)}`, d1.auth);
    assert.equal(missingHead.status, 404);

    const get = await api(main, "GET", `/v1/blobs/${blobId}`, d1.auth);
    assert.equal(get.status, 200);
    assert.equal(get.headers.get("content-type"), "application/octet-stream");
    assertSecurityHeaders(get);
    assert.ok(get.bytes.equals(blobCipher));
    assertError(await api(main, "GET", `/v1/blobs/${"0".repeat(64)}`, d1.auth), 404, "BLOB_NOT_FOUND");
  });

  await step("push easel.document + boost.item referencing the blobId", async () => {
    const res = await d1.push(
      [
        d1.mutation("easel.document", EASEL_ID, { ...easelV1, blobIds: [blobId] }, T0 + 6),
        d1.mutation("boost.item", BOOST_ID, { css: "body{background:#111}", enabled: true }, T0 + 7),
      ],
      { baseRevision: 6 },
    );
    assert.deepEqual(res.json, { currentRevision: 8, resetRevision: 0, acceptedCount: 2, conflicts: [] });
  });

  section("Device 2 signs in, pulls, decrypts");
  d2 = new Device("Device 2", main);
  let d2Ws;
  await step("Device 2: kdf-params -> PBKDF2 -> login -> unwrap the same vaultKey", async () => {
    const { res } = await d2.signIn(` ${EMAIL.toUpperCase()}`, PASSWORD);
    assert.equal(res.status, 200, JSON.stringify(res.json));
    assert.equal(res.json.accountId, accountA);
    assert.equal(res.json.serverRevision, 8);
    assert.equal(res.json.resetRevision, 0);
    assert.equal(res.json.hasCloudData, true);
    assert.deepEqual(res.json.collectionCounts, {
      "boost.item": 1,
      "credentials.profile": 1,
      "easel.document": 1,
      "settings.preferences": 1,
      "workspace.meta": 1,
      "workspace.profile": 1,
      "workspace.space": 1,
      "workspace.today": 1,
    });
    assert.ok(d2.vaultKey.equals(A.vaultKey));
  });

  await step("Device 2 connects GET /v1/sync/ws and receives {type:'connected'}", async () => {
    d2Ws = openWs(main, d2);
    await d2Ws.opened;
    const hello = await d2Ws.waitFor((m) => m.type === "connected");
    assert.deepEqual(hello, { type: "connected", serverRevision: 8, resetRevision: 0 });
  });

  let d2LastRevision = 0;
  await step("Device 2 pulls all records and decrypts exact plaintext (paginated and unpaginated)", async () => {
    const full = await d2.pullAll(0, 200);
    assert.equal(full.records.length, 8);
    assert.equal(full.first.fullResyncRequired, false);
    assert.equal(full.last.currentRevision, 8);
    assert.equal(full.last.nextSince, 8);
    assert.equal(full.last.hasMore, false);
    const byKey = new Map(full.records.map((r) => [`${r.collection}/${r.recordId}`, r]));
    const expectPlain = {
      [`workspace.meta/global`]: metaV1,
      [`workspace.space/${SPACE_ID}`]: spaceV1,
      [`settings.preferences/global`]: prefsV1,
      [`credentials.profile/${PROFILE_ID}`]: credsV1,
      [`workspace.profile/${PROFILE_ID}`]: { name: "Personal" },
      [`workspace.today/${TODAY_ID}`]: { nodes: [{ id: "tab-1" }] },
      [`easel.document/${EASEL_ID}`]: { ...easelV1, blobIds: [blobId] },
      [`boost.item/${BOOST_ID}`]: { css: "body{background:#111}", enabled: true },
    };
    for (const [key, plain] of Object.entries(expectPlain)) {
      const rec = byKey.get(key);
      assert.ok(rec, `missing ${key}`);
      assert.equal(rec.deleted, false);
      assert.equal(rec.updatedByDeviceId, d1.deviceId);
      assert.deepEqual(d2.open(rec), plain, `plaintext mismatch for ${key}`);
    }
    assert.deepEqual(full.records.map((r) => r.revision), [1, 2, 3, 4, 5, 6, 7, 8]);
    assert.equal(full.records[1].clientUpdatedAt, T0 + 1);

    const paged = await d2.pullAll(0, 3);
    assert.equal(paged.records.length, 8);
    assert.equal(paged.first.hasMore, true);
    assert.equal(paged.first.nextSince, 3);
    assert.equal(paged.first.records.length, 3);
    assert.deepEqual(paged.records.map((r) => r.revision), [1, 2, 3, 4, 5, 6, 7, 8]);

    const filtered = await d2.changes("?since=0&collections=workspace.space,credentials.profile");
    assert.deepEqual(filtered.json.records.map((r) => r.collection).sort(), ["credentials.profile", "workspace.space"]);
    assert.equal(filtered.json.nextSince, 8);
    d2LastRevision = full.last.nextSince;
  });

  await step("Device 2 downloads the blob and decrypts it to the exact original bytes", async () => {
    const get = await api(main, "GET", `/v1/blobs/${blobId}`, d2.auth);
    assert.equal(get.status, 200);
    const plain = gcmOpen(d2.vault.blobEncKey, get.bytes, blobAad(accountA, blobId));
    assert.ok(plain.equals(blobPlain));
    const check = crypto.createHmac("sha256", d2.vault.blobIdKey).update(plain).digest("hex");
    assert.equal(check, blobId, "content-addressed blobId verifies after decrypt");
  });

  await step("GET /v1/sync/status and GET /v1/account report revision, counts, blobs, devices", async () => {
    const status = await api(main, "GET", "/v1/sync/status", d2.auth);
    assert.equal(status.status, 200);
    assert.equal(status.json.serverRevision, 8);
    assert.equal(status.json.resetRevision, 0);
    assert.equal(status.json.hasCloudData, true);
    assert.equal(status.json.collectionCounts["workspace.space"], 1);
    assert.ok(Math.abs(status.json.lastModifiedAt - Date.now()) < 60_000);

    const acct = await api(main, "GET", "/v1/account", d2.auth);
    assert.equal(acct.status, 200);
    assert.equal(acct.json.accountId, accountA);
    assert.equal(acct.json.email, EMAIL);
    assert.equal(acct.json.displayName, "Alex");
    assert.equal(typeof acct.json.createdAt, "number");
    assert.equal(acct.json.blobCount, 1);
    assert.equal(acct.json.blobBytes, blobCipher.length);
    assert.equal(acct.json.devices.length, 2);
    const current = acct.json.devices.filter((d) => d.isCurrent);
    assert.equal(current.length, 1);
    assert.equal(current[0].deviceId, d2.deviceId);
    assert.equal(acct.json.devices.find((d) => d.deviceId === d1.deviceId).platform, "macos");

    const patch = await api(main, "PATCH", "/v1/account", { ...d2.auth, body: { displayName: "Alex Renamed" } });
    assert.deepEqual(patch.json, { ok: true, displayName: "Alex Renamed" });
    const acct2 = await api(main, "GET", "/v1/account", d1.auth);
    assert.equal(acct2.json.displayName, "Alex Renamed");
  });

  section("Real-time wakeup over WebSocket");
  let d1Ws;
  await step("Device 1 pushes a mutation -> Device 2 receives {type:'sync_available'} -> pulls the delta", async () => {
    d1Ws = openWs(main, d1);
    await d1Ws.opened;
    await d1Ws.waitFor((m) => m.type === "connected");

    const spaceV2 = { ...spaceV1, name: "Work (renamed)" };
    const res = await d1.push([d1.mutation("workspace.space", SPACE_ID, spaceV2, T0 + 100)], { baseRevision: 8 });
    assert.deepEqual(res.json, { currentRevision: 9, resetRevision: 0, acceptedCount: 1, conflicts: [] });

    const wake = await d2Ws.waitFor((m) => m.type === "sync_available");
    assert.deepEqual(wake, { type: "sync_available", revision: 9, resetRevision: 0, sourceDeviceId: d1.deviceId });
    await d1Ws.expectNone((m) => m.type === "sync_available", 300);

    const delta = await d2.changes(`?since=${d2LastRevision}`);
    assert.equal(delta.json.records.length, 1);
    assert.equal(delta.json.records[0].revision, 9);
    assert.deepEqual(d2.open(delta.json.records[0]), spaceV2);
    assert.equal(delta.json.nextSince, 9);
    d2LastRevision = 9;
  });

  await step("application-level ping -> pong; server heartbeat keeps well-behaved clients alive", async () => {
    d2Ws.ws.send(JSON.stringify({ type: "ping" }));
    assert.deepEqual(await d2Ws.waitFor((m) => m.type === "pong"), { type: "pong" });
    await sleep(1200); // > 3 heartbeat intervals (300 ms): undici auto-answers protocol pings
    d2Ws.ws.send(JSON.stringify({ type: "ping" }));
    assert.deepEqual(await d2Ws.waitFor((m) => m.type === "pong"), { type: "pong" });
  });

  section("Conflict detection (per-record last-writer-wins)");
  await step("stale clientUpdatedAt is returned in conflicts and does NOT overwrite the newer record", async () => {
    const stale = { ...spaceV1, name: "STALE WRITE" };
    const res = await d2.push([d2.mutation("workspace.space", SPACE_ID, stale, T0 + 50)], { baseRevision: 8 });
    assert.equal(res.status, 200);
    assert.equal(res.json.acceptedCount, 0);
    assert.equal(res.json.currentRevision, 9, "no revision consumed by a rejected mutation");
    assert.deepEqual(res.json.conflicts, [
      { collection: "workspace.space", recordId: SPACE_ID, serverRevision: 9, serverClientUpdatedAt: T0 + 100 },
    ]);
    const check = await d1.changes("?since=8");
    assert.equal(check.json.records.length, 1);
    assert.equal(d1.open(check.json.records[0]).name, "Work (renamed)");
    await d1Ws.expectNone((m) => m.type === "sync_available", 300);

    // Mixed batch: one conflict + one accepted.
    const mixed = await d2.push(
      [
        d2.mutation("workspace.space", SPACE_ID, stale, T0 + 60),
        d2.mutation("workspace.space", SPACE2_ID, { name: "Second" }, T0 + 61),
      ],
      { baseRevision: 9 },
    );
    assert.equal(mixed.json.acceptedCount, 1);
    assert.equal(mixed.json.conflicts.length, 1);
    assert.equal(mixed.json.currentRevision, 10);
    const wake = await d1Ws.waitFor((m) => m.type === "sync_available");
    assert.equal(wake.revision, 10);
    assert.equal(wake.sourceDeviceId, d2.deviceId);
    d2LastRevision = 10;
  });

  section("Tombstones and AAD binding");
  await step("deleted record seals {\"t\":1} with deleted=1 AAD; flipping AAD fields breaks GCM verification", async () => {
    const del = d1.mutation("workspace.today", TODAY_ID, null, T0 + 200, true);
    const res = await d1.push([del], { baseRevision: 10 });
    assert.equal(res.json.acceptedCount, 1);
    const pull = await d2.changes(`?since=10`);
    const rec = pull.json.records[0];
    assert.equal(rec.deleted, true);
    assert.deepEqual(d2.open(rec), { t: 1 });
    const counts = (await api(main, "GET", "/v1/sync/status", d2.auth)).json.collectionCounts;
    assert.equal(counts["workspace.today"], undefined, "tombstones are not counted as cloud data");

    const ct = fromB64(rec.ciphertext);
    const key = d2.vault.recordEncKey;
    // Server flips `deleted` -> AAD mismatch.
    assert.throws(() => gcmOpen(key, ct, recordAad(accountA, rec.collection, rec.recordId, false)));
    // Record moved to another recordId / collection / account -> AAD mismatch.
    assert.throws(() => gcmOpen(key, ct, recordAad(accountA, rec.collection, uuid(), true)));
    assert.throws(() => gcmOpen(key, ct, recordAad(accountA, "workspace.space", rec.recordId, true)));
    assert.throws(() => gcmOpen(key, ct, recordAad(crypto.randomUUID(), rec.collection, rec.recordId, true)));
    // Flipped ciphertext bit -> tag mismatch.
    const tampered = Buffer.from(ct);
    tampered[14] ^= 0x01;
    assert.throws(() => gcmOpen(key, tampered, recordAad(accountA, rec.collection, rec.recordId, true)));
    // Untampered still opens.
    assert.deepEqual(JSON.parse(gcmOpen(key, ct, recordAad(accountA, rec.collection, rec.recordId, true)).toString()), { t: 1 });
    d2LastRevision = 11;
  });

  section("Strict validation and hard limits");
  await step("unknown JSON fields are rejected with 400 VALIDATION_ERROR on every endpoint", async () => {
    const good = d1.mutation("workspace.meta", "global", metaV1, T0 + 300);
    // push (top-level and mutation-level)
    assertError(await api(main, "POST", "/v1/sync/push", { ...d1.auth, body: { deviceId: d1.deviceId, mode: "delta", baseRevision: 0, mutations: [good], bogus: 1 } }), 400, "VALIDATION_ERROR");
    assertError(await api(main, "POST", "/v1/sync/push", { ...d1.auth, body: { deviceId: d1.deviceId, mode: "delta", baseRevision: 0, mutations: [{ ...good, extra: true }] } }), 400, "VALIDATION_ERROR");
    // auth endpoints
    const dummyV = b64(crypto.randomBytes(32));
    const dummyW = b64(crypto.randomBytes(60));
    const kdf = { algorithm: "pbkdf2-sha256", iterations: 600000, saltBase64: b64(crypto.randomBytes(32)) };
    const cases = [
      ["POST", "/v1/auth/kdf-params", { email: EMAIL, extra: 1 }, undefined],
      ["POST", "/v1/auth/login", { email: EMAIL, authVerifier: dummyV, deviceId: uuid(), deviceName: "x", platform: "macos", extra: 1 }, undefined],
      ["POST", "/v1/auth/refresh", { refreshToken: "x".repeat(30), deviceId: uuid(), extra: 1 }, undefined],
      ["POST", "/v1/auth/logout", { extra: 1 }, d1.accessToken],
      ["POST", "/v1/auth/recovery-challenge", { email: EMAIL, recoveryAuthVerifier: dummyV, extra: 1 }, undefined],
      ["POST", "/v1/auth/register", { email: "x@y.z", displayName: "x", kdfParams: kdf, authVerifier: dummyV, recoveryAuthVerifier: dummyV, wrappedVaultKeyByPassword: dummyW, wrappedVaultKeyByRecovery: dummyW, deviceId: uuid(), deviceName: "x", platform: "macos", extra: 1 }, undefined],
      ["POST", "/v1/auth/register", { email: "x@y.z", displayName: "x", kdfParams: { ...kdf, extra: 1 }, authVerifier: dummyV, recoveryAuthVerifier: dummyV, wrappedVaultKeyByPassword: dummyW, wrappedVaultKeyByRecovery: dummyW, deviceId: uuid(), deviceName: "x", platform: "macos" }, undefined],
      ["POST", "/v1/auth/change-password", { currentAuthVerifier: dummyV, newKdfParams: kdf, newAuthVerifier: dummyV, newWrappedVaultKeyByPassword: dummyW, extra: 1 }, d1.accessToken],
      ["POST", "/v1/auth/recover", { email: EMAIL, recoveryTicket: "t".repeat(20), newKdfParams: kdf, newAuthVerifier: dummyV, newRecoveryAuthVerifier: dummyV, newWrappedVaultKeyByPassword: dummyW, newWrappedVaultKeyByRecovery: dummyW, deviceId: uuid(), deviceName: "x", platform: "macos", extra: 1 }, undefined],
      ["PATCH", "/v1/account", { displayName: "ok", extra: 1 }, d1.accessToken],
      ["DELETE", "/v1/account", { authVerifier: dummyV, extra: 1 }, d1.accessToken],
    ];
    for (const [method, url, body, token] of cases) {
      const res = await api(main, method, url, { token, body });
      assertError(res, 400, "VALIDATION_ERROR");
    }
  });

  await step("limits: >256 mutations, ciphertext >2 MiB, bad collection/recordId/base64/types/iterations -> 400", async () => {
    const one = d1.mutation("workspace.meta", "global", metaV1, T0 + 400);
    const pushBody = (mutations, extra = {}) => ({ deviceId: d1.deviceId, mode: "delta", baseRevision: 0, mutations, ...extra });
    const bad = async (body, label) => {
      const res = await api(main, "POST", "/v1/sync/push", { ...d1.auth, body });
      assertError(res, 400, "VALIDATION_ERROR");
      return label;
    };
    // exactly 256 is fine, 257 is not
    const ok256 = await api(main, "POST", "/v1/sync/push", { ...d1.auth, body: pushBody(Array.from({ length: 256 }, (_, i) => d1.mutation("workspace.space", uuid(), { n: i }, T0 + 1000 + i)), { baseRevision: 11 }) });
    assert.equal(ok256.status, 200, JSON.stringify(ok256.json));
    assert.equal(ok256.json.acceptedCount, 256);
    await bad(pushBody(Array.from({ length: 257 }, () => one)));
    // ciphertext: exactly 2 MiB accepted (see below), 2 MiB + 1 rejected
    await bad(pushBody([{ ...one, ciphertext: b64(crypto.randomBytes(2_097_153)) }]));
    // invalid collection / recordId variants
    await bad(pushBody([{ ...one, collection: "workspace.nope" }]));
    await bad(pushBody([{ ...one, collection: "WORKSPACE.META" }]));
    await bad(pushBody([{ ...one, recordId: "has space" }]));
    await bad(pushBody([{ ...one, recordId: "a/b" }]));
    await bad(pushBody([{ ...one, recordId: "x".repeat(129) }]));
    await bad(pushBody([{ ...one, recordId: "" }]));
    // types and encoding
    await bad(pushBody([{ ...one, deleted: "no" }]));
    await bad(pushBody([{ ...one, clientUpdatedAt: -1 }]));
    await bad(pushBody([{ ...one, clientUpdatedAt: 1.5 }]));
    await bad(pushBody([{ ...one, clientUpdatedAt: "1" }]));
    await bad(pushBody([{ ...one, ciphertext: "not base64!!" }]));
    await bad(pushBody([{ ...one, ciphertext: "QUJD" }])); // 3 bytes: shorter than nonce + tag
    await bad(pushBody([{ ...one, ciphertext: one.ciphertext.replace(/=+$/, "") + "=" + "=" }]));
    await bad(pushBody([one], { mode: "merge" }));
    await bad(pushBody([one], { baseRevision: -1 }));
    await bad(pushBody([one], { deviceId: "not-a-uuid" }));
    await bad(pushBody([one], { deviceId: uuid() })); // valid UUID, but not this session's device
    await bad({ deviceId: d1.deviceId, mode: "delta", baseRevision: 0 }); // missing mutations
    await bad(pushBody("nope"));
    // exactly 128-char recordId and exactly 2 MiB ciphertext are the inclusive maxima
    const maxId = "r".repeat(128);
    const maxRes = await api(main, "POST", "/v1/sync/push", { ...d1.auth, body: pushBody([{ ...one, recordId: maxId, ciphertext: b64(crypto.randomBytes(2_097_152)) }], { baseRevision: 267 }) });
    assert.equal(maxRes.status, 200, JSON.stringify(maxRes.json));
    assert.equal(maxRes.json.acceptedCount, 1);
    // Malformed bodies
    assertError(await api(main, "POST", "/v1/sync/push", { ...d1.auth, raw: "{not json", headers: { "Content-Type": "application/json" } }), 400, "VALIDATION_ERROR");
    assertError(await api(main, "POST", "/v1/sync/push", { ...d1.auth, raw: "[]", headers: { "Content-Type": "application/json" } }), 400, "VALIDATION_ERROR");
    assertError(await api(main, "POST", "/v1/sync/push", { ...d1.auth, raw: Buffer.from([0x7b, 0x22, 0xff, 0xfe, 0x22, 0x3a, 0x31, 0x7d]), headers: { "Content-Type": "application/json" } }), 400, "VALIDATION_ERROR");
    // register field limits
    const kdf = { algorithm: "pbkdf2-sha256", iterations: 600000, saltBase64: b64(crypto.randomBytes(32)) };
    const v = b64(crypto.randomBytes(32));
    const w = b64(crypto.randomBytes(60));
    const reg = (over) => api(main, "POST", "/v1/auth/register", {
      body: { email: "limits@example.com", displayName: "n", kdfParams: kdf, authVerifier: v, recoveryAuthVerifier: v, wrappedVaultKeyByPassword: w, wrappedVaultKeyByRecovery: w, deviceId: uuid(), deviceName: "dev", platform: "macos", ...over },
    });
    for (const over of [
      { kdfParams: { ...kdf, iterations: 299_999 } },
      { kdfParams: { ...kdf, iterations: 2_000_001 } },
      { kdfParams: { ...kdf, algorithm: "scrypt" } },
      { kdfParams: { ...kdf, saltBase64: b64(crypto.randomBytes(31)) } },
      { authVerifier: b64(crypto.randomBytes(31)) },
      { recoveryAuthVerifier: b64(crypto.randomBytes(33)) },
      { wrappedVaultKeyByPassword: b64(crypto.randomBytes(59)) },
      { wrappedVaultKeyByRecovery: b64(crypto.randomBytes(61)) },
      { email: "ab" },
      { email: "no-at-sign" },
      { email: "@nolocal" },
      { email: "nodomain@" },
      { email: `${"a".repeat(250)}@b.co` },
      { displayName: "d".repeat(121) },
      { deviceName: "n".repeat(129) },
      { deviceName: "" },
      { deviceId: "12345" },
      { platform: "mac os!" },
    ]) {
      assertError(await reg(over), 400, "VALIDATION_ERROR");
    }
    // boundary values accepted: iterations 300_000, displayName 120, deviceName 128
    const edge = await reg({ email: "limits-edge@example.com", kdfParams: { ...kdf, iterations: 300_000 }, displayName: "d".repeat(120), deviceName: "n".repeat(128) });
    assert.equal(edge.status, 201, JSON.stringify(edge.json));
    // query validation
    assertError(await d1.changes("?limit=501"), 400, "VALIDATION_ERROR");
    assertError(await d1.changes("?limit=0"), 400, "VALIDATION_ERROR");
    assertError(await d1.changes("?since=abc"), 400, "VALIDATION_ERROR");
    assertError(await d1.changes("?since=-1"), 400, "VALIDATION_ERROR");
    assertError(await d1.changes("?collections=workspace.nope"), 400, "VALIDATION_ERROR");
    assertError(await d1.changes("?bogus=1"), 400, "VALIDATION_ERROR");
    const lim500 = await d1.changes("?since=0&limit=500");
    assert.equal(lim500.status, 200);
    const dflt = await d1.changes("?since=0");
    assert.equal(dflt.json.records.length, 200, "default limit is 200");
    assert.equal(dflt.json.hasMore, true);
    // blob id / device id params
    assertError(await api(main, "GET", "/v1/blobs/NOT-A-BLOB-ID", d1.auth), 400, "VALIDATION_ERROR");
    assertError(await api(main, "PUT", `/v1/blobs/${"A".repeat(64)}`, { ...d1.auth, raw: crypto.randomBytes(64) }), 400, "VALIDATION_ERROR");
    assertError(await api(main, "DELETE", "/v1/account/devices/not-a-uuid", d1.auth), 400, "VALIDATION_ERROR");
  });

  await step("request bodies over 8 MiB and blobs over 20 MiB are rejected with 400", async () => {
    const huge = Buffer.alloc(8_388_608 + 1, 0x20);
    const res = await api(main, "POST", "/v1/sync/push", { ...d1.auth, raw: huge, headers: { "Content-Type": "application/json" } });
    assertError(res, 400, "VALIDATION_ERROR");
    const bigBlob = crypto.randomBytes(20_971_520 + 1);
    const id = crypto.createHash("sha256").update(bigBlob).digest("hex");
    const blobRes = await api(main, "PUT", `/v1/blobs/${id}`, { ...d1.auth, raw: bigBlob });
    assertError(blobRes, 400, "VALIDATION_ERROR");
    // exactly 20 MiB is accepted
    const maxBlob = crypto.randomBytes(20_971_520);
    const maxId = crypto.createHash("sha256").update(maxBlob).digest("hex");
    const ok = await api(main, "PUT", `/v1/blobs/${maxId}`, { ...d1.auth, raw: maxBlob });
    assert.equal(ok.status, 200, JSON.stringify(ok.json));
    assert.equal(ok.json.sizeBytes, 20_971_520);
    // Server still healthy afterwards.
    assert.equal((await api(main, "GET", "/health")).status, 200);
  });

  section("WebSocket protocol edge cases (raw RFC 6455 client)");
  await step("handshake rejections: no/invalid token -> 401, bad key / version -> 400, wrong path -> 404, device mismatch -> 400", async () => {
    const noAuth = await rawWs(main, {});
    assert.equal(noAuth.status, 401);
    assert.ok(noAuth.body().includes("UNAUTHORIZED"));
    assert.equal(noAuth.headers["x-content-type-options"], "nosniff");
    noAuth.destroy();
    const badToken = await rawWs(main, { token: "z".repeat(43) });
    assert.equal(badToken.status, 401);
    badToken.destroy();
    const badKey = await rawWs(main, { token: d1.accessToken, key: "bm90LTE2LWJ5dGVz" });
    assert.equal(badKey.status, 400);
    badKey.destroy();
    const badVersion = await rawWs(main, { token: d1.accessToken, version: "8" });
    assert.equal(badVersion.status, 400);
    badVersion.destroy();
    const mismatch = await rawWs(main, { token: d1.accessToken, deviceId: uuid() });
    assert.equal(mismatch.status, 400);
    mismatch.destroy();
    // wrong path
    const sock = net.connect(main.port, main.host);
    await new Promise((r) => sock.once("connect", r));
    sock.write(`GET /v1/other HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${crypto.randomBytes(16).toString("base64")}\r\nSec-WebSocket-Version: 13\r\n\r\n`);
    const reply = await new Promise((r) => sock.once("data", (d) => r(d.toString())));
    assert.ok(reply.startsWith("HTTP/1.1 404"));
    sock.destroy();
  });

  await step("valid handshake: Sec-WebSocket-Accept is correct; server frames are unmasked; masked ping/pong, text ping, fragmentation work", async () => {
    const key = crypto.randomBytes(16).toString("base64");
    const c = await rawWs(main, { token: d1.accessToken, deviceId: d1.deviceId, key });
    assert.equal(c.status, 101);
    assert.equal(c.headers["sec-websocket-accept"], crypto.createHash("sha1").update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64"));
    assert.equal(c.headers["upgrade"].toLowerCase(), "websocket");
    const hello = await c.nextDataFrame();
    assert.equal(hello.opcode, 0x1);
    assert.equal(JSON.parse(hello.payload.toString()).type, "connected");
    // protocol-level ping -> pong with same payload
    c.send(0x9, utf8("hb-1"));
    for (;;) {
      const f = await c.nextFrame();
      if (f.opcode === 0xa) { assert.equal(f.payload.toString(), "hb-1"); break; }
    }
    // app-level ping, 126-byte-plus extended length payload via padding field
    c.sendText(`{"type":"ping"}${" ".repeat(300)}`);
    let f = await c.nextDataFrame();
    assert.deepEqual(JSON.parse(f.payload.toString()), { type: "pong" });
    // fragmented text message: "{"type":"ping"}" split in 3 frames
    const msg = utf8('{"type":"ping"}');
    c.send(0x1, msg.subarray(0, 4), { fin: false });
    c.send(0x0, msg.subarray(4, 9), { fin: false });
    c.send(0x0, msg.subarray(9), { fin: true });
    f = await c.nextDataFrame();
    assert.deepEqual(JSON.parse(f.payload.toString()), { type: "pong" });
    // server heartbeat pings arrive (interval 300 ms) while we stay quiet; answering keeps us alive
    let sawPing = false;
    const until = Date.now() + 2500;
    while (Date.now() < until && !sawPing) {
      const hb = await c.nextFrame(2500);
      if (hb.opcode === 0x9) { sawPing = true; c.send(0xa, hb.payload); }
    }
    assert.ok(sawPing, "server sends heartbeat pings");
    // clean close handshake: server echoes the close code
    c.send(0x8, Buffer.from([0x03, 0xe8]));
    const close = await c.nextDataFrame();
    assert.equal(close.opcode, 0x8);
    assert.equal(closeCodeOf(close), 1000);
    assert.ok(await c.waitEnded());
    c.destroy();
  });

  await step("protocol violations close the connection: unmasked 1002, oversize 1009, bad UTF-8 1007, binary 1003, bad opcode 1002", async () => {
    const connect = async () => {
      const c = await rawWs(main, { token: d1.accessToken, deviceId: d1.deviceId });
      assert.equal(c.status, 101);
      await c.nextDataFrame(); // connected
      return c;
    };
    let c = await connect();
    c.sendText('{"type":"ping"}', { mask: false });
    let close = await c.nextDataFrame();
    assert.equal(close.opcode, 0x8);
    assert.equal(closeCodeOf(close), 1002, "unmasked client frame");
    c.destroy();

    c = await connect();
    c.send(0x1, Buffer.alloc(0), { declaredLength: 65_537 }); // header only: claims 64 KiB + 1
    close = await c.nextDataFrame();
    assert.equal(closeCodeOf(close), 1009, "payload over 64 KiB");
    c.destroy();

    c = await connect();
    c.send(0x1, Buffer.alloc(65_536, 0x20)); // exactly 64 KiB (whitespace) is accepted by the framing layer...
    close = await c.nextDataFrame();
    assert.equal(closeCodeOf(close), 1008, "...and then rejected as a non-JSON message");
    c.destroy();

    c = await connect();
    c.send(0x1, Buffer.alloc(65_536, 0x61));
    close = await c.nextDataFrame();
    assert.equal(closeCodeOf(close), 1008, "64 KiB of non-JSON text");
    c.destroy();

    c = await connect();
    c.send(0x1, Buffer.from([0xc3, 0x28]));
    close = await c.nextDataFrame();
    assert.equal(closeCodeOf(close), 1007, "invalid UTF-8");
    c.destroy();

    c = await connect();
    c.send(0x2, Buffer.from([1, 2, 3]));
    close = await c.nextDataFrame();
    assert.equal(closeCodeOf(close), 1003, "binary frames unsupported");
    c.destroy();

    c = await connect();
    c.send(0x3, Buffer.alloc(0));
    close = await c.nextDataFrame();
    assert.equal(closeCodeOf(close), 1002, "reserved opcode");
    c.destroy();

    c = await connect();
    c.send(0x9, Buffer.alloc(0), { fin: false });
    close = await c.nextDataFrame();
    assert.equal(closeCodeOf(close), 1002, "fragmented control frame");
    c.destroy();
  });

  await step("a client that never answers heartbeat pings is terminated by the server", async () => {
    const c = await rawWs(main, { token: d1.accessToken, deviceId: d1.deviceId });
    assert.equal(c.status, 101);
    assert.ok(await c.waitEnded(4000), "server dropped the unresponsive connection");
    c.destroy();
  });

  await step("hardening: >64 fragments (zero-byte CONT floods) -> 1009; query string on upgrade -> 400; invalid/unknown WS messages -> 1008", async () => {
    const connect = async () => {
      const c = await rawWs(main, { token: d1.accessToken, deviceId: d1.deviceId });
      assert.equal(c.status, 101);
      await c.nextDataFrame(); // connected
      return c;
    };
    // Exactly 64 fragments is fine; the 65th is not.
    let c = await connect();
    const ping = utf8('{"type":"ping"}');
    c.send(0x1, ping.subarray(0, 1), { fin: false });
    for (let i = 0; i < 62; i += 1) c.send(0x0, Buffer.alloc(0), { fin: false });
    c.send(0x0, ping.subarray(1), { fin: true }); // 64th fragment
    let f = await c.nextDataFrame();
    assert.deepEqual(JSON.parse(f.payload.toString()), { type: "pong" }, "64 fragments are accepted");
    c.destroy();

    c = await connect();
    c.send(0x1, Buffer.alloc(0), { fin: false });
    for (let i = 0; i < 70; i += 1) c.send(0x0, Buffer.alloc(0), { fin: false });
    let close = await c.nextDataFrame();
    assert.equal(close.opcode, 0x8);
    assert.equal(closeCodeOf(close), 1009, "zero-byte continuation flood");
    assert.equal(close.payload.subarray(2).toString(), "too_many_fragments");
    c.destroy();

    // A single TCP chunk carrying a huge pile of tiny frames is cut off too.
    c = await connect();
    const chunk = Buffer.concat([
      Buffer.from([0x01, 0x80, 0, 0, 0, 0]),
      ...Array.from({ length: 40_000 }, () => Buffer.from([0x00, 0x80, 0, 0, 0, 0])),
    ]);
    c.socket.write(chunk);
    close = await c.nextDataFrame();
    assert.equal(close.opcode, 0x8);
    assert.equal(closeCodeOf(close), 1009, "oversized single chunk of frames");
    c.destroy();

    // Query strings are rejected on the upgrade, not silently stripped.
    for (const wsPath of ["/v1/sync/ws?foo=bar", "/v1/sync/ws?"]) {
      const q = await rawWs(main, { token: d1.accessToken, deviceId: d1.deviceId, path: wsPath });
      assert.equal(q.status, 400, wsPath);
      assert.ok(q.body().includes("VALIDATION_ERROR"));
      assert.ok(await q.waitEnded());
      q.destroy();
    }

    // Anything but exactly {"type":"ping"} closes with 1008.
    for (const text of [
      "not json",
      "[]",
      "null",
      "42",
      '{"type":"ping","extra":1}',
      '{"type":"pong"}',
      '{"type":"subscribe"}',
      '{"type":1}',
      "{}",
    ]) {
      c = await connect();
      c.sendText(text);
      close = await c.nextDataFrame();
      assert.equal(close.opcode, 0x8, text);
      assert.equal(closeCodeOf(close), 1008, `message ${text}`);
      assert.equal(close.payload.subarray(2).toString(), "invalid_message");
      c.destroy();
    }

    // The same through the standard WebSocket client.
    const ws = openWs(main, d1);
    await ws.opened;
    await ws.waitFor((m) => m.type === "connected");
    ws.ws.send("definitely not json");
    assert.equal((await ws.waitClosed()).code, 1008);
  });

  section("replaceCloud and fullResyncRequired");
  await step("replaceCloud wipes records, advances resetRevision; a device with an old `since` gets fullResyncRequired", async () => {
    d2Ws.messages.length = 0; // drop wakeups from earlier pushes
    const before = (await api(main, "GET", "/v1/sync/status", d2.auth)).json;
    assert.equal(before.resetRevision, 0);
    const staleSince = d2LastRevision;
    assert.ok(staleSince > 0);

    const replacement = [
      d1.mutation("workspace.meta", "global", { profileIDs: [], spaceIDs: [SPACE2_ID] }, T0 + 5000),
      d1.mutation("settings.preferences", "global", { "open.theme": "light" }, T0 + 5001),
    ];
    const res = await d1.push(replacement, { mode: "replaceCloud", baseRevision: before.serverRevision });
    assert.equal(res.status, 200, JSON.stringify(res.json));
    assert.equal(res.json.acceptedCount, 2);
    assert.equal(res.json.conflicts.length, 0);
    assert.equal(res.json.resetRevision, before.serverRevision + 1, "resetRevision = revision of the wipe");
    assert.equal(res.json.currentRevision, before.serverRevision + 3);

    const wake = await d2Ws.waitFor((m) => m.type === "sync_available");
    assert.equal(wake.resetRevision, res.json.resetRevision);
    assert.equal(wake.revision, res.json.currentRevision);

    const stale = await d2.changes(`?since=${staleSince}`);
    assert.equal(stale.json.fullResyncRequired, true);
    assert.equal(stale.json.resetRevision, res.json.resetRevision);
    assert.equal(stale.json.records.length, 2, "only post-reset records are streamed from revision 0");
    assert.deepEqual(stale.json.records.map((r) => `${r.collection}/${r.recordId}`).sort(), ["settings.preferences/global", "workspace.meta/global"]);
    assert.deepEqual(d2.open(stale.json.records.find((r) => r.collection === "workspace.meta")), { profileIDs: [], spaceIDs: [SPACE2_ID] });
    assert.equal(stale.json.nextSince, res.json.currentRevision);

    const fresh = await d2.changes("?since=0");
    assert.equal(fresh.json.fullResyncRequired, false);
    assert.equal(fresh.json.records.length, 2);
    const current = await d2.changes(`?since=${res.json.currentRevision}`);
    assert.equal(current.json.fullResyncRequired, false);
    assert.equal(current.json.records.length, 0);

    const counts = (await api(main, "GET", "/v1/sync/status", d2.auth)).json.collectionCounts;
    assert.deepEqual(counts, { "settings.preferences": 1, "workspace.meta": 1 });

    // Blobs are content-addressed and survive a record reset.
    assert.equal((await api(main, "HEAD", `/v1/blobs/${blobId}`, d2.auth)).status, 200);
    d2LastRevision = res.json.currentRevision;
  });

  section("Tenant isolation");
  await step("Account B is isolated: cannot read A's blob or records; B's own data round-trips", async () => {
    B = newAccountMaterial("b-account-password", "bob@example.org");
    bDevice = new Device("B Device", main);
    const res = await bDevice.register(B, "Bob");
    assert.equal(res.status, 201);
    bDevice.adopt(res.json);
    bDevice.vaultKey = B.vaultKey;
    bDevice.vault = B.vault;
    const bBlob = crypto.randomBytes(2048);
    const bBlobId = crypto.createHmac("sha256", B.vault.blobIdKey).update(bBlob).digest("hex");
    await api(main, "PUT", `/v1/blobs/${bBlobId}`, { ...bDevice.auth, raw: gcmSeal(B.vault.blobEncKey, bBlob, blobAad(bDevice.accountId, bBlobId)) });
    const push = await bDevice.push([bDevice.mutation("workspace.meta", "global", { b: true }, T0)]);
    assert.equal(push.json.currentRevision, 1, "revision counters are per account");

    assertError(await api(main, "GET", `/v1/blobs/${blobId}`, bDevice.auth), 404, "BLOB_NOT_FOUND");
    assertError(await api(main, "GET", `/v1/blobs/${bBlobId}`, d1.auth), 404, "BLOB_NOT_FOUND");
    const bPull = await bDevice.pullAll(0);
    assert.equal(bPull.records.length, 1);
    assert.deepEqual(bDevice.open(bPull.records[0]), { b: true });
    // A's ciphertext cannot be opened with B's keys
    const aRecord = (await d1.changes("?since=0")).json.records[0];
    assert.throws(() => gcmOpen(B.vault.recordEncKey, fromB64(aRecord.ciphertext), recordAad(accountA, aRecord.collection, aRecord.recordId, aRecord.deleted)));
    // device removal is account-scoped
    const foreignDelete = await api(main, "DELETE", `/v1/account/devices/${d1.deviceId}`, bDevice.auth);
    assert.deepEqual(foreignDelete.json, { ok: true, removed: false });
  });

  section("Refresh-token rotation and replay detection");
  await step("refresh rotates both tokens; replaying the old refresh token -> 401 TOKEN_REUSED and revokes the family", async () => {
    const oldRefresh = d1.refreshToken;
    const oldAccess = d1.accessToken;
    const res = await api(main, "POST", "/v1/auth/refresh", { body: { refreshToken: oldRefresh, deviceId: d1.deviceId } });
    assert.equal(res.status, 200, JSON.stringify(res.json));
    assert.deepEqual(Object.keys(res.json).sort(), ["accessToken", "accessTokenExpiresAt", "refreshToken"]);
    assert.notEqual(res.json.refreshToken, oldRefresh);
    assert.notEqual(res.json.accessToken, oldAccess);
    const newAccess = res.json.accessToken;
    const newRefresh = res.json.refreshToken;
    assert.equal((await api(main, "GET", "/v1/account", { token: newAccess })).status, 200);

    // invalid refresh attempts
    assertError(await api(main, "POST", "/v1/auth/refresh", { body: { refreshToken: "q".repeat(43), deviceId: d1.deviceId } }), 401, "INVALID_REFRESH_TOKEN");
    assertError(await api(main, "POST", "/v1/auth/refresh", { body: { refreshToken: newRefresh, deviceId: uuid() } }), 401, "INVALID_REFRESH_TOKEN");

    // Replay the rotated token.
    const ws = openWs(main, d1, { token: newAccess });
    await ws.opened;
    await ws.waitFor((m) => m.type === "connected");
    assertError(await api(main, "POST", "/v1/auth/refresh", { body: { refreshToken: oldRefresh, deviceId: d1.deviceId } }), 401, "TOKEN_REUSED");

    // The whole family is revoked: new access + refresh tokens are dead, WS closed with 4001.
    assertError(await api(main, "GET", "/v1/account", { token: newAccess }), 401, "UNAUTHORIZED");
    assertError(await api(main, "POST", "/v1/auth/refresh", { body: { refreshToken: newRefresh, deviceId: d1.deviceId } }), 401, "INVALID_REFRESH_TOKEN");
    const closed = await ws.waitClosed();
    assert.equal(closed.code, 4001);
    assert.equal(closed.reason, "session_revoked");
    assert.equal((await d1Ws.waitClosed()).code, 4001, "Device 1's earlier websocket is closed as well");

    // Device 1 signs in again with the password; the other devices are unaffected.
    const { res: relogin } = await d1.signIn(EMAIL, PASSWORD);
    assert.equal(relogin.status, 200);
    assert.equal((await api(main, "GET", "/v1/account", d2.auth)).status, 200);
  });

  await step("logout revokes only the calling session", async () => {
    const tmp = new Device("Temp", main);
    const { res } = await tmp.signIn(EMAIL, PASSWORD);
    assert.equal(res.status, 200);
    const ws = openWs(main, tmp);
    await ws.opened;
    const out = await api(main, "POST", "/v1/auth/logout", { ...tmp.auth, body: {} });
    assert.deepEqual(out.json, { ok: true });
    assertError(await api(main, "GET", "/v1/account", tmp.auth), 401, "UNAUTHORIZED");
    assert.equal((await ws.waitClosed()).code, 4001);
    assertError(await api(main, "POST", "/v1/auth/refresh", { body: { refreshToken: tmp.refreshToken, deviceId: tmp.deviceId } }), 401, "INVALID_REFRESH_TOKEN");
    assert.equal((await api(main, "GET", "/v1/account", d1.auth)).status, 200);
    // clean up the temp device
    assert.equal((await api(main, "DELETE", `/v1/account/devices/${tmp.deviceId}`, d1.auth)).json.removed, true);
  });

  section("Password change");
  await step("change-password: wrong current verifier -> 401; correct -> revokes other sessions; old password dead; new password unwraps the same vaultKey", async () => {
    const newSalt = crypto.randomBytes(32);
    const newIterations = 650_000;
    const newKeys = passwordKeys(NEW_PASSWORD, EMAIL, newSalt, newIterations);
    const newWrapped = gcmSeal(newKeys.passwordWrapKey, d1.vaultKey, wrapAad("vault-pw", EMAIL));
    const body = (currentKey) => ({
      currentAuthVerifier: b64(currentKey),
      newKdfParams: { algorithm: "pbkdf2-sha256", iterations: newIterations, saltBase64: b64(newSalt) },
      newAuthVerifier: b64(newKeys.authKey),
      newWrappedVaultKeyByPassword: b64(newWrapped),
      revokeOtherSessions: true,
    });
    assertError(await api(main, "POST", "/v1/auth/change-password", { ...d1.auth, body: body(crypto.randomBytes(32)) }), 401, "INVALID_CREDENTIALS");
    assert.equal((await api(main, "GET", "/v1/account", d2.auth)).status, 200, "failed change leaves other sessions alone");

    const res = await api(main, "POST", "/v1/auth/change-password", { ...d1.auth, body: body(A.authKey) });
    assert.equal(res.status, 200, JSON.stringify(res.json));
    assert.deepEqual(res.json, { ok: true, revokedSessions: 1 }, "only Device 2's session was other");
    assert.equal((await d2Ws.waitClosed()).code, 4001, "Device 2's websocket closed on revocation");
    assertError(await api(main, "GET", "/v1/account", d2.auth), 401, "UNAUTHORIZED");
    assert.equal((await api(main, "GET", "/v1/account", d1.auth)).status, 200, "calling session survives");

    // Old password no longer logs in (real client flow with the *new* kdf-params).
    const probe = new Device("Probe", main);
    const stale = await probe.signIn(EMAIL, PASSWORD);
    assert.equal(stale.res.status, 401);
    // New password does, and unwraps the SAME vault key.
    const ok = await probe.signIn(EMAIL, NEW_PASSWORD);
    assert.equal(ok.res.status, 200, JSON.stringify(ok.res.json));
    assert.ok(probe.vaultKey.equals(A.vaultKey), "vaultKey unchanged by password change");
    const kdf = (await api(main, "POST", "/v1/auth/kdf-params", { body: { email: EMAIL } })).json.kdfParams;
    assert.equal(kdf.iterations, newIterations);
    assert.equal(kdf.saltBase64, b64(newSalt));
    // existing records still decrypt after the change
    const pull = await probe.pullAll(0);
    assert.equal(pull.records.length, 2);
    for (const r of pull.records) assert.ok(probe.open(r));
    assert.equal((await api(main, "DELETE", `/v1/account/devices/${probe.deviceId}`, d1.auth)).json.removed, true);
    A.passwordNow = NEW_PASSWORD;
  });

  section("Recovery key flow");
  await step("recovery-challenge + recover: wrong key -> 401; right key yields the vaultKey; new password set; all sessions revoked; ticket single-use", async () => {
    d3 = new Device("Device 3 (recovering)", main);
    // The user types the recovery key as printed; the parser tolerates case/space/hyphen noise.
    const typed = A.recoveryKeyString.toLowerCase().replace(/-/g, " ");
    const bytes = parseRecoveryKey(typed);
    assert.ok(bytes.equals(A.recoveryKeyBytes));
    assert.match(A.recoveryKeyString, /^OPEN(-[A-Z2-7]{4}){13}$/);
    const rk = recoveryKeys(bytes);

    const wrongKey = recoveryKeys(crypto.randomBytes(32));
    assertError(
      await api(main, "POST", "/v1/auth/recovery-challenge", { body: { email: EMAIL, recoveryAuthVerifier: b64(wrongKey.recoveryAuthKey) } }),
      401,
      "INVALID_RECOVERY_KEY",
    );
    assertError(
      await api(main, "POST", "/v1/auth/recovery-challenge", { body: { email: "ghost@example.com", recoveryAuthVerifier: b64(rk.recoveryAuthKey) } }),
      401,
      "INVALID_RECOVERY_KEY",
    );
    const challenge = await api(main, "POST", "/v1/auth/recovery-challenge", { body: { email: EMAIL, recoveryAuthVerifier: b64(rk.recoveryAuthKey) } });
    assert.equal(challenge.status, 200, JSON.stringify(challenge.json));
    assert.deepEqual(Object.keys(challenge.json).sort(), ["accountId", "recoveryTicket", "wrappedVaultKeyByRecovery"]);
    assert.equal(challenge.json.accountId, accountA);
    const recoveredVaultKey = gcmOpen(rk.recoveryWrapKey, fromB64(challenge.json.wrappedVaultKeyByRecovery), wrapAad("vault-rec", EMAIL));
    assert.ok(recoveredVaultKey.equals(A.vaultKey));

    // Build the new credentials: new password + a brand-new recovery key.
    const newSalt = crypto.randomBytes(32);
    const newPw = passwordKeys(RECOVERED_PASSWORD, EMAIL, newSalt, 600000);
    const newRecoveryBytes = crypto.randomBytes(32);
    const newRec = recoveryKeys(newRecoveryBytes);
    const recoverBody = (ticket) => ({
      email: EMAIL,
      recoveryTicket: ticket,
      newKdfParams: { algorithm: "pbkdf2-sha256", iterations: 600000, saltBase64: b64(newSalt) },
      newAuthVerifier: b64(newPw.authKey),
      newRecoveryAuthVerifier: b64(newRec.recoveryAuthKey),
      newWrappedVaultKeyByPassword: b64(gcmSeal(newPw.passwordWrapKey, recoveredVaultKey, wrapAad("vault-pw", EMAIL))),
      newWrappedVaultKeyByRecovery: b64(gcmSeal(newRec.recoveryWrapKey, recoveredVaultKey, wrapAad("vault-rec", EMAIL))),
      deviceId: d3.deviceId,
      deviceName: d3.deviceName,
      platform: "macos",
    });
    assertError(await api(main, "POST", "/v1/auth/recover", { body: recoverBody("w".repeat(43)) }), 401, "INVALID_RECOVERY_TICKET");
    const res = await api(main, "POST", "/v1/auth/recover", { body: recoverBody(challenge.json.recoveryTicket) });
    assert.equal(res.status, 200, JSON.stringify(res.json));
    assert.equal(res.json.accountId, accountA);
    assert.equal(res.json.deviceId, d3.deviceId);
    assert.ok(res.json.hasCloudData);
    assert.equal(res.json.serverRevision >= 1, true);
    d3.adopt(res.json);
    d3.email = EMAIL;
    d3.vaultKey = gcmOpen(newPw.passwordWrapKey, fromB64(res.json.wrappedVaultKeyByPassword), wrapAad("vault-pw", EMAIL));
    d3.vault = vaultKeys(d3.vaultKey);
    assert.ok(d3.vaultKey.equals(A.vaultKey));

    // Single use + all prior sessions revoked.
    assertError(await api(main, "POST", "/v1/auth/recover", { body: recoverBody(challenge.json.recoveryTicket) }), 401, "INVALID_RECOVERY_TICKET");
    assertError(await api(main, "GET", "/v1/account", d1.auth), 401, "UNAUTHORIZED");
    assertError(await api(main, "POST", "/v1/auth/refresh", { body: { refreshToken: d1.refreshToken, deviceId: d1.deviceId } }), 401, "INVALID_REFRESH_TOKEN");

    // Recovered vault key decrypts the existing records.
    const pull = await d3.pullAll(0);
    assert.equal(pull.records.length, 2);
    const meta = pull.records.find((r) => r.collection === "workspace.meta");
    assert.deepEqual(d3.open(meta), { profileIDs: [], spaceIDs: [SPACE2_ID] });
    const prefs = pull.records.find((r) => r.collection === "settings.preferences");
    assert.deepEqual(d3.open(prefs), { "open.theme": "light" });

    // Password flow now uses the recovered password; the previous password and previous recovery key are dead.
    const probe = new Device("Probe 2", main);
    assert.equal((await probe.signIn(EMAIL, NEW_PASSWORD)).res.status, 401);
    const good = await probe.signIn(EMAIL, RECOVERED_PASSWORD);
    assert.equal(good.res.status, 200);
    assert.ok(probe.vaultKey.equals(A.vaultKey));
    assertError(
      await api(main, "POST", "/v1/auth/recovery-challenge", { body: { email: EMAIL, recoveryAuthVerifier: b64(rk.recoveryAuthKey) } }),
      401,
      "INVALID_RECOVERY_KEY",
    );
    const again = await api(main, "POST", "/v1/auth/recovery-challenge", { body: { email: EMAIL, recoveryAuthVerifier: b64(newRec.recoveryAuthKey) } });
    assert.equal(again.status, 200, "the new recovery key works");
    assert.equal((await api(main, "DELETE", `/v1/account/devices/${probe.deviceId}`, d3.auth)).json.removed, true);
  });

  section("Device listing and revocation");
  await step("list devices, revoke Device 2: its WebSocket closes with 4001 and its token is rejected", async () => {
    d1 = Object.assign(new Device("Device 1b", main), { wireId: d1.wireId, deviceId: d1.deviceId });
    const { res } = await d1.signIn(EMAIL, RECOVERED_PASSWORD);
    assert.equal(res.status, 200);
    const s2 = new Device("Device 2b", main);
    assert.equal((await s2.signIn(EMAIL, RECOVERED_PASSWORD)).res.status, 200);
    const ws = openWs(main, s2);
    await ws.opened;
    await ws.waitFor((m) => m.type === "connected");

    const list = (await api(main, "GET", "/v1/account", d1.auth)).json.devices;
    const ids = list.map((d) => d.deviceId);
    assert.ok(ids.includes(d1.deviceId) && ids.includes(s2.deviceId) && ids.includes(d3.deviceId));
    assert.equal(list.filter((d) => d.isCurrent).length, 1);
    assert.equal(list.find((d) => d.isCurrent).deviceId, d1.deviceId);
    for (const d of list) {
      assert.equal(typeof d.deviceName, "string");
      assert.equal(typeof d.lastSeenAt, "number");
    }

    const del = await api(main, "DELETE", `/v1/account/devices/${s2.deviceId}`, d1.auth);
    assert.deepEqual(del.json, { ok: true, removed: true });
    const closed = await ws.waitClosed();
    assert.equal(closed.code, 4001);
    assert.equal(closed.reason, "session_revoked");
    assertError(await api(main, "GET", "/v1/account", s2.auth), 401, "UNAUTHORIZED");
    assertError(await api(main, "POST", "/v1/auth/refresh", { body: { refreshToken: s2.refreshToken, deviceId: s2.deviceId } }), 401, "INVALID_REFRESH_TOKEN");
    assert.deepEqual((await api(main, "DELETE", `/v1/account/devices/${s2.deviceId}`, d1.auth)).json, { ok: true, removed: false });
    const after = (await api(main, "GET", "/v1/account", d1.auth)).json.devices.map((d) => d.deviceId);
    assert.ok(!after.includes(s2.deviceId));
    // Handshake with a revoked token is refused.
    const refused = await rawWs(main, { token: s2.accessToken });
    assert.equal(refused.status, 401);
    refused.destroy();
  });

  section("Secondary server: quotas, token expiry, persistence, rate limiting");
  let second;
  await step("per-account blob quota -> 413 QUOTA_EXCEEDED; access tokens expire; state and dummy-salt secret persist across restart", async () => {
    second = await startServer({ OPEN_SYNC_MAX_ACCOUNT_BLOB_BYTES: "1000", OPEN_SYNC_ACCESS_TOKEN_TTL_MS: "1500" });
    extraServers.push(second);
    const m = newAccountMaterial("quota-password", "quota@example.com", 300_000);
    const dev = new Device("Quota", second);
    const reg = await dev.register(m, "Quota");
    assert.equal(reg.status, 201);
    dev.adopt(reg.json);
    const small1 = crypto.randomBytes(600);
    const small2 = crypto.randomBytes(600);
    const id1 = crypto.createHash("sha256").update(small1).digest("hex");
    const id2 = crypto.createHash("sha256").update(small2).digest("hex");
    assert.equal((await api(second, "PUT", `/v1/blobs/${id1}`, { ...dev.auth, raw: small1 })).status, 200);
    assertError(await api(second, "PUT", `/v1/blobs/${id2}`, { ...dev.auth, raw: small2 }), 413, "QUOTA_EXCEEDED");
    assertError(await api(second, "GET", `/v1/blobs/${id2}`, dev.auth), 404, "BLOB_NOT_FOUND");
    // re-uploading the existing blob is still fine (idempotent, no extra quota)
    assert.equal((await api(second, "PUT", `/v1/blobs/${id1}`, { ...dev.auth, raw: small1 })).json.created, false);
    // minimum blob size (nonce + tag)
    assertError(await api(second, "PUT", `/v1/blobs/${"1".repeat(64)}`, { ...dev.auth, raw: crypto.randomBytes(10) }), 400, "VALIDATION_ERROR");

    await sleep(1700);
    assertError(await api(second, "GET", "/v1/account", dev.auth), 401, "UNAUTHORIZED");
    const refreshed = await api(second, "POST", "/v1/auth/refresh", { body: { refreshToken: dev.refreshToken, deviceId: dev.deviceId } });
    assert.equal(refreshed.status, 200);
    dev.accessToken = refreshed.json.accessToken;
    dev.refreshToken = refreshed.json.refreshToken;
    assert.equal((await api(second, "GET", "/v1/account", dev.auth)).status, 200);

    const ghostBefore = (await api(second, "POST", "/v1/auth/kdf-params", { body: { email: "ghost-persist@example.com" } })).json.kdfParams.saltBase64;
    const { dataDir } = second;
    const exit = await second.stop();
    assert.equal(exit.code, 0, `graceful SIGTERM exit; stderr: ${second.stderr()}`);
    second = await startServer({ OPEN_SYNC_MAX_ACCOUNT_BLOB_BYTES: "1000", OPEN_SYNC_ACCESS_TOKEN_TTL_MS: "60000" }, dataDir);
    extraServers.push(second);
    dev.server = second;
    assert.equal((await api(second, "GET", "/v1/account", dev.auth)).status, 200, "tokens survive restart (hash-stored)");
    const ghostAfter = (await api(second, "POST", "/v1/auth/kdf-params", { body: { email: "ghost-persist@example.com" } })).json.kdfParams.saltBase64;
    assert.equal(ghostAfter, ghostBefore, "HMAC secret persisted in server_meta");
    const blob = await api(second, "GET", `/v1/blobs/${id1}`, dev.auth);
    assert.ok(blob.bytes.equals(small1));
    const exit2 = await second.stop();
    assert.equal(exit2.code, 0);
    await rm(dataDir, { recursive: true, force: true });
  });

  await step("per-IP sliding-window rate limit on /v1/auth/* -> 429 RATE_LIMITED with Retry-After", async () => {
    const limited = await startServer({ OPEN_SYNC_AUTH_RATE_LIMIT: "5" });
    extraServers.push(limited);
    let firstLimited = -1;
    for (let i = 0; i < 12; i += 1) {
      const res = await api(limited, "POST", "/v1/auth/kdf-params", { body: { email: `user${i}@example.com` } });
      if (res.status === 429) {
        assertError(res, 429, "RATE_LIMITED");
        assert.ok(Number(res.headers.get("retry-after")) >= 1);
        firstLimited = i;
        break;
      }
      assert.equal(res.status, 200);
    }
    assert.equal(firstLimited, 5, "6th request inside the window is refused");
    // Non-auth endpoints are not limited.
    for (let i = 0; i < 10; i += 1) assert.equal((await api(limited, "GET", "/health")).status, 200);
    await limited.stop();
    await rm(limited.dataDir, { recursive: true, force: true });
  });

  await step("DELETE /v1/account (runs scrypt) shares the per-IP auth rate limiter -> 429; other account routes are not limited", async () => {
    const limited = await startServer({ OPEN_SYNC_AUTH_RATE_LIMIT: "3" });
    extraServers.push(limited);
    const bogus = { token: "z".repeat(43), body: { authVerifier: b64(crypto.randomBytes(32)) } };
    for (let i = 0; i < 3; i += 1) {
      assertError(await api(limited, "DELETE", "/v1/account", bogus), 401, "UNAUTHORIZED");
    }
    const res = await api(limited, "DELETE", "/v1/account", bogus);
    assertError(res, 429, "RATE_LIMITED");
    assert.ok(Number(res.headers.get("retry-after")) >= 1);
    // The limiter bucket is shared with /v1/auth/*.
    assertError(await api(limited, "POST", "/v1/auth/kdf-params", { body: { email: "a@example.com" } }), 429, "RATE_LIMITED");
    // Other account routes (GET/PATCH, device removal) are untouched by the limiter.
    for (let i = 0; i < 5; i += 1) {
      assertError(await api(limited, "GET", "/v1/account", { token: bogus.token }), 401, "UNAUTHORIZED");
      assertError(await api(limited, "DELETE", "/v1/account/devices/x", { token: bogus.token }), 401, "UNAUTHORIZED");
    }
    await limited.stop();
    await rm(limited.dataDir, { recursive: true, force: true });
  });

  section("Device ID canonicalization");
  await step("uppercase and lowercase UUIDs are one device: login normalizes to lowercase, isCurrent works, DELETE with the uppercase id removes it", async () => {
    const dev = new Device("Casing", main);
    assert.notEqual(dev.wireId, dev.deviceId);
    const first = await dev.signIn(EMAIL, RECOVERED_PASSWORD);
    assert.equal(first.res.status, 200, JSON.stringify(first.res.json));
    assert.equal(first.res.json.deviceId, dev.deviceId, "uppercase request -> lowercase response");
    // Same device signs in again with a differently cased id: still one row.
    dev.wireId = dev.deviceId;
    assert.equal((await dev.signIn(EMAIL, RECOVERED_PASSWORD)).res.status, 200);
    const acct = (await api(main, "GET", "/v1/account", dev.auth)).json;
    assert.equal(acct.devices.filter((d) => d.deviceId.toLowerCase() === dev.deviceId).length, 1, "no duplicate device rows");
    assert.ok(acct.devices.every((d) => d.deviceId === d.deviceId.toLowerCase()), "all stored ids are lowercase");
    assert.equal(acct.devices.find((d) => d.deviceId === dev.deviceId).isCurrent, true, "isCurrent matches");
    // Refresh with the uppercase spelling also works.
    const refreshed = await api(main, "POST", "/v1/auth/refresh", { body: { refreshToken: dev.refreshToken, deviceId: dev.deviceId.toUpperCase() } });
    assert.equal(refreshed.status, 200, JSON.stringify(refreshed.json));
    dev.adopt({ ...refreshed.json, accountId: dev.accountId });
    assert.equal((await api(main, "GET", "/v1/account", dev.auth)).status, 200, "rotated tokens work");
    // Removing with the UPPERCASE id works from another device of the account.
    const del = await api(main, "DELETE", `/v1/account/devices/${dev.deviceId.toUpperCase()}`, d1.auth);
    assert.deepEqual(del.json, { ok: true, removed: true });
    const after = (await api(main, "GET", "/v1/account", d1.auth)).json.devices.map((d) => d.deviceId);
    assert.ok(!after.includes(dev.deviceId));
  });

  section("Account deletion");
  await step("DELETE /v1/account: wrong verifier -> 401; correct removes DB rows + blob files; login fails; websockets close", async () => {
    const blobDir = path.join(main.dataDir, "blobs", accountA);
    assert.ok(existsSync(blobDir), "blob directory exists before deletion");
    const ws = openWs(main, d1);
    await ws.opened;
    await ws.waitFor((m) => m.type === "connected");

    // Real verifier for the current password: fetch the live kdf params like a client would.
    const kdf = (await api(main, "POST", "/v1/auth/kdf-params", { body: { email: EMAIL } })).json.kdfParams;
    const real = passwordKeys(RECOVERED_PASSWORD, EMAIL, fromB64(kdf.saltBase64), kdf.iterations);
    assertError(await api(main, "DELETE", "/v1/account", { ...d1.auth, body: { authVerifier: b64(crypto.randomBytes(32)) } }), 401, "INVALID_CREDENTIALS");
    assert.equal((await api(main, "GET", "/v1/account", d1.auth)).status, 200, "account intact after a wrong verifier");

    const res = await api(main, "DELETE", "/v1/account", { ...d1.auth, body: { authVerifier: b64(real.authKey) } });
    assert.equal(res.status, 200, JSON.stringify(res.json));
    assert.deepEqual(res.json, { ok: true });
    assert.equal((await ws.waitClosed()).code, 4001);

    assert.ok(!existsSync(blobDir), "blob directory removed from disk");
    const { DatabaseSync } = await import("node:sqlite");
    const db = new DatabaseSync(path.join(main.dataDir, "open-sync.sqlite"), { readOnly: true });
    try {
      for (const table of ["accounts", "devices", "sessions", "sync_records", "sync_blobs", "recovery_tickets"]) {
        const col = table === "accounts" ? "id" : "account_id";
        const row = db.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE ${col} = ?`).get(accountA);
        assert.equal(row.n, 0, `${table} rows for deleted account`);
      }
      assert.equal(db.prepare("SELECT COUNT(*) AS n FROM accounts WHERE email = ?").get(EMAIL).n, 0);
      assert.ok(db.prepare("SELECT COUNT(*) AS n FROM accounts").get().n >= 1, "other accounts are untouched");
    } finally {
      db.close();
    }

    const probe = new Device("After delete", main);
    assert.equal((await probe.signIn(EMAIL, RECOVERED_PASSWORD)).res.status, 401);
    assertError(await api(main, "GET", "/v1/account", d1.auth), 401, "UNAUTHORIZED");
    assertError(await api(main, "GET", "/v1/account", d3.auth), 401, "UNAUTHORIZED");
    // The email can be registered again as a brand new account.
    const again = await new Device("Reborn", main).register(newAccountMaterial("fresh", EMAIL), "Reborn");
    assert.equal(again.status, 201);
    assert.notEqual(again.json.accountId, accountA);
    assert.equal(again.json.hasCloudData, false);
    // Account B is untouched.
    const bStatus = await api(main, "GET", "/v1/sync/status", bDevice.auth);
    assert.equal(bStatus.json.serverRevision, 1);
    assert.ok(existsSync(path.join(main.dataDir, "blobs", bDevice.accountId)), "B's blobs are intact");
  });

  section("Graceful shutdown");
  await step("SIGTERM closes WebSockets, HTTP server, and SQLite cleanly (exit code 0)", async () => {
    const ws = openWs(main, bDevice);
    await ws.opened;
    await ws.waitFor((m) => m.type === "connected");
    const exit = await main.stop();
    assert.equal(exit.code, 0, `exit ${JSON.stringify(exit)}; stderr: ${main.stderr()}`);
    const closed = await ws.waitClosed();
    assert.equal(closed.code, 1001);
    assert.ok(!main.stderr().includes("unhandled error"), `server logged an unhandled error:\n${main.stderr()}`);
  });
}

async function cleanup() {
  for (const s of [main, ...extraServers]) {
    if (!s) continue;
    if (s.proc.exitCode === null && s.proc.signalCode === null) {
      s.proc.kill("SIGKILL");
      await s.exited;
    }
  }
  for (const s of [main, ...extraServers]) {
    if (s?.dataDir) await rm(s.dataDir, { recursive: true, force: true });
  }
}

let failed = false;
try {
  await run();
} catch (error) {
  failed = true;
  console.error(`\nE2E aborted: ${error.message}`);
} finally {
  const pids = [main, ...extraServers].filter(Boolean).map((s) => s.proc.pid);
  const dirs = [main, ...extraServers].filter(Boolean).map((s) => s.dataDir);
  await cleanup();
  let leftoverProcs = 0;
  for (const pid of pids) {
    try {
      process.kill(pid, 0);
      leftoverProcs += 1;
    } catch {
      /* gone */
    }
  }
  const leftoverDirs = dirs.filter((d) => existsSync(d));
  console.log(`\nleftover server processes: ${leftoverProcs}; leftover temp dirs: ${leftoverDirs.length}`);
  if (leftoverProcs > 0 || leftoverDirs.length > 0) failed = true;
}

const passed = results.filter((r) => r.ok).length;
const failedCount = results.filter((r) => !r.ok).length;
console.log(`\n${failed || failedCount ? "FAILED" : "PASSED"}: ${passed} steps passed, ${failedCount} failed`);
process.exit(failed || failedCount ? 1 : 0);
