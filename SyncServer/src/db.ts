import { randomBytes, randomUUID } from "node:crypto";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import type { SQLInputValue, StatementSync } from "node:sqlite";
import { LIMITS } from "./validation.js";
import type { Mutation } from "./validation.js";
import { sha256Hex, newToken } from "./security.js";

export const DB_FILE_NAME = "open-sync.sqlite";

const SCHEMA = `
CREATE TABLE IF NOT EXISTS server_meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS accounts (
  id                    TEXT PRIMARY KEY,
  email                 TEXT NOT NULL UNIQUE,
  display_name          TEXT NOT NULL,
  kdf_algorithm         TEXT NOT NULL,
  kdf_iterations        INTEGER NOT NULL,
  kdf_salt              BLOB NOT NULL,
  auth_salt             BLOB NOT NULL,
  auth_hash             BLOB NOT NULL,
  recovery_salt         BLOB NOT NULL,
  recovery_hash         BLOB NOT NULL,
  wrapped_vault_key_pw  BLOB NOT NULL,
  wrapped_vault_key_rec BLOB NOT NULL,
  current_revision      INTEGER NOT NULL DEFAULT 0,
  reset_revision        INTEGER NOT NULL DEFAULT 0,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  last_modified_at      INTEGER NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS devices (
  account_id   TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id    TEXT NOT NULL,
  device_name  TEXT NOT NULL,
  platform     TEXT NOT NULL,
  created_at   INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL,
  PRIMARY KEY (account_id, device_id)
) STRICT;

CREATE TABLE IF NOT EXISTS sessions (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id        TEXT NOT NULL,
  device_id         TEXT NOT NULL,
  token_family      TEXT NOT NULL,
  access_hash       TEXT NOT NULL UNIQUE,
  refresh_hash      TEXT NOT NULL UNIQUE,
  access_expires_at INTEGER NOT NULL,
  refresh_expires_at INTEGER NOT NULL,
  created_at        INTEGER NOT NULL,
  rotated_at        INTEGER,
  revoked_at        INTEGER,
  FOREIGN KEY (account_id, device_id) REFERENCES devices(account_id, device_id) ON DELETE CASCADE
) STRICT;
CREATE INDEX IF NOT EXISTS sessions_family_idx ON sessions(token_family);
CREATE INDEX IF NOT EXISTS sessions_account_idx ON sessions(account_id, device_id);

CREATE TABLE IF NOT EXISTS recovery_tickets (
  ticket_hash TEXT PRIMARY KEY,
  account_id  TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  created_at  INTEGER NOT NULL,
  expires_at  INTEGER NOT NULL,
  used_at     INTEGER
) STRICT;
CREATE INDEX IF NOT EXISTS recovery_tickets_account_idx ON recovery_tickets(account_id);

CREATE TABLE IF NOT EXISTS sync_records (
  account_id            TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  collection            TEXT NOT NULL,
  record_id             TEXT NOT NULL,
  revision              INTEGER NOT NULL,
  deleted               INTEGER NOT NULL CHECK (deleted IN (0, 1)),
  client_updated_at     INTEGER NOT NULL,
  ciphertext            BLOB NOT NULL,
  updated_by_device_id  TEXT NOT NULL,
  PRIMARY KEY (account_id, collection, record_id)
) STRICT;
CREATE INDEX IF NOT EXISTS sync_records_revision_idx ON sync_records(account_id, revision);

CREATE TABLE IF NOT EXISTS sync_blobs (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  blob_id    TEXT NOT NULL,
  size_bytes INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (account_id, blob_id)
) STRICT;
`;

type Row = Record<string, unknown>;

export interface AccountRow {
  id: string;
  email: string;
  display_name: string;
  kdf_algorithm: string;
  kdf_iterations: number;
  kdf_salt: Uint8Array;
  auth_salt: Uint8Array;
  auth_hash: Uint8Array;
  recovery_salt: Uint8Array;
  recovery_hash: Uint8Array;
  wrapped_vault_key_pw: Uint8Array;
  wrapped_vault_key_rec: Uint8Array;
  current_revision: number;
  reset_revision: number;
  created_at: number;
  updated_at: number;
  last_modified_at: number;
}

