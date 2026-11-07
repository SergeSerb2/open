# Import from Arc, phase 2: plan

Status: ready for implementation.
Reader: one coding agent. The agent has no other context.
Read this file top to bottom. Do each step in order. Do not skip a step.

Product: Open. Open is a native macOS browser.
Language: Swift 6. Platform: macOS 26 and later.
Repo root: `/Users/serge/.t3/projects/open`.
Package: `Packages/OpenKit`. Build in that folder.

## How to read this plan

- One sentence gives one instruction.
- The word "record" means one Swift struct value.
- The word "store" means the Open SQLite history store.
- The word "reader" means new read-only code in `OpenImport`.
- The word "writer" means new write code in `OpenStore`.
- Code blocks show exact code shape. Copy names exactly.
- A check with the word MUST names a hard gate. Stop if a MUST check fails.

## Hard rules for this work

1. Read Arc data read-only. Never write to the Arc folder.
2. Never print a URL, a title, a username, a cookie value, or a secret value in a log, a test, a doc, or a commit.
3. CLI output shows counts, times, and hosts only. Add a `--show-titles` style flag only where this plan says so.
4. Never write unit tests. Verify end to end through the `openkit` CLI.
5. Do not spawn subagents.
6. Do not run `gclient`, `gn`, `ninja`, or a build in `~/Developer/open-engine/chromium_git`.
   That tree is read-only for this work. A build already runs there.
7. Make no network request in import code.
8. Commit no real Arc data. Fixtures use `example.com` hosts only.

## Facts that this plan rests on

Read these files before you write code:

- [model.md](../model.md) describes the current model, store, importer, and CLI.
- [data-model.md](../re/data-model.md) section 4 describes Chromium profile data.
- [suggest.md](../suggest.md) describes command bar ranking and frecency.
- Notes in `.re/import2/` hold schemas, counts, and encryption parameters.
  The notes hold no row content.

Measured facts on this Mac, 2026-10-25:

- Arc profile dir: `~/Library/Application Support/Arc/User Data/Default`.
- `History` holds 12 URL rows and 24 visit rows. History schema version is 70.
- `Top Sites` holds 5 rows. Schema version is 5.
- `Login Data` holds 0 login rows. `Cookies` holds 20 rows.
- `Web Data` holds 27 keyword rows. Address count is 0. Card count is 0.
- Secure Preferences holds 3 extension records. Each record points inside the Arc app bundle.
- Site engagement holds 6 origins in Preferences.

Current code facts:

- History store file: `Packages/OpenKit/Sources/OpenStore/HistoryStore.swift`.
- The history store holds `urls`, `visits`, and `history_fts`.
- `HistoryStore` stores times as `REAL` seconds since 1970.
- `HistoryStore.recordVisitsBulk` writes URL rows only. The method writes no visit rows.
  The method sets typed count to 0. Phase 2 adds a new method. Keep the old method for `bench`.
- Importer file: `Packages/OpenKit/Sources/OpenImport/ArcImport.swift`.
- `OpenImport` depends on `OpenModel` only. See `Packages/OpenKit/Package.swift`.
- CLI files: `Packages/OpenKit/Sources/openkit/main.swift` and `Packages/OpenKit/Sources/openkit/CLI.swift`.
- OpenSuggest reads history through `HistoryStore.search`.
  The search score uses visit count, typed count, and last visit time.

## Decision summary

| Topic | Decision |
|---|---|
| History | Import URLs and visits now. Skip search terms and segments. |
| Top Sites | Do not import. History already holds the source data. |
| Site engagement | Do not import in phase 2. Gain is small. Cost is real. |
| Passwords and cookies | Decrypt and parse now, behind consent. Store nothing now. |
| Autofill addresses | Parse now. Store nothing now. |
| Payment cards | Decrypt and count now. Store nothing now. |
| Secret storage later | Engine writes secrets through Chromium store APIs. Never write Chromium SQLite directly. |
| Extensions | List IDs now. Reinstall waits for the engine. |
| Open key | Engine uses `Open Safe Storage`. Arc key never becomes the Open key. |

---

## 1. History import

### 1.1 Source

Source file: `<arcUserData>/<profileDir>/History`.
Default profile dir: `Default`.
Chromium schema version 70 matches Chromium 156. See `.re/import2/schemas.md`.

Source tables to read:

- `urls(id, url, title, visit_count, typed_count, last_visit_time, hidden)`
- `visits(id, url, visit_time, transition, incremented_omnibox_typed_score)`
  The column `visits.url` holds the `urls.id` value.

Source tables to count and skip:

- `keyword_search_terms` — count rows, import nothing.
  Open has no search-term store. History search already covers the need.
- `segments` and `segment_usage` — import nothing.
  Segment names hold URL strings on this install. The names give no label for Open.

### 1.2 Destination

Destination: one `HistoryStore` per Open Profile.
CLI target: the history file at `<dbPath>`.
The `--db` value is a full file path. Example: `<outDir>/State/history.sqlite3`.
Keep the current `HistoryStore(root:)` init for app code.
Add one new init that takes a file URL. Section 1.5 gives the exact shape.

### 1.3 Time conversion

Chromium times use microseconds since 1601-01-01 00:00 UTC.
Open stores seconds since 1970-01-01 00:00 UTC as `REAL`.

Use integer math first. Then convert to `Double`.

```text
let offsetMicros: Int64 = 11_644_473_600_000_000
unixSeconds = Double(chromeMicros - offsetMicros) / 1_000_000.0
```

Rules:

- Reject a visit with `chromeMicros <= offsetMicros`. Count the visit as `skippedInvalidTime`.
- Reject a visit with a converted time later than now plus 24 hours. Count the visit as `skippedInvalidTime`.
- Never use the Arc 2001 epoch here. That epoch serves Storable JSON files only.

### 1.4 URL filter

Import a URL only if the scheme passes the filter.

Allow:

- `http`
- `https`
- `file`

Reject all other schemes. Count each rejected visit as `skippedInternal`.
The reject set covers `chrome`, `chrome-extension`, `arc`, `about`, `data`, `blob`, `view-source`, `javascript`, and `devtools`.
Compare schemes in lowercase.
A URL with no scheme counts as `skippedInternal`.

Read the `hidden` flag. Do not store the flag. Open has no hidden field.
Import hidden URL rows if a kept visit points at the row.

### 1.5 New types

Add file `Packages/OpenKit/Sources/OpenImport/ArcHistoryImport.swift`.

```swift
import Foundation

public struct ArcHistoryVisitRecord: Sendable {
    public var chromiumVisitID: Int64
    public var urlString: String
    public var title: String
    public var time: Date
    public var transition: String
    public var isTyped: Bool
}

public struct ArcHistoryImportBatch: Sendable {
    public var visits: [ArcHistoryVisitRecord]
}

public struct ArcHistoryReadReport: Sendable {
    public var sourceURLRows: Int = 0
    public var sourceVisitRows: Int = 0
    public var keptVisits: Int = 0
    public var skippedInternal: Int = 0
    public var skippedSubframe: Int = 0
    public var skippedInvalidTime: Int = 0
    public var keywordSearchTermRows: Int = 0
}
```

The reader returns batches. One batch holds at most 5,000 visits.
Batch flow bounds memory on a 1,000,000-visit profile.

Add file `Packages/OpenKit/Sources/OpenStore/HistoryImport.swift`.

```swift
import Foundation

public struct HistoryImportBatchResult: Sendable {
    public var insertedVisits: Int = 0
    public var duplicateVisits: Int = 0
    public var affectedURLs: Int = 0
}
```

### 1.6 Store schema change

Add this SQL to `HistoryStore.open()` in [HistoryStore.swift](../../Packages/OpenKit/Sources/OpenStore/HistoryStore.swift).
Run the SQL on every open. Each statement uses `IF NOT EXISTS`.

