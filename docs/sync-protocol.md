# Open Account & Sync Protocol (v1)

This document specifies the exact cryptography, wire protocol, data collections, and limits shared by the self-hosted Open Sync Server (`SyncServer/`) and the Open macOS client (`Packages/OpenKit/Sources/OpenSync/`, `App/Sync/`).

## 1. Zero-Knowledge End-to-End Encryption (v1)

The sync server never sees the user's plaintext password, raw encryption keys, or plaintext browser data.

### 1.1 Normalization and Random Values

- `normalizedEmail`: `email.trim().toLowerCase()` (UTF-8, 3..254 bytes, must contain `@` with non-empty local and domain parts).
- `kdfSalt`: 32 cryptographically random bytes (`saltBase64` in wire JSON).
- `vaultKey`: 32 cryptographically random bytes (AES-256 data key).
- `recoveryKeyBytes`: 32 cryptographically random bytes.

### 1.2 Password Key Derivation

- Algorithm: `pbkdf2-sha256`
- Iterations: `600000` (server accepts `300000...2000000`; default `600000`).
- Salt input to PBKDF2: `kdfSalt || UTF8("open-sync-v1:") || UTF8(normalizedEmail)` (concatenation of raw 32-byte `kdfSalt` and the UTF-8 domain tag + normalized email).
- Output: 32-byte `masterKey`.

From `masterKey`, derive two independent 32-byte subkeys using **HKDF-SHA256** (empty salt `""`, L = 32):

| Key | Info string (UTF-8) | Purpose |
|---|---|---|
| `authKey` | `"open-sync-auth-v1"` | Sent to server as `authVerifier` (Base64, 32 bytes). Server hashes it again with `scrypt` + per-user random salt. |
| `passwordWrapKey` | `"open-sync-wrap-v1"` | Stays on client only. Wraps/unwraps `vaultKey`. |

### 1.3 Recovery Key Format and Derivation

- `recoveryKeyBytes` (32 bytes = 256 bits) are encoded with standard RFC 4648 Base32 uppercase alphabet (`ABCDEFGHIJKLMNOPQRSTUVWXYZ234567`, no padding, 52 chars) prefixed with `OPEN-` and grouped in chunks of 4 characters separated by `-`:
  `OPEN-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX` (52 Base32 chars = 13 groups of 4 chars after `OPEN-`).
- Parser strips whitespace and hyphens, uppercases, strips optional leading `OPEN`, validates exact 52 Base32 characters decoding to 32 bytes (rejecting trailing non-zero padding bits).
- From `recoveryKeyBytes`, derive two independent 32-byte subkeys using **HKDF-SHA256** (empty salt `""`, L = 32):

| Key | Info string (UTF-8) | Purpose |
|---|---|---|
| `recoveryAuthKey` | `"open-sync-recovery-auth-v1"` | Sent to server as `recoveryAuthVerifier` (Base64, 32 bytes). Server hashes it with `scrypt` so `wrappedVaultKeyByRecovery` is never returned without proof of the recovery key. |
| `recoveryWrapKey` | `"open-sync-recovery-wrap-v1"` | Stays on client only. Wraps/unwraps `vaultKey`. |

### 1.4 Vault Subkeys

From `vaultKey` (32 bytes), derive client-side subkeys using **HKDF-SHA256** (empty salt `""`, L = 32):

| Key | Info string (UTF-8) | Purpose |
|---|---|---|
| `recordEncKey` | `"open-sync-record-enc-v1"` | AES-256-GCM key for encrypting sync records. |
| `blobEncKey` | `"open-sync-blob-enc-v1"` | AES-256-GCM key for encrypting Easel/Note asset blobs. |
| `payloadHashKey` | `"open-sync-payload-hash-v1"` | HMAC-SHA256 key for local dirty detection (never exposes plaintext hashes). |
| `blobIdKey` | `"open-sync-blob-id-v1"` | HMAC-SHA256 key for content-addressed `blobId = hex(HMAC-SHA256(blobIdKey, plaintextBlobBytes))` (64 lowercase hex chars). |

### 1.5 AES-256-GCM Wire Format

Every AES-256-GCM ciphertext (`wrappedVaultKeyByPassword`, `wrappedVaultKeyByRecovery`, record `ciphertext`, and encrypted blob files) uses the exact combined binary layout:

```
[12-byte random nonce] || [ciphertext bytes] || [16-byte GCM auth tag]
```

This matches Apple `CryptoKit`'s `AES.GCM.SealedBox.combined` verbatim. For JSON fields, this combined byte sequence is Base64-encoded. For blobs (`/v1/blobs/:blobId`), the raw combined bytes are sent as `application/octet-stream`.

