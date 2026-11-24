import { createHash, createHmac, randomBytes, scrypt, timingSafeEqual } from "node:crypto";

const SCRYPT_PARAMS = { N: 16384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 } as const;
const SCRYPT_KEYLEN = 32;
const SALT_BYTES = 16;

export function sha256Hex(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

/** Opaque 256-bit bearer token (base64url, 43 chars). */
export function newToken(): string {
  return randomBytes(32).toString("base64url");
}

function scryptAsync(secret: Buffer, salt: Buffer): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    scrypt(secret, salt, SCRYPT_KEYLEN, SCRYPT_PARAMS, (error, derived) => {
      if (error) reject(error);
      else resolve(derived);
    });
  });
}

export interface HashedVerifier {
  salt: Buffer;
  hash: Buffer;
}

/** Hashes a client-derived 32-byte verifier with scrypt and a fresh 16-byte salt. */
export async function hashVerifier(verifier: Buffer): Promise<HashedVerifier> {
  const salt = randomBytes(SALT_BYTES);
  return { salt, hash: await scryptAsync(verifier, salt) };
}

export async function verifyVerifier(
  verifier: Buffer,
  salt: Uint8Array,
  expected: Uint8Array,
): Promise<boolean> {
  const derived = await scryptAsync(verifier, Buffer.from(salt));
  const expectedBuffer = Buffer.from(expected);
  return expectedBuffer.length === derived.length && timingSafeEqual(derived, expectedBuffer);
}

/** Burns the same CPU as a real verification, for unknown accounts. */
export async function burnVerification(verifier: Buffer): Promise<void> {
  await scryptAsync(verifier, Buffer.alloc(SALT_BYTES));
}

/** Deterministic dummy KDF salt for unknown emails (no account enumeration). */
export function dummyKdfSalt(secret: Buffer, normalizedEmail: string): Buffer {
  return createHmac("sha256", secret).update("open-sync-kdf-dummy-v1|", "utf8").update(normalizedEmail, "utf8").digest();
}
