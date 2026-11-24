import { DeviceLimitError } from "./db.js";
import type { AccountRow, SessionTokens } from "./db.js";
import { ApiError } from "./errors.js";
import type { Context } from "./http.js";
import { burnVerification, dummyKdfSalt, hashVerifier, verifyVerifier } from "./security.js";
import {
  expectKeys,
  readDeviceName,
  readDisplayName,
  readEmail,
  readKdfParams,
  readPlatform,
  readString,
  readUuid,
  readVerifier,
  readWrappedKey,
  readBoolean,
} from "./validation.js";

const RECOVERY_TICKET_TTL_MS = 5 * 60 * 1000;
const DEFAULT_KDF_ITERATIONS = 600_000;

function kdfParamsJson(account: AccountRow): { algorithm: string; iterations: number; saltBase64: string } {
  return {
    algorithm: "pbkdf2-sha256",
    iterations: account.kdf_iterations,
    saltBase64: Buffer.from(account.kdf_salt).toString("base64"),
  };
}

/** Register / login / recover response body. Must be called inside the same transaction as the writes. */
function sessionResponse(c: Context, accountId: string, deviceId: string, tokens: SessionTokens): object {
  const account = c.store.getAccount(accountId);
  if (!account) throw new ApiError(401, "INVALID_CREDENTIALS", "Invalid email or password.");
  const state = c.store.accountState(accountId);
  return {
    accountId: account.id,
    email: account.email,
    displayName: account.display_name,
    deviceId,
    accessToken: tokens.accessToken,
    refreshToken: tokens.refreshToken,
    accessTokenExpiresAt: tokens.accessTokenExpiresAt,
    wrappedVaultKeyByPassword: Buffer.from(account.wrapped_vault_key_pw).toString("base64"),
    serverRevision: state.serverRevision,
    resetRevision: state.resetRevision,
    hasCloudData: state.hasCloudData,
    collectionCounts: state.collectionCounts,
  };
}

function ttls(c: Context): { accessMs: number; refreshMs: number } {
  return { accessMs: c.app.config.accessTokenTtlMs, refreshMs: c.app.config.refreshTokenTtlMs };
}

function deviceLimitError(): ApiError {
  return new ApiError(409, "DEVICE_LIMIT_REACHED", "This account already has the maximum number of devices.");
}

export async function register(c: Context): Promise<void> {
  const body = await c.readJson();
  expectKeys(body, "Request", [
    "email",
    "displayName",
    "kdfParams",
    "authVerifier",
    "recoveryAuthVerifier",
    "wrappedVaultKeyByPassword",
    "wrappedVaultKeyByRecovery",
    "deviceId",
    "deviceName",
    "platform",
  ]);
  const email = readEmail(body);
  const displayName = readDisplayName(body);
  const kdf = readKdfParams(body, "kdfParams");
  const authVerifier = readVerifier(body, "authVerifier");
  const recoveryVerifier = readVerifier(body, "recoveryAuthVerifier");
  const wrappedPw = readWrappedKey(body, "wrappedVaultKeyByPassword");
  const wrappedRec = readWrappedKey(body, "wrappedVaultKeyByRecovery");
  const deviceId = readUuid(body, "deviceId");
  const deviceName = readDeviceName(body);
  const platform = readPlatform(body);

  const auth = await hashVerifier(authVerifier);
  const recovery = await hashVerifier(recoveryVerifier);
  const now = Date.now();

  const result = c.store.tx(() => {
    const accountId = c.store.insertAccount(
      {
        email,
        displayName,
        kdfIterations: kdf.iterations,
        kdfSalt: kdf.salt,
        authSalt: auth.salt,
        authHash: auth.hash,
        recoverySalt: recovery.salt,
        recoveryHash: recovery.hash,
        wrappedVaultKeyPw: wrappedPw,
        wrappedVaultKeyRec: wrappedRec,
      },
      now,
    );
    if (accountId === undefined) return undefined;
    c.store.upsertDevice(accountId, deviceId, deviceName, platform, now);
    const tokens = c.store.createSession(accountId, deviceId, c.store.newFamily(), ttls(c), now);
    return sessionResponse(c, accountId, deviceId, tokens);
  });
  if (result === undefined) throw new ApiError(409, "EMAIL_TAKEN", "An account with this email already exists.");
  c.json(201, result);
}