```sql
CREATE TABLE IF NOT EXISTS history_import_keys(
  visit_key TEXT PRIMARY KEY NOT NULL,
  url_id INTEGER NOT NULL REFERENCES urls(id)
);
CREATE INDEX IF NOT EXISTS idx_visits_url_time ON visits(url_id, time);
```

The visit key format is exact:

```text
<sourceProfileKey>:<chromiumVisitID>
```

Example shape: `Default:12345`. Never use a real ID in docs or logs.
The source profile key is the Arc profile dir name. Example: `Default`.

Keep current tables. Change no current column.
Current rows keep a null-free state. The new table starts empty.

### 1.7 Writer API

Add to `HistoryStore`:

```swift
public func importHistoryBatch(
    _ visits: [ArcHistoryVisitRecord],
    sourceProfileKey: String
) -> HistoryImportBatchResult
```

The reader lives in `OpenImport`. The writer needs the visit record type.
Solve the layer rule this way:

1. Define the visit record in `OpenStore`, not in `OpenImport`.
   Name: `ImportedHistoryVisit`. File: `HistoryImport.swift`.
2. The `OpenImport` reader maps its records to `ImportedHistoryVisit` in the CLI file.
   `openkit` already depends on both targets. See `Package.swift`.
3. Do not add an `OpenImport` to `OpenStore` dependency.

Final shapes:

```swift
// In OpenStore, HistoryImport.swift
public struct ImportedHistoryVisit: Sendable {
    public var chromiumVisitID: Int64
    public var urlString: String
    public var title: String
    public var time: Date
    public var transition: String
    public var isTyped: Bool
    public init(chromiumVisitID: Int64, urlString: String, title: String, time: Date, transition: String, isTyped: Bool) {
        self.chromiumVisitID = chromiumVisitID
        self.urlString = urlString
        self.title = title
        self.time = time
        self.transition = transition
        self.isTyped = isTyped
    }
}
```

Writer algorithm. Follow each step in order:

1. Open the store. Start one transaction with `BEGIN IMMEDIATE`.
2. Collect distinct URL strings from the batch. Keep first-seen order.
3. For each distinct URL, upsert one `urls` row.
   Use this SQL:

```sql
INSERT INTO urls(url, title, visit_count, typed_count, last_visit)
VALUES(?, ?, 0, 0, 0)
ON CONFLICT(url) DO UPDATE SET
  title = CASE WHEN excluded.title <> '' THEN excluded.title ELSE urls.title END;
```

   Bind the batch title for the URL. If two visits give two titles, keep the last non-empty title in batch order.
4. Read each URL row ID with `SELECT id FROM urls WHERE url = ?`.
   Store the map in a `[String: Int64]` dictionary.
5. For each visit, build the visit key. Insert the key with `INSERT OR IGNORE INTO history_import_keys(visit_key, url_id) VALUES(?, ?)`.
   Read `sqlite3_changes`. A change of 1 means a new visit. A change of 0 means a duplicate.
6. For each new visit only, insert one row:

```sql
INSERT INTO visits(url_id, time, transition) VALUES(?, ?, ?);
```

   Bind time as `time.timeIntervalSince1970`.
7. Collect each affected URL ID once. Recompute counts for each affected URL:

```sql
UPDATE urls SET
  visit_count = (SELECT COUNT(*) FROM visits WHERE visits.url_id = urls.id),
  typed_count = (SELECT COUNT(*) FROM visits WHERE visits.url_id = urls.id AND visits.transition = 'typed'),
  last_visit = COALESCE((SELECT MAX(time) FROM visits WHERE visits.url_id = urls.id), 0)
WHERE urls.id = ?;
```

8. Commit with `COMMIT`. On any SQLite failure, run `ROLLBACK` and return zero counts.
   The CLI treats a zero return with a non-empty batch as a failure. See section 5.
9. Return inserted visits, duplicate visits, and affected URL count.

Rules for the writer:

- Update only `visit_count`, `typed_count`, and `last_visit` in step 7.
  Keep `title` and `url` out of that update. FTS triggers then stay quiet.
- Never increment counts by hand. Recompute from `visits` each time.
  Recompute makes a repeat import safe.
- Keep one transaction per batch. Never run one transaction per visit.
- Reuse prepared statements inside one batch. Reset and clear bindings after each use.

### 1.8 Reader API

Add to `OpenImport` in `ArcHistoryImport.swift`:

```swift
public enum ArcHistoryImportError: Error {
    case missingHistoryFile
    case copyFailed
    case openFailed
    case schemaMismatch
}

public struct ArcHistoryReader {
    public let historyFileURL: URL
    public init(historyFileURL: URL)
    public func readBatches(batchSize: Int = 5000) throws -> (report: ArcHistoryReadReport, batches: [[ArcHistoryVisitRecord]])
}
```

Return batches in visit time order. Sort by `visit_time`, then by visit `id`.
A sync return is fine. The CLI runs the read off the main actor.

Reader steps:

1. Check the file exists. Throw `missingHistoryFile` if the file is absent.
2. Copy the file to a private temp dir. Section 1.9 gives the copy rules.
3. Open the copy with SQLite. Link `sqlite3` from `OpenImport`.
   Add `OpenImport` linker setting `.linkedLibrary("sqlite3")` in `Package.swift`.
   Add a small private SQLite reader inside `ArcHistoryImport.swift`.
   Do not reuse `SQLiteDB`. That type is internal to `OpenStore`.
4. Read `PRAGMA user_version` is not the schema gate. Read the `meta` table instead.
   Run `SELECT value FROM meta WHERE key = 'version'`.
   Accept versions 65 to 75. Throw `schemaMismatch` outside that range.
   Version 70 is the observed value. The range covers small Chromium drift.
5. Count `keyword_search_terms` rows. Store the count in the report.
6. Read URL rows into a map: `SELECT id, url, title, hidden FROM urls`.
7. Stream visits: `SELECT id, url, visit_time, transition, incremented_omnibox_typed_score FROM visits ORDER BY visit_time ASC, id ASC`.
8. Map each visit through sections 1.3, 1.4, and 1.10.
9. Append kept visits to the current batch. Flush a batch at 5,000 visits.
10. Delete the temp copy. Delete the copy in all paths, success and failure.

### 1.9 Copy rules for a locked DB

Arc locks the History file while Arc runs. Never open the live file.

1. Create a temp dir with `FileManager.default.temporaryDirectory`.
   Append `open-history-import-` plus a UUID string.
   Set dir permissions to `0o700`.
2. Copy `History` into the temp dir.
3. Copy `History-wal` if the file exists. Copy `History-shm` if the file exists.
4. Open the copy as read-write. The copy belongs to Open. SQLite recovery needs write access.
5. Run `PRAGMA quick_check`. Accept the text `ok` only.
6. On a quick check failure, wait 200 ms. Repeat steps 2 to 5 one time.
7. On a second failure, delete the temp dir. Throw `copyFailed`.
   The CLI prints a clear error. The error tells the user to quit Arc and run again.
8. Delete the temp dir after the read. Use `defer` in the reader.

### 1.10 Transition mapping

Chromium stores one integer. The low byte holds the core type.
Source: `ui/base/page_transition_types.h` in the Chromium tree.
Core mask: `0xFF` (decimal 255).

Compute:

```swift
let core = rawTransition & 0xFF
```

Map the core value:

| Core | Name for Open | Action |
|---|---|---|
| 0 | `link` | Keep |
| 1 | `typed` | Keep. Set `isTyped` true |
| 2 | `bookmark` | Keep |
| 3 | `subframe` | Skip. Count `skippedSubframe` |
| 4 | `subframe` | Skip. Count `skippedSubframe` |
| 5 | `generated` | Keep |
| 6 | `toplevel` | Keep |
| 7 | `form` | Keep |
| 8 | `reload` | Keep |
| 9 | `keyword` | Keep |
| 10 | `keyword` | Keep |
| Other | `link` | Keep |