### 1.6 Additional Authenticated Data (AAD)

| Ciphertext | Exact AAD UTF-8 string |
|---|---|
| `wrappedVaultKeyByPassword` | `open-sync-v1\|vault-pw\|<normalizedEmail>` |
| `wrappedVaultKeyByRecovery` | `open-sync-v1\|vault-rec\|<normalizedEmail>` |
| Sync record `ciphertext` | `open-sync-v1\|rec\|<accountId>\|<collection>\|<recordId>\|<deleted ? "1" : "0">` |
| Encrypted blob | `open-sync-v1\|blob\|<accountId>\|<blobId>` |

When a record is deleted (`deleted: true`), the client seals a minimal JSON tombstone payload `{"t":1}` with `deleted = 1` in the AAD, so the server cannot flip `deleted` without breaking GCM verification.

## 2. Allowed Collections

Every sync record's `collection` must be one of these exact strings:

1. `workspace.meta` — `recordId: "global"` — Ordered `profileIDs`, ordered `spaceIDs`, `routingRules`, `defaultDestination`.
2. `workspace.profile` — `recordId: <ProfileUUID>` — Profile metadata, icon, favorites, `ProfileSettings` (search engines, archive, sleep, downloads).
3. `workspace.space` — `recordId: <SpaceUUID>` — Space metadata, icon, theme, `profileID`, pinned nodes (tabs/folders/splits/live folders), `isPinnedCollapsed`.
4. `workspace.today` — `recordId: <SpaceUUID>` — Space's unpinned `today` nodes (tabs/folders/splits).
5. `workspace.windowLayout` — `recordId: "default"` — Portable sidebar width, sidebar mode, toolbar visibility preference.
6. `archive.profile` — `recordId: <ProfileUUID>` — Up to 2,000 most recent archived tab/folder records for a Profile.
7. `settings.preferences` — `recordId: "global"` — Portable allow-listed `open.*` preferences.
8. `settings.keybindings` — `recordId: "global"` — Custom keyboard shortcuts (`KeyBindingStore`).
9. `adblock.config` — `recordId: "global"` — Global ad-block enabled flag + per-profile enabled block-list IDs and allowed/excluded domains.
10. `boost.item` — `recordId: <ProfileUUID>:<BoostUUID>` — Individual Boost (CSS, JS, color adjustment, font, text zoom, zaps, site match, enabled state).
11. `easel.document` — `recordId: <EaselUUID>` — `EaselDocument` + encrypted `blobId` references for embedded images.
12. `note.document` — `recordId: <NoteUUID>` — `NoteDocument` + encrypted `blobId` references for attached assets.
13. `history.profile` — `recordId: <ProfileUUID>` — Up to 5,000 most recent history visits for a Profile.
14. `extensions.profile` — `recordId: <ProfileUUID>` — Installed Chrome Web Store extensions (`extensionID`, `name`, `isEnabled`, `isPinned`, `pinnedIndex`).
15. `credentials.profile` — `recordId: <ProfileUUID>` — Autofill saving preferences + saved logins, addresses, and credit cards (E2EE only).
16. `sitePermissions.profile` — `recordId: <ProfileUUID>` — Per-origin permission decisions and changed content settings for a Profile.

## 3. Hard Bounds & Validation

Every endpoint rejects unknown JSON fields, malformed UTF-8, invalid types, and out-of-range values with `400 Bad Request` (`{ "error": { "code": "...", "message": "..." } }`).

| Limit | Value |
|---|---|
| Max JSON request body | `8 MiB` (`8_388_608` bytes) |
| Max single record decoded ciphertext | `2 MiB` (`2_097_152` bytes) |
| Max mutations per `POST /v1/sync/push` | `256` |
| Max `limit` on `GET /v1/sync/changes` | `500` (default `200`) |
| Max single blob size (`PUT /v1/blobs/:blobId`) | `20 MiB` (`20_971_520` bytes) |
| Default max total blob storage per account | `250 MiB` (`262_144_000` bytes, configurable) |
| Max devices per account | `64` |
| Max `recordId` length | `128` ASCII characters matching `^[A-Za-z0-9._:-]{1,128}$` |
| Max `deviceName` length | `128` chars |
| Max `displayName` length | `120` chars |
| `email` length | `3...254` chars |
| `kdfParams.iterations` | `300_000...2_000_000` |
| `kdfParams.saltBase64` decoded length | exactly `32` bytes |
| `authVerifier` / `recoveryAuthVerifier` decoded length | exactly `32` bytes |
| Wrapped vault key decoded length | `60` bytes (12 nonce + 32 key + 16 tag) |
| `blobId` format | `^[0-9a-f]{64}$` |