export async function kdfParams(c: Context): Promise<void> {
  const body = await c.readJson();
  expectKeys(body, "Request", ["email"]);
  const email = readEmail(body);
  const account = c.store.findAccountByEmail(email);
  if (account) {
    c.json(200, { kdfParams: kdfParamsJson(account) });
    return;
  }
  c.json(200, {
    kdfParams: {
      algorithm: "pbkdf2-sha256",
      iterations: DEFAULT_KDF_ITERATIONS,
      saltBase64: dummyKdfSalt(c.store.hmacSecret, email).toString("base64"),
    },
  });
}

export async function login(c: Context): Promise<void> {
  const body = await c.readJson();
  expectKeys(body, "Request", ["email", "authVerifier", "deviceId", "deviceName", "platform"]);
  const email = readEmail(body);
  const verifier = readVerifier(body, "authVerifier");
  const deviceId = readUuid(body, "deviceId");
  const deviceName = readDeviceName(body);
  const platform = readPlatform(body);

  const account = c.store.findAccountByEmail(email);
  let ok = false;
  if (account) ok = await verifyVerifier(verifier, account.auth_salt, account.auth_hash);
  else await burnVerification(verifier);
  if (!account || !ok) throw new ApiError(401, "INVALID_CREDENTIALS", "Invalid email or password.");

  const now = Date.now();
  const response = c.store.tx(() => {
    const current = c.store.getAccount(account.id);
    if (!current || Buffer.compare(Buffer.from(current.auth_hash), Buffer.from(account.auth_hash)) !== 0) {
      return undefined; // deleted or password changed while verifying
    }
    try {
      c.store.upsertDevice(account.id, deviceId, deviceName, platform, now);
    } catch (error) {
      if (error instanceof DeviceLimitError) throw deviceLimitError();
      throw error;
    }
    c.store.revokeDeviceSessions(account.id, deviceId, now);
    const tokens = c.store.createSession(account.id, deviceId, c.store.newFamily(), ttls(c), now);
    return sessionResponse(c, account.id, deviceId, tokens);
  });
  if (response === undefined) throw new ApiError(401, "INVALID_CREDENTIALS", "Invalid email or password.");
  c.app.hub.reconcile(account.id);
  c.json(200, response);
}

export async function refresh(c: Context): Promise<void> {
  const body = await c.readJson();
  expectKeys(body, "Request", ["refreshToken", "deviceId"]);
  const refreshToken = readString(body, "refreshToken", { min: 1, max: 512 });
  const deviceId = readUuid(body, "deviceId");
  const now = Date.now();
  const outcome = c.store.tx(() => c.store.rotateRefreshToken(refreshToken, deviceId, ttls(c), now));
  if (outcome.kind === "reused") {
    c.app.hub.reconcile(outcome.accountId);
    throw new ApiError(401, "TOKEN_REUSED", "Refresh token was already used; the session has been revoked.");
  }
  if (outcome.kind === "invalid") {
    throw new ApiError(401, "INVALID_REFRESH_TOKEN", "Refresh token is invalid or expired.");
  }
  c.json(200, {
    accessToken: outcome.tokens.accessToken,
    refreshToken: outcome.tokens.refreshToken,
    accessTokenExpiresAt: outcome.tokens.accessTokenExpiresAt,
  });
}

export async function logout(c: Context): Promise<void> {
  const session = c.auth;
  const body = await c.readJson({ allowEmpty: true });
  expectKeys(body, "Request", []);
  c.store.tx(() => c.store.revokeFamily(session.family, Date.now()));
  c.app.hub.reconcile(session.accountId);
  c.json(200, { ok: true });
}

export async function changePassword(c: Context): Promise<void> {
  const session = c.auth;
  const body = await c.readJson();
  expectKeys(
    body,
    "Request",
    ["currentAuthVerifier", "newKdfParams", "newAuthVerifier", "newWrappedVaultKeyByPassword"],
    ["revokeOtherSessions"],
  );
  const currentVerifier = readVerifier(body, "currentAuthVerifier");
  const newKdf = readKdfParams(body, "newKdfParams");
  const newVerifier = readVerifier(body, "newAuthVerifier");
  const newWrapped = readWrappedKey(body, "newWrappedVaultKeyByPassword");
  const revokeOthers = Object.hasOwn(body, "revokeOtherSessions") ? readBoolean(body, "revokeOtherSessions") : true;

  const account = c.store.getAccount(session.accountId);
  if (!account) throw new ApiError(401, "UNAUTHORIZED", "Missing or invalid access token.");
  if (!(await verifyVerifier(currentVerifier, account.auth_salt, account.auth_hash))) {
    throw new ApiError(401, "INVALID_CREDENTIALS", "Current password is incorrect.");
  }
  const next = await hashVerifier(newVerifier);
  const now = Date.now();
  const revoked = c.store.tx(() => {
    const current = c.store.getAccount(session.accountId);
    if (!current || Buffer.compare(Buffer.from(current.auth_hash), Buffer.from(account.auth_hash)) !== 0) {
      throw new ApiError(409, "CONFLICT", "Credentials changed concurrently; retry.");
    }
    c.store.updateCredentials(
      session.accountId,
      {
        kdfIterations: newKdf.iterations,
        kdfSalt: newKdf.salt,
        authSalt: next.salt,
        authHash: next.hash,
        wrappedVaultKeyPw: newWrapped,
      },
      now,
    );
    return revokeOthers ? c.store.revokeOtherSessions(session.accountId, session.family, now) : 0;
  });
  c.app.hub.reconcile(session.accountId);
  c.json(200, { ok: true, revokedSessions: revoked });
}

