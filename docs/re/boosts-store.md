# Arc Boosts storage evidence

Target: Arc 1.170.0, build 89123. These are our own findings, not Arc code.
Raw metadata, strings, and query output stay in `.re/s14/boosts/`.

## Evidence and limits

The installed bundle's `CFBundleShortVersionString` and `CFBundleVersion`, read with
`plutil -extract … raw /Applications/Arc.app/Contents/Info.plist`, are `1.170.0`
and `89123`. `xcrun dwarfdump --uuid` gives the same arm64 UUID
`BE2EB88A-675C-357B-8143-840A9196E154` for that bundle's executable and the
shared `.re/bin/Arc-arm64` snapshot used below.

The following command reads Swift reflection records (`__swift5_fieldmd`) without
executing Arc. The helper decodes field names, field types, and enum cases; it
does not decompile implementations.

```sh
python3 /Users/serge/.t3/projects/open/.re/media/swift_fields.py \
  /Users/serge/.t3/projects/open/.re/bin/Arc-arm64 \
  > .re/s14/boosts/swift-fields.tsv
strings -a /Users/serge/.t3/projects/open/.re/bin/Arc-arm64 \
  > .re/s14/boosts/strings.txt
```

On 2026-11-06, a read-only count of `StorableBoosts*.json` in the permitted Arc
data directory returned **0**. `BoostsImageCache` had **0** entries. The separate
Firestore cache exists, but its Boost entry is a deletion marker (see below).
No populated real Boost document was available to validate the full mapping.

## The Storable file stores local enablement

The file name `StorableBoostsData.json` is confirmed by `strings -a` above.
The reflection rows for `BoostsClient.StorableBoostsData` and its `CodingKeys`
both list exactly these two fields:

| Key | Reflected Swift type |
|---|---|
| `version` | `Int` (`Si`) |
| `locallyEnabledBoostIDs` | `Set<BoostID>` (`Shy…G`) |

`BoostsClient.BoostID` has a `value: String` field and `CodingKeys.value`.
Evidence: the same command's `BoostsClient.BoostID` and
`BoostsClient.BoostID.CodingKeys` rows.

**Inference:** normal Swift Codable output would encode the set as an array of
`{"value":"synthetic-id"}` objects. No observed file yet confirms that array
shape, the numeric version, or the meaning of an absent ID. The type and coding
keys provide no CSS, JS, host, title, or complete Boost payload in this file.
A decoder must not invent Boost records from enabled IDs alone.

Earlier notes in `data-model.md` §2.6 and `features-advanced.md` BO-1/BO-6 treated
this file as a full Boost store. That claim was an inference from its name.
The reflection evidence above supersedes it.

## Content types and storage owners

Reflection distinguishes the following types. The command above and the exact
type names in this table are the evidence for each row.

| Type | Reflected fields relevant to import |
|---|---|
| `BoostsClient.BoostData` | `data`, `type`, `hostPattern`, `author`, `title`, `signature`, `lastModified`, `isActive`, `forkedFromSnapshotID`, `forkedFromBoostID` |
| `BoostsClient.BoostData.InternalData` and `.CodingKeys` | `css`, `js`, `font`, `textTransform`, `textZoom`, `zaps`, `colorScheme` |
| `BoostsClient.BoostFont` and `.CodingKeys` | `family` |
| `BoostsClient.BoostTextZoom` and `.CodingKeys` | integer `level` |
| `BoostsClient.BoostTextTransform` | `capitalize`, `uppercase`, `lowercase` |
| `BoostsClient.BoostColorScheme` and `.CodingKeys` | `colorWheelDriven`, `themeDriven`; the former's coding keys contain `_0` |
| `BoostsClient.BoostColorWheelScheme` and `.CodingKeys` | `primaryHueDegrees`, `primarySaturation`, `secondaryHueOffset`, `invertLightness`, `baseAppearance`, `advancedSettings` |
| `BoostsClient.BoostColorWheelScheme.AdvancedSettings` and `.CodingKeys` | optional `preservedSaturation`, `preservedLightness`, `lightnessShift`, `secondarySaturation`, `primaryLightness`, `secondaryLightness`, `primaryColorModel`, `secondaryColorModel` |
| `BoostsClient.BoostSnapshotData` | `originalBoostID`, `boostData`, `boostTitle`, `creatorName`, `creatorSignature`, `previewImageURL` |
| `BoostsClient.BoostsStorageFirebaseImpl` | `firebaseClient`, `localBoostsDataStore` |
| `BoostsClient.BoostsStorageMemoryImpl` | `locallyEnabledBoostIDs`, `boosts`, `boostSnapshots`, `listeners`, `nextListenerId` |
| `BoostsClient.BoostsCollectionIDs` | `boosts`, `boostSnapshots` |

