import { validationError } from "./errors.js";

/** Hard bounds from docs/sync-protocol.md section 3. */
export const LIMITS = {
  maxJsonBodyBytes: 8_388_608,
  maxCiphertextBytes: 2_097_152,
  minCiphertextBytes: 28, // 12-byte nonce + 16-byte tag (empty plaintext)
  maxMutationsPerPush: 256,
  maxChangesLimit: 500,
  defaultChangesLimit: 200,
  maxBlobBytes: 20_971_520,
  maxDevicesPerAccount: 64,
  maxDeviceNameChars: 128,
  maxDisplayNameChars: 120,
  minEmailBytes: 3,
  maxEmailBytes: 254,
  minIterations: 300_000,
  maxIterations: 2_000_000,
  kdfSaltBytes: 32,
  verifierBytes: 32,
  wrappedVaultKeyBytes: 60,
  /** Server-side guard: decoded ciphertext bytes returned per /changes page. */
  maxChangesPageBytes: 8_388_608,
} as const;

export const COLLECTIONS: readonly string[] = [
  "workspace.meta",
  "workspace.profile",
  "workspace.space",
  "workspace.today",
  "workspace.windowLayout",
  "archive.profile",
  "settings.preferences",
  "settings.keybindings",
  "adblock.config",
  "boost.item",
  "easel.document",
  "note.document",
  "history.profile",
  "extensions.profile",
  "credentials.profile",
  "sitePermissions.profile",
];
const COLLECTION_SET = new Set(COLLECTIONS);

const RECORD_ID_RE = /^[A-Za-z0-9._:-]{1,128}$/;
const BLOB_ID_RE = /^[0-9a-f]{64}$/;
const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const PLATFORM_RE = /^[A-Za-z0-9._-]{1,32}$/;
const BASE64_RE = /^[A-Za-z0-9+/]*={0,2}$/;
const CONTROL_RE = /\p{Cc}/u;

export type JsonObject = Record<string, unknown>;

export function isCollection(value: string): boolean {
  return COLLECTION_SET.has(value);
}

export function isBlobId(value: string): boolean {
  return BLOB_ID_RE.test(value);
}

export function isUuid(value: string): boolean {
  return UUID_RE.test(value);
}

/** Parses a request body that must be a JSON object. */
export function parseJsonObject(raw: Buffer): JsonObject {
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(raw);
  } catch {
    throw validationError("Request body is not valid UTF-8.");
  }
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw validationError("Request body is not valid JSON.");
  }
  return asObject(value, "Request body");
}

export function asObject(value: unknown, what: string): JsonObject {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw validationError(`${what} must be a JSON object.`);
  }
  return value as JsonObject;
}

/** Rejects unknown fields and missing required fields. */
export function expectKeys(
  obj: JsonObject,
  what: string,
  required: readonly string[],
  optional: readonly string[] = [],
): void {
  const allowed = new Set<string>([...required, ...optional]);
  for (const key of Object.keys(obj)) {
    if (!allowed.has(key)) throw validationError(`${what} has unknown field "${key}".`);
  }
  for (const key of required) {
    if (!Object.hasOwn(obj, key)) throw validationError(`${what} is missing field "${key}".`);
  }
}

function codePointLength(value: string): number {
  let count = 0;
  for (const _ of value) count += 1;
  return count;
}

export function readString(
  obj: JsonObject,
  key: string,
  opts: { min: number; max: number; noControl?: boolean },
): string {
  const value = obj[key];
  if (typeof value !== "string") throw validationError(`"${key}" must be a string.`);
  if (!value.isWellFormed()) throw validationError(`"${key}" is not valid Unicode.`);
  const length = codePointLength(value);
  if (length < opts.min || length > opts.max) {
    throw validationError(`"${key}" length must be ${opts.min}...${opts.max} characters.`);
  }
  if (opts.noControl !== false && CONTROL_RE.test(value)) {
    throw validationError(`"${key}" must not contain control characters.`);
  }
  return value;
}