Set `isTyped` true only for core 1.
Ignore the `incremented_omnibox_typed_score` flag for typed count.
The flag is a ranking hint in Chromium. Open typed count means core 1 only.
Ignore all qualifier bits for the stored name.
One qualifier matters for a future step only. Keep no qualifier in phase 2.

Store the name string in `visits.transition`.
The writer typed count counts rows with transition `typed`. See step 7 in section 1.7.

### 1.11 Titles

- Take the title from the `urls` row.
- An empty title stays empty. The command bar falls back to the host.
- Never fetch a title from the network.
- A later live visit may fill the title. `HistoryStore.recordVisit` already holds that rule.

### 1.12 Idempotent re-import

- The visit key gives idempotency. A repeat visit inserts no new row.
- Recompute gives stable counts. Counts never double.
- A second full import MUST give `insertedVisits = 0` for every batch.
- A partial import stays safe. Run the import again to finish the work.
- New Arc visits since the last import carry new Chromium visit IDs.
  The next import inserts only the new visits.

### 1.13 Performance target

Target: 100,000 visits in under 3 seconds on Apple Silicon, release build.
The current bench inserts 100,000 URLs in 1,162 to 1,400 ms. See [model.md](../model.md).
Keep the import path inside the target with these rules:

- One transaction per 5,000-visit batch.
- No per-visit `SELECT` for the URL ID. Use the batch map from step 4.
- No FTS work per visit. FTS triggers fire on URL insert only.
- No JSON work in the loop. No date formatter in the loop.
- Read the temp copy with `PRAGMA temp_store = MEMORY` on the reader connection.

Measure with the CLI timing line in section 5. The timing check is a MUST gate.

### 1.14 Effect on command bar frecency

OpenSuggest history frecency, from [suggest.md](../suggest.md):

```text
frecency = min(30, 8 * ln(1 + (visits + 3 * typed) / (1 + 0.15 * ageDays)))
```

History store search order uses `(visit_count + 3 * typed_count) / (1 + ageDays)`.

Import effects:

- Visit count and typed count raise the score at once.
- Last visit time sets the age. Old history decays in the correct way.
- An empty query lists top pages by `visit_count + 3 * typed_count`.
  Imported top pages appear in that list at once.
- No Suggest code change is needed in phase 2.
- No Top Sites import is needed for this effect.

---

## 2. Top Sites and site engagement

### 2.1 Top Sites

Source file: `<arcUserData>/<profileDir>/Top Sites`.
Source table: `top_sites(url, url_rank, title)`. Row count on this Mac: 5.

Decision: do not import Top Sites.

Reasons:

- History import already brings visit counts and last visit times.
- Chromium rebuilds Top Sites from history. The file is a cache.
- Five rows add no signal past frecency.
- A second store for five rows adds code with no user gain.

Action for phase 2: read nothing from Top Sites.
The history CLI does not open that file.

### 2.2 Site engagement

Source: Preferences JSON at `<arcUserData>/<profileDir>/Preferences`.
Key path: `profile.content_settings.exceptions.site_engagement`.
Each value holds `rawScore`, `pointsAddedToday`, `lastEngagementTime`, and `lastShortcutLaunchTime`.
Origin count on this Mac: 6. Raw scores range from 2.7 to 11.7.

Decision: do not import site engagement in phase 2.

Reasons:

- History frecency already ranks the same origins.
- Six origins change few command bar results.
- Engagement decays each day in Chromium. Open frecency decays by age.
  The two decay rules clash. A raw copy gives wrong rank after one week.
- `lastEngagementTime` is a JSON double. The double loses microsecond precision.
- Origin strings need parse work for a small gain.

Revisit rule: add engagement only if a command bar check shows a miss.
The check must name the query and the wrong order. Then map score this way:

1. Parse the origin to a host.
2. Cap the boost at 5 points.
3. Add the boost to history frecency for that host only.
4. Store no raw engagement table. Recompute the boost at import time.

Phase 2 action: no code reads Preferences for engagement.
Log no origin. Count nothing.

---

## 3. Passwords, cookies, and autofill

This section splits work in two parts.
Part A runs now in Swift. Part B waits for the engine.
Part A decrypts and parses. Part A stores nothing.

### 3.1 How Chromium encrypts secrets on macOS

Source tree: `~/Developer/open-engine/chromium_git/chromium/src`.
Read these files. Change nothing there.

- `components/os_crypt/async/browser/keychain_key_provider.mm`
- `components/os_crypt/async/common/encryptor.cc`
- `components/os_crypt/common/keychain_password_mac.mm`
- `components/os_crypt/async/browser/keychain_key_provider_unittest.mm`

Exact parameters:

| Item | Value |
|---|---|
| Key location | macOS Keychain, one generic password item |
| Stored prefix | 3 ASCII bytes `v10` |
| KDF | PBKDF2 with HMAC-SHA1 |
| Salt | 9 ASCII bytes `saltysalt` |
| Iterations | 1003 |
| Derived key | 16 bytes, AES-128 |
| Cipher | AES-128-CBC with PKCS7 padding |
| IV | 16 bytes, each byte 0x20 (space) |
| Fallback key | PBKDF2 with empty password, salt `saltysalt`, 1 iteration |

Known answer check from the Chromium test:

```text
PBKDF2-HMAC-SHA1(password "mock_password", salt "saltysalt", 1003 rounds)
= AF0F762AAF6D7D11581B7AA8CE7218DE (hex)
```

Keychain names need a probe. Stock Chromium uses one pair per branding:

- Google Chrome branding: service `Chrome Safe Storage`, account `Chrome`.
- No Google branding: service `Chromium Safe Storage`, account `Chromium`.

Arc uses a branded fork. The brief names the Arc item `Arc Safe Storage`.
Treat that name as the first probe candidate. Do not hardcode one pair.

Probe pairs in this order:

1. Service `Arc Safe Storage`, account `Arc`.
2. Service `Chrome Safe Storage`, account `Chrome`.
3. Service `Chromium Safe Storage`, account `Chromium`.

Open uses one new pair: service `Open Safe Storage`, account `Open`.
The engine creates the Open item. Swift import code never creates any Keychain item.

`Local State` holds no `os_crypt` key on this Mac.
Do not add a Local State key path for macOS.

### 3.2 Source tables

Profile dir: `<arcUserData>/<profileDir>`.

Passwords. File `Login Data`:

- `logins(origin_url, action_url, username_value, password_value, signon_realm, date_created, blacklisted_by_user, scheme, times_used, date_last_used, date_password_modified)`
- `password_notes(parent_id, key, value, date_created, confidential)`
  The note `value` is an encrypted blob. The note `key` is plain text.

Cookies. File `Cookies`:

- `cookies(host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, last_access_utc, has_expires, samesite, source_scheme, source_port)`
- Use `encrypted_value` if the blob is non-empty. Else use `value`.
- Cookie times use the Chromium 1601 microsecond epoch.
  An `expires_utc` of 0 means a session cookie.

Autofill. File `Web Data`:

- `addresses(guid, use_count, use_date, date_modified)`
- `address_type_tokens(guid, type, value)`
  Address field values are plain text. No key is needed for addresses.
- `autofill(name, value, count, date_created, date_last_used)`
  Form history values are plain text.
- `credit_cards(guid, name_on_card, expiration_month, expiration_year, card_number_encrypted, billing_address_id, use_count, use_date)`
  The card number blob uses the `v10` scheme. Name and expiry are plain text.

Search keywords. File `Web Data`, table `keywords`:
Phase 2 counts keyword rows only. Import no keyword row.
Open search engines live in OpenSuggest. A keyword map needs a separate design.

Copy each SQLite file before you open the file.
Use the copy rules in section 1.9 for each file. Change the file name per file.

### 3.3 Neutral in-memory types (Part A, build now)