In `InternalData`, CSS and JS are optional strings; zaps are `[String]`.
`BoostData.BoostType` has `edited` and `installed` cases. The reflection command's
corresponding field/type rows prove those types and cases. `BoostData` itself
has no reflected `CodingKeys` enum; it uses a custom remote dictionary decoder.

Read-only queries of the shared `ArcMain` Ghidra snapshot, using
`analyzeHeadless … ArcMain -process Arc-arm64 -noanalysis -readOnly`, identify
the decoder at `FUN_101150064` (`0x101150064`) and its inverse at
`FUN_101150b54` (`0x101150b54`). Raw queries: `payload-ghidra.txt` and
`store-ghidra.txt` in `.re/s14/boosts/`. These functions establish:

- `hostPattern` and `data` are required strings. `data` contains JSON decoded
  as `BoostData.InternalData`; it is not a Firestore map of components.
- The dictionary also reads `author`, `title`, `signature`, `lastModified`,
  `isActive`, `forkedFromBoostID`, `forkedFromSnapshotID`, and `type`.
- `signature` is JSON text. `lastModified` is ISO 8601 text. The encoder writes
  `isActive` as the string `"true"` or `"false"`. `type` is `edited` or `installed`.
- The create dictionary at `FUN_101166318` (`0x101166318`) adds `creatorID`.

The fixture's complete populated document remains synthetic. Reflection proves
the component types and keys; ordinary Codable shapes for the local ID set and
color enum are inferences until a populated sample is available.

`strings -a` also finds `BoostsClient/BoostsStorageFirebaseImpl.swift`,
`queryBoostData(id:)`, `queryBoosts(for:matching:)`, and
`BoostData unexpectedly includes JS; rejecting as invalidData`. Together with
the storage-owner fields, these support remote content storage. They do not
prove a local cache layout or authorize account/network access.

The `boosts` and `boostSnapshots` dictionaries above belong to the **memory**
implementation. They are not keys of `StorableBoostsData`. Similarly,
`BoostsClient.BoostsObserver.activeBoosts` is runtime observer state, not a
Storable coding key. Evidence: each named reflection row.

No Profile, Space, creation date, or per-Boost version field occurs in the
reflected `BoostData` fields. Ownership and creation-time defaults would be
importer decisions, not facts established by this metadata.

## Firestore offline cache

The lead authorized this additional read-only source on 2026-11-06:
`~/Library/Application Support/firestore/Arc/bcny-arc-server/main/`.
The reader first copies the **whole** flat directory into a fresh mode-700
temporary directory, with mode-600 files. It opens source files only with
`O_RDONLY | O_NOFOLLOW | O_CLOEXEC`, checks regular-file identity and size, and
checks size/mtime again after each copy. It never opens a database API or locks
the original. Copies are removed on both success and failure. A changing or
incomplete cache reports unreadable; sidebar import continues.