## 4. HTTP REST API (`/v1/...`)

All error responses have the shape:
```json
{ "error": { "code": "STRING_CODE", "message": "Human readable message" } }
```

Authenticated endpoints require `Authorization: Bearer <accessToken>`.

### 4.1 Health
- `GET /health` -> `200 { "ok": true, "service": "open-sync", "version": 1 }`

### 4.2 Auth Endpoints
- `POST /v1/auth/register`
  - Request:
    ```json
    {
      "email": "user@example.com",
      "displayName": "Alex",
      "kdfParams": { "algorithm": "pbkdf2-sha256", "iterations": 600000, "saltBase64": "..." },
      "authVerifier": "<base64-32-bytes>",
      "recoveryAuthVerifier": "<base64-32-bytes>",
      "wrappedVaultKeyByPassword": "<base64-60-bytes>",
      "wrappedVaultKeyByRecovery": "<base64-60-bytes>",
      "deviceId": "<uuid-string>",
      "deviceName": "Alex's MacBook Pro",
      "platform": "macos"
    }
    ```
  - Response `201`:
    ```json
    {
      "accountId": "<uuid>",
      "email": "user@example.com",
      "displayName": "Alex",
      "deviceId": "<uuid>",
      "accessToken": "<opaque-token>",
      "refreshToken": "<opaque-token>",
      "accessTokenExpiresAt": 1795500000000,
      "wrappedVaultKeyByPassword": "<base64-60-bytes>",
      "serverRevision": 0,
      "resetRevision": 0,
      "hasCloudData": false,
      "collectionCounts": {}
    }
    ```
  - Errors: `409 EMAIL_TAKEN`, `400 VALIDATION_ERROR`.

- `POST /v1/auth/kdf-params`
  - Request: `{ "email": "user@example.com" }`
  - Response `200`: `{ "kdfParams": { "algorithm": "pbkdf2-sha256", "iterations": 600000, "saltBase64": "..." } }`
  - Unknown emails receive a deterministic HMAC-derived dummy salt so account existence is not leaked.

- `POST /v1/auth/login`
  - Request: `{ "email": "...", "authVerifier": "...", "deviceId": "...", "deviceName": "...", "platform": "macos" }`
  - Response `200`: same shape as `/v1/auth/register` response, with real `serverRevision`, `resetRevision`, `hasCloudData`, `collectionCounts`.
  - Errors: `401 INVALID_CREDENTIALS`.

- `POST /v1/auth/refresh`
  - Request: `{ "refreshToken": "...", "deviceId": "..." }`
  - Response `200`: `{ "accessToken": "...", "refreshToken": "...", "accessTokenExpiresAt": 1795500000000 }`
  - Rotates `refreshToken`; reusing an already-rotated token revokes the session family and returns `401 TOKEN_REUSED`.

- `POST /v1/auth/logout` (Bearer)
  - Request: `{}`
  - Response `200`: `{ "ok": true }`

- `POST /v1/auth/change-password` (Bearer)
  - Request:
    ```json
    {
      "currentAuthVerifier": "<base64-32-bytes>",
      "newKdfParams": { "algorithm": "pbkdf2-sha256", "iterations": 600000, "saltBase64": "..." },
      "newAuthVerifier": "<base64-32-bytes>",
      "newWrappedVaultKeyByPassword": "<base64-60-bytes>",
      "revokeOtherSessions": true
    }
    ```
  - Response `200`: `{ "ok": true, "revokedSessions": 1 }`

- `POST /v1/auth/recovery-challenge`
  - Request: `{ "email": "...", "recoveryAuthVerifier": "<base64-32-bytes>" }`
  - Response `200`: `{ "accountId": "<uuid>", "wrappedVaultKeyByRecovery": "<base64-60-bytes>", "recoveryTicket": "<opaque-5m-single-use-ticket>" }`
  - Errors: `401 INVALID_RECOVERY_KEY`.

- `POST /v1/auth/recover`
  - Request:
    ```json
    {
      "email": "...",
      "recoveryTicket": "...",
      "newKdfParams": { "algorithm": "pbkdf2-sha256", "iterations": 600000, "saltBase64": "..." },
      "newAuthVerifier": "<base64-32-bytes>",
      "newRecoveryAuthVerifier": "<base64-32-bytes>",
      "newWrappedVaultKeyByPassword": "<base64-60-bytes>",
      "newWrappedVaultKeyByRecovery": "<base64-60-bytes>",
      "deviceId": "<uuid>",
      "deviceName": "...",
      "platform": "macos"
    }
    ```
  - Response `200`: same shape as `/v1/auth/login` response (all prior sessions revoked).