export async function recoveryChallenge(c: Context): Promise<void> {
  const body = await c.readJson();
  expectKeys(body, "Request", ["email", "recoveryAuthVerifier"]);
  const email = readEmail(body);
  const verifier = readVerifier(body, "recoveryAuthVerifier");
  const account = c.store.findAccountByEmail(email);
  let ok = false;
  if (account) ok = await verifyVerifier(verifier, account.recovery_salt, account.recovery_hash);
  else await burnVerification(verifier);
  if (!account || !ok) throw new ApiError(401, "INVALID_RECOVERY_KEY", "Recovery key is not valid for this account.");

  const now = Date.now();
  const result = c.store.tx(() => {
    const current = c.store.getAccount(account.id);
    if (!current) return undefined;
    const ticket = c.store.createRecoveryTicket(account.id, now, RECOVERY_TICKET_TTL_MS);
    return {
      accountId: current.id,
      wrappedVaultKeyByRecovery: Buffer.from(current.wrapped_vault_key_rec).toString("base64"),
      recoveryTicket: ticket,
    };
  });
  if (!result) throw new ApiError(401, "INVALID_RECOVERY_KEY", "Recovery key is not valid for this account.");
  c.json(200, result);
}

export async function recover(c: Context): Promise<void> {
  const body = await c.readJson();
  expectKeys(body, "Request", [
    "email",
    "recoveryTicket",
    "newKdfParams",
    "newAuthVerifier",
    "newRecoveryAuthVerifier",
    "newWrappedVaultKeyByPassword",
    "newWrappedVaultKeyByRecovery",
    "deviceId",
    "deviceName",
    "platform",
  ]);
  const email = readEmail(body);
  const ticket = readString(body, "recoveryTicket", { min: 1, max: 512 });
  const newKdf = readKdfParams(body, "newKdfParams");
  const newAuthVerifier = readVerifier(body, "newAuthVerifier");
  const newRecoveryVerifier = readVerifier(body, "newRecoveryAuthVerifier");
  const newWrappedPw = readWrappedKey(body, "newWrappedVaultKeyByPassword");
  const newWrappedRec = readWrappedKey(body, "newWrappedVaultKeyByRecovery");
  const deviceId = readUuid(body, "deviceId");
  const deviceName = readDeviceName(body);
  const platform = readPlatform(body);

  const account = c.store.findAccountByEmail(email);
  const auth = await hashVerifier(newAuthVerifier);
  const recovery = await hashVerifier(newRecoveryVerifier);
  const now = Date.now();

  const response = c.store.tx(() => {
    if (!account) return undefined;
    if (!c.store.consumeRecoveryTicket(account.id, ticket, now)) return undefined;
    c.store.updateCredentials(
      account.id,
      {
        kdfIterations: newKdf.iterations,
        kdfSalt: newKdf.salt,
        authSalt: auth.salt,
        authHash: auth.hash,
        wrappedVaultKeyPw: newWrappedPw,
        recovery: { salt: recovery.salt, hash: recovery.hash, wrappedVaultKeyRec: newWrappedRec },
      },
      now,
    );
    c.store.deleteRecoveryTickets(account.id);
    c.store.revokeAllSessions(account.id, now);
    try {
      c.store.upsertDevice(account.id, deviceId, deviceName, platform, now);
    } catch (error) {
      if (error instanceof DeviceLimitError) throw deviceLimitError();
      throw error;
    }
    const tokens = c.store.createSession(account.id, deviceId, c.store.newFamily(), ttls(c), now);
    return sessionResponse(c, account.id, deviceId, tokens);
  });
  if (response === undefined) {
    throw new ApiError(401, "INVALID_RECOVERY_TICKET", "Recovery ticket is invalid, expired, or already used.");
  }
  if (account) c.app.hub.reconcile(account.id);
  c.json(200, response);
}