The own reader follows `CURRENT` and replays the manifest to select live
tables and log numbers. It decodes table restart/prefix blocks, masked CRC32C,
Snappy literals/copies, fragmented WAL records and WriteBatch operations, and
resolves sequence numbers and tombstones. It does not scan obsolete tables for
string matches. Format references: LevelDB's
[table format](https://github.com/google/leveldb/blob/main/doc/table_format.md),
[log format](https://github.com/google/leveldb/blob/main/doc/log_format.md), and
[VersionEdit tags](https://github.com/google/leveldb/blob/main/db/version_edit.cc).
No third-party code or dependency is included.

Only the `remote_document` keyspace is decoded as documents. Its prefix in the
private local copy is `85 72 65 6d 6f 74 65 5f 64 6f 63 75 6d 65 6e 74 00 01`.
Values use Firestore's
[MaybeDocument](https://github.com/firebase/firebase-ios-sdk/blob/main/Firestore/Protos/protos/firestore/local/maybe_document.proto):
`no_document=1`, `document=2`, `unknown_document=3`, with committed mutations in
field 4. A Document has name 1, field map 2, creation timestamp 3 and update
timestamp 4; its map values use `google.firestore.v1.Value` wire fields.
Only exact `projects/bcny-arc-server/databases/(default)/documents/boosts/ID`
documents can become Boosts. Other collections are counted only. Query targets,
snapshots, mutations and deletion markers never become imported content.

The preliminary private-copy scan found **0 live Boost documents and 1
no_document marker**. A string containing a Boost path in a query target is not
a Boost document. The production CLI receipt is counts only; no names, hosts,
CSS, JS, creator IDs or source document IDs may appear in it.

Limits: 256 source files, 32 MiB per file, 64 MiB total source bytes, 8 MiB per
decoded table/log block, 100,000 current records, 500,000 visited records,
4,096-byte LevelDB keys, 2 MiB documents, 1 MiB strings, 128 map entries,
1,024 array entries, 16 nesting levels and 4,096 Boost documents. Over-limit
cache input produces a fixed privacy-safe status; a malformed document is
skipped and counted separately.

## Mapping limits for Open

Open's existing `Boost` fields can hold a title, host match, enable state, CSS,
JS, font family, text transform, zaps, modification time, and source Boost ID.
See `OpenBoosts/Boost.swift`. `ArcBoostsReader` maps these fields. ID mapping uses
the existing deterministic UUID algorithm with namespace `boost`. Creation time
comes from the Document timestamp, with modification time as fallback. A missing
modification time falls back to the Document update time, then the Unix epoch.
Bare hosts and leading `*.` hosts are accepted. Broader/path patterns are skipped
rather than silently widened. Open's existing site match includes subdomains.

Local enablement is the intersection of `locallyEnabledBoostIDs` and remote
`isActive`. If the local file is absent or unreadable, imported Boosts are
disabled and counted in `enablementUnknown`. This is an importer decision.
Account-scoped Boosts map to the Default Profile; this is a counted **guess**.

The following Arc fields have no direct, evidence-backed Open mapping:

- `creatorID`, `author`, `signature`, `type`, and `forkedFromSnapshotID`.
- Remote snapshot ownership, creator details, and preview image URL.
- The color scheme's `secondaryHueOffset`, `baseAppearance`, and advanced
  settings. Open's `BoostColorWheel` uses a different set of inputs.
- Integer text-zoom `level`: the scale conversion is not established here.

The parser counts unmapped fields by fixed field name and unknown keys by count.
All color leaves and integer zoom levels are dropped pending a proven conversion;
Open's color wheel is a CSS-filter approximation with different inputs.

The CLI writes through `OpenBoosts` into the existing per-Profile layout while
holding `OpenDataRoot.prepare()`'s lock. Existing stable IDs are preserved on
re-import, including user edits. `BoostStore.upsert` sets `updatedAt` to import
time; the `protectedEdits` count therefore means an existing record is newer
than its source, not proof of a user edit. No model or store API changes are made.

App persistence, live apply, re-import and shared Undo are **BLOCKED (Section 12
AppBoosts)**. `AppImportRunner.recordBoostImport([ProfileID: [Boost]], counts:)`
records counts only. The future implementation must use the sole owner:
`app.stores.boosts.store(for: profileID).upsert(boost)` for each addition, then
`app.stores.boosts.refresh(profile: profileID)` once per Profile. It must never
construct another App BoostStore or write a Boost file directly.

## Sample request

Please create one synthetic Boost for `example.com`, with CSS, a harmless JS
statement, a font, a text-size change, a color change, and one Zap. Disable a
second synthetic Boost. After quitting Arc, provide a reviewed, redacted export
of only those `boosts` remote documents from the offline cache, plus
`StorableBoostsData.json` if present. Replace every ID consistently, remove
creator/author/signature values, and replace all hosts, names, CSS and JS with
synthetic example.com content. Keep field names and value types, including the
JSON string in `data`. Do not send the raw LevelDB folder, account files,
authentication data or a whole Profile. Local enablement IDs alone cannot
recover Boost content.