### 4.3 Account & Devices Endpoints (Bearer)
- `GET /v1/account`
  - Response `200`:
    ```json
    {
      "accountId": "<uuid>",
      "email": "...",
      "displayName": "...",
      "createdAt": 1795400000000,
      "serverRevision": 42,
      "resetRevision": 0,
      "hasCloudData": true,
      "collectionCounts": { "workspace.space": 3 },
      "blobCount": 2,
      "blobBytes": 48120,
      "devices": [
        { "deviceId": "...", "deviceName": "...", "platform": "macos", "lastSeenAt": 1795450000000, "isCurrent": true }
      ]
    }
    ```
- `PATCH /v1/account`
  - Request: `{ "displayName": "New Name" }`
  - Response `200`: `{ "ok": true, "displayName": "New Name" }`
- `DELETE /v1/account/devices/:deviceId`
  - Response `200`: `{ "ok": true, "removed": true }`
- `DELETE /v1/account`
  - Request: `{ "authVerifier": "<base64-32-bytes>" }`
  - Response `200`: `{ "ok": true }`

### 4.4 Sync Endpoints (Bearer)
- `GET /v1/sync/status`
  - Response `200`: `{ "serverRevision": 42, "resetRevision": 0, "hasCloudData": true, "collectionCounts": { ... }, "lastModifiedAt": 1795450000000 }`

- `GET /v1/sync/changes?since=<int>&limit=<int>[&collections=a,b]`
  - Response `200`:
    ```json
    {
      "currentRevision": 42,
      "resetRevision": 0,
      "fullResyncRequired": false,
      "hasMore": false,
      "nextSince": 42,
      "records": [
        {
          "collection": "workspace.space",
          "recordId": "550e8400-e29b-41d4-a716-446655440000",
          "revision": 42,
          "deleted": false,
          "clientUpdatedAt": 1795450000000,
          "ciphertext": "<base64>",
          "updatedByDeviceId": "<uuid>"
        }
      ]
    }
    ```
  - If `since > 0 && since < resetRevision`, the server returns `fullResyncRequired: true` and streams records from revision `0` (excluding deleted tombstones from before `resetRevision`).

- `POST /v1/sync/push`
  - Request:
    ```json
    {
      "deviceId": "<uuid>",
      "mode": "delta",
      "baseRevision": 41,
      "mutations": [
        {
          "collection": "workspace.space",
          "recordId": "550e8400-e29b-41d4-a716-446655440000",
          "deleted": false,
          "clientUpdatedAt": 1795450000123,
          "ciphertext": "<base64>"
        }
      ]
    }
    ```
  - `mode`: `"delta"` (per-record LWW using `clientUpdatedAt`) or `"replaceCloud"` (atomically wipes existing account records, advances `resetRevision`, and inserts the supplied batch; for multi-batch cloud replacement, the first batch uses `"replaceCloud"` and subsequent batches use `"delta"`).
  - Response `200`:
    ```json
    {
      "currentRevision": 43,
      "resetRevision": 0,
      "acceptedCount": 1,
      "conflicts": [
        {
          "collection": "workspace.space",
          "recordId": "...",
          "serverRevision": 42,
          "serverClientUpdatedAt": 1795450000999
        }
      ]
    }
    ```

### 4.5 Encrypted Blob Endpoints (Bearer)
- `PUT /v1/blobs/:blobId` — Raw binary body (`application/octet-stream`), `Content-Length` ≤ 20 MiB. Idempotent if `blobId` already exists for the account.
  - Response `200`: `{ "ok": true, "blobId": "...", "sizeBytes": 12345, "created": true }`
- `GET /v1/blobs/:blobId` — Returns `200 application/octet-stream` raw ciphertext bytes, or `404 BLOB_NOT_FOUND`.
- `HEAD /v1/blobs/:blobId` — Returns `200` with `Content-Length` if present, or `404`.

### 4.6 Real-Time Wakeup WebSocket
- `GET /v1/sync/ws` (HTTP Upgrade to WebSocket, `Authorization: Bearer <accessToken>`, optional `X-Open-Device-Id: <deviceId>`).
- Server -> Client JSON text frames:
  - On connect: `{ "type": "connected", "serverRevision": 42, "resetRevision": 0 }`
  - On push by another device: `{ "type": "sync_available", "revision": 43, "resetRevision": 0, "sourceDeviceId": "<uuid>" }`
  - On session/device revocation: WebSocket close code `4001` (`"session_revoked"`).
- Client -> Server: standard RFC 6455 Ping/Pong or `{ "type": "ping" }` -> `{ "type": "pong" }`.