Add file `Packages/OpenKit/Sources/OpenImport/ArcSecrets.swift`.
These types hold secrets in memory only. No type writes to disk.
No type conforms to `Codable`. No type offers a debug text form.

```swift
import Foundation

public struct ImportedLoginRecord {
    public var originURLString: String
    public var actionURLString: String?
    public var username: String
    public var passwordBytes: [UInt8]
    public var signonRealm: String
    public var dateCreated: Date
    public var isBlacklisted: Bool
    public var timesUsed: Int
    public mutating func zeroSecrets() {
        for i in passwordBytes.indices { passwordBytes[i] = 0 }
        passwordBytes.removeAll()
    }
}

public struct ImportedCookieRecord {
    public var hostKey: String
    public var name: String
    public var valueBytes: [UInt8]
    public var path: String
    public var expiresUTC: Date?
    public var isSecure: Bool
    public var isHTTPOnly: Bool
    public mutating func zeroSecrets() {
        for i in valueBytes.indices { valueBytes[i] = 0 }
        valueBytes.removeAll()
    }
}

public struct ImportedAddressRecord: Sendable {
    public var guid: String
    public var fields: [Int: String]
    public var useCount: Int
    public var useDate: Date
}

public struct ImportedCardRecord {
    public var guid: String
    public var nameOnCard: String
    public var expirationMonth: Int
    public var expirationYear: Int
    public var numberBytes: [UInt8]
    public mutating func zeroSecrets() {
        for i in numberBytes.indices { numberBytes[i] = 0 }
        numberBytes.removeAll()
    }
}

public struct ArcSecretsReadReport: Sendable {
    public var loginRows: Int = 0
    public var loginsDecryptOK: Int = 0
    public var loginsDecryptFailed: Int = 0
    public var loginsBlacklisted: Int = 0
    public var cookieRows: Int = 0
    public var cookiesDecryptOK: Int = 0
    public var cookiesDecryptFailed: Int = 0
    public var cookiesExpired: Int = 0
    public var addressRows: Int = 0
    public var cardRows: Int = 0
    public var cardsDecryptOK: Int = 0
    public var cardsDecryptFailed: Int = 0
    public var keywordRows: Int = 0
}
```

Rules for these types:

- Keep secret bytes as `[UInt8]`. Do not store a secret as `String`.
  A Swift `String` copies bytes and gives no zero control.
- Call `zeroSecrets()` in a `defer` block after each use.
- Never print a record. Never log a field.
- Keep records in one array at a time. Zero and drop the array before the next file.
- Do not make the types `Sendable`. Secrets stay on one task.

### 3.4 Decrypt function (Part A, build now)

Add file `Packages/OpenKit/Sources/OpenImport/ChromiumCrypto.swift`.

Use Security and CommonCrypto. Add imports:

```swift
import Security
import CommonCrypto
```

Add linker settings to the `OpenImport` target in `Package.swift`:

```swift
linkerSettings: [
    .linkedLibrary("sqlite3"),
    .linkedFramework("Security"),
]
```

CommonCrypto needs no linker setting on macOS.

Key fetch. One function:

```swift
enum ChromiumCryptoError: Error {
    case keychainItemNotFound
    case keychainAccessDenied(OSStatus)
    case keychainFailed(OSStatus)
    case badPrefix
    case decryptFailed
}

func fetchKeychainPassword(service: String, account: String) throws -> [UInt8]
```

Steps:

1. Build a query dict: class generic password, service, account, one match.
   Set return data true. Set match limit one.
2. Call `SecItemCopyMatching`. This call may show the system Keychain prompt.
   Call the function only after user consent. See section 3.5.
3. On `errSecItemNotFound`, throw `keychainItemNotFound`.
4. On `errSecAuthFailed` or `errSecUserCanceled`, throw `keychainAccessDenied`.
5. On success, copy the data bytes into `[UInt8]`.
   Zero the `Data` object bytes at once with `resetBytes(in:)`.
6. Return the password bytes. The caller zeros the bytes after key derivation.

Existence probe. One function:

```swift
func keychainItemExists(service: String, account: String) -> Bool
```

Use return attributes true and return data false.
This probe reads metadata only. The probe must not read secret data.
Probe the three pairs from section 3.1 in order. Pick the first pair that exists.
If no pair exists, throw `keychainItemNotFound`.

Key derivation. One function:

```swift
func deriveChromiumKey(passwordBytes: [UInt8]) -> [UInt8] // 16 bytes
```

Use `CCKeyDerivationPBKDF` with:

- Algorithm: `kCCPBKDFAlgorithm`.
- Password: the password bytes.
- Salt: the ASCII bytes of `saltysalt`.
- PRF: `kCCPRFHmacAlgSHA1`.
- Rounds: 1003.
- Key length: 16.

Zero the password bytes right after derivation. The caller owns that step.

Blob decrypt. One function:

```swift
func decryptChromiumBlob(_ blob: [UInt8], key: [UInt8]) throws -> [UInt8]
```

Steps:

1. If blob count is 0, throw `decryptFailed`.
2. If the first 3 bytes are not `v`, `1`, `0`, handle the blob as plain text.
   Return the blob bytes. Count the row as plain, not as decrypt OK.
   Section 5 output folds plain rows into the OK count with a note.
   Keep this rule: early Chromium rows hold plain text.
3. Drop the 3 prefix bytes. The rest is cipher data.
   Cipher data count must be a multiple of 16 and at least 16. Else throw `decryptFailed`.
4. Call `CCCrypt` with decrypt, AES, PKCS7 padding.
   Key: the 16 derived bytes. IV: 16 bytes of 0x20.
5. On a padding failure, retry one time with the fallback key.
   Fallback key bytes in hex: `d0d0ec9c7d77d43ac54187fa4818d17f`.
   Code the 16 bytes as a byte array literal.
6. Return plain bytes. The caller zeros cipher and plain bytes after use.
7. Zero the derived key after the last blob for the file.
   Zero with a byte loop, then remove all elements.

Never log a blob length per row. Counts only.
A length log per row can leak site patterns over time.

### 3.5 User consent flow

The Keychain prompt is unavoidable.
macOS shows the prompt because Open asks for an item that Arc created.
No API skips that prompt. Do not try to skip the prompt.

CLI flow for phase 2:

1. Print what will happen. Print counts of files found. Print no value.
2. Require the flag `--allow-keychain-access`.
   Without that flag, read row counts only. Touch no Keychain item.
   Print `keychain: not requested`.
3. With that flag, run the existence probe. Print the service name that exists.
   A service name is not a secret. Print the service name only.
4. Print one line before the data read.
   Text: `macOS will show a Keychain prompt. Choose Allow to continue.`
5. Read the password one time. Derive the key one time per run.
   Never read the password per row.
6. On denial (`errSecAuthFailed` or `errSecUserCanceled`):
   Print `error: Keychain access denied. No secret data read.`
   Exit with code 3. Retry no read. Show no second prompt.
7. On a missing item:
   Print `error: Arc Safe Storage Keychain item not found.`
   Exit with code 3.
8. The user may pick Always Allow in the system prompt.
   macOS then adds Open to the item access list. Later runs show no prompt.
   Do not promise that result. The user controls that choice.

App flow later, for the engine phase:

- Show an in-app consent sheet before the first Keychain read.
- The sheet names the data: passwords, cookies, addresses, cards.
- One Allow button starts the read. One Cancel button ends the flow.
- The app reads the key one time. The app then reads all four files.
- The app never asks again in the same run.

### 3.6 What Part A reads

Add one reader type in `ArcSecrets.swift`:

```swift
public struct ArcSecretsReader {
    public let profileDirectory: URL
    public init(profileDirectory: URL)
    public func countOnly() throws -> ArcSecretsReadReport
    public func readWithKey(_ key: [UInt8]) throws -> (report: ArcSecretsReadReport, logins: [ImportedLoginRecord], cookies: [ImportedCookieRecord], addresses: [ImportedAddressRecord], cards: [ImportedCardRecord])
}
```