export function readBoolean(obj: JsonObject, key: string): boolean {
  const value = obj[key];
  if (typeof value !== "boolean") throw validationError(`"${key}" must be a boolean.`);
  return value;
}

export function readInteger(obj: JsonObject, key: string, min: number, max: number): number {
  const value = obj[key];
  if (typeof value !== "number" || !Number.isSafeInteger(value)) {
    throw validationError(`"${key}" must be an integer.`);
  }
  if (value < min || value > max) {
    throw validationError(`"${key}" must be between ${min} and ${max}.`);
  }
  return value;
}

/** Strict, canonical standard Base64 (with padding). */
export function decodeBase64(
  value: unknown,
  key: string,
  opts: { exactBytes?: number; minBytes?: number; maxBytes?: number },
): Buffer {
  if (typeof value !== "string") throw validationError(`"${key}" must be a Base64 string.`);
  const maxBytes = opts.exactBytes ?? opts.maxBytes ?? LIMITS.maxCiphertextBytes;
  if (value.length > Math.ceil(maxBytes / 3) * 4) {
    throw validationError(`"${key}" is too large.`);
  }
  if (value.length % 4 !== 0 || !BASE64_RE.test(value)) {
    throw validationError(`"${key}" is not valid Base64.`);
  }
  const decoded = Buffer.from(value, "base64");
  if (decoded.toString("base64") !== value) {
    throw validationError(`"${key}" is not canonical Base64.`);
  }
  if (opts.exactBytes !== undefined && decoded.length !== opts.exactBytes) {
    throw validationError(`"${key}" must decode to exactly ${opts.exactBytes} bytes.`);
  }
  if (opts.minBytes !== undefined && decoded.length < opts.minBytes) {
    throw validationError(`"${key}" must decode to at least ${opts.minBytes} bytes.`);
  }
  if (opts.maxBytes !== undefined && decoded.length > opts.maxBytes) {
    throw validationError(`"${key}" must decode to at most ${opts.maxBytes} bytes.`);
  }
  return decoded;
}

export function readBase64(
  obj: JsonObject,
  key: string,
  opts: { exactBytes?: number; minBytes?: number; maxBytes?: number },
): Buffer {
  return decodeBase64(obj[key], key, opts);
}

export function readVerifier(obj: JsonObject, key: string): Buffer {
  return readBase64(obj, key, { exactBytes: LIMITS.verifierBytes });
}

export function readWrappedKey(obj: JsonObject, key: string): Buffer {
  return readBase64(obj, key, { exactBytes: LIMITS.wrappedVaultKeyBytes });
}

/** `email.trim().toLowerCase()` with the protocol's length and shape rules. */
export function normalizeEmail(value: unknown, key = "email"): string {
  if (typeof value !== "string") throw validationError(`"${key}" must be a string.`);
  if (!value.isWellFormed()) throw validationError(`"${key}" is not valid Unicode.`);
  const email = value.trim().toLowerCase();
  const bytes = Buffer.byteLength(email, "utf8");
  if (bytes < LIMITS.minEmailBytes || bytes > LIMITS.maxEmailBytes) {
    throw validationError(`"${key}" length must be ${LIMITS.minEmailBytes}...${LIMITS.maxEmailBytes} bytes.`);
  }
  const at = email.indexOf("@");
  if (at <= 0 || at >= email.length - 1 || /[\s\p{Cc}]/u.test(email)) {
    throw validationError(`"${key}" is not a valid email address.`);
  }
  return email;
}

export function readEmail(obj: JsonObject, key = "email"): string {
  return normalizeEmail(obj[key], key);
}

export function readUuid(obj: JsonObject, key: string): string {
  const value = obj[key];
  if (typeof value !== "string" || !UUID_RE.test(value)) {
    throw validationError(`"${key}" must be a UUID string.`);
  }
  return value.toLowerCase();
}

export function parseUuidParam(value: string, key: string): string {
  if (!UUID_RE.test(value)) throw validationError(`"${key}" must be a UUID string.`);
  return value.toLowerCase();
}