export interface SessionTokens {
  accessToken: string;
  refreshToken: string;
  accessTokenExpiresAt: number;
}

export interface AuthenticatedSession {
  accountId: string;
  deviceId: string;
  family: string;
}

export interface TokenTtls {
  accessMs: number;
  refreshMs: number;
}

export interface AccountState {
  serverRevision: number;
  resetRevision: number;
  hasCloudData: boolean;
  collectionCounts: Record<string, number>;
}

export interface DeviceInfo {
  deviceId: string;
  deviceName: string;
  platform: string;
  lastSeenAt: number;
}

export interface Conflict {
  collection: string;
  recordId: string;
  serverRevision: number;
  serverClientUpdatedAt: number;
}

export interface PushResult {
  currentRevision: number;
  resetRevision: number;
  acceptedCount: number;
  conflicts: Conflict[];
  /** True when at least one revision was written (others should be woken up). */
  changed: boolean;
}

export interface ChangeRecord {
  collection: string;
  recordId: string;
  revision: number;
  deleted: boolean;
  clientUpdatedAt: number;
  ciphertext: string;
  updatedByDeviceId: string;
}

export interface ChangesResult {
  currentRevision: number;
  resetRevision: number;
  fullResyncRequired: boolean;
  hasMore: boolean;
  nextSince: number;
  records: ChangeRecord[];
}

export type RefreshOutcome =
  | { kind: "ok"; accountId: string; deviceId: string; family: string; tokens: SessionTokens }
  | { kind: "invalid" }
  | { kind: "reused"; accountId: string };

export interface NewAccountInput {
  email: string;
  displayName: string;
  kdfIterations: number;
  kdfSalt: Buffer;
  authSalt: Buffer;
  authHash: Buffer;
  recoverySalt: Buffer;
  recoveryHash: Buffer;
  wrappedVaultKeyPw: Buffer;
  wrappedVaultKeyRec: Buffer;
}

export interface CredentialUpdate {
  kdfIterations: number;
  kdfSalt: Buffer;
  authSalt: Buffer;
  authHash: Buffer;
  wrappedVaultKeyPw: Buffer;
  recovery?: { salt: Buffer; hash: Buffer; wrappedVaultKeyRec: Buffer };
}

export class DeviceLimitError extends Error {
  constructor() {
    super("Device limit reached.");
    this.name = "DeviceLimitError";
  }
}

function num(row: Row, key: string): number {
  return Number(row[key]);
}

export class Store {
  readonly dataDir: string;
  readonly db: DatabaseSync;
  readonly hmacSecret: Buffer;
  private readonly statements = new Map<string, StatementSync>();
  private readonly lastSeenWrites = new Map<string, number>();
  private inTransaction = false;

  constructor(dataDir: string) {
    this.dataDir = dataDir;
    mkdirSync(path.join(dataDir, "blobs"), { recursive: true, mode: 0o700 });
    this.db = new DatabaseSync(path.join(dataDir, DB_FILE_NAME));
    this.db.exec("PRAGMA journal_mode = WAL");
    this.db.exec("PRAGMA foreign_keys = ON");
    this.db.exec("PRAGMA busy_timeout = 5000");
    this.db.exec("PRAGMA synchronous = NORMAL");
    this.db.exec(SCHEMA);
    this.hmacSecret = this.loadOrCreateSecret();
  }

  private loadOrCreateSecret(): Buffer {
    return this.tx(() => {
      const row = this.get("SELECT value FROM server_meta WHERE key = 'hmac_secret'");
      if (row) return Buffer.from(String(row["value"]), "base64");
      const secret = randomBytes(32);
      this.run("INSERT INTO server_meta (key, value) VALUES ('hmac_secret', ?)", secret.toString("base64"));
      this.run("INSERT OR IGNORE INTO server_meta (key, value) VALUES ('schema_version', '1')");
      return secret;
    });
  }