- `countOnly()` opens copies and counts rows. The function decrypts nothing.
- `readWithKey(_:)` decrypts, validates, and returns records plus a report.
  Validate each secret: UTF-8 text for passwords and cookie values.
  A card number must pass UTF-8 and hold 12 to 19 digits after space removal.
  Count a failed validation as decrypt failed. Zero the bytes at once.
- Skip expired cookies. Count them as `cookiesExpired`.
  Expired means `expiresUTC` exists and that time is in the past.
- Count blacklisted logins apart. A blacklisted row holds an empty password by design.
  Do not count a blacklisted row as decrypt failed.
- Convert `date_created` and cookie times with the 1601 rule from section 1.3.
- Zero each record right after the CLI validates counts.
  The CLI in phase 2 keeps no record past the count step.

### 3.7 Destination (Part B, waits for the engine)

Recommendation: the engine writes secrets through Chromium store APIs.
Never write Chromium SQLite files directly from Swift.

Use these Chromium entry points in the engine fork:

- Passwords: `ProfileWriter::AddPasswordForm` in `chrome/browser/importer/profile_writer.h`.
  The writer calls the profile password store.
  Fallback in engine code: `PasswordStore::AddLogin` with one `PasswordForm`.
- History (future sync): `ProfileWriter::AddHistoryPage`. Phase 2 does not need this path.
- Cookies: the profile cookie store through the network service.
  Use `net::CanonicalCookie` creation, then store set.
  Never hand-build a cookie row.
- Autofill and cards: `WebDataService` and `AutofillManager` add APIs.
  Cards need engine encryption under the Open key.
- Search keywords: `ProfileWriter::AddKeywords` if a later phase imports keywords.

Reasons to reject direct SQLite writes:

- Chromium holds the DB open. A second writer risks lock errors and corruption.
- The engine must encrypt each secret with the Open key.
  Swift direct writes would need a second encryption stack forever.
- Chromium checks schema versions and sync metadata.
  A hand row can lack required fields, such as `signon_realm` and form data.
- Cookie rules need canonical form checks. The store API runs those checks.
- Password notes, insecure credential flags, and stats live in side tables.
  The store API keeps those tables in sync.

What waits for the engine:

- One OpenEngine call that takes neutral records and writes them.
  The call takes logins, cookies, addresses, and cards in one batch.
- The engine re-encrypts each secret with the Open key.
  The Open key pair is `Open Safe Storage` and `Open`.
- The engine shows the real account UI after import.
  Passwords must appear in the password manager. Cookies must survive a restart.

What Part A must never do:

- Never write `Login Data`, `Cookies`, or `Web Data` in any dir.
- Never copy Arc blobs into an Open profile. Blob copy binds data to the Arc key.
- Never save decrypted records to disk, even in a temp file.

---

## 4. Extensions

### 4.1 Source

Two sources. Read both. Take the union by extension ID.

Source A: Preferences file `Secure Preferences`, key `extensions.settings`.
Each key is one extension ID. Each value holds:

- `manifest` with `name`, `version`, and `manifest_version`.
- `from_webstore` as a bool.
- `location` as an integer.
- `path` as a string.
- `first_install_time` and `last_update_time` as Chromium time strings.

Source B: folder `<profileDir>/Extensions/<extensionID>/<version>/`.
Each subfolder name is one installed version.

On this Mac: Source A holds 3 records. Source B does not exist.
Each Source A path points inside the Arc app bundle.
Result: zero records qualify for reinstall on this Mac.

### 4.2 Record type (build now)

Add file `Packages/OpenKit/Sources/OpenImport/ArcExtensions.swift`.

```swift
import Foundation

public struct ArcExtensionRecord: Sendable {
    public var extensionID: String
    public var version: String?
    public var manifestVersion: Int?
    public var fromWebStore: Bool
    public var locationRaw: Int?
    public var isInternal: Bool
}

public struct ArcExtensionReport: Sendable {
    public var totalRecords: Int = 0
    public var internalRecords: Int = 0
    public var reinstallCandidates: Int = 0
    public var missingManifest: Int = 0
}
```

Classify a record as internal if one rule hits:

- The `path` value has prefix `/Applications/`.
- The `path` value is empty and Source B holds no folder for the ID.
  Count that record as internal. Store payload is absent.
- The record comes from Source B only and the folder holds no `manifest.json`.
  Count that record as internal.

All other records are reinstall candidates.
Never hardcode an extension ID list. Classify by path and payload only.
A disabled record still counts. Open reinstalls the extension. The user enables the extension.

Read `Secure Preferences` as JSON.
Never print an extension name. A name can hold user text.
Never print a full path. Print counts only. See section 5 for the ID flag rule.

### 4.3 Reinstall plan

**Implementation errata (Section 14 C3c, 2026-11-07):** The App queue has
no install deadline. An unanswered Chromium consent sheet remains pending.
`EI_failure_reported_app` gates offline App failure handling: a missing fixture
is refused before `installLocalCRX`, the row retains the error, the summary
counts it, and the next candidate installs. `EI_failure_reported_engine` is
**BLOCKED**, because `installLocalCRX` has no failure completion for a damaged
signature; the lead filed the engine need. The damaged-signature fixture stays
in the harness for that future hook. No engine change is part of this work.
A production Web Store request for a well-formed nonexistent ID is an INFO
receipt, bounded to two minutes by the harness. That bound never marks a row
failed or advances the App queue. The merged multi-Profile mapping resolves
Arc Default to the live Default by role, and named sources to their live
Profiles. The synthetic second source uses the observed nested
`custom._0.directoryBasename` shape with `Profile 2`. Readiness waits also have
no deadline; shutdown, cancellation, or closing the report stops them.

The App now detects
extensions during import for each `sourceProfileDirectories` entry. It retains
only in-memory metadata, grouped by the imported Open Profile ID, and records
total, internal, candidate, and missing-manifest counts in `ImportReport`.
Unreadable extension preferences are counted per Profile and do not stop the
sidebar import.

Both the first-run report and Settings import result show an **Extensions**
section only when mapped candidates exist. Every row starts checked and shows
the manifest name; imports with multiple Profiles also show the Profile name.
The report explains that extension settings and data stay behind. The user
must click **Install Extensions**. The queue calls the target Profile's
`OEExtensionManager.installFromWebStore` one item at a time and uses Open's
normal consent sheet. Cancel and already-installed items are skipped. Errors
retain the engine error string. Rows and the final installed/skipped/failed
counts show the result. First run can finish without installing.

An extension install is a separate user action. **Undo Import does not
uninstall an extension installed from this section.** No extension folder,
cache CRX, or extension storage is copied from Arc. Automation builds alone
can map synthetic candidate IDs to signed local CRX fixtures, using the P3
`installLocalCRX` consent path for offline e2e verification. Production always
uses the Web Store API. The e2e block is `tools/e2e/firstrun_extensions.py`,
called by the `firstrun` suite.

The historical staging plan below describes the original data/engine split;
the App workflow above supersedes its "engine side later" timing.

Data side now:

- Produce the candidate ID list in memory.
- Write a manifest file only if the user passes `--out-manifest`.
  See section 5. The file holds IDs. Guard the file.

Engine side later:

1. For each candidate ID, build the Web Store item address from the ID.
   Address form: `https://chromewebstore.google.com/detail/<extensionID>`.
   The engine uses its Web Store install API. Swift code builds no URL fetch.
2. Install one extension at a time. Use the engine install call.
   Chromium entry points: `ExtensionService` and the Web Store installer in `chrome/browser/extensions/`.
   The engine agent picks the exact call for the fork build.
