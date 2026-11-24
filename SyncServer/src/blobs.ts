import { randomBytes } from "node:crypto";
import { createReadStream, createWriteStream, renameSync, rmSync } from "node:fs";
import { mkdir, rm, stat } from "node:fs/promises";
import path from "node:path";
import { Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import { accountBlobDir } from "./account.js";
import { ApiError, validationError } from "./errors.js";
import { BASE_HEADERS } from "./http.js";
import type { Context } from "./http.js";
import { LIMITS, isBlobId, readQuery } from "./validation.js";

function blobIdParam(c: Context): string {
  const blobId = c.params["blobId"] ?? "";
  if (!isBlobId(blobId)) throw validationError('"blobId" must be 64 lowercase hex characters.');
  return blobId;
}

function blobPath(c: Context, accountId: string, blobId: string): string {
  return path.join(accountBlobDir(c.app.config.dataDir, accountId), blobId);
}

export async function putBlob(c: Context): Promise<void> {
  const session = c.auth;
  const blobId = blobIdParam(c);
  readQuery(c.url, []);

  const declared = c.req.headers["content-length"];
  if (declared === undefined || !/^\d{1,12}$/.test(declared)) {
    throw validationError("Content-Length is required.");
  }
  const size = Number(declared);
  if (size > LIMITS.maxBlobBytes) {
    throw validationError(`Blob exceeds ${LIMITS.maxBlobBytes} bytes.`);
  }
  if (size < LIMITS.minCiphertextBytes) {
    throw validationError(`Blob must be at least ${LIMITS.minCiphertextBytes} bytes (nonce + tag).`);
  }

  const existing = c.store.getBlobSize(session.accountId, blobId);
  if (existing !== undefined) {
    // Idempotent: content-addressed, already stored. Discard the upload.
    c.req.resume();
    await new Promise<void>((resolve, reject) => {
      c.req.once("end", resolve);
      c.req.once("error", reject);
      c.req.once("aborted", () => reject(new Error("request aborted")));
    });
    c.json(200, { ok: true, blobId, sizeBytes: existing, created: false });
    return;
  }

  const totals = c.store.blobTotals(session.accountId);
  if (totals.bytes + size > c.app.config.maxAccountBlobBytes) {
    throw new ApiError(413, "QUOTA_EXCEEDED", "Blob storage quota for this account would be exceeded.");
  }

  const dir = accountBlobDir(c.app.config.dataDir, session.accountId);
  await mkdir(dir, { recursive: true, mode: 0o700 });
  const finalPath = blobPath(c, session.accountId, blobId);
  const tempPath = path.join(dir, `.upload-${randomBytes(8).toString("hex")}.tmp`);

  let received = 0;
  const counter = new Transform({
    transform(chunk: Buffer, _encoding, callback) {
      received += chunk.length;
      if (received > size) callback(validationError("Body is longer than Content-Length."));
      else callback(null, chunk);
    },
  });
  try {
    await pipeline(c.req, counter, createWriteStream(tempPath, { flags: "wx", mode: 0o600 }));
    if (received !== size) throw validationError("Body is shorter than Content-Length.");

    const created = c.store.tx(() => {
      const raced = c.store.getBlobSize(session.accountId, blobId);
      if (raced !== undefined) return false;
      const used = c.store.blobTotals(session.accountId).bytes;
      if (used + size > c.app.config.maxAccountBlobBytes) {
        throw new ApiError(413, "QUOTA_EXCEEDED", "Blob storage quota for this account would be exceeded.");
      }
      c.store.insertBlob(session.accountId, blobId, size, Date.now());
      renameSync(tempPath, finalPath);
      return true;
    });
    if (!created) await rm(tempPath, { force: true });
    c.json(200, { ok: true, blobId, sizeBytes: created ? size : (c.store.getBlobSize(session.accountId, blobId) ?? size), created });
  } catch (error) {
    rmSync(tempPath, { force: true });
    throw error;
  }
}

async function sendBlob(c: Context, head: boolean): Promise<void> {
  const session = c.auth;
  const blobId = blobIdParam(c);
  readQuery(c.url, []);
  const notFound = (): ApiError => new ApiError(404, "BLOB_NOT_FOUND", "Blob not found.");
  if (c.store.getBlobSize(session.accountId, blobId) === undefined) throw notFound();
  const file = blobPath(c, session.accountId, blobId);
  let size: number;
  try {
    size = (await stat(file)).size;
  } catch {
    throw notFound();
  }
  c.res.writeHead(200, {
    ...BASE_HEADERS,
    "Content-Type": "application/octet-stream",
    "Content-Length": size,
  });
  if (head) {
    c.res.end();
    return;
  }
  try {
    await pipeline(createReadStream(file), c.res);
  } catch {
    c.res.destroy();
  }
}

export function getBlob(c: Context): Promise<void> {
  return sendBlob(c, false);
}

export function headBlob(c: Context): Promise<void> {
  return sendBlob(c, true);
}