  close(): void {
    this.statements.clear();
    try {
      this.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    } catch {
      // best effort
    }
    this.db.close();
  }

  // ---- low level helpers ------------------------------------------------

  private prepare(sql: string): StatementSync {
    let stmt = this.statements.get(sql);
    if (stmt === undefined) {
      stmt = this.db.prepare(sql);
      this.statements.set(sql, stmt);
    }
    return stmt;
  }

  private run(sql: string, ...params: SQLInputValue[]): { changes: number } {
    const result = this.prepare(sql).run(...params);
    return { changes: Number(result.changes) };
  }

  private get(sql: string, ...params: SQLInputValue[]): Row | undefined {
    return this.prepare(sql).get(...params) as Row | undefined;
  }

  private all(sql: string, ...params: SQLInputValue[]): Row[] {
    return this.prepare(sql).all(...params) as Row[];
  }

  /** Runs `fn` inside BEGIN IMMEDIATE ... COMMIT. `fn` must be synchronous. */
  tx<T>(fn: () => T): T {
    if (this.inTransaction) return fn();
    this.db.exec("BEGIN IMMEDIATE");
    this.inTransaction = true;
    try {
      const result = fn();
      this.db.exec("COMMIT");
      return result;
    } catch (error) {
      try {
        this.db.exec("ROLLBACK");
      } catch {
        // connection already rolled back
      }
      throw error;
    } finally {
      this.inTransaction = false;
    }
  }

  // ---- accounts ----------------------------------------------------------

  findAccountByEmail(email: string): AccountRow | undefined {
    return this.get("SELECT * FROM accounts WHERE email = ?", email) as AccountRow | undefined;
  }

  getAccount(accountId: string): AccountRow | undefined {
    return this.get("SELECT * FROM accounts WHERE id = ?", accountId) as AccountRow | undefined;
  }

  /** Returns the new account id, or undefined if the email is already registered. */
  insertAccount(input: NewAccountInput, now: number): string | undefined {
    if (this.get("SELECT 1 AS x FROM accounts WHERE email = ?", input.email)) return undefined;
    const id = randomUUID();
    this.run(
      `INSERT INTO accounts (id, email, display_name, kdf_algorithm, kdf_iterations, kdf_salt,
         auth_salt, auth_hash, recovery_salt, recovery_hash, wrapped_vault_key_pw, wrapped_vault_key_rec,
         current_revision, reset_revision, created_at, updated_at, last_modified_at)
       VALUES (?, ?, ?, 'pbkdf2-sha256', ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?)`,
      id,
      input.email,
      input.displayName,
      input.kdfIterations,
      input.kdfSalt,
      input.authSalt,
      input.authHash,
      input.recoverySalt,
      input.recoveryHash,
      input.wrappedVaultKeyPw,
      input.wrappedVaultKeyRec,
      now,
      now,
      now,
    );
    return id;
  }

  updateCredentials(accountId: string, update: CredentialUpdate, now: number): void {
    this.run(
      `UPDATE accounts SET kdf_iterations = ?, kdf_salt = ?, auth_salt = ?, auth_hash = ?,
         wrapped_vault_key_pw = ?, updated_at = ? WHERE id = ?`,
      update.kdfIterations,
      update.kdfSalt,
      update.authSalt,
      update.authHash,
      update.wrappedVaultKeyPw,
      now,
      accountId,
    );
    if (update.recovery) {
      this.run(
        "UPDATE accounts SET recovery_salt = ?, recovery_hash = ?, wrapped_vault_key_rec = ? WHERE id = ?",
        update.recovery.salt,
        update.recovery.hash,
        update.recovery.wrappedVaultKeyRec,
        accountId,
      );
    }
  }

  setDisplayName(accountId: string, displayName: string, now: number): void {
    this.run("UPDATE accounts SET display_name = ?, updated_at = ? WHERE id = ?", displayName, now, accountId);
  }