3. On a 404 or a removed item, count the ID as `reinstallFailed`.
   Continue with the next ID. Fail no batch for one bad ID.
4. After install, the engine reads back the installed ID set.
   Compare the set with the candidate set. Report the diff as counts.
5. Copy no `Extensions` folder content.
   Copy no LevelDB state (`Extension State`, `Extension Rules`, `Extension Scripts`).
   Extension storage holds site data. A folder copy breaks signature checks.

What never ships:

- Never side-load a CRX from the Arc cache folders.
  Folders `extensions_crx_cache` and `component_crx_cache` hold cache data only.
- Never promise that extension data moves. Settings and storage stay behind.
  Tell the user that fact in the import UI later.

---

## 5. CLI acceptance checks

Add two commands to `openkit`.
Edit `Packages/OpenKit/Sources/openkit/main.swift` for dispatch.
Add file `Packages/OpenKit/Sources/openkit/HistoryImportCLI.swift`.
Add file `Packages/OpenKit/Sources/openkit/SecretsImportCLI.swift`.
Keep parse code in those files. Keep `CLI.swift` unchanged for these commands.

Exit codes for both commands:

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Account check failed. See the output line with `check` |
| 2 | Usage error. Print usage to stderr |
| 3 | Consent or Keychain error, or engine writer missing |
| 4 | Source file error: missing, copy failed, or schema mismatch |

### 5.1 `import-arc-history`

Usage line. Print this exact form on a usage error:

```text
usage: openkit import-arc-history --arc-user-data DIR --db PATH [--profile NAME]
```

Flags:

- `--arc-user-data DIR` — required. DIR holds one folder per Chromium profile.
- `--db PATH` — required. PATH is the Open history file path.
- `--profile NAME` — optional. Default `Default`. NAME is the Arc profile dir name.

Steps the command runs:

1. Build the source path: `<DIR>/<profile>/History`.
2. Read batches with `ArcHistoryReader`. Time the read.
3. Open `HistoryStore` at PATH. Add an init that takes a file URL:

```swift
// In HistoryStore: file URL init next to the root init.
public init(fileURL: URL) { self.fileURL = fileURL }
```

4. Map each reader record to `ImportedHistoryVisit`. Write each batch.
   Sum inserted and duplicate counts across batches.
5. Time the full run. Print the report. Print no URL and no title.

Output. Print these lines in this order.
Replace each `<n>` with the count. Print no URL and no title.

```text
history import:
  source profile=<profile> urlRows=<n> visitRows=<n>
  kept=<n> inserted=<n> duplicates=<n>
  skipped internal=<n> subframe=<n> invalidTime=<n>
  keywordSearchTerms=<n> (not imported)
  urls in store=<n>
  elapsed=<seconds>s visitsPerSecond=<n>
  check read: kept+skipped=<sum> visitRows=<n> OK
  check write: inserted+duplicates=<sum> kept=<n> OK
```

Check rules:

- Read sum is `kept + internal + subframe + invalidTime`.
  The read sum MUST equal `visitRows`.
- Write sum is `inserted + duplicates`.
  The write sum MUST equal `kept`.
- Print `OK` at the end of a check line only if the sums match.
  Else print `MISMATCH` at the end of that line.
- Exit with code 1 if any check line shows `MISMATCH`. Print no tree.

Timing gate:

- Print `elapsed` with 3 decimal places.
- The fixture check in section 6 gives the 100k gate.
  The live Arc check has few rows. Apply no time gate to the live check.

Failure output:

- Missing file: `error: History file not found at <path>.` Exit 4.
  Print the path. A path holds no secret.
- Copy failed: `error: History copy failed. Quit Arc and run again.` Exit 4.
- Schema mismatch: `error: History schema version <v> outside 65...75.` Exit 4.

### 5.2 `import-arc-secrets`

Usage line:

```text
usage: openkit import-arc-secrets --arc-user-data DIR [--profile NAME] --dry-run [--allow-keychain-access] [--out-manifest PATH]
```

Flags:

- `--arc-user-data DIR` — required.
- `--profile NAME` — optional. Default `Default`.
- `--dry-run` — required in phase 2.
  Without `--dry-run`, print `error: secret storage waits for the engine. Use --dry-run.` Exit 3.
- `--allow-keychain-access` — optional. Absent flag means counts only.
- `--out-manifest PATH` — optional. Writes the extension manifest from section 5.3.
  The flag belongs to this run so one consent flow covers secrets and extensions.

Steps:

1. Build the profile dir: `<DIR>/<profile>`.
2. Run `countOnly()`. Print row counts.
3. Without `--allow-keychain-access`, print `keychain: not requested`. Exit 0.
4. With the flag, probe Keychain pairs. Print the found service name.
5. Print the prompt warning line from section 3.5, step 4.
6. Fetch the password one time. Derive the key one time.
7. Run `readWithKey(_:)`. Zero each record after count validation.
   Zero the key. Drop all records.
8. Print the report. Print no value, no username, no host, no origin.

Output with no Keychain access:

```text
secrets import (dry-run):
  profile=<profile>
  logins rows=<n> blacklisted=<n>
  cookies rows=<n>
  addresses rows=<n> cards rows=<n> keywords rows=<n>
  keychain: not requested
  stored=0 (engine writer pending)
```

Output with Keychain access adds these lines. Replace the `keychain:` line:

```text
  keychain: service=<serviceName> found
  logins decrypt ok=<n> failed=<n>
  cookies decrypt ok=<n> failed=<n> expired=<n>
  cards decrypt ok=<n> failed=<n>
  check logins: ok+failed+blacklisted=<sum> rows=<n> OK
  check cookies: ok+failed+expired=<sum> rows=<n> OK
```

Print `MISMATCH` and exit 1 if a check sum fails.
Note: plain-text legacy rows count inside `ok`. Add no separate plain line.

Failure output:

- Keychain denied: `error: Keychain access denied. No secret data read.` Exit 3.
- Keychain missing: `error: Arc Safe Storage Keychain item not found.` Exit 3.
  Use that text for any missing pair. The service name in the text is the expected Arc name.
- Missing SQLite file: `error: <file> file not found in profile <profile>.` Exit 4.
  Treat each file as optional. A missing file gives row count 0 and no error.
  Exception: all three files missing gives the error. Name the profile dir.

### 5.3 Extension list in the secrets run

If `--out-manifest` is absent, print counts only:

```text
extensions:
  total=<n> internal=<n> reinstall candidates=<n> missingManifest=<n>
```

Extension IDs reveal the installed set. Treat IDs as personal data.

- Print no ID by default.
- With `--out-manifest PATH`, write one JSON file.
  File content: one object with key `candidates` and value as an array of ID strings.
  Set file permissions to `0o600` after write.
  Print `manifest: wrote <count> ids to <path>`.
  Print no ID in the CLI output.
- Never commit a manifest file. The file lives outside the repo or in `.re/`.

Add a standalone count check inside the same command.
No separate `list-arc-extensions` command ships in phase 2.
One command keeps consent and profile flags in one place.

### 5.4 Failure cases to handle

Handle each case. Print the given line. Use the given exit code.

| Case | Line | Code |
|---|---|---|
| Arc user data dir absent | `error: Arc user data dir not found at <path>.` | 4 |
| History file absent | See section 5.1 | 4 |
| DB locked and copy fails | See section 5.1 | 4 |
| History schema outside range | See section 5.1 | 4 |
| Profile dir absent | `error: profile <name> not found.` | 4 |
| Keychain item absent | See section 5.2 | 3 |
| Keychain denied | See section 5.2 | 3 |
| No `--dry-run` for secrets | See section 5.2 | 3 |
| Empty profile (0 rows each) | Print zero counts. | 0 |

---

## 6. Implementation order

Do the steps in order. Each step ends with checks.
Run all checks for a step before the next step.
Build command for each step, from `Packages/OpenKit`:

```text
swift build -c release
```

