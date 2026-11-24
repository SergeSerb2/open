import { rm } from "node:fs/promises";
import path from "node:path";
import { ApiError } from "./errors.js";
import type { Context } from "./http.js";
import { verifyVerifier } from "./security.js";
import { expectKeys, parseUuidParam, readDisplayName, readVerifier } from "./validation.js";

export function accountBlobDir(dataDir: string, accountId: string): string {
  return path.join(dataDir, "blobs", accountId);
}

export function getAccount(c: Context): void {
  const session = c.auth;
  const account = c.store.getAccount(session.accountId);
  if (!account) throw new ApiError(401, "UNAUTHORIZED", "Missing or invalid access token.");
  const state = c.store.accountState(account.id);
  const blobs = c.store.blobTotals(account.id);
  c.json(200, {
    accountId: account.id,
    email: account.email,
    displayName: account.display_name,
    createdAt: account.created_at,
    serverRevision: state.serverRevision,
    resetRevision: state.resetRevision,
    hasCloudData: state.hasCloudData,
    collectionCounts: state.collectionCounts,
    blobCount: blobs.count,
    blobBytes: blobs.bytes,
    devices: c.store.listDevices(account.id).map((device) => ({
      ...device,
      isCurrent: device.deviceId === session.deviceId,
    })),
  });
}

export async function patchAccount(c: Context): Promise<void> {
  const session = c.auth;
  const body = await c.readJson();
  expectKeys(body, "Request", ["displayName"]);
  const displayName = readDisplayName(body);
  c.store.tx(() => c.store.setDisplayName(session.accountId, displayName, Date.now()));
  c.json(200, { ok: true, displayName });
}

export function removeDevice(c: Context): void {
  const session = c.auth;
  const deviceId = parseUuidParam(c.params["deviceId"] ?? "", "deviceId");
  const removed = c.store.tx(() => c.store.removeDevice(session.accountId, deviceId));
  if (removed) c.app.hub.reconcile(session.accountId);
  c.json(200, { ok: true, removed });
}

export async function deleteAccount(c: Context): Promise<void> {
  const session = c.auth;
  const body = await c.readJson();
  expectKeys(body, "Request", ["authVerifier"]);
  const verifier = readVerifier(body, "authVerifier");
  const account = c.store.getAccount(session.accountId);
  if (!account) throw new ApiError(401, "UNAUTHORIZED", "Missing or invalid access token.");
  if (!(await verifyVerifier(verifier, account.auth_salt, account.auth_hash))) {
    throw new ApiError(401, "INVALID_CREDENTIALS", "Password is incorrect.");
  }
  c.store.tx(() => c.store.deleteAccount(account.id));
  c.app.hub.closeAccount(account.id);
  await rm(accountBlobDir(c.app.config.dataDir, account.id), { recursive: true, force: true });
  c.json(200, { ok: true });
}