  deleteAccount(accountId: string): boolean {
    return this.run("DELETE FROM accounts WHERE id = ?", accountId).changes > 0;
  }

  accountState(accountId: string): AccountState {
    const account = this.get("SELECT current_revision, reset_revision FROM accounts WHERE id = ?", accountId);
    const counts: Record<string, number> = {};
    let total = 0;
    for (const row of this.all(
      "SELECT collection, COUNT(*) AS n FROM sync_records WHERE account_id = ? AND deleted = 0 GROUP BY collection ORDER BY collection",
      accountId,
    )) {
      const n = num(row, "n");
      counts[String(row["collection"])] = n;
      total += n;
    }
    return {
      serverRevision: account ? num(account, "current_revision") : 0,
      resetRevision: account ? num(account, "reset_revision") : 0,
      hasCloudData: total > 0,
      collectionCounts: counts,
    };
  }

  // ---- devices -----------------------------------------------------------

  /** Registers or refreshes a device; throws DeviceLimitError for a 65th device. */
  upsertDevice(accountId: string, deviceId: string, deviceName: string, platform: string, now: number): void {
    const existing = this.get(
      "SELECT 1 AS x FROM devices WHERE account_id = ? AND device_id = ?",
      accountId,
      deviceId,
    );
    if (!existing) {
      const count = num(this.get("SELECT COUNT(*) AS n FROM devices WHERE account_id = ?", accountId) ?? {}, "n");
      if (count >= LIMITS.maxDevicesPerAccount) throw new DeviceLimitError();
    }
    this.run(
      `INSERT INTO devices (account_id, device_id, device_name, platform, created_at, last_seen_at)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(account_id, device_id) DO UPDATE SET
         device_name = excluded.device_name, platform = excluded.platform, last_seen_at = excluded.last_seen_at`,
      accountId,
      deviceId,
      deviceName,
      platform,
      now,
      now,
    );
  }

  listDevices(accountId: string): DeviceInfo[] {
    return this.all(
      "SELECT device_id, device_name, platform, last_seen_at FROM devices WHERE account_id = ? ORDER BY last_seen_at DESC, device_id",
      accountId,
    ).map((row) => ({
      deviceId: String(row["device_id"]),
      deviceName: String(row["device_name"]),
      platform: String(row["platform"]),
      lastSeenAt: num(row, "last_seen_at"),
    }));
  }

  /** Deletes a device (cascades to its sessions). */
  removeDevice(accountId: string, deviceId: string): boolean {
    return this.run("DELETE FROM devices WHERE account_id = ? AND device_id = ?", accountId, deviceId).changes > 0;
  }

  touchDevice(accountId: string, deviceId: string, now: number): void {
    const key = `${accountId}|${deviceId}`;
    const last = this.lastSeenWrites.get(key) ?? 0;
    if (now - last < 60_000) return;
    this.lastSeenWrites.set(key, now);
    if (this.lastSeenWrites.size > 10_000) this.lastSeenWrites.clear();
    this.run(
      "UPDATE devices SET last_seen_at = ? WHERE account_id = ? AND device_id = ?",
      now,
      accountId,
      deviceId,
    );
  }

  // ---- sessions ----------------------------------------------------------