The build MUST end with zero warnings and zero errors.
Run the build after each step that changes Swift code.

### Step 1: History writer

Files:

- Edit `Packages/OpenKit/Sources/OpenStore/HistoryStore.swift`.
  Add the SQL from section 1.6. Add the file URL init from section 5.1.
- Add `Packages/OpenKit/Sources/OpenStore/HistoryImport.swift`.
  Add `ImportedHistoryVisit` and `importHistoryBatch`. See section 1.7.

Checks:

- Run the build. The build MUST pass.
- Run `swift run -c release openkit bench`.
  The bench MUST print history insert and search lines. Note the times.
  Times may shift. A crash fails the step.

### Step 2: History reader

Files:

- Add `Packages/OpenKit/Sources/OpenImport/ArcHistoryImport.swift`.
  Add the types and reader from sections 1.5 and 1.8.
- Edit `Packages/OpenKit/Package.swift`.
  Add `.linkedLibrary("sqlite3")` to the `OpenImport` target.

Checks:

- Run the build. The build MUST pass.
- Create the synthetic fixture. See appendix A.
  Run fixture script F1. The script builds a small History DB.
- No CLI exists yet. Stop after the build check.

### Step 3: History CLI

Files:

- Add `Packages/OpenKit/Sources/openkit/HistoryImportCLI.swift`.
- Edit `Packages/OpenKit/Sources/openkit/main.swift`.
  Add dispatch for `import-arc-history`.

Checks. Run each check. Each check MUST pass:

1. Fixture import. Run:

```text
swift run -c release openkit import-arc-history --arc-user-data /tmp/open-fixture-arc --db /tmp/open-fixture-out/history.sqlite3
```

   Expect `check read` OK and `check write` OK.
   Fixture F1 holds 6 visit rows. Expect kept 3, internal 1, subframe 1, invalidTime 1.
2. Repeat the same run. Expect inserted 0. Expect duplicates 3.
   Both check lines MUST show OK.
3. Timing fixture. Run fixture script F2 for 100,000 visits.
   Run the import. Note `elapsed`.
   The elapsed value MUST be under 3.000 s.
4. Missing file. Run with an empty user data dir.
   Expect exit code 4 and the missing file line from section 5.1.
5. Live Arc read. Copy is internal to the reader. Run:

```text
swift run -c release openkit import-arc-history --arc-user-data "$HOME/Library/Application Support/Arc/User Data" --db /tmp/open-live-out/history.sqlite3
```

   Expect both check lines OK. Note counts only.
   Paste no output with titles into docs. This command prints no titles.
6. Search effect. Run `openkit bench` again.
   Then run `openkit suggest-check` if the command exists in the tree.
   Expect PASS lines. A FAIL fails the step.

### Step 4: Crypto core

Files:

- Add `Packages/OpenKit/Sources/OpenImport/ChromiumCrypto.swift`.
  Add the fetch, probe, derive, and decrypt functions from section 3.4.
- Edit `Packages/OpenKit/Package.swift`.
  Add `.linkedFramework("Security")` to the `OpenImport` target.

Checks:

1. Run the build. The build MUST pass.
2. Known answer check. Write a throwaway probe in `/tmp`, not in the repo.
   The probe calls `deriveChromiumKey` with password bytes for `mock_password`.
   Expect hex `AF0F762AAF6D7D11581B7AA8CE7218DE`.
   Delete no repo file for this probe. Keep the probe in `/tmp`.
3. Round trip check in the same probe.
   Encrypt one known plain text with CommonCrypto and the derived key.
   Use IV 16 bytes of 0x20. Prefix the cipher with `v10`.
   Decrypt with `decryptChromiumBlob`. Expect the same plain text.
   Print PASS or FAIL only. Print no key and no plain text.

### Step 5: Secrets reader and CLI

Files:

- Add `Packages/OpenKit/Sources/OpenImport/ArcSecrets.swift`.
  Add the types and reader from sections 3.3 and 3.6.
- Add `Packages/OpenKit/Sources/OpenImport/ArcExtensions.swift`.
  Add the types from section 4.2. Read Secure Preferences in this file.
- Add `Packages/OpenKit/Sources/openkit/SecretsImportCLI.swift`.
- Edit `Packages/OpenKit/Sources/openkit/main.swift`.
  Add dispatch for `import-arc-secrets`.

Checks. Run each check:

1. Run the build. The build MUST pass.
2. Dry run, no consent. Run against the live Arc dir:

```text
swift run -c release openkit import-arc-secrets --arc-user-data "$HOME/Library/Application Support/Arc/User Data" --dry-run
```

   Expect `keychain: not requested` and `stored=0`.
   Expect extension counts with 3 total and 0 candidates on this Mac.
   Counts may change after new Arc use. The stored line MUST stay 0.
3. Dry run, no `--dry-run` flag. Run the same command without `--dry-run`.
   Expect exit code 3 and the engine writer line from section 5.2.
4. Consent run. This run shows a system prompt. Run only with the user present:

```text
swift run -c release openkit import-arc-secrets --arc-user-data "$HOME/Library/Application Support/Arc/User Data" --dry-run --allow-keychain-access
```

   Pick Deny in the prompt one time.
   Expect exit code 3 and the denied line. No second prompt may appear.
   Run again and pick Allow. Expect decrypt count lines and check OK lines.
   On this Mac, login rows are 0. Decrypt lines for logins stay 0.
   That result still passes. Cookie decrypt lines prove the path.
5. Synthetic secret fixture. See appendix B.
   Build fixture S1 with a test Keychain item.
   Use a test service name in the probe. Never touch the Arc item for the fixture.
   Expect decrypt ok counts to match fixture counts.
   Delete the test Keychain item after the check.
   Record the delete step in your run notes.
6. Manifest check. Run with `--out-manifest /tmp/open-ext-manifest.json`.
   Expect the wrote line with the candidate count.
   Check file permissions with `ls -l`. Expect `600`.
   Delete the manifest file after the check if the count is 0.

### Step 6: Record the decision

Files:

- No code change in this step.

Checks:

- Read section 2 again.
- Confirm no code reads Top Sites or site engagement.
  Search the new files for `Top Sites` and `site_engagement`.
  Expect zero hits in Swift files.
- Confirm no Swift file writes `Login Data`, `Cookies`, or `Web Data`.
  Search for those names in write calls. Expect zero write hits.
  Read calls on copies are fine.

### Step 7: Final end-to-end pass

Run each item. Record pass or fail per item:

1. `swift build -c release` in `Packages/OpenKit`. Zero warnings. Zero errors.
2. `swift run -c release openkit bench`. Note history times.
3. `swift run -c release openkit commands-demo /tmp/open-final-demo`. Expect all checks OK.
4. History fixture F1 import twice. Second run inserted 0.
5. History fixture F2 import one time. Elapsed under 3.000 s.
6. Secrets dry run without consent. Stored 0.
7. Git status review. Run `git status --short`.
   New files must match the file map in appendix C.
   No Arc data file may appear. No manifest file may appear.

---

## 7. Privacy and security rules

Check each rule before you call the work done:

- Logs hold counts, hosts, and times only.
  One host in a log line is fine. A full URL in a log line fails the work.
- Temp copies live in a `0o700` dir. Delete copies after each read.
- Never print decrypted bytes. Never print a username.
  Never print a cookie name with a host together.
  Counts hide which site holds which count.
- Zero secret bytes after use. Zero the derived key after each file.
  Zero each record with `zeroSecrets()` before drop.
- Derive the key one time per run. Fetch the password one time per run.
- Make no network call in `OpenImport` or in the two new CLI files.
  Search those files for `URLSession`. Expect zero hits.
- Store no secret to disk in phase 2. That rule covers temp files and caches.
- Extension IDs stay out of logs and commits.
  IDs may live in one `0o600` manifest file outside the repo.