export function readDeviceName(obj: JsonObject): string {
  return readString(obj, "deviceName", { min: 1, max: LIMITS.maxDeviceNameChars });
}

export function readPlatform(obj: JsonObject): string {
  const value = obj["platform"];
  if (typeof value !== "string" || !PLATFORM_RE.test(value)) {
    throw validationError(`"platform" must match ${PLATFORM_RE.source}.`);
  }
  return value;
}

export function readDisplayName(obj: JsonObject, key = "displayName"): string {
  return readString(obj, key, { min: 0, max: LIMITS.maxDisplayNameChars });
}

export interface KdfParams {
  algorithm: "pbkdf2-sha256";
  iterations: number;
  salt: Buffer;
}

export function readKdfParams(obj: JsonObject, key: string): KdfParams {
  const params = asObject(obj[key], `"${key}"`);
  expectKeys(params, `"${key}"`, ["algorithm", "iterations", "saltBase64"]);
  if (params["algorithm"] !== "pbkdf2-sha256") {
    throw validationError(`"${key}.algorithm" must be "pbkdf2-sha256".`);
  }
  const iterations = readInteger(params, "iterations", LIMITS.minIterations, LIMITS.maxIterations);
  const salt = decodeBase64(params["saltBase64"], `${key}.saltBase64`, { exactBytes: LIMITS.kdfSaltBytes });
  return { algorithm: "pbkdf2-sha256", iterations, salt };
}

export interface Mutation {
  collection: string;
  recordId: string;
  deleted: boolean;
  clientUpdatedAt: number;
  ciphertext: Buffer;
}

export function readMutation(value: unknown, index: number): Mutation {
  const what = `mutations[${index}]`;
  const obj = asObject(value, what);
  expectKeys(obj, what, ["collection", "recordId", "deleted", "clientUpdatedAt", "ciphertext"]);
  const collection = obj["collection"];
  if (typeof collection !== "string" || !COLLECTION_SET.has(collection)) {
    throw validationError(`${what}.collection is not an allowed collection.`);
  }
  const recordId = obj["recordId"];
  if (typeof recordId !== "string" || !RECORD_ID_RE.test(recordId)) {
    throw validationError(`${what}.recordId must match ${RECORD_ID_RE.source}.`);
  }
  const deleted = readBoolean(obj, "deleted");
  const clientUpdatedAt = readInteger(obj, "clientUpdatedAt", 0, Number.MAX_SAFE_INTEGER);
  const ciphertext = decodeBase64(obj["ciphertext"], `${what}.ciphertext`, {
    minBytes: LIMITS.minCiphertextBytes,
    maxBytes: LIMITS.maxCiphertextBytes,
  });
  return { collection, recordId, deleted, clientUpdatedAt, ciphertext };
}

/** Validates a query string; rejects unknown and repeated parameters. */
export function readQuery(
  url: URL,
  allowed: readonly string[],
): Map<string, string> {
  const out = new Map<string, string>();
  for (const [key, value] of url.searchParams) {
    if (!allowed.includes(key)) throw validationError(`Unknown query parameter "${key}".`);
    if (out.has(key)) throw validationError(`Query parameter "${key}" is repeated.`);
    out.set(key, value);
  }
  return out;
}

export function parseQueryInt(
  raw: string | undefined,
  key: string,
  fallback: number,
  min: number,
  max: number,
): number {
  if (raw === undefined) return fallback;
  if (!/^\d{1,16}$/.test(raw)) throw validationError(`"${key}" must be a non-negative integer.`);
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw validationError(`"${key}" must be between ${min} and ${max}.`);
  }
  return value;
}

export function parseCollectionsFilter(raw: string | undefined): string[] | undefined {
  if (raw === undefined) return undefined;
  const parts = raw.split(",");
  const seen = new Set<string>();
  for (const part of parts) {
    if (!COLLECTION_SET.has(part)) throw validationError(`"collections" contains "${part}", which is not an allowed collection.`);
    seen.add(part);
  }
  return [...seen];
}