  createSession(
    accountId: string,
    deviceId: string,
    family: string,
    ttls: TokenTtls,
    now: number,
  ): SessionTokens {
    const accessToken = newToken();
    const refreshToken = newToken();
    const accessTokenExpiresAt = now + ttls.accessMs;
    this.run(
      `INSERT INTO sessions (account_id, device_id, token_family, access_hash, refresh_hash,
         access_expires_at, refresh_expires_at, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      accountId,
      deviceId,
      family,
      sha256Hex(accessToken),
      sha256Hex(refreshToken),
      accessTokenExpiresAt,
      now + ttls.refreshMs,
      now,
    );
    return { accessToken, refreshToken, accessTokenExpiresAt };
  }

  newFamily(): string {
    return randomUUID();
  }

  authenticate(accessToken: string, now: number): AuthenticatedSession | undefined {
    const row = this.get(
      `SELECT account_id, device_id, token_family FROM sessions
       WHERE access_hash = ? AND revoked_at IS NULL AND access_expires_at > ?`,
      sha256Hex(accessToken),
      now,
    );
    if (!row) return undefined;
    return {
      accountId: String(row["account_id"]),
      deviceId: String(row["device_id"]),
      family: String(row["token_family"]),
    };
  }

  isFamilyActive(family: string): boolean {
    return this.get("SELECT 1 AS x FROM sessions WHERE token_family = ? AND revoked_at IS NULL LIMIT 1", family) !== undefined;
  }

  /** Revokes every live session of one device (a fresh login supersedes older ones). */
  revokeDeviceSessions(accountId: string, deviceId: string, now: number): void {
    this.run(
      "UPDATE sessions SET revoked_at = ? WHERE account_id = ? AND device_id = ? AND revoked_at IS NULL",
      now,
      accountId,
      deviceId,
    );
  }

  revokeFamily(family: string, now: number): void {
    this.run("UPDATE sessions SET revoked_at = ? WHERE token_family = ? AND revoked_at IS NULL", now, family);
  }

  revokeAllSessions(accountId: string, now: number): number {
    const row = this.get(
      "SELECT COUNT(DISTINCT token_family) AS n FROM sessions WHERE account_id = ? AND revoked_at IS NULL",
      accountId,
    );
    this.run("UPDATE sessions SET revoked_at = ? WHERE account_id = ? AND revoked_at IS NULL", now, accountId);
    return row ? num(row, "n") : 0;
  }

  /** Revokes all sessions except the given family; returns the number of sessions (families) revoked. */
  revokeOtherSessions(accountId: string, keepFamily: string, now: number): number {
    const row = this.get(
      "SELECT COUNT(DISTINCT token_family) AS n FROM sessions WHERE account_id = ? AND token_family != ? AND revoked_at IS NULL",
      accountId,
      keepFamily,
    );
    this.run(
      "UPDATE sessions SET revoked_at = ? WHERE account_id = ? AND token_family != ? AND revoked_at IS NULL",
      now,
      accountId,
      keepFamily,
    );
    return row ? num(row, "n") : 0;
  }

  /** Rotates a refresh token. A previously rotated token revokes its whole family. */
  rotateRefreshToken(refreshToken: string, deviceId: string, ttls: TokenTtls, now: number): RefreshOutcome {
    const row = this.get(
      `SELECT id, account_id, device_id, token_family, refresh_expires_at, rotated_at, revoked_at
       FROM sessions WHERE refresh_hash = ?`,
      sha256Hex(refreshToken),
    );
    if (!row) return { kind: "invalid" };
    const accountId = String(row["account_id"]);
    const family = String(row["token_family"]);
    if (row["rotated_at"] !== null) {
      this.revokeFamily(family, now);
      return { kind: "reused", accountId };
    }
    if (
      row["revoked_at"] !== null ||
      num(row, "refresh_expires_at") <= now ||
      String(row["device_id"]).toLowerCase() !== deviceId.toLowerCase()
    ) {
      return { kind: "invalid" };
    }
    this.run("UPDATE sessions SET rotated_at = ? WHERE id = ?", now, num(row, "id"));
    const storedDeviceId = String(row["device_id"]);
    const tokens = this.createSession(accountId, storedDeviceId, family, ttls, now);
    return { kind: "ok", accountId, deviceId: storedDeviceId, family, tokens };
  }

  // ---- recovery tickets --------------------------------------------------

  createRecoveryTicket(accountId: string, now: number, ttlMs: number): string {
    this.run("DELETE FROM recovery_tickets WHERE account_id = ?", accountId);
    const ticket = newToken();
    this.run(
      "INSERT INTO recovery_tickets (ticket_hash, account_id, created_at, expires_at) VALUES (?, ?, ?, ?)",
      sha256Hex(ticket),
      accountId,
      now,
      now + ttlMs,
    );
    return ticket;
  }

  /** Atomically consumes a valid, unused, unexpired ticket. */
  consumeRecoveryTicket(accountId: string, ticket: string, now: number): boolean {
    return (
      this.run(
        `UPDATE recovery_tickets SET used_at = ?
         WHERE ticket_hash = ? AND account_id = ? AND used_at IS NULL AND expires_at > ?`,
        now,
        sha256Hex(ticket),
        accountId,
        now,
      ).changes === 1
    );
  }

  deleteRecoveryTickets(accountId: string): void {
    this.run("DELETE FROM recovery_tickets WHERE account_id = ?", accountId);
  }

  // ---- sync --------------------------------------------------------------

  /** Applies a push atomically (caller wraps in tx). */
  applyPush(
    accountId: string,
    deviceId: string,
    mode: "delta" | "replaceCloud",
    mutations: Mutation[],
    now: number,
  ): PushResult {
    const account = this.get("SELECT current_revision, reset_revision FROM accounts WHERE id = ?", accountId);
    if (!account) throw new Error("account vanished during push");
    const startRevision = num(account, "current_revision");
    let revision = startRevision;
    let resetRevision = num(account, "reset_revision");
    let accepted = 0;
    const conflicts: Conflict[] = [];

    if (mode === "replaceCloud") {
      revision += 1;
      resetRevision = revision;
      this.run("DELETE FROM sync_records WHERE account_id = ?", accountId);
    }

    for (const m of mutations) {
      const existing = this.get(
        `SELECT revision, deleted, client_updated_at, ciphertext FROM sync_records
         WHERE account_id = ? AND collection = ? AND record_id = ?`,
        accountId,
        m.collection,
        m.recordId,
      );
      if (existing) {
        const serverUpdatedAt = num(existing, "client_updated_at");
        if (m.clientUpdatedAt < serverUpdatedAt) {
          conflicts.push({
            collection: m.collection,
            recordId: m.recordId,
            serverRevision: num(existing, "revision"),
            serverClientUpdatedAt: serverUpdatedAt,
          });
          continue;
        }
        if (
          m.clientUpdatedAt === serverUpdatedAt &&
          (num(existing, "deleted") === 1) === m.deleted &&
          Buffer.compare(Buffer.from(existing["ciphertext"] as Uint8Array), m.ciphertext) === 0
        ) {
          // Exact replay of the stored record: idempotent, no new revision.
          accepted += 1;
          continue;
        }
      }
      revision += 1;
      accepted += 1;
      this.run(
        `INSERT INTO sync_records (account_id, collection, record_id, revision, deleted,
           client_updated_at, ciphertext, updated_by_device_id)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(account_id, collection, record_id) DO UPDATE SET
           revision = excluded.revision, deleted = excluded.deleted,
           client_updated_at = excluded.client_updated_at, ciphertext = excluded.ciphertext,
           updated_by_device_id = excluded.updated_by_device_id`,
        accountId,
        m.collection,
        m.recordId,
        revision,
        m.deleted ? 1 : 0,
        m.clientUpdatedAt,
        m.ciphertext,
        deviceId,
      );
    }

    const changed = revision !== startRevision;
    if (changed) {
      this.run(
        "UPDATE accounts SET current_revision = ?, reset_revision = ?, last_modified_at = ? WHERE id = ?",
        revision,
        resetRevision,
        now,
        accountId,
      );
    }
    return { currentRevision: revision, resetRevision, acceptedCount: accepted, conflicts, changed };
  }

  readChanges(
    accountId: string,
    since: number,
    limit: number,
    collections: string[] | undefined,
  ): ChangesResult {
    this.db.exec("BEGIN");
    try {
      const account = this.get("SELECT current_revision, reset_revision FROM accounts WHERE id = ?", accountId);
      if (!account) throw new Error("account vanished during read");
      const currentRevision = num(account, "current_revision");
      const resetRevision = num(account, "reset_revision");
      const fullResyncRequired = (since > 0 && since < resetRevision) || since > currentRevision;
      const effectiveSince = fullResyncRequired ? 0 : since;

      const params: SQLInputValue[] = [accountId, effectiveSince];
      let filter = "";
      if (collections && collections.length > 0) {
        filter += ` AND collection IN (${collections.map(() => "?").join(",")})`;
        params.push(...collections);
      }
      if (fullResyncRequired) {
        filter += " AND NOT (deleted = 1 AND revision < ?)";
        params.push(resetRevision);
      }

      const meta = this.all(
        `SELECT revision, length(ciphertext) AS size FROM sync_records
         WHERE account_id = ? AND revision > ?${filter} ORDER BY revision ASC LIMIT ?`,
        ...params,
        limit + 1,
      );

      let picked = 0;
      let bytes = 0;
      for (const row of meta) {
        if (picked >= limit) break;
        const size = num(row, "size");
        if (picked > 0 && bytes + size > LIMITS.maxChangesPageBytes) break;
        bytes += size;
        picked += 1;
      }
      const hasMore = picked < meta.length;
      const lastRevision = picked > 0 ? num(meta[picked - 1] as Row, "revision") : effectiveSince;

      const records: ChangeRecord[] = [];
      if (picked > 0) {
        const rows = this.all(
          `SELECT collection, record_id, revision, deleted, client_updated_at, ciphertext, updated_by_device_id
           FROM sync_records WHERE account_id = ? AND revision > ?${filter} AND revision <= ? ORDER BY revision ASC`,
          ...params,
          lastRevision,
        );
        for (const row of rows) {
          records.push({
            collection: String(row["collection"]),
            recordId: String(row["record_id"]),
            revision: num(row, "revision"),
            deleted: num(row, "deleted") === 1,
            clientUpdatedAt: num(row, "client_updated_at"),
            ciphertext: Buffer.from(row["ciphertext"] as Uint8Array).toString("base64"),
            updatedByDeviceId: String(row["updated_by_device_id"]),
          });
        }
      }

      this.db.exec("COMMIT");
      return {
        currentRevision,
        resetRevision,
        fullResyncRequired,
        hasMore,
        nextSince: hasMore ? lastRevision : currentRevision,
        records,
      };
    } catch (error) {
      try {
        this.db.exec("ROLLBACK");
      } catch {
        // already rolled back
      }
      throw error;
    }
  }

  lastModifiedAt(accountId: string): number {
    const row = this.get("SELECT last_modified_at FROM accounts WHERE id = ?", accountId);
    return row ? num(row, "last_modified_at") : 0;
  }

  // ---- blobs -------------------------------------------------------------

  getBlobSize(accountId: string, blobId: string): number | undefined {
    const row = this.get("SELECT size_bytes FROM sync_blobs WHERE account_id = ? AND blob_id = ?", accountId, blobId);
    return row ? num(row, "size_bytes") : undefined;
  }

  blobTotals(accountId: string): { count: number; bytes: number } {
    const row = this.get(
      "SELECT COUNT(*) AS n, COALESCE(SUM(size_bytes), 0) AS bytes FROM sync_blobs WHERE account_id = ?",
      accountId,
    );
    return { count: row ? num(row, "n") : 0, bytes: row ? num(row, "bytes") : 0 };
  }

  insertBlob(accountId: string, blobId: string, sizeBytes: number, now: number): void {
    this.run(
      "INSERT INTO sync_blobs (account_id, blob_id, size_bytes, created_at) VALUES (?, ?, ?, ?)",
      accountId,
      blobId,
      sizeBytes,
      now,
    );
  }

  // ---- maintenance -------------------------------------------------------

  purgeExpired(now: number): void {
    this.tx(() => {
      this.run("DELETE FROM sessions WHERE refresh_expires_at <= ?", now);
      this.run("DELETE FROM recovery_tickets WHERE expires_at <= ? OR used_at IS NOT NULL", now);
    });
  }
}