- Arc profile paths may appear in error lines. Paths hold no secret.
- Real Arc titles and URLs never enter docs, fixtures, or commits.
  Fixtures use `example.com` only.

Memory rules for secrets:

- Hold one file set of records at a time.
- Zero and drop logins before you read cookies.
- Zero and drop cookies before you read cards.
- The derived key lives only in one `[UInt8]` value.
  No copy of the key enters a struct that outlives the run.

## 8. Open questions

Answer each question before the engine phase. Phase 2 ships without answers:

1. Exact Arc Keychain pair: does pair 1 (`Arc Safe Storage`, `Arc`) hit on a fresh Mac?
   The probe in section 3.1 answers this on first consent run.
2. Multi-profile map: does Arc hold one Chromium profile per Arc Profile?
   Phase 2 imports one `--profile` at a time. That covers the observed single-profile install.
3. Extension disabled state: does Open need to restore disabled state after reinstall?
   Phase 2 counts disabled records as candidates. State restore needs engine prefs work.
4. Password notes and passkeys: do notes need UI in v1?
   Part A counts logins only. Notes parse waits for the password UI.
5. Cookie partition keys: Chromium 156 cookie rows hold `top_frame_site_key`.
   Part A drops that field. Engine cookie set must decide partition handling.

---

## Appendix A: History fixtures

Write fixture scripts in `/tmp`. Commit no fixture script.
Use `python3` with the `sqlite3` module.

Fixture F1: small correctness DB.
Create dirs and DB at `/tmp/open-fixture-arc/Default/History`.

Run this SQL on a new DB:

```sql
CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
INSERT INTO meta VALUES('version', '70');
CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER DEFAULT 0 NOT NULL, typed_count INTEGER DEFAULT 0 NOT NULL, last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL);
CREATE TABLE visits(id INTEGER PRIMARY KEY AUTOINCREMENT, url INTEGER NOT NULL, visit_time INTEGER NOT NULL, from_visit INTEGER, transition INTEGER DEFAULT 0 NOT NULL, incremented_omnibox_typed_score BOOLEAN DEFAULT FALSE NOT NULL);
CREATE TABLE keyword_search_terms(keyword_id INTEGER NOT NULL, url_id INTEGER NOT NULL, term LONGVARCHAR NOT NULL, normalized_term LONGVARCHAR NOT NULL);
INSERT INTO urls VALUES(1, 'https://example.com/a', 'Alpha', 2, 1, 13437000000000000, 0);
INSERT INTO urls VALUES(2, 'https://example.com/b', 'Beta', 1, 0, 13437000010000000, 0);
INSERT INTO urls VALUES(3, 'chrome://settings', 'Settings', 1, 0, 13437000020000000, 0);
INSERT INTO visits VALUES(1, 1, 13437000000000000, NULL, 0, 0);
INSERT INTO visits VALUES(2, 1, 13437000005000000, NULL, 1, 1);
INSERT INTO visits VALUES(3, 2, 13437000010000000, NULL, 8, 0);
INSERT INTO visits VALUES(4, 3, 13437000020000000, NULL, 0, 0);
INSERT INTO visits VALUES(5, 1, 13437000030000000, NULL, 3, 0);
INSERT INTO visits VALUES(6, 1, 0, NULL, 0, 0);
```

Expect: urlRows 3, visitRows 6, kept 3, internal 1, subframe 1, invalidTime 1.
Row map: visit 1 link keep, visit 2 typed keep, visit 3 reload keep.
Visit 4 chrome skip, visit 5 subframe skip, visit 6 zero time skip.
First import inserts 3 rows. Second import gives duplicates 3.

Fixture F2: speed DB.
Create DB at `/tmp/open-fixture-arc-big/Default/History`.
Use Python loops. Insert 5,000 URL rows on `example.com`.
Insert 100,000 visit rows. Spread visits over the URL rows.
Use transition 0 for most rows. Use transition 1 for each 10th row.
Use visit times after 13437000000000000. Add the row index as microseconds offset.
Runtime rule: the import MUST finish in under 3 seconds.

## Appendix B: Secret fixture S1

Goal: prove decrypt with known bytes and no real user data.

1. Create a temp profile dir `/tmp/open-secret-fixture/Default`.
2. Create `Login Data` with the `logins` schema from section 3.2.
   Create minimal tables to pass reads: `logins` and `meta`.
3. In a `/tmp` Swift probe, create one test Keychain item.
   Service: `Open Test Safe Storage`. Account: `OpenTest`.
   Password: one random test string. Print no password.
4. Derive the key with probe code that calls the same CC calls as section 3.4.
   Encrypt one test password with AES-128-CBC, IV spaces, PKCS7.
   Prefix bytes `v10`. Insert one login row with that blob.
   Use origin `https://example.com/login`. Print no value.
5. Run the crypto functions against the test service pair in probe code.
   The probe needs a pair override. Add an internal probe entry in `/tmp` only.
   Never add a test pair to shipped probe order.
6. Expect decrypt ok 1, failed 0.
7. Delete the test Keychain item with `SecItemDelete`.
   Confirm delete with a probe miss. Print PASS only.

App code change for S1: none.
The shipped reader keeps the three-pair probe from section 3.1.

## Appendix C: File map

Create:

- `Packages/OpenKit/Sources/OpenStore/HistoryImport.swift`
- `Packages/OpenKit/Sources/OpenImport/ArcHistoryImport.swift`
- `Packages/OpenKit/Sources/OpenImport/ChromiumCrypto.swift`
- `Packages/OpenKit/Sources/OpenImport/ArcSecrets.swift`
- `Packages/OpenKit/Sources/OpenImport/ArcExtensions.swift`
- `Packages/OpenKit/Sources/openkit/HistoryImportCLI.swift`
- `Packages/OpenKit/Sources/openkit/SecretsImportCLI.swift`

Edit:

- `Packages/OpenKit/Sources/OpenStore/HistoryStore.swift`
- `Packages/OpenKit/Package.swift`
- `Packages/OpenKit/Sources/openkit/main.swift`

Read only, change nothing:

- `Packages/OpenKit/Sources/OpenImport/ArcImport.swift`
- `Packages/OpenKit/Sources/openkit/CLI.swift`
- All files in `~/Developer/open-engine/chromium_git`
- All files in `~/Library/Application Support/Arc`

## Appendix D: Source evidence index

- History schema and transition names:
  `components/history/core/browser/history_database.cc` (version 70)
  and `ui/base/page_transition_types.h` (core mask `0xFF`).
- Encryption:
  `components/os_crypt/async/browser/keychain_key_provider.mm`,
  `components/os_crypt/async/common/encryptor.cc`,
  `components/os_crypt/common/keychain_password_mac.mm`.
- Engine write path:
  `chrome/browser/importer/profile_writer.h` (`AddPasswordForm`, `AddHistoryPage`, `AddKeywords`).
- Current Open history and ranking:
  [HistoryStore.swift](../../Packages/OpenKit/Sources/OpenStore/HistoryStore.swift),
  [Providers.swift](../../Packages/OpenKit/Sources/OpenSuggest/Providers.swift),
  and [suggest.md](../suggest.md).
- Measured Arc counts: `.re/import2/schemas.md` and `.re/import2/extensions-engagement.md`.
  Those notes hold counts only.




## Appendix — Lead decisions (2026-10-25)

- Implement now: history import (full, against real Arc data, counts-only output) and the secrets decrypt/parse code.
- **The implementer must NOT access the user's real Keychain** ("Arc Safe Storage") and must not decrypt the user's real Login Data, Cookies, or Web Data. Verify the secrets path only with the synthetic fixtures (S1 and similar) built from a known test key. A real run happens later, only after the user gives explicit consent in the app's import flow.
- Skip Top Sites and site engagement (as the plan recommends).
- Writing secrets into Open's profile waits for the engine's password-store/ProfileWriter API.
