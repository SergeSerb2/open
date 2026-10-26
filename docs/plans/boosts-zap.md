# Boosts + Zap — implementation plan for Open

Status: plan for implementation. Implementer: follow this file top to bottom.
Do not read Arc code or copy Arc assets. Build from the behavior facts in this plan.
Reference behavior source: [features-advanced.md §4–§5](../re/features-advanced.md).
Architecture context: [architecture.md](../architecture.md). Model context: [model.md](../model.md).
Data-model caveat: [data-model.md §2.6](../re/data-model.md) — `StorableBoostsData` is **unverified**.
No real file exists on this Mac. This plan does **not** guess that file format.

How to use this plan:

1. Work the steps in §12 in order. Do not skip ahead.
2. Each step lists exact files, exact signatures, and acceptance checks.
   A step is done only when its checks pass.
3. If a signature in this plan conflicts with the real `OpenEngine` API when it lands,
   keep the `OpenBoosts` types in this plan and adapt only the thin adapter in §8.4.
   Do not redesign the data model to fit a draft engine API.
4. No unit tests. Verify with the harness in §10 and the real app flow, per AGENTS.md rule 6.

---

## 0. Scope and non-scope

### 0.1 In scope (this plan)

| Area | Deliverable |
|---|---|
| Swift data layer | New `OpenBoosts` library target in `Packages/OpenKit`. Own types, own store. No change to `OpenModel` sources. |
| Matcher | `URL → [Boost]` lookup. O(1) by host with suffix matching. |
| Page runtime | Two plain-JavaScript files, ES2022, no framework, no build step. `boost-applier.js` and `zap-picker.js`. |
| Bridge | Versioned JS ↔ native message contract over an abstract engine bridge. |
| Native glue | `InjectionPlan` value the engine layer consumes. Picker message handling. Zap persistence. |
| Harness | Four standalone HTML pages + loader page + local server script under `Packages/OpenKit/Sources/OpenBoosts/Harness/`. |
| Budgets | Applier < 1 ms at `document_start`. Picker hover < 2 ms per frame. Measurement method in §11. |

### 0.2 Out of scope (do not build)

- Boost editor window UI (color wheel, Monaco code panel, shelf). This plan provides the data
  and runtime the editor will later call. The only UI in this plan is the in-page Zap overlay.
- Site Control Center section UI. It will call `BoostStore` and `BoostMatcher` later.
- Sharing, install links, Firebase, preview-image upload. Arc facts: JS Boosts are **not shareable**
  (`features-advanced.md` BO-2, BO-6). Open has no accounts. Store a `containsJS` flag so a future
  share action can refuse. Do not build share.
- Import from Arc for Boosts. Blocked on a real `StorableBoostsData.json`. See §13.3.
- Ad blocking. Separate milestone (M6 sibling).
- Incognito policy decision. Runtime must accept a `context: "normal" | "incognito"` flag in the
  injection plan and apply the same code in both until product decides. Do not hard-block incognito
  in `OpenBoosts`. Record the choice as open question Q4 in §14.

### 0.3 Milestone fit

This is the Boosts/Zap half of M6 in [plan.md](../plan.md). It depends only on M1 (`OpenKit`
exists). It must not block on `OpenEngine` being finished: §8 defines the boundary so the Swift
side and the JS side can be built and harness-tested before the engine lands.

---

## 1. Locked facts from the behavior spec (do not re-derive)

These are facts from `docs/re/features-advanced.md`. Implement these; do not re-investigate Arc.

| ID | Fact | Where it lands in this plan |
|---|---|---|
| BO-1 | A Boost is a per-site record: ID, site pattern, title/name, author, enabled flag, one or more components. | §3 `Boost` |
| BO-2 | Components are independent subsets: CSS, JS, fonts, text zoom/transform, color, Zaps. Any subset may be present. | §3.3 |
| BO-2 | JS Boosts cannot be shared. Validation string `BoostData unexpectedly includes JS; rejecting as invalidData` exists on a share/validate path. | §3.3 `containsJS`, §13.2 |
| BO-3 | Simple panel color is a hue-based recolor. Store wheel state **and** final values. | §3.4 `ColorAdjustment` |
| BO-4 | Fonts and text controls are declarative and site-wide. They compile to CSS. | §3.5, §6.4 |
| BO-5 | A Boost applies only when site matches AND Boost enabled AND global Boosts preference on. | §5 matcher + §8 plan builder |
| BO-8 | A dedicated helper applies Boosts to every matching web content on navigation and on edit. | §8 `BoostInjectionPlanner` |
| BO-9 | CSS is a stylesheet resource (`arc://boost/v2/css/<id>` in Arc). JS is a user script. Timing is a **guess** in the spec: use `document_start` for both. | §6.1, §8.2 |
| ZA-1 | Zap is a hover-highlight + click picker over the live page. | §7 |
| ZA-2 | Selector algorithm: semantic scoring, ≤ 100 matches, top 15 candidates, ancestor depth 8, descendant depth 2, style-uniformity preference, diversity bucketing. Three page entry points in Arc: `getHoveredElement`, `getSelectorCandidates`, `rectsForSelector`. Open implements the same **behavior** in its own code with the bridge API in §9. | §7.5 |
| ZA-3 | "Zap all related elements" widens one pick to repeated siblings. Preview rects first, then commit. | §7.4 |
| ZA-4 | Zaps are selector strings inside the Boost. `appendZap` / `removeZap`. No duplicate selectors. | §3.6, §8.3 |
| ZA-5 | Zaps hide by CSS at injection time. Exact declaration is a guess in the spec. This plan fixes it: `display: none !important`. | §6.3 |
| ZA-6 | Per-Zap delete un-hides. Editor undo for last Zap is a guess. This plan requires in-page undo of the last Zap (§7.6) because the harness can verify it without the editor. | §7.6 |

Arc CSS scheme note: Arc serves generated CSS from `arc://boost/v2/css/<id>`. Open does **not**
copy that scheme. Open passes CSS text inside `InjectionPlan` (§8.2). The engine layer decides
whether to inject the text directly or serve it from its own internal scheme. The JS runtime in
§6 never fetches `arc://` URLs.

---

## 2. Package and file inventory

### 2.1 Package change (only build-system edit)

Edit exactly one existing file: [Package.swift](../../Packages/OpenKit/Package.swift).

Add one library product and one target. `OpenBoosts` depends on `OpenModel` **only** for
`ProfileID` (`Packages/OpenKit/Sources/OpenModel/Identifiers.swift`). Do not edit any file under
`Sources/OpenModel/`. Do not add dependencies between `OpenBoosts` and `OpenStore`, `OpenImport`,
or `OpenSuggest`.

```swift
// In products: add
.library(name: "OpenBoosts", targets: ["OpenBoosts"]),

// In targets: add
.target(
    name: "OpenBoosts",
    dependencies: ["OpenModel"],
    resources: [.copy("Resources/boost-applier.js"), .copy("Resources/zap-picker.js")]
),
```

Do not add `OpenBoosts` to the `openkit` executable target in this milestone. The harness
(§10) is the verification surface. A CLI is out of scope.

### 2.2 New files (create exactly these)

```
Packages/OpenKit/Sources/OpenBoosts/
  Boost.swift                  §3  value types: Boost, SiteMatch, ColorAdjustment, ZappedElement, BoostID
  BoostStore.swift             §4  per-profile JSON store, atomic writes, debounced save
  BoostMatcher.swift           §5  host index + URL matching
  InjectionPlan.swift          §8  InjectionPlan, ResolvedBoost, BoostInjectionPlanner
  PickerMessages.swift         §8  page→native / native→page payload types + handler
  Resources/
    boost-applier.js           §6  document_start applier
    zap-picker.js              §7  Zap picker + selector generator
  Harness/
    static.html                §10.2  plain content page
    spa.html                   §10.3  client-side content swap page
    shadow-dom.html            §10.4  open + closed shadow root page
    obfuscated.html            §10.5  generated-looking class names page
    loader.html                §10.6  bridge simulator + runtime injector + message log
    serve.py                   §10.7  tiny local server
    README.md                  §10.8  how to run the harness (implementer writes from §10)
```

That is 7 Swift/JS production files plus 7 harness files. No other new production files.
If a file grows past ~600 lines, split only inside the same list (for example
`BoostStore.swift` stays one file; do not invent `BoostStoreIO.swift`).

### 2.3 Files the implementer must read before coding (already in repo)

| File | Why |
|---|---|
| `Packages/OpenKit/Sources/OpenModel/Identifiers.swift` | `ProfileID` shape. Reuse it. Do not copy it. |
| `Packages/OpenKit/Sources/OpenStore/SnapshotStore.swift` | Debounce + atomic-write pattern to mirror in §4. |
| `Packages/OpenKit/Sources/OpenStore/SnapshotDTOs.swift` | DTO style: `Codable, Sendable`, `schemaVersion`, sorted keys. Mirror it. |
| `docs/architecture.md` § "Performance budgets" | Budget style. §11 extends it for Boosts. |

### 2.4 Naming rules

- Swift types: `Boost`, `BoostID`, `SiteMatch`, `ColorAdjustment`, `ZappedElement`,
  `BoostFileDTO`, `BoostStore`, `BoostMatcher`, `InjectionPlan`, `ResolvedBoost`,
  `BoostInjectionPlanner`, `PickerInbound`, `PickerOutbound`, `BoostPickerCoordinator`.
- JS globals: everything lives under `window.__openBoosts` (applier) and
  `window.__openZap` (picker). The bridge itself is `window.__open` and is owned by the
  engine layer, not by these files. These files must not overwrite `window.__open`.
- DOM ids created by the runtime: prefix every id with `open-boosts-` or `open-zap-`.
  Never use an `arc` prefix.

---

## 3. Data model — `Boost.swift`

Create `Packages/OpenKit/Sources/OpenBoosts/Boost.swift`.
Swift 6, strict concurrency. Every type in this file is `Codable, Hashable, Sendable`.
No AppKit, no WebKit, no engine import. `import Foundation` and `import OpenModel` only
(`OpenModel` is needed for `ProfileID` in §4/§5 signatures; `Boost.swift` itself does not
need `ProfileID` and must not import it if the compiler warns — keep the import only in
files that name `ProfileID`).

### 3.1 `BoostID`

```swift
public struct BoostID: Hashable, Codable, Sendable, CustomStringConvertible {
    public var rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public init(uuidString: String) { self.rawValue = UUID(uuidString: uuidString) ?? UUID() }
    public var description: String { rawValue.uuidString }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        rawValue = UUID(uuidString: try c.decode(String.self)) ?? UUID()
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue.uuidString)
    }
}
```

Match the encode/decode style of `Identifier<Tag>` in `OpenModel`. Do not reuse
`Identifier<BoostTag>` because that would require editing `OpenModel`.

### 3.2 `SiteMatch` — domain + optional path prefix

```swift
public struct SiteMatch: Codable, Hashable, Sendable {
    /// Lowercased host pattern without scheme, port, or trailing dot.
    /// Examples: "example.com", "news.example.com".
    /// Never empty. Never contains "*".
    public var domain: String
    /// Optional path prefix. Nil means "all paths on this host".
    /// When non-nil: starts with "/", length > 1, no trailing "/" unless the value is "/".
    /// "/" alone is stored as nil at init time (see normalization).
    public var pathPrefix: String?

    public init(domain: String, pathPrefix: String? = nil)
    /// Returns the canonical form. See normalization rules below.
    public static func normalized(domain: String, pathPrefix: String?) -> SiteMatch
    /// Host suffix test + path test against an already-parsed URL. See §5.3.
    public func matches(host: String, path: String) -> Bool
}
```

Normalization (implement exactly; the matcher in §5 depends on it):

1. `domain`: trim whitespace, lowercase, strip one leading `*.` if present,
   strip scheme if the caller passed a URL string by accident (`https://` prefix → drop
   through `://`), strip everything from the first `/`, `?`, `#`, or `:` (port),
   strip one trailing `.`. If the result is empty, the initializer is only called from
   validated UI/store code — in `normalized` return `SiteMatch(domain: "", pathPrefix: nil)`
   and let the store reject empty domains on save (§4.5). Do not `fatalError`.
2. `pathPrefix`: nil or empty string → nil. Ensure a leading `/`. Collapse repeated `/`
   into one. Strip a trailing `/` unless the whole value is `/`. Map `/` → nil.
   Do not lowercase the path. Do not percent-decode.
3. Equality and hashing use the normalized stored values only. Store code must call
   `normalized` before persisting. The decoder must also normalize (custom `init(from:)`
   that normalizes both fields) so a hand-edited file cannot create a non-canonical key.

Matching semantics (full algorithm in §5.3):

- Host match: `host == domain` OR `host` ends with `"." + domain`. So a Boost for
  `example.com` matches `example.com` and `www.example.com` and `a.b.example.com`.
  A Boost for `news.example.com` does **not** match `example.com` or `other.example.com`.
- Path match: if `pathPrefix == nil`, pass. Else pass when
  `path == pathPrefix` OR `path.hasPrefix(pathPrefix + "/")`.
  Exception: a prefix that itself ends in a file-like suffix is still a prefix test only —
  do not add extension logic. `/blog` matches `/blog`, `/blog/`, `/blog/post-1`.
  It does not match `/blogger`. This boundary rule is the point of the `+ "/"` test.
- Query and fragment never participate. Port never participates.

### 3.3 `Boost`

```swift
public struct Boost: Codable, Hashable, Sendable, Identifiable {
    public var id: BoostID
    public var name: String                 // user-visible title, may be ""
    public var siteMatch: SiteMatch
    public var isEnabled: Bool
    public var css: String                  // raw CSS text, "" when absent
    public var js: String                   // raw JS text, "" when absent
    public var colorAdjustment: ColorAdjustment?   // nil = no color change
    public var fontFamily: String?          // nil = no font override; see §3.5
    public var zaps: [ZappedElement]        // order = insertion order, no duplicate selectors
    public var createdAt: Date
    public var updatedAt: Date
    public var forkedFromID: BoostID?       // set when installed/forked from a snapshot

    public init(
        id: BoostID = BoostID(),
        name: String = "",
        siteMatch: SiteMatch,
        isEnabled: Bool = true,
        css: String = "",
        js: String = "",
        colorAdjustment: ColorAdjustment? = nil,
        fontFamily: String? = nil,
        zaps: [ZappedElement] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        forkedFromID: BoostID? = nil
    )

    /// True when js contains any non-whitespace. JS Boosts are never shareable.
    public var containsJS: Bool { get }
    /// True when every component is empty/nil. The editor may still save it; the
    /// runtime treats it as a no-op (see §6.7).
    public var isEmpty: Bool { get }
}
```

Field rules:

- `name`: stored verbatim. Display falls back to `siteMatch.domain` when empty. Do that
  fallback in UI later, not in this model.
- `css` / `js`: stored verbatim, including whitespace. Trim only for the `containsJS` /
  emptiness tests. Never rewrite user CSS/JS on save.
- `zaps`: invariant — no two entries share the same `selector` string (exact string equality
  after trimming leading/trailing whitespace of the selector; selectors are otherwise
  case-sensitive). Enforce in `BoostStore.upsert` and in the picker coordinator (§8.3),
  not in a `didSet`. Provide `mutating func appendZap(_ zap: ZappedElement) -> Bool`
  that returns `false` and changes nothing on duplicate, and
  `mutating func removeZap(selector: String) -> Bool`.
- Dates encode as seconds since 1970 (`timeIntervalSince1970` Double) to match
  `SnapshotDTOs.TabDTO`. Use the default `Codable` `Date` strategy only if the store
  encoder is configured the same way — §4.3 fixes the encoder, so default `Date`
  coding (deferredToDate) is **not** used. Implement `Boost` with explicit
  `CodingKeys` and encode `createdAt`/`updatedAt` as `timeIntervalSince1970`.
  Simplest correct approach: keep stored properties as `Date` and give the store's
  `JSONEncoder`/`JSONDecoder` a `.secondsSince1970` date strategy. State that in §4.3
  and do not add custom date code in `Boost.swift` beyond `CodingKeys` if needed.
  Pick the encoder-strategy approach. Do not mix both.

### 3.4 `ColorAdjustment`

Arc's simple panel is hue-based (BO-3). Open stores the five filter components directly
so the runtime needs no wheel math. The future editor converts its wheel to these values.

```swift
public struct ColorAdjustment: Codable, Hashable, Sendable {
    public var hueRotateDegrees: Double   // 0..<360, default 0
    public var saturation: Double         // >= 0, 1 = identity, default 1. Range clamp 0...3
    public var brightness: Double         // >= 0, 1 = identity, default 1. Range clamp 0...3
    public var contrast: Double           // >= 0, 1 = identity, default 1. Range clamp 0...3
    public var invert: Double             // 0...1, 0 = identity, 1 = full invert, default 0

    public init(hueRotateDegrees: Double = 0, saturation: Double = 1,
                brightness: Double = 1, contrast: Double = 1, invert: Double = 0)
    public static var identity: ColorAdjustment { get }
    public var isIdentity: Bool { get }   // all five at identity within 1e-9
    /// Clamped copy. Call before persisting and before building CSS.
    public func clamped() -> ColorAdjustment
}
```

Clamp rules in `clamped()`: `hueRotateDegrees` wraps with `truncatingRemainder(dividingBy: 360)`
then `+360` if negative. `saturation`/`brightness`/`contrast` clamp to `0...3`.
`invert` clamps to `0...1`. NaN in any field becomes that field's identity value.
`isIdentity` compares the clamped values.

CSS generation lives in the planner (§8.2), not here. This type only stores numbers.

### 3.5 Font override

`fontFamily` is a single CSS `font-family` value as the user/editor wrote it, for example
`"Georgia, serif"` or `"-apple-system"`. Rules:

- Nil or whitespace-only means no override. The store normalizes whitespace-only to nil.
- Stored verbatim otherwise. Do not add quotes. Do not validate against installed fonts.
- The runtime (§6.4) wraps it as `font-family: <value> !important` on a controlled selector.
  Because the value goes into CSS text, the **planner** (§8.2) must reject a `fontFamily`
  that contains `;`, `{`, `}`, or a newline when building the plan (drop the font component,
  keep the rest of the Boost, log to stderr in debug). Do not reject at model init time —
  imported or hand-edited files must still load.

### 3.6 `ZappedElement`

```swift
public struct ZappedElement: Codable, Hashable, Sendable {
    public var selector: String   // CSS selector, trimmed, non-empty
    public var label: String      // human label for editor list, may be ""
    public var createdAt: Date

    public init(selector: String, label: String = "", createdAt: Date = Date())
}
```

- `label` is display only (for example `"Ad banner"` or the element tag the picker
  suggests). It never affects matching. The picker (§7) sends a suggested label;
  native may store it verbatim or replace it. Default when native creates a zap without
  a label: `""`.
- Selector validation: non-empty after trim. Full CSS validity is checked in the page
  (§7.5 step V) and again defensively in the applier (§6.7). The Swift model accepts any
  non-empty string so a selector written by a newer picker still round-trips.

### 3.7 What is **not** in the model

- No author string. Arc has `BoostData` author fields (BO-1). Open has no accounts and the
  task scope lists no author field. Omit it. If a future share feature needs it, add it then
  with a defaulted `Codable` property so old files still decode.
- No preview image. Out of scope (§0.2).
- No per-Boost profile field. The file is already per-profile (§4.1). A `Boost` value does
  not know its profile. `BoostStore` and `BoostMatcher` carry the `ProfileID`.

---

## 4. Persistence — `BoostStore.swift`

Create `Packages/OpenKit/Sources/OpenBoosts/BoostStore.swift`.
Mirror `SnapshotStore` (`Packages/OpenKit/Sources/OpenStore/SnapshotStore.swift`):
same queue style, same atomic write, same debounce idea. Do not import `OpenStore`.
Re-implement the ~40 lines you need. Sharing code by copy is worse than a small duplicate
here because the targets must stay independent for parallel work
(`docs/architecture.md`: "Each library target is owned by one agent at a time").

### 4.1 File location and format

- Root is injectable. Default root: `~/Library/Application Support/Open`
  (same default as `SnapshotStore`: `applicationSupportDirectory` + `"Open"`).
- One file per profile: `<root>/Boosts/<profileID>.json` where `<profileID>` is
  `ProfileID.rawValue.uuidString` (uppercase, as `UUID.uuidString` produces).
  Example: `~/Library/Application Support/Open/Boosts/3F2504E0-4F89-41D3-9A0C-0305E82C3301.json`.
- Create the `Boosts/` directory on first write. Never create it on load.

On-disk DTO (define in this file, `private` is wrong — the harness and future editor
need to read it in tests, so make it `public`):

```swift
public struct BoostFileDTO: Codable, Sendable {
    public var schemaVersion: Int          // always 1 in this plan
    public var profileID: String           // uuidString, must equal the file name stem
    public var boosts: [Boost]             // sorted by id.uuidString in the file (see §4.3)
    public init(schemaVersion: Int = 1, profileID: String, boosts: [Boost])
}
```

JSON example (exact key names; `sortedKeys` output will order them alphabetically on disk,
the example shows logical grouping):

```json
{
  "schemaVersion": 1,
  "profileID": "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
  "boosts": [
    {
      "id": "9B2F207E-9A6B-4E1A-8E2D-111111111111",
      "name": "Calm news",
      "siteMatch": { "domain": "example.com", "pathPrefix": "/blog" },
      "isEnabled": true,
      "css": "body { background: #111; }",
      "js": "",
      "colorAdjustment": {
        "hueRotateDegrees": 40, "saturation": 0.8,
        "brightness": 1.0, "contrast": 1.05, "invert": 0
      },
      "fontFamily": "Georgia, serif",
      "zaps": [
        { "selector": "#promo-banner", "label": "Promo banner", "createdAt": 1730000000 }
      ],
      "createdAt": 1730000000,
      "updatedAt": 1730000100,
      "forkedFromID": null
    }
  ]
}
```

Notes:

- Optional fields (`pathPrefix`, `colorAdjustment`, `fontFamily`, `forkedFromID`):
  use synthesized `Codable` and do not hand-roll `encodeIfPresent`. Swift's synthesized
  encoder writes nil optionals with `encodeIfPresent`, so nil keys are **omitted** from
  the file. The synthesized decoder accepts both a missing key and an explicit `null`.
  Files may therefore show either form after hand edits; both must load. The JSON
  example above shows `null` for readability only. Add a code comment with this rule so
  no one "fixes" the encoder later.
- Dates are numbers (seconds since 1970) via the encoder strategy in §4.3. The example
  shows numbers. Do not store ISO-8601 strings.

### 4.2 Public API

```swift
import Foundation
import OpenModel

public final class BoostStore: @unchecked Sendable {
    public let root: URL
    public let profileID: ProfileID
    public var fileURL: URL { get }   // <root>/Boosts/<profileID>.json

    public init(root: URL? = nil, profileID: ProfileID)

    /// Synchronous load. Missing file → empty. Corrupt file → see §4.5.
    /// Safe to call from any thread; does file I/O on the caller thread.
    /// Call it once at profile open, off the main actor if the file may be large.
    public func load() -> [Boost]

    /// Replace the whole set in memory and schedule a debounced write.
    /// The store keeps an in-memory copy; load() populates it, upsert/delete mutate it.
    public func allBoosts() -> [Boost]              // sorted by name, then id (display order)
    public func boost(id: BoostID) -> Boost?
    @discardableResult public func upsert(_ boost: Boost) -> Boost  // returns normalized stored copy
    @discardableResult public func delete(id: BoostID) -> Bool
    @discardableResult public func setEnabled(id: BoostID, enabled: Bool) -> Bool
    @discardableResult public func appendZap(boostID: BoostID, zap: ZappedElement) -> Bool
    @discardableResult public func removeZap(boostID: BoostID, selector: String) -> Bool

    /// Debounced save (1 s, like SnapshotStore). Callers mutate via the methods above;
    /// those methods schedule the save themselves. This method exists for symmetry
    /// and for a future editor that batches several mutations.
    public func scheduleSave()
    /// Synchronous write of the current in-memory set. Call on quit (per profile).
    public func saveNow()
    /// Drain the write queue. Returns after any in-flight write finishes.
    public func flush()
}
```

Threading model (copy `SnapshotStore` exactly):

- Private serial queue: `DispatchQueue(label: "open.boosts", qos: .utility)`.
- `NSLock` guards `pendingWork: DispatchWorkItem?` and the in-memory `[BoostID: Boost]`
  dictionary plus a cached sorted array. Every public method takes the lock for the
  dictionary access, then schedules I/O off the lock.
- `load()` does **not** use the queue. It reads the file, decodes, replaces the in-memory
  dictionary under the lock, and returns the boosts. Document that `load()` must not race
  `upsert` — the app calls `load()` once before any mutation.
- Mutations update `updatedAt` of the affected Boost to `Date()` inside `upsert` only
  when the caller did not already change it: rule — `upsert` always sets
  `updatedAt = Date()` on the stored copy. `setEnabled`, `appendZap`, `removeZap`
  also bump `updatedAt`. `delete` has no timestamp.
- Normalization on every `upsert`: `siteMatch = .normalized(domain:pathPrefix:)`,
  `colorAdjustment = colorAdjustment?.clamped()`, whitespace-only `fontFamily` → nil,
  each zap selector trimmed, duplicate zap selectors dropped (keep first),
  zap with empty selector dropped. If `siteMatch.domain` is empty after normalization,
  `upsert` still stores the Boost (so the editor can hold a draft) but the matcher
  (§5) must skip empty-domain Boosts. Do not reject in the store.

### 4.3 Encoding and atomic write

- Encoder: `JSONEncoder`, `outputFormatting = [.sortedKeys, .prettyPrinted]`,
  `dateEncodingStrategy = .secondsSince1970`.
  Pretty-printed differs from `SnapshotStore` (sorted keys only). Reason: Boost files are
  user-inspectable and diff-friendly; CSS/JS strings stay readable. File size is small
  (tens of Boosts). Keep `.prettyPrinted`.
- Decoder: `JSONDecoder`, `dateDecodingStrategy = .secondsSince1970`.
- File content order: `boosts` sorted by `id.rawValue.uuidString` ascending before encode,
  so the same set always produces the same bytes (round-trip check in §10 can compare bytes).
- Atomic write (copy `SnapshotStore.write`): create directory, encode, write to
  `Boosts/<profileID>.json.tmp-<UUID>`, then `replaceItemAt` if the target exists else
  `moveItem`. On error, write one line to stderr:
  `BoostStore write failed: <error>` and keep the in-memory state. Never throw to the UI.
- Debounce: 1.0 s on the serial queue, cancel-and-reschedule per mutation (same
  `pendingWork?.cancel()` pattern as `SnapshotStore.scheduleSave`).
  `saveNow()` cancels pending work and writes synchronously on the queue
  (`queue.sync { write(...) }` is wrong if called from the queue — follow `SnapshotStore`:
  encode the DTO value first, then write. For `BoostStore`, snapshot the DTO under the lock,
  then `queue.sync` the file write only when `saveNow` is called off-queue; document that
  `saveNow` must not be called from the store queue. The app calls it from the main actor.)
- `flush()`: `queue.sync {}` after cancelling nothing — it waits for the in-flight write.
  Simpler and correct: implement `flush()` as `queue.sync { _ = pendingDTO }` is noise.
  Implement it exactly as: take lock, capture `pendingWork`, unlock, then `queue.sync {}`
  so any already-enqueued write completes. Match `SnapshotStore.flush` intent and add a
  comment that a not-yet-fired debounced item (still in `asyncAfter`) is **not** flushed —
  call `saveNow()` on quit, not `flush()`. This matches the `SnapshotStore` caveat.

### 4.4 Global Boosts preference

The global on/off (`features-advanced.md` BO-5, §4.4 "Enable Boosts on websites you visit")
does **not** live in the per-profile Boost file. The planner (§8) takes
`boostsGloballyEnabled: Bool` as a parameter. The setting itself belongs to the future
Settings UI / profile settings. Do not add a field for it to `BoostFileDTO` and do not
store it in `OpenModel` (that would edit `OpenModel`). The harness loader (§10.6) has a
checkbox that maps to this parameter.

### 4.5 Load failures and edge cases

| Case | Required behavior |
|---|---|
| File missing | `load()` returns `[]`. No directory created. No error. |
| File empty (0 bytes) | Treat as corrupt (below). |
| JSON decode fails | Rename the file to `<profileID>.json.corrupt-<yyyyMMddHHmmss>` (local time), write `BoostStore: corrupt file moved aside: <name>` to stderr, return `[]`. Never delete user data silently. |
| `schemaVersion > 1` | Still try to decode (forward-compatible fields decode; unknown keys are ignored by `Codable`). If decode succeeds, return the boosts and do **not** rewrite the file until the next mutation, at which point write `schemaVersion: 1` only if no unknown top-level keys were present — you cannot detect that with synthesized decoding, so rule: on save after loading a `>1` file, write `schemaVersion` as the loaded value (preserve it). Store the loaded version in memory and emit it back. Implement with a `loadedSchemaVersion` property. |
| `schemaVersion < 1` or missing | Treat missing as 1. Decode normally. |
| `profileID` in file ≠ file name | Trust the file name (the store was constructed for that profile). Ignore the inner value on load; write the correct one on save. Log to stderr in debug. |
| Duplicate Boost ids in file | Keep the last occurrence. Log count to stderr in debug. |
| Duplicate zap selectors in one Boost | Keep first, drop rest (same as `upsert`). |
| Boost with empty domain | Keep it (draft). Matcher skips it (§5.4). |

No throwing API. `load()` never throws. This matches the app's "persistence failure must
not crash" rule in `SnapshotStore`.

---

## 5. Matcher — `BoostMatcher.swift`

Create `Packages/OpenKit/Sources/OpenBoosts/BoostMatcher.swift`.
Goal: given a URL, return the enabled, matching Boosts fast. Called on every navigation
and on every Boost edit for every open tab (BO-8), so it must be cheap and allocation-light.

### 5.1 API

```swift
import Foundation
import OpenModel

public struct BoostMatcher: Sendable {
    public init(boosts: [Boost])
    /// Rebuild the index. Call after any store mutation that affects matching.
    public mutating func rebuild(boosts: [Boost])
    /// Active boosts for a URL, in application order (§5.4). Global preference is
    /// applied by the caller/planner, not here. Disabled boosts are never returned.
    public func matching(url: URL) -> [Boost]
    /// Host-only fast path used by the planner to skip work for non-matching sites.
    public func hasMatch(host: String) -> Bool
}
```

`BoostMatcher` is a value type with an immutable index built at `init`/`rebuild`.
The owner (app or coordinator) holds one matcher per profile and rebuilds it after store
mutations. `matching(url:)` is pure and thread-safe on an immutable matcher.

### 5.2 Index construction — O(1) by host

Build `[String: [Boost]]` keyed by exact `siteMatch.domain`:

```swift
private var byDomain: [String: [Boost]] = [:]  // key = normalized domain
```

Construction rules:

1. Skip Boosts where `isEnabled == false`. (Rebuild on enable toggle; do not filter per query.)
2. Skip Boosts where normalized `domain` is empty.
3. Normalize each domain again defensively (`SiteMatch.normalized`) even though the store
   already did — the matcher can be built from in-memory values that never went through
   the store (harness, future import).
4. Append the Boost to `byDomain[domain]`. Preserve input order inside each bucket;
   final ordering happens in §5.4, not here.
5. Also keep `allDomains: Set<String>` (the keys) for `hasMatch` suffix probing.

Memory: one dictionary entry per distinct domain. This is the O(1) structure: a lookup
probes at most `labelCount` keys (see §5.3), never scans all Boosts.

### 5.3 Lookup algorithm (implement exactly)

```text
func matching(url):
    guard let host0 = url.host, !host0.isEmpty else return []
    host = host0.lowercased()
           .strip one trailing "."
           .strip port — url.host never contains a port; do not parse it
    if host is an IPv4 literal (four dot-separated decimal parts) or
       host hasPrefix("[") (IPv6 literal from url.host without brackets — Foundation
       returns it without brackets; test both):
        candidates = byDomain[host] ?? []        // exact only, no suffix probing
    else:
        labels = host.split(separator: ".")       // ["a","b","example","com"]
        candidates = []
        // Probe longest suffix first: a.b.example.com, b.example.com, example.com, com
        for i in 0..<labels.count:
            suffix = labels[i...].joined(separator: ".")
            if let bucket = byDomain[suffix]: candidates += bucket
        // Note: probing "com" is intentional. A Boost for domain "com" is absurd but
        // the algorithm stays uniform. The store UI should warn; the matcher does not special-case.
    path = url.path.isEmpty ? "/" : url.path      // Foundation: path is percent-encoded; keep as-is
    result = candidates.filter { $0.siteMatch.matches(host: host, path: path) }
    // siteMatch.matches re-checks host suffix + path. The host re-check is redundant
    // for bucket members but keeps matches() correct as a standalone API.
    return ordered(result)   // §5.4
```

`SiteMatch.matches(host:path:)` implements §3.2: suffix host test + path boundary test.

Why probe suffixes instead of storing every suffix at build time: build stays O(Boosts),
query is O(labels × bucket). Label count is ≤ ~10 in practice. Either is fine; this plan
fixes the probe-at-query design so the implementer does not invent a second one.

Percent-encoding: compare `url.path` (encoded) against the stored prefix (as-written).
Document that a prefix containing a space will never match an encoded path with `%20`
unless the editor stores `%20`. That is acceptable for v1. Do not decode.

IDN: `url.host` may be punycode (`xn--…`) or unicode depending on Foundation version.
Normalize by lowercasing only. Do not convert between punycode and unicode in the matcher.
The store normalizer also only lowercases, so both sides agree as long as the editor
stores what the browser reports. Note this as a known v1 limit in a code comment.

### 5.4 Ordering when several Boosts match

Arc open question 7 in `features-advanced.md` ("Conflict order when two Boosts match")
is unanswered. Open fixes this deterministic order. The returned array is in
**application order: general first, specific last**. Sort ascending by this tuple:

```swift
(domain.count, pathPrefixLength, createdAt, id.uuidString)
// pathPrefixLength = pathPrefix?.count ?? 0
```

Rules in words:

1. Shorter `domain` first; longer (more specific) domain last. Ties on length break by
   domain string ascending.
2. Then shorter `pathPrefix` first (nil = 0); path-scoped Boosts come after host-wide
   Boosts on the same domain.
3. Then `createdAt` ascending (older is the base layer; newer wins).
4. Then `id.uuidString` ascending (stable tie-break).

Application order matters for CSS cascade (§6.3): later in the returned array means
later in the generated stylesheet, so more specific Boosts win ties at equal
specificity because later CSS rules win.

Example: a page on `news.example.com` matching a Boost for `example.com` (11 chars)
and a Boost for `news.example.com` (16 chars) returns `[example.com, news.example.com]`.
The `news` Boost is last and wins. A host-wide Boost (path length 0) precedes a
`/blog` Boost (length 5) on the same domain.

JS execution order follows the same array order (§6.5). Zaps are unioned (§6.3).

### 5.5 Matcher edge cases

| Input | Result |
|---|---|
| `about:blank`, `about:srcdoc`, file URL with empty host | `[]` (host guard) |
| `http://localhost:8080/x` | host `localhost`, single label, probe `["localhost"]` only |
| `http://127.0.0.1/x` | IPv4 exact only. A Boost for `0.1` must never match it. |
| URL with uppercase host `HTTPS://EXAMPLE.COM/` | host lowercased → matches `example.com` |
| Boost domain `example.com`, URL host `badexample.com` | No match (suffix test requires dot boundary) |
| Boost domain `example.com`, URL host `example.com.` (trailing dot) | Trailing dot stripped → match |
| Two boosts same domain, one disabled | Disabled excluded at index build |
| Path prefix `/blog`, URL path `/blog` | Match. URL path `/blog/` → match. `/blogger` → no. |
| Path prefix nil, any path | Match |
| URL path empty (`https://example.com`) | Treat as `/`. A prefix of `/x` does not match. A nil prefix matches. |

---

## 6. Page runtime A — Boost applier (`boost-applier.js`)

Create `Packages/OpenKit/Sources/OpenBoosts/Resources/boost-applier.js`.
Plain JavaScript, ES2022, no imports, no framework, no TypeScript, no build step.
One file. Target size 250–400 lines. It runs in the page world at `document_start`
and again on bridge `boost:apply` messages (§9).

### 6.1 Injection contract (what the engine layer does)

The engine layer (future `OpenEngine` adapter, §8.4) must:

1. At `document_start`, inject this file's text, then immediately call
   `window.__openBoosts.apply(plan)` with the `InjectionPlan` payload for that page
   (plan shape in §8.2, wire shape in §9.3). If no Boost matches, the engine may skip
   injection entirely — the applier must also handle "injected but never applied"
   without error.
2. On SPA navigation (same-document navigation) the engine does **not** re-inject.
   The applier survives (§6.6). The planner does **not** need to re-send on
   `pushState` — the plan is host-scoped and the URL path check was already done
   natively. Exception: if the engine knows the path prefix no longer matches after
   a SPA route change (it re-runs the matcher), it sends `boost:clear` (§9).
   The applier must handle both: stay applied across SPA nav, clear on message.
3. On full navigation, the engine re-injects at `document_start`. The applier must be
   idempotent: calling `apply` twice with the same plan is a no-op second time
   (guard by plan hash, §6.2).
4. The applier runs in the **page (main) world** so Boost JS can see page JS (Arc BO-9
   guess, fixed here as main world for v1). CSS works in either world; JS needs main.
   Record the guess in a comment at the top of the file:
   `// Injection world: main. Arc timing evidence is a guess; see boosts-zap.md §1 BO-9.`

The file must not assume `window.__open` exists. The harness loader (§10.6) provides a
fake. In production the engine provides it. Applier → native traffic is only the
`boost:applied` and `boost:error` reports (§9.2). If `window.__open` is missing, skip
reporting silently.

### 6.2 Public surface (exact)

```js
window.__openBoosts = {
  version: 1,
  apply(plan) {},      // plan = §9.3 boost:apply payload. Idempotent by plan.planID.
  clear() {},          // remove all Open styles/JS effects. Idempotent.
  state() {},          // returns { appliedPlanID, boostIDs, zapCount } for harness checks
};
```

- `planID` is a native-generated opaque string (planner: `"<boostIDs-joined>:<contentHash>"`,
  §8.2). The applier stores `appliedPlanID`. `apply` with the same `planID` returns at once.
  `apply` with a different `planID` fully replaces the old effects (call internal clear first).
- No other globals. Internals live in an IIFE `(function () { "use strict"; ... })();`.
  Use `const`/`let`, arrow functions, `querySelectorAll`, `MutationObserver` only (ES2022).
- The file must parse with no top-level `await` and no modules.

### 6.3 CSS application — one managed `<style>` element

Create one style element and own it fully:

```js
const STYLE_ID = "open-boosts-style";
```

Rules:

1. On `apply`, build the complete CSS text (order fixed below), then set it on the
   style element. Create the element if missing:
   `document.documentElement.appendChild(styleEl)` works even before `<head>` exists
   at `document_start`. Do not wait for `DOMContentLoaded`. If
   `document.documentElement` is null (extremely early), queue the apply and retry on
   `DOMContentLoaded` once, plus a `MutationObserver` on `document` until
   `documentElement` appears (disconnect after first success). Keep this fallback < 20 lines.
2. If the page removes our style element (SPA frameworks sometimes clear `<head>`),
   re-insert it. Use exactly one observer: `MutationObserver` on
   `document.documentElement` with `{ childList: true, subtree: true }`. In the
   callback, do only this cheap check (throttled to one run per animation frame via
   a pending-flag + `requestAnimationFrame`): if
   `document.getElementById(STYLE_ID)` is null and a plan is applied, re-append the
   style element with the stored CSS text. Also run the same check on `popstate` and
   from the patched `history.pushState`/`replaceState` hooks (§6.6). Do not observe
   attributes or character data (cost).
3. CSS text assembly order (later wins at equal specificity — this is why §5.4 orders
   general → specific):
   a. Color/filter block (§6.4) — at most one `html` filter rule. Filters do not
      compose by concatenation across Boosts. The planner (§8.2) selects a single
      `ColorAdjustment` (most specific Boost wins) before the plan is sent. The
      applier emits that one rule and never merges filters itself.
   b. Font block (§6.4) — at most one, selected natively (most specific Boost wins).
   c. Each Boost's raw `css` in plan order, wrapped in a comment banner:
      `/* open-boost:<boostID> */\n<css>\n`.
   d. Zap hide rules last (highest precedence for hiding):
      for each distinct zap selector in plan order:
      `<selector> { display: none !important; }`
      Validate each selector in the page before emitting: test it with
      `document.querySelector` inside try/catch; skip invalid selectors and report
      `boost:error` once per bad selector (§9.2). Emit **one rule per selector**,
      never a comma-joined list (one bad selector in a comma list invalidates the
      whole rule in CSS).
4. Zap selector dedup: dedupe exact strings, keep first occurrence order.
5. `clear()` removes the style element and disconnects the style observer. It does not
   remove shadow-root styles (§6.8) — clear must also iterate tracked shadow roots and
   remove the adopted sheet / style there.

Shadow DOM CSS: see §6.8. The main-document style element cannot reach shadow trees.

### 6.4 Color adjustment and font CSS (exact generation)

Color filter CSS. Given the single composed `ColorAdjustment` `c` (already clamped
natively; clamp again defensively here):

```css
html {
  filter: hue-rotate(<h>deg) saturate(<s>) brightness(<b>) contrast(<ct>) invert(<i>);
}
```

- Emit the rule only when `c` is non-identity (any component differs from identity
  beyond 1e-9). Format numbers with up to 4 decimal places, trailing zeros stripped
  (`Number(v.toFixed(4)).toString()` via a small helper — write it, do not inline).
- Media exclusion: a filter on `<html>` filters images/video too, which the user does
  not expect (Arc recolors the site, not photos — GOAL from BO-3 intent; mark as Open
  design decision). Counter-filter media back:
  - When `invert > 0`: add
    `img, video, picture, canvas { filter: invert(<i>) hue-rotate(<h2>deg); }`
    where `h2 = (h + 180) % 360` is **not** correct for partial invert — document the
    limit: full counter-invert is only exact at `invert == 1`. Rule: emit the media
    counter-rule **only** when `invert >= 0.999`; for partial invert, emit no media rule
    and accept that media is partially inverted. Add this as a comment in the JS.
  - `saturate`/`brightness`/`contrast`/`hue-rotate` on media are accepted (they are the
    site recolor). Only `invert` gets the counter-rule. Do not try to fully un-filter media.
- `background-color` on `<html>`/`<body>`: do not set it. A filter over a transparent
  root can produce fringing on some engines; leave backgrounds to the page and Boost CSS.

Font CSS. Given the single chosen `fontFamily` string `f` (planner already rejected
values containing `;{}"` or newline):

```css
body, body *:not(script):not(style):not(code):not(pre):not(kbd):not(samp) {
  font-family: <f> !important;
}
```

- Emit only when `f` is non-null/non-empty.
- The `:not(code/pre/...)` exclusion keeps monospace code readable. Keep the exclusion
  list exactly as above. Do not exclude `textarea`/`input` (form text should follow).
- Icon fonts will break under a blanket `!important` font override (known tradeoff of
  every Boost implementation). Do not try to detect icon fonts in v1. Note it in the
  harness README known-limits.

### 6.5 JavaScript application

- The plan's `js` is the concatenation of each matching Boost's `js` in plan order,
  separated by `\n;\n`, composed natively. The applier executes it **once per apply**
  (per `planID`) by creating a `<script>` element with `textContent = js`, appending to
  `document.documentElement`, then removing the element. Wrap execution in the element
  only — do not use `eval` or `new Function` (CSP: a Boost script element injected at
  `document_start` before page CSP applies may still run; `eval` is blocked by more
  CSPs than inline script in some configurations, and the spec's model is "user script",
  which is script-element semantics). Add a comment stating this choice.
- Run Boost JS **after** CSS is installed (so JS measuring layout sees boosted styles).
- A throwing Boost JS must not break the page or the applier: script element execution
  errors surface as page errors, not applier exceptions. Additionally wrap the composed
  JS natively? No — do not wrap user JS in try/catch text (it changes top-level `return`
  and `this` semantics). Execute verbatim.
- On `clear()` or re-`apply` with a new plan, prior JS effects are **not** undone
  (impossible in general). Document: changing Boost JS requires reload to fully take
  effect; CSS/zaps/color/font update live. This matches BO-8's "re-applies without
  reload (guess)" — Open guarantees live update for CSS-family components only.
- CSP note: if the page CSP blocks inline script, Boost JS silently does not run.
  Detect nothing; report nothing. The editor (future) may warn. Harness pages have no
  CSP, so harness checks (§10) verify the happy path.

### 6.6 SPA survival

Single-page apps replace DOM without full navigation. Required mechanisms:

1. Style-element guard observer (§6.3 rule 2) — re-inserts CSS after head/body swaps.
2. History hooks: wrap `history.pushState` and `history.replaceState` once (store
   originals, call through, then schedule a re-assert). Also listen to `popstate` and
   `hashchange`. "Re-assert" means: if the style element is missing, re-insert; if
   tracked shadow roots were replaced, §6.8 re-attach handles it via the shadow observer.
   Do not re-run Boost JS on SPA nav (it would duplicate listeners/timers).
3. Zap persistence across SPA swaps is automatic: zap rules live in the stylesheet,
   not on elements, so new matching nodes are hidden as soon as they render. No
   per-element work. State this in a comment — it is the reason zaps are CSS, not
   `element.style.display = "none"`.
4. `MutationObserver` for shadow roots (§6.8) must observe the whole document subtree
   but with a cheap callback (collect new shadow hosts, do not scan all nodes).

Budget guard: all SPA handlers together must stay within the §11 hover/apply budgets.
No handler may call `querySelectorAll` on the whole document except shadow-host
discovery, which must be throttled (see §6.8).

### 6.7 Applier edge cases

| Case | Behavior |
|---|---|
| Empty plan (no boosts) | `apply` with empty arrays: install an empty style element? No — treat as `clear()`. Do not leave an empty `<style>` in the page. |
| Invalid zap selector | Skip that one rule, report `boost:error { kind: "invalid-zap-selector", selector }`, apply the rest. |
| Invalid user CSS | Browser CSS parser drops bad rules natively. Applier does nothing special. Never reject the whole sheet for CSS text. |
| Very large CSS (> 512 KB) | Apply anyway. Do not truncate user CSS. (Planner may warn in future editor.) |
| `apply` before `documentElement` exists | Queue and retry per §6.3 rule 1. `state()` before ready returns `{ appliedPlanID: null, boostIDs: [], zapCount: 0 }`. |
| `clear()` when never applied | No-op, no error. |
| Page is `about:blank` / error page | Engine should not inject. If injected, `apply` still works (empty document). No special case. |

### 6.8 Shadow DOM

Goal: "where possible" (task scope). Required behavior:

1. Patch `Element.prototype.attachShadow` once at first `apply`:
   store the original, call it, then register the returned `ShadowRoot` in a
   `Set` (`trackedRoots`), and inject the current zap+font CSS into it (below).
   Handle `mode: "closed"` — the applier gets the root object from the return value
   even for closed roots, which is exactly why patching the method works. If the page
   already created shadow roots before injection, find them: you cannot enumerate
   closed roots after the fact. Open roots can be found by walking elements and
   checking `el.shadowRoot`. Do a one-time walk at first `apply` for open roots only.
   Document: closed roots created before `document_start` injection are unreachable —
   acceptable, injection is at `document_start` so this window is minimal.
2. Per-root injection: prefer `root.adoptedStyleSheets` with a `CSSStyleSheet`
   containing **only** zap hide rules + font rule (not the `html` filter rule — filters
   do not cross shadow boundaries usefully). Fallback when `adoptedStyleSheets` is
   unavailable: append a `<style data-open-boosts>` element inside the shadow root.
   Keep one sheet/style per root; update its text on re-`apply`.
3. New roots after apply: the `attachShadow` patch covers them. Roots created inside
   other shadow trees are covered too because the patch is on the prototype.
4. Removed roots: keep them in the `Set` until `clear()`; stale entries are harmless
   (detached roots are GC'd with their hosts — the `Set` would leak them, so use a
   `WeakRef`? `Set` of `ShadowRoot` strongly holds. Use an array with periodic prune:
   on each re-apply, filter `trackedRoots` to roots whose `host.isConnected`. Implement
   prune on apply/clear only, not on a timer (idle CPU near zero — architecture goal).
5. Iframe content: do not attempt to pierce iframes. Same-origin iframe Boosts are the
   engine's job (it injects per-frame). Note as out of scope in a comment.

---

## 7. Page runtime B — Zap picker (`zap-picker.js`)

Create `Packages/OpenKit/Sources/OpenBoosts/Resources/zap-picker.js`.
Plain JavaScript, ES2022, one file, no framework. Target size 700–1000 lines
(selector generation is most of it). It is injected **on demand** at `document_idle`
(or `document_end`) when the user enters Zap mode — never at `document_start`,
so pages without Zap pay nothing. It must also work if injected earlier.

Arc behavior to match (ZA-1..ZA-3, restated as Open requirements):

- Hover highlights the element under the pointer.
- Click commits a Zap (hides that element set).
- The picker computes robust selectors (scoring, ≤ 100 matches, top 15 candidates).
- "Zap all related" widens to siblings with a rect preview before commit.
- Esc exits. Undo of the last Zap. List/unzap via bridge messages.

### 7.1 Public surface (exact)

```js
window.__openZap = {
  version: 1,
  enter(options) {},   // options: { boostID: string } — starts picker for that Boost
  exit() {},           // same as Esc. Idempotent.
  isActive() {},       // boolean
  undo() {},           // undo last zap made in this picker session. Returns boolean.
  candidatesAt(x, y) {}, // §7.5 — returns [{ selector, matches }] top 15. For harness + native preview.
  rectsForSelector(selector) {}, // returns [{ x, y, width, height }] viewport coords.
  hoveredAt(x, y) {},  // returns { rect, hash } | null. See §7.5 hash definition.
};
```

These mirror Arc's three entry points (`getHoveredElement`, `getSelectorCandidates`,
`rectsForSelector`) with Open names. Implement `candidatesAt`/`rectsForSelector`/
`hoveredAt` as pure functions of the current document (usable while picker is inactive,
for harness checks). `enter`/`exit`/`undo` manage the interactive session.

The picker must not depend on the applier being present. Zap hide preview (§7.4) uses
its own preview style element so it works standalone in the harness.

### 7.2 Overlay — closed shadow root (exact DOM)

On first `enter`, create the overlay host once and reuse it:

```html
<div id="open-zap-overlay-host" style="all: initial; position: fixed; inset: 0;
     pointer-events: none; z-index: 2147483647;">
  <!-- closed shadow root:
    <style> ...our styles only... </style>
    <div class="hl"></div>        highlight box
    <div class="tag"></div>       label chip (tag + selector preview)
    <div class="bar"></div>       bottom bar: candidate count, Undo, Done buttons
  -->
</div>
```

Rules:

- `attachShadow({ mode: "closed" })`. Page CSS cannot reach inside. Page JS cannot
  reach it via `host.shadowRoot` (null for closed). Keep a JS reference to the root
  in the picker's closure. Never store it on the host element.
- Our overlay styling is our own minimal design (AGENTS.md rule 1 — do not copy Arc's
  `ZapPreviewBackground` asset or look). Fix these values:
  highlight: `border: 2px solid #4C8DFF; background: rgba(76,141,255,0.12);
  border-radius: 2px;` Label chip: system font 11 px, dark background
  `rgba(20,20,25,0.92)`, white text, `border-radius: 4px`, padding `2px 6px`.
  Bottom bar: fixed bottom center, same dark chip style, buttons as text.
  These exact values make harness screenshots reviewable. Do not import Arc colors.
- `pointer-events: none` on host and highlight so `elementFromPoint` and clicks pass
  through logically — the picker listens on `document` in capture phase instead.
  The bottom bar buttons need pointer events: set `pointer-events: auto` on the bar
  only, and in the document click handler ignore events whose target is inside the
  bar (check via the stored shadow root's elements, using `event.composedPath()`).
- Position the highlight from `getBoundingClientRect()` (viewport coords) with
  `position: fixed`. Update on hover (rAF-throttled) and on scroll/resize while active.
- The overlay host must never be returned as a hover target: in hover handling,
  if `document.elementFromPoint` returns the host (it should not, due to
  pointer-events:none, but iframes/shadow can surprise), walk to the element below
  via `document.elementsFromPoint` and pick the first non-Open element. Filter out
  any element whose id starts with `open-zap-` or `open-boosts-`.

### 7.3 Interaction state machine

States: `inactive` → (`enter`) → `picking` → (`exit`/Esc/Done) → `inactive`.
While `picking`:

| Input | Behavior |
|---|---|
| `mousemove` | rAF-throttle (store last event, process once per frame). Compute hovered element (§7.5 entry). Move highlight. Update label chip text to `tagName` + best selector preview (first candidate's selector, truncated to 60 chars). Cost budget §11. |
| `click` (capture, on document) | If click hits bottom-bar buttons, handle button. Else: `preventDefault()` + `stopPropagation()` (do not let the page navigate). Compute candidates (§7.5). Take candidate[0] as the zap. Preview-hide it (§7.4). Send `zap:committed` (§9.2). Push onto session undo stack (§7.6). Stay in picking (user can zap more). If candidates is empty (element unselectable, §7.5), flash the highlight border red for 200 ms and send `zap:error { kind: "no-candidate" }`. Do not exit. |
| `keydown` Esc | Exit picker (remove overlay listeners, hide overlay, send `picker:exited { reason: "esc" }`). |
| `keydown` Cmd/Ctrl+Z | Undo last zap (§7.6). Also the bar Undo button does this. |
| "Zap all related" | After a click, if candidate list has an entry with `matches > 1`, the bottom bar shows `Zap all related (N)`. Clicking it re-commits using that wider candidate instead (replace the last zap: send `zap:replaced` — see §9.2 — or undo+commit pair; §9 fixes `zap:replaced`). Before commit, show all rects via `rectsForSelector` highlights for 1 preview state: implement as — hovering the button highlights all matching rects (draw extra highlight boxes), clicking commits. Keep implementation simple: on button hover, draw N extra `.hl-multi` boxes; on leave, remove them. |
| Done button / bridge `zap:exit` | Exit with reason `"done"`. |
| Scroll / resize | Reposition highlight to the last hovered element's fresh rect (recompute via stored element reference, not coordinates). If the element left the DOM, hide the highlight. |

Listener hygiene: add listeners on `enter`, remove every one on `exit`
(`mousemove`, `click` capture, `keydown`, `scroll`, `resize`). Use named handler
functions so `removeEventListener` works. No listeners remain while inactive
(idle CPU — architecture goal). The rAF handle must be cancelled on exit.

Element identity: store the hovered `Element` reference plus its hash (§7.5).
If the page mutates and the reference disconnects, drop it (check `isConnected`).

### 7.4 Commit and preview-hide

On commit of selector `s`:

1. Add `s` to the picker's session-hidden list.
2. Ensure a preview `<style id="open-zap-preview-style">` in the main document with
   one rule per session-hidden selector: `<s> { display: none !important; }`.
   (Same one-rule-per-selector rule as §6.3. Invalid selector here means the generator
   has a bug — it validated already — still guard with try/catch around a
   `querySelectorAll` probe and skip silently.)
3. Send the bridge message (§9.2). Native persists (§8.3) and later sends a fresh
   `boost:apply` plan that includes the zap in the applier stylesheet. Both styles
   then hide the element; that overlap is harmless. On picker `exit`, remove the
   preview style after a short delay? No — remove it immediately on exit **only if**
   native has confirmed (native sends `boost:apply` including the new zap before or
   independently). Race rule: on exit, keep the preview style until the next
   `boost:apply` arrives or 500 ms pass, whichever first, to avoid a flash of the
   zapped element reappearing. Implement with a single timeout, cleared on apply.
   The applier must expose a hook: when `__openBoosts.apply` runs, it dispatches
   `window.dispatchEvent(new CustomEvent("open-boosts-applied"))`. The picker
   listens for it once during the exit grace period. (In the harness, the loader
   simulates the apply — §10.6.)
4. Shadow-root zaps: if the zapped element lives in a shadow root, the main-document
   preview style cannot hide it. The generator (§7.5) only generates selectors
   evaluated against the element's root (document or its shadow root). For commit:
   if `element.getRootNode()` is a `ShadowRoot`, inject the hide rule into that root
   (adopted sheet or style, same as §6.8) and mark the zap payload with
   `inShadowRoot: true` + `hostHint` (a document-level selector for the host, best
   effort). Native stores the selector verbatim; the applier (§6.8) reapplies zap
   rules into tracked shadow roots, which covers open roots and patched closed roots
   on reload. Closed roots created before applier injection remain a known gap (§6.8).

### 7.5 Selector generation (normative algorithm)

Implement `generateCandidates(rootElement)` returning
`[{ selector, matches, semanticness }]` internally; `candidatesAt(x, y)` exposes
`[{ selector, matches }]` (top 15, sorted by matches ascending — fewest matches first,
most precise first — matching Arc's returned sort). Follow these steps exactly.
This is Open's own implementation of the behavior in ZA-2. Do not copy Arc's
`SelectorPicker.js` code. Write from this spec.

**Entry.** `elementFromPoint(x, y)` → element. If null or an Open overlay element,
return `[]`. If the element is inside a shadow root, generation is scoped to that
root: all `querySelectorAll` calls run on `element.getRootNode()`, and ancestor
climbing stops at the shadow root's host's parent boundary — include the host as the
top ancestor term when the root is a shadow root (selector stays valid inside the
root only; see §7.4 step 4). Document-level generation scopes to `document`.

**Step A — identifier terms for one element.** For element `e`, build terms
`[{ term, score }]`:

| Term source | Term text | Score |
|---|---|---|
| id (if `e.id` non-empty) | `#<escaped-id>` | semantic id: `+1`; unknown: `-0.5`; gibberish: `-1` (classify by §Step B) |
| each class | `.<escaped-class>` | same classification as id |
| `data-testid` attribute present | `[data-testid="<value>"]` | `+1` (also plain `[data-testid]` at attribute-name score) |
| `aria-label` | `[aria-label="<value>"]` | `+0.8` |
| `role` | `[role="<value>"]` | `+0.5` |
| `tabindex` | `[tabindex="<value>"]` | `+0.5` |
| `href` (on `<a>`/`<area>`/`<link>`) | `[href="<value>"]` | `+0.6` |
| any other attribute `name` | `[name]` | `-0.1` |
| any other attribute `name="value"` | `[name="<value>"]` | gibberish value: `-1`; else `+0.3` |
| tag (semantic set below) | `tagname` | `+0.5` |
| tag (custom element, contains `-`) | `tagname` | `+1` |
| tag (all other) | `tagname` | `-0.1` |
| positional | `:first-child` / `:last-child` / `:nth-child(n)` (only the true ones) | `-0.1` each |

- Escape ids/classes/attribute values with `CSS.escape` when available, else a local
  fallback that backslash-escapes non-`[a-zA-Z0-9_-]` characters. Attribute values are
  placed inside double quotes; escape `"` and `\` first.
- Semantic tag set (fixed list): `a, article, aside, blockquote, button, details,
  dialog, dl, fieldset, figcaption, figure, footer, form, h1, h2, h3, h4, h5, h6,
  header, hgroup, hr, main, nav, pre, section, p, svg, picture, video, iframe, object`.
- Attribute-value prefix/suffix terms (Arc behavior): for attribute values containing
  spaces or `-` or `/`, also emit a first-token term `[name^="<first> "]` and a
  last-token term `[name$=" <last>"]` with the value's score. Cap: only for
  `class`-like long values? No — apply to any attribute value with a separator, per spec
  functions `c`/`s` behavior restated in ZA-2 evidence. Keep it: it helps with
  utility-class values. (If this floods candidates, Step D pruning handles it.)

**Step B — gibberish classification.** A string `s` (id, class, or attribute value)
is gibberish when any test fires:

1. Digit count `> 2`.
2. Last character is uppercase A–Z while the string is not all-uppercase
   (mixed-case ending, typical of generated hashes).
3. Any consonant run longer than 4 characters. Consonants = letters excluding
   `aeiouAEIOU` and excluding `-_ ` separators (split on those first; a segment longer
   than 4 with no vowel is the signal — implement as: split into runs of
   non-`aeiouAEIOU-_ ` characters; any run length `> 4` fires).
4. Contains any rare bigram from this fixed list (lowercased compare):
   `jz jx jq jv jw zj zx zq zk zv zw xj xz xq xk xv xw qj qz qx qk qv qw kz kx kq kv kw
   vj vz vx vq vk vw wj wx wq`.
   (This list is restated from the behavior spec facts, ZA-2. It is data, not code.)

A string is "known semantic" when it **contains** any word from the fixed semantic word
list (substring match, case-insensitive). Use this list (restated facts, ZA-2 evidence
words): `data, inline, grid, meta, avatar, card, col, item, info, line, text, title,
header, footer, button, link, icon, image, logo, menu, nav, search, social, tag, time,
video, audio, widget, wrapper, content, container, main, section, article, aside, page,
post, sidebar, site, author, category, date, entry, excerpt, featured, gallery,
navigation, next, pagination, permalink, previous`.
Classification precedence: if known-semantic and not gibberish → semantic (`+1` for
id/class). If gibberish → gibberish (`-1`) even if it contains a semantic substring
(`card-x7qz9` is gibberish). Else unknown (`-0.5` for id/class, `+0.3` for attribute values).

**Step C — candidate construction.** A candidate is
`{ ancestorTerms: [...], selfTerm, descendantTerms: [...], selector, matches, semanticness }`.
Build by expansion (breadth over two phases, mirroring the spec's two-pass behavior):

- Phase 1 (no descendants): seeds = one candidate per Step-A term of the target
  element (self term alone, `semanticness = term score`, `matches = count(selector)`).
  Expand ancestors: for depth `d = 1..8`, for each current candidate, prepend each
  term of the ancestor at depth `d` (climb `parentElement`; stop at `body`/`html`
  boundary — include `body` as a term source, do not go above the scope root).
  Join ancestor chain + self with descendant combinator `" "`; additionally, for
  `d == 1`, also try the child combinator form (insert `" > "` between the parent
  term and the rest) with an extra `-0.1` (descendant-selector penalty).
  Each expansion adds the ancestor term's score. Keep per depth step only the best
  `90` candidates (Phase-1 `candidatesPerStep`) by the Step-E ranking, to bound cost.
- Phase 2 (with descendants, only if Phase 1 yields fewer than 15 usable candidates
  or the best Phase-1 candidate matches `> 1` and siblings matter — simpler fixed rule:
  always run Phase 2 with smaller budgets): from the surviving candidates, expand
  descendants up to depth 2: for each descendant element up to 2 levels below the
  target (collect in document order, cap the descendant element list at 32), take its
  Step-A terms with `score >= 0.5` only, append ` :has(<descendant chain>)` to the
  candidate selector (descendant chain joined by `" "`, with a `" > "` variant at
  depth 1, penalty `-0.1`). Add the descendant term's score. Budgets for Phase 2:
  3 expansion steps, keep `12` per step.
- Dedupe candidates by selector string at every step (keep the higher semanticness).

Match counting: `count(selector)` = `scopeRoot.querySelectorAll(selector).length`
inside try/catch; a throwing selector counts as 0 and the candidate is dropped.
Cache counts in a `Map` per generation run (same selector counted once).
Also cache Step-A terms per element in a `Map` keyed by a temporary expando id:
assign `el.__open_id = counter++` on first visit (own name, not Arc's `__arc_id`).
Clean up is not required (expando on elements is the spec's approach; our name avoids
colliding with Arc-injected pages).

**Step D — filtering.**

- Drop `matches == 0` and `matches > 100`. (Hard limit from ZA-2. A candidate matching
  101 elements is never returned, even if it is the only one.)
- Drop candidates that also match inside the Open overlay (cannot happen — overlay is
  in a closed shadow root of a filtered host — but assert by scope: generation scope
  excludes the overlay host subtree because the host is filtered at entry).
- Style-uniformity preference: for each surviving candidate with `matches > 1`,
  compute whether all matches share the same computed-style fingerprint
  (`fontFamily/fontSize/color/backgroundColor/textDecoration/fontWeight` joined).
  Candidates whose matches are style-uniform get `+20` **ranking bonus** (Step E),
  not a filter. Single-match candidates need no check.

**Step E — ranking and diversity (top 15).**

- Ranking score for ordering = `semanticness + (styleUniform ? 20 : 0)`.
- Sort by ranking score descending, then bucket for diversity so near-duplicates do
  not fill the list (Arc behavior: bucketed selection over `matches`): bucket key =
  `floor(log10(matches))` combined with ranking-score range. Implement the spec's
  method restated simply: group candidates into buckets by
  `(log10(matches) bucket, ranking-score decile)`, then round-robin take from buckets
  (highest-ranked bucket first) until 15 are taken or candidates run out.
  If implementing the faithful bucket math is unclear, the acceptable faithful-enough
  rule is: sort by `(rankingScore desc)`, then stable-take with the constraint that
  no more than 5 taken candidates share the same `matches` value, second pass fills
  remaining slots without the constraint. Document whichever is implemented in a
  comment; the acceptance checks (§10) verify observable behavior (≤ 15, sorted,
  unique element included), not internal bucket math.
- Final returned list: sort the taken 15 by `matches` ascending (Arc returns sorted by
  match count). Each entry exposes only `{ selector, matches }` publicly;
  `candidatesAt` maps to that shape.

**Step F — verification.**

- After ranking, verify the target element is matched by at least the top candidate:
  `scopeRoot.querySelectorAll(top.selector).includes(target)` — if not (race with page
  mutation), regenerate once; if still not, return the list anyway but the click path
  (§7.3) treats an empty verified list as no-candidate. For `candidatesAt`, no
  verification — return the ranked list as computed.
- Uniqueness preference is emergent (matches == 1 ranks well via precision), do not add
  a separate uniqueness sort that breaks the Step-E order.

Performance guard: generation runs on click, not hover. Hover (§7.3) computes only
`hoveredAt` (rect + hash) and a best-term preview (cheapest single term: id if
semantic, else first non-gibberish class, else tag). Full generation on hover would
break the 2 ms frame budget. State this in code comments.

### 7.6 Undo, list, unzap (picker session)

- Session undo stack: array of `{ boostID, selector }` committed this session.
  `undo()`: pop the last entry, remove its rule from the preview style (and from its
  shadow root if `inShadowRoot`), send `zap:removed { boostID, selector, via: "undo" }`
  (§9.2). Return `true`. Empty stack → return `false`, send nothing.
- Native→picker list flow: native sends `zap:list { boostID }` (§9.3); picker replies
  `zap:list-result { boostID, zaps: [{ selector, label, rects }] }` where `rects` comes
  from `rectsForSelector` per selector (cap rects per selector at 100; if a selector
  matches more, return the first 100 rects and `truncated: true` for that entry).
  This lets the future editor show live highlight counts without its own page access.
- Unzap from native: native sends `zap:remove { boostID, selector }`; picker removes
  the preview rule if present in the session list and replies
  `zap:removed { boostID, selector, via: "native" }`. If the zap was not session-local
  (persisted earlier), the picker still replies (the applier plan refresh does the
  real un-hide; picker preview has nothing to remove).
- The picker never writes to the store. Persistence is native-only (§8.3).

### 7.7 Picker edge cases

| Case | Behavior |
|---|---|
| Click on `<html>`/`<body>` background | Candidates will be broad (`body` etc.). Allow it. Zap of `body` hides everything — the Undo button and Esc remain reachable because the overlay is outside page flow (fixed, top z-index). Do not special-case-block it. |
| Element inside an iframe | `elementFromPoint` returns the `<iframe>` element. Zap targets the iframe. Do not descend into iframe documents. |
| Element in closed shadow root (page's own) | `elementFromPoint` returns the host (retargeting). Hover highlights the host. This is correct v1 behavior. Document as a limit: picker cannot pick inside closed shadow trees it does not own. (Its **own** overlay is closed but excluded.) |
| Element in open shadow root | `elementFromPoint` retargets to host too in the main document. To pick inside, the harness shadow page uses `composedPath` — implement hover picking as: on mousemove, take `event.composedPath()[0]` as the true target when available (it pierces open shadow roots), else `elementFromPoint`. Use the composed target for generation with shadow scoping (§7.5 entry). |
| Page captures clicks first | Picker listens in capture phase and stops propagation on zap clicks. Links/buttons under the cursor must not activate while picking. |
| Keyboard: Tab focus in page | Picker does not manage focus. Esc is the only guaranteed key (keydown on document, capture). |
| Re-enter while active | `enter` when active is a no-op (keeps the current boostID). Native must exit first to switch boosts. |
| Multiple `zap:enter` for different boosts in one page | Same as above: no-op + reply `picker:error { kind: "already-active" }`. |

---

## 8. Native glue (Swift, in `OpenBoosts`)

### 8.1 Files

- `Packages/OpenKit/Sources/OpenBoosts/InjectionPlan.swift` — plan types + planner.
- `Packages/OpenKit/Sources/OpenBoosts/PickerMessages.swift` — message payloads + coordinator.

Both import `Foundation` and `OpenModel` (`ProfileID`). No AppKit. No engine import.
The App target will bridge these to `OpenEngine` (§8.4).

### 8.2 `InjectionPlan.swift` — types and planner

```swift
import Foundation
import OpenModel

/// One Boost resolved for one page, in application order.
public struct ResolvedBoost: Codable, Sendable, Equatable {
    public var boostID: BoostID
    public var name: String
    public var css: String          // verbatim Boost css (may be "")
    public var js: String           // verbatim Boost js (may be "")
    public var zaps: [String]       // zap selectors, deduped, order preserved
}

/// Everything the engine needs to inject for one page load.
/// Built by BoostInjectionPlanner. Consumed by the App target's engine adapter.
public struct InjectionPlan: Sendable, Equatable {
    public var planID: String                 // stable hash, see below
    public var url: URL                       // page URL the plan was built for
    public var profileID: ProfileID
    public var boosts: [ResolvedBoost]        // application order (§5.4)
    public var colorAdjustment: ColorAdjustment?  // selected single adjustment (nil = none)
    public var fontFamily: String?            // selected single font (nil = none)
    public var combinedJS: String             // all Boost js joined, "" when none
    public var containsJS: Bool               // combinedJS non-empty after trim
    public var bridgeVersion: Int             // always 1 in this plan

    public var isEmpty: Bool { get }          // boosts.isEmpty
}

public enum BoostInjectionPlanner {
    public static func plan(
        url: URL,
        profileID: ProfileID,
        matcher: BoostMatcher,
        boostsGloballyEnabled: Bool,
        context: PlanContext = .normal
    ) -> InjectionPlan

    public enum PlanContext: Sendable { case normal, incognito }
}
```

Planner algorithm (implement exactly):

1. If `boostsGloballyEnabled == false`, return an empty plan (`boosts: []`,
   `planID: "empty"`). The engine skips injection for empty plans.
2. `let matched = matcher.matching(url: url)`. If empty, return empty plan.
3. Select `colorAdjustment` and `fontFamily` (most specific wins; do not compose
   filters): `colorAdjustment` is the adjustment of the **last** matched Boost (in
   §5.4 order) whose adjustment is non-nil and non-identity, clamped. If none, nil.
   `fontFamily` is the font of the **last** matched Boost with a non-nil font that
   passes the §3.5 planner rejection (drop font values containing `;`, `{`, `}`, or
   a newline). If none, nil. Rationale: the output is a single CSS filter and a
   single font rule, so composition would be arbitrary; last-wins matches the CSS
   order in §5.4 and stays understandable in the future editor.
4. `boosts: [ResolvedBoost]` = matched.map with verbatim css/js and deduped zap
   selectors per Boost (dedupe across Boosts happens in the applier, §6.3; keep
   per-Boost lists faithful here).
5. `combinedJS` = matched js values filtered to non-whitespace, joined by
   `"\n;\n"`. Do **not** pre-build a combined stylesheet natively. The
   `InjectionPlan` carries structured parts (`boosts` with css/zaps, plus
   `colorAdjustment`/`fontFamily`); the applier builds the final CSS text (§6.3)
   because zap selectors need page-side validation. The wire payload is §9.3.
6. `planID`: FNV-1a 64-bit hash (implement the ~10-line non-cryptographic hash in
   this file; do not import CryptoKit for a cache key). Hash the actual content —
   never `hashValue`, which is not stable across launches. Concatenate, per boost,
   `boostID + "\0" + css + "\0" + js + "\0" + zaps.joined("\0")`, plus the selected
   color/font descriptions. FNV-1a over the UTF-8 bytes, hex-encode.
   `planID = "<count>-<hex16>"`. Two plans with identical content share an ID so
   the applier no-ops (§6.2).
7. `context` is recorded nowhere in the plan payload in v1 (both contexts apply the
   same). Keep the parameter so the App target can pass it and a future policy
   (Q4, §14) has one change site. Add a comment.

The planner is a pure function of `(url, matcher, flag)`. It does no I/O.

### 8.3 `PickerMessages.swift` — payloads and coordinator

Wire envelopes are defined in §9. This file defines the Swift side.

```swift
import Foundation
import OpenModel

/// Page → native. Decoded from the bridge JSON by the App adapter, then passed here.
public enum PickerInbound: Sendable {
    case zapCommitted(boostID: BoostID, selector: String, label: String, matches: Int, inShadowRoot: Bool)
    case zapReplaced(boostID: BoostID, oldSelector: String, newSelector: String, label: String, matches: Int)
    case zapRemoved(boostID: BoostID, selector: String, via: String)   // via: "undo" | "native"
    case zapListResult(boostID: BoostID, entries: [ZapListEntry])
    case pickerReady(boostID: BoostID)
    case pickerExited(boostID: BoostID?, reason: String)
    case pickerError(kind: String, selector: String?)
    case boostApplied(planID: String)
    case boostError(kind: String, selector: String?)
}

public struct ZapListEntry: Sendable {
    public var selector: String
    public var label: String
    public var matchCount: Int
    public var truncated: Bool
}

/// Native → page commands. The coordinator returns these; the App adapter sends them.
public enum PickerOutbound: Sendable {
    case enterZap(boostID: BoostID)
    case exitZap
    case listZaps(boostID: BoostID)
    case removeZap(boostID: BoostID, selector: String)
    case applyBoosts(InjectionPlan)
    case clearBoosts
}

/// Owns picker side effects: persists zaps. Plan rebuilding stays in the caller,
/// which keeps this class free of matcher ownership.
@MainActor
public final class BoostPickerCoordinator {
    private let store: BoostStore
    public private(set) var lastListResult: [ZapListEntry] = []

    public init(store: BoostStore)
    /// Persist side effects only. Returns true when the store changed and the
    /// caller must rebuild the matcher + re-plan + send boost:apply to open pages.
    public func handle(_ message: PickerInbound) -> Bool
}
```

`handle` behavior per case:

| Inbound | Store effect | Returns |
|---|---|---|
| `zapCommitted` | `store.appendZap(boostID, ZappedElement(selector, label))`. Duplicate → no change. Unknown boostID → no change, stderr log in debug. | `true` if appended |
| `zapReplaced` | Remove old selector, append new. Atomic from the caller's view (two store calls, one `updatedAt` bump is fine). If old missing, just append new. | `true` if the zap set changed |
| `zapRemoved` (via `undo`) | `store.removeZap(boostID, selector)`. | `true` if removed |
| `zapRemoved` (via `native`) | No store change (the removal was initiated natively; the editor already updated the store). | `false` |
| `zapListResult` | Cache into `lastListResult` for the editor UI to read. | `false` |
| `pickerReady`, `pickerExited`, `pickerError`, `boostApplied`, `boostError` | No store change. `pickerError`/`boostError` log to stderr in debug builds only. | `false` |

Wiring note for the App target (implementer of this plan only builds `OpenBoosts`;
the App wiring is specified here so signatures fit): the App holds
`store + matcher + coordinator` per profile. On page message: decode (§9.4) →
`coordinator.handle` → if `true`, `matcher.rebuild(store.allBoosts())`, then for each
open page whose URL matches the changed Boost's site, build a new plan and send
`boost:apply`. On navigation: build plan, inject applier if non-empty. On Zap entry
request from the future editor: send `zap:enter` (injecting `zap-picker.js` first if
needed). None of that App code is in this milestone; the coordinator and planner must
make it writable without changes to `OpenBoosts`.

### 8.4 Engine adapter boundary (what to assume, what not to build)

`docs/engine-api.md` does not exist yet (checked 2026-10-25; an engine agent is
writing the OpenEngine API in parallel). Assume only this abstract bridge:

- Page → native: page calls `window.__open.postMessage(type, payload)`.
  The engine delivers `(type: String, payloadJSON: String)` to native.
- Native → page: native calls the engine with a JS string that invokes
  `window.__open.receive(msg)` where `msg` is the JSON envelope from §9.1.
  The applier/picker register a single receive handler (§9.5).

Do **not** import any engine type in `OpenBoosts`. Do **not** name CEF types.
The App target owns a ~100-line adapter (future work, not in this plan's file list):

```swift
// App target (future, shown only to fix the boundary — do not create in this milestone):
// - On document_start for a matching page: evaluate boost-applier.js text,
//   then evaluate "window.__openBoosts && window.__openBoosts.apply(<payloadJSON>)".
// - On zap-enter: evaluate zap-picker.js if "window.__openZap" is undefined,
//   then send zap:enter via receive.
// - On engine message (type, payloadJSON): switch type prefix "zap:"/"picker:"/
//   "boost:" → decode in PickerMessages.swift helpers → coordinator.
```

Open questions that depend on the real API are listed in §14. If the real API offers
document-start script/CSS injection (per the task prompt, it will provide
"document-start script/CSS injection and a JS↔native message channel"), the adapter
should prefer native CSS injection for the zap/color/font parts when available and
keep the applier as the SPA/shadow owner. The JS runtime in §6 is designed to work
with either delivery, because it owns a `<style>` element either way. Do not block
this milestone on that choice.

### 8.5 Resource loading

Load the JS files from the target bundle:

```swift
public enum BoostResources {
    public static var applierJS: String { get }  // Bundle.module, "boost-applier.js"
    public static var pickerJS: String { get }   // Bundle.module, "zap-picker.js"
}
```

Put this enum in `InjectionPlan.swift` (bottom) or a small section of
`BoostStore.swift` — choose `InjectionPlan.swift`. Load once, cache in a
`static let` (lazy, thread-safe). If the resource is missing (misconfigured build),
return `""` and log to stderr; the planner still works and the harness (which loads
files directly) is unaffected. Use `.copy` resources (§2.1) so text loads verbatim.

---

## 9. Bridge contract (JS ↔ native)

This section is normative. Both JS files and the Swift `PickerMessages.swift`
implement only this contract. The engine adapter (§8.4) is a dumb transport for it.

### 9.1 Envelope and versioning

Every message in both directions is one JSON object:

```json
{ "v": 1, "type": "<string>", "payload": { } }
```

- `v` is the bridge version. Always `1` in this plan. Both sides ignore messages whose
  `v` is not `1` (log to console/stderr in debug, send nothing back). Do not negotiate.
- `type` uses `<area>:<verb>` strings from the tables below. Unknown types are ignored
  silently (forward compatibility). Never throw on unknown types.
- `payload` is always an object (possibly `{}`). Never send bare strings/numbers.
- Size guard: bridge payloads carry CSS/JS text in `boost:apply` (can be large).
  The bridge must not truncate. If the real engine channel has a size limit, that is
  open question Q2 (§14) and the fallback is native CSS injection (§8.4). The JS side
  imposes no limit.

Transport (abstract, per task prompt):

- Page → native: `window.__open.postMessage(type, payload)`.
  The JS helpers call this as `postToNative(type, payload)` which wraps
  `{ v: 1, type, payload }` — check the real engine shim when it lands: if
  `window.__open.postMessage` already wraps an envelope, the helper must not
  double-wrap. Implement the helper as: try `window.__open.postMessage(type, payload)`;
  the harness fake (§10.6) implements exactly that two-argument form. Document the
  assumption in the helper comment so the adapter author checks it first.
- Native → page: native evaluates `window.__open.receive(<envelopeJSON>)`.
  Each JS file registers its interest without overwriting the other:
  the **first** of the two files to load installs
  `window.__open.receive = function (msg) { dispatch to handlers }` with a handler
  registry `window.__open._handlers = []`; each file pushes its handler.
  If `window.__open` does not exist yet when a file loads (harness loads files
  before the fake bridge in one test), the file installs a minimal
  `window.__open = { postMessage() {}, _handlers: [], receive(msg) {...} }` stub
  so later real-bridge installation can adopt the handlers. Keep this shim under
  15 lines and identical in both files (copy it; do not factor into a third file).

### 9.2 Page → native messages (complete list)

| Type | Payload (exact keys) | Sent when | Native effect (§8.3) |
|---|---|---|---|
| `picker:ready` | `{ boostID }` | Picker finishes `enter` (overlay live, listeners attached) | none |
| `picker:exited` | `{ boostID, reason }` reason ∈ `"esc" \| "done" \| "bridge"` | Picker exits (any path) | none |
| `picker:error` | `{ kind, selector? }` kind ∈ `"no-candidate" \| "already-active"` | §7.3 / §7.7 | log only |
| `zap:committed` | `{ boostID, selector, label, matches, inShadowRoot }` | Click commits a zap (§7.4). `matches` = candidate match count at generation time. `label` = suggested label: `tagName` lowercased plus `#id` when the chosen selector is an id selector, else `tagName`. | persist zap |
| `zap:replaced` | `{ boostID, oldSelector, newSelector, label, matches }` | "Zap all related" replaces the just-committed zap | swap zap |
| `zap:removed` | `{ boostID, selector, via }` via ∈ `"undo" \| "native"` | Undo pops a zap (`"undo"`), or picker echoes a native-initiated removal (`"native"`) | undo → persist removal; native → no-op |
| `zap:list-result` | `{ boostID, entries: [{ selector, label, matchCount, truncated }] }` | Reply to `zap:list` (§7.6) | cache for editor |
| `boost:applied` | `{ planID }` | Applier finishes `apply` (including no-op same-plan applies? No — only when CSS actually changed or first apply). Fire once per distinct planID per page. | log only |
| `boost:error` | `{ kind, selector? }` kind ∈ `"invalid-zap-selector"` | Applier skips a bad zap selector (§6.3) | log only |

No other page→native types. In particular the picker never sends Boost CSS/JS and the
applier never sends picker state.

Label rule for `zap:committed`: keep it deterministic for harness assertions.
If the winning selector starts with `#`, label = `"<tag>#<id>"` (for example `div#promo`).
Else label = `"<tag>"` (for example `div`). Native stores it as `ZappedElement.label`.

### 9.3 Native → page messages (complete list)

| Type | Payload (exact keys) | Handled by | Behavior |
|---|---|---|---|
| `boost:apply` | `{ planID, boosts: [{ boostID, css, zaps: [string] }], colorAdjustment: { hueRotateDegrees, saturation, brightness, contrast, invert } \| null, fontFamily: string \| null, js: string }` | applier `apply()` | §6. Field names match `InjectionPlan` exactly. `js` is the planner's `combinedJS`. Empty plan is sent as `boosts: [], js: "", colorAdjustment: null, fontFamily: null` with `planID: "empty"` and must behave as clear. |
| `boost:clear` | `{}` | applier `clear()` | §6.2. |
| `zap:enter` | `{ boostID }` | picker `enter({ boostID })` | §7.3. If picker file not yet injected, the engine injects it first (§8.4). |
| `zap:exit` | `{}` | picker `exit()` with reason `"bridge"` | §7.3. |
| `zap:list` | `{ boostID }` | picker replies `zap:list-result` | §7.6. |
| `zap:remove` | `{ boostID, selector }` | picker removes preview + echoes `zap:removed` via `"native"` | §7.6. The real un-hide comes from the follow-up `boost:apply` without that zap. |
| `zap:undo` | `{}` | picker `undo()` | Same as Cmd/Ctrl+Z. For editor Undo buttons that live natively. |

Ordering guarantee the JS side may assume: for one page, native sends `boost:apply`
messages in plan order; a `zap:enter` for a page always follows any pending
`boost:apply` for that page. The JS side must still behave if order flips (apply
during picking must not exit the picker; it only refreshes styles + ends the §7.4
grace handling).

### 9.4 Swift decoding helpers (in `PickerMessages.swift`)

Add these exact helpers so the App adapter has one decode site:

```swift
public enum BridgeDecode {
    /// Returns nil for unknown types and bad payloads (never throws to the adapter).
    public static func decode(type: String, payloadJSON: String) -> PickerInbound?
    public static func encode(_ message: PickerOutbound) -> (type: String, payloadJSON: String)
}
```

Encoding rules: `JSONEncoder` with `.sortedKeys`, no pretty printing, date strategy
irrelevant (payloads carry no dates — zap `createdAt` is assigned natively at persist
time, never sent over the bridge). `boost:apply` encoding must produce keys exactly as
§9.3 (Swift property names already match; do not add `CodingKeys` renames).
Decoding must accept missing optional payload keys as defaults (`label` missing → `""`,
`inShadowRoot` missing → `false`) so an older picker still talks to newer native code.

### 9.5 Receive dispatch (JS side, both files)

Each file's handler checks `msg.v === 1` and switches on `msg.type` for only its own
types (applier: `boost:*`; picker: `zap:*` plus it listens for the
`open-boosts-applied` DOM event, not a bridge type). Handlers wrap their work in
try/catch and report failures via `console.warn("[open-boosts]", ...)` — bridge
errors must never throw into the engine's `receive` caller (it may be native eval code
that treats a throw as a page error).

---

## 10. Test harness (no unit tests — real browser, T3 preview tools)

All harness files live in `Packages/OpenKit/Sources/OpenBoosts/Harness/`.
They are **not** package resources and never ship in the app bundle. They are plain
files served over localhost so `preview_*` tools can drive them.
Do not add them to `Package.swift`. SwiftPM ignores unlisted directories under
`Sources/<target>/` only if they contain no Swift files — this directory contains
HTML/JS/Python only, so the build stays clean. Verify with `swift build` in Step 1
(§12) that the Harness directory does not break the target build; if SwiftPM
complains, add `exclude: ["Harness", "Resources"]` handling correctly (Resources are
declared; Harness must be excluded if SwiftPM errors — add
`exclude: ["Harness"]` to the `OpenBoosts` target in that case and note it).

Tools for every check below (T3 collaborative browser preview):

- `preview_open` a tab, `preview_navigate` to loader URLs, `preview_click`,
  `preview_hover`, `preview_press`, `preview_evaluate` to read page state,
  `preview_snapshot` only when a check says to look at the overlay visually.
- Never use computer use / desktop automation for harness checks (AGENTS.md + thread rules).

### 10.1 How the harness simulates production

Production: the engine injects the runtime files and sends `boost:apply` /
`zap:enter` (§9). The harness simulates that job in-page. `loader.html` (§10.6) is
the entry page and the canonical source of the simulation code. Each test page
(§§10.2–10.5) is standalone (no iframe — an iframe would break `elementFromPoint`
coordinates for `preview_click` and the shadow tests). At the end of `<body>`,
each test page includes exactly these, in this order:

```html
<script>/* fake __open bridge, inline, ~30 lines, identical in every page */</script>
<script src="../Resources/boost-applier.js"></script>
<script src="../Resources/zap-picker.js"></script>
```

Each test page also includes a fixed control bar (`<div id="harness-bar">`) whose
buttons apply fixtures and drive the picker (§10.6). Write the bridge + bar snippet
once in `loader.html` as the canonical text, then copy it verbatim into each test
page. Check H0 (§10.9) exercises the same bridge logging on the loader and on a
test page, which catches copy drift. `Harness/` contains exactly the 7 files in
§2.2. Do not create a shared `harness-bridge.js`.

`loader.html` itself holds: explanation, links to the four test pages, the fixture
plan JSON in `<pre id="fixtures">`, and the canonical bridge snippet in
`<pre id="bridge-snippet">`. Harness checks start at `loader.html` (runtime files
load, versions report), then navigate to the test pages.

### 10.2 `static.html` — static content page

Fixed structure (ids/classes are normative; checks reference them):

```html
<header id="site-header">…nav…</header>
<div id="promo-banner" class="promo card">Spring sale — dismiss is the Zap target</div>
<main id="content">
  <article class="post card" data-testid="post-1"><h2>First post</h2><p>…</p></article>
  <article class="post card" data-testid="post-2"><h2>Second post</h2><p>…</p></article>
  <article class="post card" data-testid="post-3"><h2>Third post</h2><p>…</p></article>
  <aside id="sidebar-ad" class="ad-unit">Ad</aside>
  <div class="x7qz9 a1b2c3">Obfuscated widget (also on obfuscated page; here as a control)</div>
  <img id="hero-img" src="…inline SVG data URI or CSS gradient div…" alt="Hero">
  <pre><code>code sample stays monospace (font check)</code></pre>
</main>
<footer id="site-footer">…</footer>
```

Requirements: no external resources (inline style only, no CDN), no CSP header
(`serve.py` sends none), deterministic layout (fixed widths, no animations except
where a check needs one), text states the purpose of each block so a human reviewer
can follow checks without reading this plan. Include the harness bar (§10.1) with:
boost fixture selector (three fixtures F1–F3 below), Enter Zap, Undo, Exit,
message log `<ol id="harness-log">`, and `window.__harness = { messages: [], lastPlan: null }`.

Fixtures (exact; the loader and every page embed them):

- **F1 "css+zap"**: domain = harness host (see §10.7 host note), css =
  `#site-header { outline: 3px solid rgb(255, 0, 0); }`, zaps = `["#promo-banner"]`,
  no color/font/js. Proves CSS + zap application.
- **F2 "color+font"**: css = `""`, zaps = `[]`,
  colorAdjustment = `{ hueRotateDegrees: 90, saturation: 0.5, brightness: 1, contrast: 1, invert: 0 }`,
  fontFamily = `"Georgia, serif"`. Proves filter + font.
- **F3 "js"**: js =
  `document.documentElement.dataset.boostJsCount = String(Number(document.documentElement.dataset.boostJsCount || 0) + 1); document.documentElement.setAttribute("data-boost-js", "ran");`,
  css/zaps empty. Proves JS runs, and runs once per plan (check A5).

Host note: harness pages are served from `127.0.0.1`. The harness never runs the
Swift matcher (no Swift runs in the browser). The harness bar builds the §9.3
`boost:apply` payload directly in JS from these fixtures. Verify domain matching
natively in §12 Step 3 (scratch Swift run pasted into the PR description).
Do not add a CLI for it.

### 10.3 `spa.html` — SPA that swaps content

A page with two views swapped by `history.pushState` (no reload):

- View A (`/spa.html#a` state): contains `#promo-banner` (same id as static) and
  `#view-a-marker`.
- A "Go to view B" button calls `pushState` and replaces `<main>` innerHTML with
  view B markup containing a **new** `#promo-banner` node and `#view-b-marker`.
- A "Back" button pops state.
- The swap also removes and recreates `<head>` children (simulate a framework head
  manager: remove all non-essential head nodes, re-add) in one variant button
  "Swap + reset head" to prove §6.3 style re-insertion.
- Include a route that changes only the path (`pushState` to a fake `/blog/post`
  path on the same document — `serve.py` must serve `spa.html` for unknown paths
  under its directory, §10.7) to support the path-prefix plan-clear simulation:
  the harness bar button "Simulate path no longer matches" sends `boost:clear`.

### 10.4 `shadow-dom.html` — shadow DOM page

- One open shadow host `<div id="open-host">` with shadow content containing
  `<div id="shadow-promo" class="promo">` and `<p class="shadow-text">`.
- One closed shadow host `<div id="closed-host">` (created via JS
  `attachShadow({ mode: "closed" })`) with similar content. The page script keeps
  no reference reachable from `window` for the closed root (to prove §6.8 limits
  honestly). A boolean on the page records that the closed root was created
  **after** applier injection when a harness button is used (see checks S2–S3).
- One `<button id="make-late-shadow">` that creates a new open shadow root after
  Boosts are applied (proves the `attachShadow` patch).
- Zap note: picking inside the **open** shadow root must work via `composedPath`
  (§7.7). Picking the closed host highlights the host.

### 10.5 `obfuscated.html` — generated-looking class names

- Repeated cards with generated classes (vary them; all must trip §7.5 Step B):
  `class="a1b2c3 x7qz9 card-k8x2"`, siblings × 6 identical-structure cards, each with
  a stable `data-testid="card-N"` on the card and a semantic child
  (`<h2 class="card-title">`)? Design carefully: cards themselves have **only**
  gibberish classes; the stable hook is `data-testid`. Inside each card, a title
  with semantic class `post-title` and a body paragraph. One unique element with
  a stable id `#stable-cta`.
- Purpose: the picker must prefer `[data-testid="card-2"]` (or an ancestor-scoped
  variant) over any gibberish class selector, and must not return a selector whose
  primary term is a gibberish class among the top candidates when a semantic
  alternative exists. Exact assertions in O-checks (§10.9).

### 10.6 `loader.html` — entry + canonical bridge snippet

Content: title, short instructions, links to the four pages (relative), fixture JSON
in `<pre id="fixtures">`, the canonical fake-bridge + harness-bar snippet in
`<pre id="bridge-snippet">`, and its own live demo area? No demo area — loader only
proves the two runtime files parse and expose `__openBoosts`/`__openZap` version 1.
It includes the two runtime script tags (with no test content) and a status line
filled by an inline script: `applier: v1, picker: v1`. Checks start here (H0).

Canonical fake bridge (normative text; copy into every test page):

```js
window.__harness = { messages: [], lastPlan: null };
window.__open = {
  _handlers: [],
  postMessage(type, payload) {
    const msg = { v: 1, type, payload };
    window.__harness.messages.push(msg);
    const li = document.createElement("li");
    li.textContent = type + " " + JSON.stringify(payload).slice(0, 160);
    document.getElementById("harness-log")?.appendChild(li);
  },
  receive(msg) {
    for (const h of window.__open._handlers) { try { h(msg); } catch (e) { console.warn(e); } }
    if (msg.type === "boost:apply") window.__harness.lastPlan = msg.payload;
  },
};
```

The harness bar buttons call: `applyFixture("F1"|"F2"|"F3")` (builds §9.3 payload
with `planID: "harness-<name>"`, calls `window.__open.receive(...)`),
`enterZap()` (ensures picker loaded — it is, via script tag — then
`receive({ v:1, type:"zap:enter", payload:{ boostID:"harness-boost" } })`),
`undoZap()` (`__openZap.undo()`), `exitZap()`, `listZaps()`
(`receive zap:list`), `clearBoosts()` (`receive boost:clear`).
`boostID: "harness-boost"` is fixed for all harness zaps.

### 10.7 `serve.py` — tiny local server

```python
# Usage: python3 serve.py [--port 8931]  (run from the Harness directory)
```

Requirements: Python 3 standard library only (`http.server`). Serves the Harness
directory **and** the sibling `Resources/` directory (because test pages reference
`../Resources/*.js`). Implementation: custom handler whose root is the `OpenBoosts`
directory (`Sources/OpenBoosts/`), so `/Harness/static.html` and
`/Resources/boost-applier.js` both resolve. Bind `127.0.0.1` only. Default port
`8931` (pick it; checks use it). Unknown paths that look like SPA routes under
`/Harness/spa.html` fallback: if the path starts with `/Harness/` and the file does
not exist and the `Referer` contains `spa.html`, serve `spa.html`. Simpler: if path
ends with `/post` or starts with `/Harness/blog`, serve `Harness/spa.html`. Log
requests to stdout. No caching headers beyond defaults; add
`Cache-Control: no-store` so edited JS reloads without hard-refresh confusion.
Print the four page URLs on startup.

Start command for checks (detached, survives the session per AGENTS.md rule 9 —
harness server is a long-running job):

```bash
cd Packages/OpenKit/Sources/OpenBoosts/Harness && python3 serve.py --port 8931
```

Run it via the runtime's managed background execution (or the repo's setsid pattern
from AGENTS.md rule 9 if the implementer runs it outside the agent session).
Base URL for all checks: `http://127.0.0.1:8931/Harness/loader.html`.

### 10.8 `README.md` (in Harness)

One page: how to start the server, the four URLs, fixture meanings, known limits
(icon-font breakage, partial-invert media, pre-injection closed roots, iframe
contents), and the perf-measurement snippet (§11). The implementer writes it from
§10–§11 of this plan. Do not copy this plan file into it; summarize.

### 10.9 Acceptance checks (run every one; record pass/fail in the PR)

Notation: **Open** = `preview_open`/`preview_navigate`. **Eval** = `preview_evaluate`
expression → expected. **Click/Hover/Press** = the `preview_*` tools on the harness
page (coordinates from a prior Eval of `getBoundingClientRect`, or locators on
harness-bar buttons — harness buttons have stable ids). Every check starts from a
fresh navigation unless it says "continue".

Global checks:

- **H0 — Runtime loads.** Open `loader.html`. Eval
  `window.__openBoosts?.version` → `1`. Eval `window.__openZap?.version` → `1`.
  Eval `document.querySelector("#loader-status").textContent` contains `picker: v1`.
  No console errors from our files (check via Eval hook: the loader installs
  `window.__harness.errors` collecting `window.onerror` for our file names; expect empty).
- **H1 — Server serves real runtime files.** Eval on any test page:
  `fetch("../Resources/boost-applier.js").then(r => r.status)` → `200`.
  (Proves checks test the production files, not inline copies.)

Static page (`static.html`):

- **A1 — CSS fixture applies.** Click harness **F1**. Eval
  `getComputedStyle(document.querySelector("#site-header")).outlineStyle` → `"solid"`.
  Eval `window.__openBoosts.state()` → `{ appliedPlanID: "harness-F1", zapCount: 1, ... }`
  (assert planID + zapCount; boostIDs contains `harness-boost`? F1 uses one synthetic
  boost entry — assert `boostIDs.length === 1`).
- **A2 — Zap target hidden by plan.** Continue A1. Eval
  `getComputedStyle(document.querySelector("#promo-banner")).display` → `"none"`.
- **A3 — Reload keeps Boost (persistence of injection, engine simulation).**
  `preview_navigate` to `static.html` again (fresh load injects runtime but no plan).
  Eval promo display → not `"none"` (no plan yet). Click **F1** again. Eval → `"none"`.
  This proves re-apply on a fresh document, the production navigation path.
- **A4 — Color + font fixture.** Fresh navigate. Click **F2**. Eval
  `getComputedStyle(document.documentElement).filter` contains `hue-rotate(90deg)`
  and `saturate(0.5)`. Eval
  `getComputedStyle(document.querySelector("article p")).fontFamily` contains
  `Georgia`. Eval code stays monospace:
  `getComputedStyle(document.querySelector("pre code")).fontFamily` does **not**
  contain `Georgia` (or contains a monospace family — assert not-Georgia).
- **A5 — JS fixture runs once.** Fresh navigate. Click **F3**. Eval
  `document.documentElement.getAttribute("data-boost-js")` → `"ran"` and
  `document.documentElement.dataset.boostJsCount` → `"1"`. Click **F3** again
  (same planID). Eval `dataset.boostJsCount` → still `"1"` (same-plan apply is a
  no-op, §6.2, so the counter does not increment).
- **A6 — Clear restores.** Continue. Click **Clear**. Eval promo display (after
  re-applying F1 first if needed) → not `"none"`; header outline → `"none"` style;
  `__openBoosts.state().appliedPlanID` → `null`.
- **A7 — Picker zap by clicking the banner.** Fresh navigate (no plan, so the banner
  is visible). Click **Enter Zap**. Hover the banner center via `preview_hover`
  (coordinates from Eval rect). `preview_snapshot` — reviewer confirms the highlight
  box overlays the banner (visual check, note pass/fail). `preview_click` the banner
  center. Eval `window.__harness.messages.filter(m => m.type === "zap:committed")`
  → length 1; entry payload `selector` → `"#promo-banner"` (the id is stable, the
  generator must rank it first); `matches` → `1`. Eval promo computed display →
  `"none"` (preview style). Eval `__openZap.isActive()` → `true` (still picking).
- **A8 — Esc exits, zap survives via simulated native re-apply.** Continue A7.
  `preview_press` Escape. Eval `__openZap.isActive()` → `false`. Messages contain
  `picker:exited` with reason `"esc"`. Then simulate native persistence: click **F1**
  (whose zaps already include `#promo-banner`)? F1 already hides it — instead click
  a harness button **Re-apply with committed zaps** (the bar builds a new plan whose
  zaps are all selectors harvested from `__harness.messages` `zap:committed` events;
  planID `harness-committed`). Implement this button in the bar. Eval promo display
  → `"none"` after picker preview style is gone (assert by removing picker preview:
  after re-apply + 600 ms, Eval
  `document.getElementById("open-zap-preview-style")` → `null` and promo still
  `"none"`). Proves the §7.4 grace handoff.
- **A9 — Undo last zap.** Fresh navigate. Enter Zap. Click `#sidebar-ad`. Eval its
  display → `"none"`. `preview_press` Control+Z (and Meta+Z variant: send the bar
  **Undo** click as the deterministic path; keyboard is a second attempt — assert
  via the button). Click bar **Undo**. Eval sidebar-ad display → not `"none"`.
  Messages contain `zap:removed` with `via: "undo"` and the sidebar selector.
  Eval `__openZap.undo()` again via Eval → `false` (empty stack).
- **A10 — Candidates API shape.** Eval
  `window.__openZap.candidatesAt(<promo center x>, <promo center y>)` →
  array length between 1 and 15; every entry has string `selector` and number
  `matches` with `1 <= matches <= 100`; entries sorted by `matches` ascending;
  first entry selector → `"#promo-banner"`. Eval `rectsForSelector("#promo-banner")`
  → one rect with positive width/height. Eval `hoveredAt(x, y).hash` starts with
  `DIV#promo-banner` (hash format `TAG#id.class...@siblingIndex`, §7.5 entry —
  assert prefix only).
- **A11 — Zap all related.** Fresh navigate. Enter Zap. Click the first
  `article.post`. Eval last committed selector matches 1 element (the generator's
  top pick may already be the shared class — handle both: if the committed
  `matches === 3`, the check passes at this step). Else the bar shows
  **Zap all related (3)**; hover it (multi-rects visible — snapshot),
  click it. Messages contain `zap:replaced` (or a second committed) whose selector
  has `matches === 3`. Eval all three articles' display → `"none"`. Implementer
  records which branch occurred; both are pass if the end state holds.

SPA page (`spa.html`):

- **S-A1 — Zap survives SPA swap.** Open `spa.html`. Click **F1**. Eval view-A
  promo display → `"none"`. Click **Go to view B** (pushState swap creates a new
  `#promo-banner`). Eval new promo display → `"none"` without any further apply
  clicks. (CSS-rule persistence, §6.6.)
- **S-A2 — Style survives head reset.** Continue. Click **Swap + reset head**.
  Eval `document.getElementById("open-boosts-style")` → not null. Promo display
  still `"none"`. (May need one frame: Eval after a 100 ms wait via
  `preview_wait_for` on a condition or a second Eval — assert eventual presence,
  record if a frame delay was needed.)
- **S-A3 — Path-clear simulation.** Click **Simulate path no longer matches**.
  Eval promo display → not `"none"`. Proves `boost:clear` handling. (Native matcher
  path logic itself is Step-3 verified, §12.)

Shadow page (`shadow-dom.html`):

- **S1 — Open-root zap rule applies.** Open page. Apply a harness plan whose zaps
  include `#shadow-promo` scoped how? Main-document `#shadow-promo` cannot match
  inside shadow. The plan zap for shadow content is the bare selector the picker
  would generate inside the root. Harness fixture **F-shadow**: zaps =
  `["#shadow-promo"]`, applied via the normal apply flow (applier pushes zap rules
  into tracked open roots, §6.8). Add this fixture button. Eval: pierce via
  `document.querySelector("#open-host").shadowRoot.querySelector("#shadow-promo")`
  computed display → `"none"`. (Reading `shadowRoot` here is test code on an open
  root — allowed; the runtime uses adopted sheets, the assertion reads computed style.)
- **S2 — Late shadow root gets styles.** Continue S1. Click **Make late shadow**.
  Eval the new root's promo-equivalent computed display → `"none"`. Proves the
  `attachShadow` patch.
- **S3 — Closed root created after injection gets zap styles; before does not
  (documented limit).** The page creates its closed root on load (before any apply
  — but after `document_start` injection in production; in the harness the runtime
  script tags sit at body end, so the closed root predates the applier). After
  applying F-shadow, assert the closed root's promo is **not** hidden (Eval cannot
  reach a closed root — assert indirectly: the page exposes
  `window.__harness.closedPromoDisplay()` helper that the page script implements
  with its retained reference — the page may keep a reference for testability even
  though production picker cannot. Keep the helper; it returns the computed display.
  Expected: not `"none"` = known limit, **pass** if documented in README).
  Then click the page's **Make late closed shadow** button (add it): new closed
  root created after applier load → helper for the late root returns `"none"`
  (patch captured it). Both assertions together are the check.
- **S4 — Pick inside open shadow.** Enter Zap. Click the open host's shadow promo
  (coordinates: Eval the host rect + known offset; shadow content layout must be
  deterministic). Eval last `zap:committed` payload `inShadowRoot` → `true`,
  selector non-empty. Eval that element's computed display (via shadowRoot probe)
  → `"none"`.

Obfuscated page (`obfuscated.html`):

- **O1 — Picker prefers `data-testid` over gibberish classes.** Enter Zap. Click
  card 2's body. Eval `candidatesAt` at that point: assert no entry in the top 5
  has a selector whose first term starts with `.a1b2c3` or `.x7qz9` (gibberish
  classes from the fixture — read exact fixture class names when writing the page
  and put them in the check), and assert some entry contains `data-testid`.
  Eval committed (after click) selector contains `data-testid="card-2"` or is
  `#stable-cta`-style precise — for the card click, require `data-testid`.
- **O2 — Gibberish-only unique element still zappable.** Click the obfuscated
  widget that has no semantic hook except structure. Eval committed selector
  non-empty, its `matches >= 1`, and the widget's display → `"none"`. (Robustness:
  the generator must still produce something, likely tag+position or ancestor-scoped.)
- **O3 — Candidate limits hold on repeated structures.** Eval `candidatesAt` on a
  card: length `<= 15`, every `matches <= 100`, sorted ascending. On this page also
  Eval a broad selector probe: `rectsForSelector(".post-title")` length equals the
  card count (6) — proves rect preview counts.

Failure/empty cases (any page):

- **E1 — No-candidate path.** On `static.html`, enter Zap and click the harness log
  area? Log is outside picking scope (bar buttons excluded). Instead: Eval-direct
  `window.__openZap.candidatesAt(-100, -100)` → `[]`. And click at (2,2) (page
  margin over `<html>`): either a broad commit occurs (allowed, §7.7) or
  `zap:error` — record which; pass if no exception and picker stays active.
- **E2 — Invalid zap selector in plan does not break apply.** Harness button
  **Apply bad-zap plan**: plan zaps = `["#promo-banner", "!!!invalid"]`. Click it.
  Eval promo → `"none"` (good zap still applied). Messages contain `boost:error`
  with kind `"invalid-zap-selector"`. Header outline from F1 portion (include F1
  css in this plan) still applies.
- **E3 — Double-enter rejected.** Enter Zap. Eval `__openZap.enter({boostID:"other"})`
  → picker stays on `harness-boost` (Eval `isActive()` true and a subsequent commit
  carries `boostID: "harness-boost"`), messages contain `picker:error`
  kind `"already-active"`.

Performance checks: §11 defines P1–P3. Run them as part of the harness pass.

---

## 11. Performance budgets and measurement

Budgets extend `docs/architecture.md` (M5 Pro, release build intent; harness numbers
are in the T3 preview browser, so treat them as relative gates, not absolute hardware
promises — a harness failure by 2× still blocks; a pass with headroom is the goal).

| ID | Budget | Applies to |
|---|---|---|
| PERF-1 | Boost applier `< 1 ms` at `document_start` for a typical plan (≤ 5 Boosts, ≤ 20 zap selectors, ≤ 32 KB combined CSS, no Boost JS). Measured as `apply()` execution time excluding JS payload execution. | §6 `apply` |
| PERF-2 | Picker hover handling `< 2 ms per frame` (the rAF hover callback: target resolution + hash + highlight move). Full selector generation is **not** in this budget (it runs on click). | §7.3 hover |
| PERF-3 | Selector generation on click `< 50 ms` for the static page's article element (ancestors ≤ 8, descendants ≤ 2). Not a task-stated budget; it is the click-responsiveness gate so picking feels instant. If generation exceeds it, the click still works; the PR must note the measured value. | §7.5 |

How to measure in the harness (implement exactly; add the snippet to `Harness/README.md`):

- P1 (applier): on `static.html`, Eval:
  ```js
  (() => {
    const plan = window.__harness.lastPlan; // after clicking F1 once
    window.__openBoosts.clear();
    const t0 = performance.now();
    window.__openBoosts.apply(structuredClone(plan));
    const t1 = performance.now();
    return { ms: t1 - t0, state: window.__openBoosts.state() };
  })()
  ```
  Run 5 times (clear between runs, alternate planIDs `harness-F1` / `harness-F1b`
  with identical content so the planID no-op does not hide the cost — build F1b in
  the bar as the same fixture with a different planID). Report median. Gate: median
  `< 1 ms`. If the preview browser is noisy, report all 5 values; a single outlier
  from GC does not fail, a median above budget does. Boost JS plans (F3) are
  excluded from P1 timing (script execution cost is user code).
  Note: `document_start` timing in production is earlier than this harness measure
  (harness applies after parse). The harness number is an upper bound for style
  construction cost; the real `document_start` claim needs the engine adapter to log
  `performance.now()` deltas later. State this in the PR.
- P2 (hover): on `static.html` with Zap active, Eval:
  ```js
  (() => {
    const pts = []; // 20 points across the article grid, computed from rects
    // The harness bar button "Perf hover" runs this and writes the result into
    // #harness-log + window.__harness.perfHover = { median, max }.
  })()
  ```
  Implement the **Perf hover** bar button in every test page: it dispatches 20
  synthetic `mousemove` events? Synthetic events do not exercise
  `elementFromPoint` the same way. Preferred: the button drives the picker's
  internal hover processor directly if the picker exposes it for the harness —
  it does not (public surface is §7.1 only). So measure with real tool calls:
  `preview_hover` across 5 distinct elements while Eval samples
  `performance.now()` around `hoveredAt(x, y)` calls (the pure part of hover).
  Gate: median `hoveredAt` < 2 ms over 20 calls. Record the full-hover path
  (tool hover + snapshot) qualitatively (no visible lag). Implement the button as
  the `hoveredAt` loop (it is the measurable proxy); name it **Perf hoveredAt**.
- P3 (generation): Eval `candidatesAt` timing on the article point, 5 runs, median
  reported. No hard fail below 50 ms guidance; record the value.

Native-side budget (no harness): matcher `matching(url:)` for 100 boosts /
10 domains must be negligible (dictionary probes). No formal gate; the implementer
runs the §12 Step 3 spot check and reports the elapsed time for 10,000 lookups.
If it exceeds 1 ms per lookup something is wrong (likely a linear scan).

Idle cost: with no Boost applied and picker inactive, our JS must add no timers and
no observers. Verify: Eval on a fresh test page (runtime loaded, never applied):
`window.__openBoosts.state().appliedPlanID` → `null`, and the page's
`getEventListeners` is not available in Eval — instead assert by code reading plus
the P2 baseline: hover cost on an unapplied page equals harness noise. List this as
a code-reading check in the PR, not a tool check.

---

## 12. Implementation order (work top to bottom)

Do the steps in order. Each step ends with its acceptance criteria. Do not start the
next step with a failing criterion unless the failure is recorded as a known limit
that this plan already documents.

### Step 1 — Package skeleton + resources plumbing

Files: edit `Packages/OpenKit/Package.swift` (§2.1). Create
`Sources/OpenBoosts/Boost.swift` with only `BoostID` + stub types so it compiles,
empty `Resources/boost-applier.js` (`window.__openBoosts = { version: 1 };` stub)
and `Resources/zap-picker.js` stub. Create `Harness/` directory with a placeholder
`README.md` (one line) so SwiftPM behavior is testable early.

Do: `swift build` in `Packages/OpenKit`. Fix the Harness exclusion here if needed
(§10 intro). Confirm existing targets still build (`OpenModel`, `OpenStore`,
`OpenSuggest`, `openkit` untouched).

Accept:
- [ ] `swift build` succeeds with zero new warnings in `OpenBoosts`.
- [ ] `git status` shows only `Package.swift` modified and `Sources/OpenBoosts/` new.
      No `OpenModel` file is modified.
- [ ] `BoostResources.applierJS` (add the enum now, §8.5) returns the stub text in a
      manual check (temporary `print` via a scratch `swift run`? No CLI change —
      verify by a one-off `swift -e` importing the built module is awkward; instead
      assert the resource file exists in the built bundle:
      `find .build -name "boost-applier.js"` finds it. Record the path.)

### Step 2 — Data model (`Boost.swift` complete)

Files: complete `Boost.swift` per §3 (all types, normalization, clamping,
`appendZap`/`removeZap`, `containsJS`, `isEmpty`).

Accept (verify by reading + a temporary scratch Swift file run with `swift` against
the package — create it under `/tmp`, not in the repo; delete nothing in the repo):
- [ ] Normalization (domain and pathPrefix are separate inputs):
      `SiteMatch.normalized(domain: "EXAMPLE.com.", pathPrefix: "blog//x/")`
      → domain `"example.com"`, pathPrefix `"/blog/x"`.
      `SiteMatch.normalized(domain: "example.com", pathPrefix: "/")`
      → pathPrefix nil. `SiteMatch.normalized(domain: "*.Example.COM", pathPrefix: nil)`
      → domain `"example.com"`.
- [ ] `ColorAdjustment(hueRotateDegrees: 370, saturation: 9, invert: 2).clamped()`
      → hue `10`, saturation `3`, invert `1`. NaN saturation → `1`.
- [ ] Zap dedupe: appending the same selector twice returns `[true, false]` and
      leaves one zap.
- [ ] JSON round-trip of the §4.1 example Boost through the §4.3 encoder/decoder
      yields an equal value (compare encoded bytes twice for stability).

Implementation tip: run the scratch checks as a file in `/tmp/boost-check/main.swift`
with `swiftc` against the built package products, or add a temporary executable
target locally and remove it before committing. Never commit the scratch.

### Step 3 — Store + matcher

Files: `BoostStore.swift` (§4), `BoostMatcher.swift` (§5).

Accept:
- [ ] Store round-trip in `/tmp`: create a store at a temp root for a fixed
      `ProfileID`, upsert two Boosts (one with path prefix `/blog`), `saveNow()`,
      assert the file exists at `<root>/Boosts/<uuid>.json`, create a second store
      instance at the same root, `load()`, assert equality of the boost sets
      (IDs, selectors, color values). Paste the file JSON into the PR description
      (redact nothing — synthetic data).
- [ ] Corrupt-file path: write `not json` into the file, `load()` → `[]`, assert a
      `.corrupt-*` sibling exists and the original path is gone.
- [ ] Matcher table (assert every row of §5.5 in the scratch run): build boosts for
      `example.com`, `example.com` + `/blog`, `news.example.com`, `0.1`; query the
      §5.5 URLs; assert results and **order** (general before specific). Include:
      `https://www.example.com/blog/post` matches host-wide + `/blog` + (not
      `news`), in that order; `https://badexample.com/` matches none;
      `https://example.com/blogger` matches host-wide only.
- [ ] Perf spot check: 100 boosts, 10,000 lookups, report ms/lookup (expect ≪ 1 ms).
- [ ] Debounce: three rapid upserts produce one file write (assert by file mtime /
      content after 1.2 s contains all three; do not assert write counts by
      instrumenting production code).

### Step 4 — Boost applier JS

Files: `Resources/boost-applier.js` (§6). Harness pages needed now: `loader.html`,
`static.html`, `serve.py` (§§10.2, 10.6, 10.7). Write the canonical bridge/bar in
`loader.html` first, copy into `static.html`.

Accept (T3 preview, §10.9): H0, H1, A1–A6, E2 pass on `static.html`.
Perf P1 median recorded (gate < 1 ms; if the preview browser cannot resolve
sub-millisecond timing reliably, record `performance.now()` resolution limits and
the 5 raw values — a median an order of magnitude over budget still fails).

Do not proceed to the picker until A2 (zap-by-plan) passes: the picker depends on
the same hide-rule mechanics.

### Step 5 — Zap picker: overlay + hover + basic commit

Files: `Resources/zap-picker.js` (§7.2–§7.4, with a **temporary** simple selector:
id if present else tag — replaced in Step 6). Wire `zap:enter/exit/committed/removed`
and undo (§7.6). Bar buttons for enter/undo/exit must work.

Accept: A7 (with the temporary selector, the committed selector for the banner is
still `#promo-banner` because it has an id — the check holds), A9 pass. Snapshot
shows our overlay (border `#4C8DFF` family) — reviewer confirms it does not look
like Arc's picker (own minimal styling, §7.2).

### Step 6 — Selector generation (full §7.5)

Files: replace the Step 5 temporary selector inside `zap-picker.js` with the full
algorithm (Steps A–F). No public-surface change.

Accept: A10, A11, O1–O3 pass. P3 median recorded. E1, E3 pass.
Also: Eval `candidatesAt` on the static obfuscated control div (`.x7qz9`) — record
the returned top selector in the PR; it must not be the bare `.x7qz9` class alone
when an ancestor-scoped alternative exists (if it is, tune Step B/E weights and
re-run O-checks; do not change the fixture to make it pass).

### Step 7 — SPA + shadow completion

Files: applier §6.6/§6.8 completion (if deferred), picker shadow scoping (§7.4–§7.5),
harness pages `spa.html` + `shadow-dom.html` (§§10.3–10.4).

Accept: S-A1–S-A3, S1–S4 pass, including the documented closed-root limit (S3).
A3 (reload) still passes.

### Step 8 — Obfuscated page + full harness pass

Files: `obfuscated.html` (§10.5), `Harness/README.md` (§10.8, include §11 snippet).

Accept: **every** check in §10.9 passes (H, A, S-A, S, O, E) plus P1–P3 recorded.
`swift build` still clean. Start the server fresh per §10.7 and run the full pass
from `loader.html` without restarting between pages (except where a check says
fresh navigate). Record results as a checklist in the PR description with the
preview tool evidence (Eval return values quoted, not screenshots alone, except
A7/S-A overlay visuals where a snapshot is the evidence).

### Step 9 — Native glue (`InjectionPlan` + picker coordinator)

Files: `InjectionPlan.swift` (§8.2), `PickerMessages.swift` (§8.3–§9.4).
Replace stubs as needed. `BoostResources` (§8.5) final.

Accept:
- [ ] Scratch Swift run: build a store with the §4.1 example Boost (adapt domain to
      `example.com`), matcher, plan for `https://www.example.com/blog/post` with
      global on → plan contains the Boost, `colorAdjustment`/`fontFamily` chosen,
      `planID` stable across two builds with same content and different after an
      edit. Global off → empty plan (`planID == "empty"`).
- [ ] Coordinator: feed `PickerInbound.zapCommitted` for a known boost → store gains
      the zap, `handle` returns `true`; duplicate → `false`. `zapRemoved` via
      `"native"` → `false` and no store change.
- [ ] `BridgeDecode` round-trip: encode each `PickerOutbound` case, decode the
      `boost:apply` payload shape in JS terms (assert key names by inspecting the
      JSON string contains `"planID"` and `"colorAdjustment"`). Paste one encoded
      `boost:apply` example into the PR.
- [ ] Harness still passes (native files do not affect the browser; this guards
      accidental resource edits).

Out of scope for this step: wiring the App target to `OpenEngine`. That follows
when `docs/engine-api.md` lands (Q1–Q3). The PR description must state this.

### Step order dependency summary

`1 → 2 → 3` (Swift foundation; 2 and 3 can be one PR if small).
`4 → 5 → 6 → 7 → 8` (JS runtime + harness, sequential — each builds on the last).
`9` (native glue) can overlap `4–8` in a separate branch/PR since it only shares
the §9 contract, but merge it after Step 3. Recommended PR split (one PR per
milestone rule in `docs/plan.md` still holds — these are sub-PRs to a feature
branch, merged to `main` together as M6-Boosts):
PR-a: Steps 1–3. PR-b: Steps 4–5. PR-c: Steps 6–8. PR-d: Step 9.

---

## 13. Cross-cutting rules

### 13.1 Errors and logging

- JS: `console.warn("[open-boosts]", ...)` / `console.warn("[open-zap]", ...)`.
  Never `console.log` in production paths except the harness bar (harness pages may log).
- Swift: stderr lines prefixed `BoostStore:` / `BoostPicker:` in debug only
  (`#if DEBUG`). Release builds stay silent (idle/noise goals). Persistence failures
  (§4.3) are the exception: one stderr line in all builds, matching `SnapshotStore`.

### 13.2 Security and privacy

- Boost JS runs in the page world with page privileges (that is the feature).
  Do not add a permission prompt in this milestone; the future editor owns trust UX.
  Record in the harness README: "Harness fixtures run arbitrary JS by design."
- `containsJS` must be accurate (whitespace-trimmed) because the future share path
  refuses JS Boosts (BO-2). Test it in Step 2 (JS of only spaces → `false`).
- CSS values from `fontFamily` are the one place model data becomes CSS syntax:
  enforce the §3.5 planner rejection (`;{}"` + newline → drop font component).
  User `css` is emitted verbatim by design (it is the user's own stylesheet for
  their browser). Zap selectors are validated by probe (§6.3) before emission.
- No network access in `OpenBoosts` or the runtime files. No telemetry.

### 13.3 Import from Arc (explicit non-goal with a hook)

`StorableBoostsData.json` has never been observed (data-model.md §2.6, model.md
"boosts: not imported"). Do not write a parser. The hook: `Boost` field names
(`css`, `js`, `zaps`, enabled, site match) are chosen so a future importer can map
observed Arc fields onto them without renaming. When a real file is captured
(data-model.md §6 item 2), write the importer against that evidence in `OpenImport`,
not in `OpenBoosts`. Until then the import report keeps saying "boosts: not imported".

### 13.4 What "done" means for this milestone

The Swift package builds clean; the harness pass (§10.9) is green in a real browser
via preview tools; perf values are recorded; no App/engine wiring is claimed.
A follow-up (editor UI + engine adapter + Site Control Center section) consumes
§8–§9 without changing them.

---

## 14. Open questions (need a decision or the engine API)

| ID | Question | Blocks | Default assumed in this plan |
|---|---|---|---|
| Q1 | `docs/engine-api.md` does not exist yet. Does `OpenEngine` deliver messages as `(type, payloadJSON)`, and does native→page go through `window.__open.receive` exactly, or a named handler per area? | App adapter (future) | §8.4/§9.1 abstract bridge. `OpenBoosts` is insulated; only the future adapter changes. |
| Q2 | Is there a message-size limit or a preferred native CSS-injection API for large Boost CSS at `document_start`? | Large-CSS pages in production | Bridge carries text (§9.1). If limited, adapter prefers native CSS injection and the applier keeps SPA/shadow duties (§8.4). |
| Q3 | Does the engine re-run per-frame injection automatically for same-origin iframes? | Boosts inside iframes | Assumed yes per-frame (engine's job, §6.8). If not, Boosts skip iframe content in v1. |
| Q4 | Do Boosts apply in incognito, Peek, Little Arc, and Split View panes? Arc evidence is a guess (BO-10, BO-6 Q6). | Planner `context` use | Apply everywhere the adapter injects; `context` param exists (§8.2) so policy lands in one place. Product to confirm. |
| Q5 | Global Boosts preference storage (Settings toggle "Enable Boosts on websites you visit") — profile settings or app preference? `OpenModel` change needs its own plan. | Real app wiring | Planner takes a Bool (§4.4). Harness has a checkbox. Owner: Settings milestone. |
| Q6 | Exact editor entry for Zap (Site Control Center "Customize Page…" exists in Arc menus; Open's editor is a later milestone). Does any v1 surface besides the editor need `zap:enter`? | Zap reachability in the real app | Runtime supports bridge entry only. No menu/hotkey in this plan. Confirm no direct Zap shortcut is needed for M6 (Arc open question ZA-4). |
| Q7 | Hue-wheel → `ColorAdjustment` conversion for the simple editor (BO-3 wheel semantics unobserved). | Future editor | Runtime stores filter components (§3.4). Editor plan must define the conversion; runtime does not change. |
| Q8 | Text zoom / text transform components (BO-2 `BoostTextZoom`, `BoostTextTransform`) are in Arc's component list but not in this task's data scope (color + font only). Add `textZoom`/`textTransform` fields now or later? | Model completeness | Omitted. Adding them later is a defaulted-`Codable`-field change. Confirm the omission is acceptable for M6, or add two optional fields in Step 2 (`textZoom: Double?`, `textTransform: String?`) with matching CSS in §6.4 — decide before Step 2 starts. |

Decision discipline: Q8 must be answered before Step 2. Q1–Q3 unblock only the
future adapter, not this milestone. Q4–Q7 have defaults above; implement the
defaults and note the assumption in the PR.

---

## Appendix A — Identifier and string constants (single source)

| Constant | Value | Defined in |
|---|---|---|
| Bridge version | `1` (`"v": 1`) | §9.1 |
| Applier global | `window.__openBoosts`, `version: 1` | §6.2 |
| Picker global | `window.__openZap`, `version: 1` | §7.1 |
| Style element id | `open-boosts-style` | §6.3 |
| Zap preview style id | `open-zap-preview-style` | §7.4 |
| Overlay host id | `open-zap-overlay-host` | §7.2 |
| Harness boost id | `harness-boost` | §10.6 |
| Store directory | `<root>/Boosts/<profileID>.json` | §4.1 |
| Store schema | `schemaVersion: 1` | §4.1 |
| Picker temp expando | `__open_id` | §7.5 Step C |
| Zap hide declaration | `display: none !important` | §6.3 |
| Candidate caps | max matches 100, top 15, ancestors 8, descendants 2 | §7.5 |

## Appendix B — Glossary

- **Boost**: one per-site customization record (§3.3).
- **Zap**: one hide-rule (CSS selector) inside a Boost (§3.6). "To zap" = pick an
  element and store its selector.
- **Plan**: `InjectionPlan` — the matched, ordered, composed Boost set for one page
  load (§8.2). Sent to the page as `boost:apply`.
- **Harness**: the localhost HTML test rig (§10), driven with T3 preview tools.
  Not a unit test.


## Appendix C — Lead decisions (2026-10-25)

- **Q8: include now.** In Step 2 add `textZoom: Double?` (1.0 = default; CSS `zoom` on the root, clamp 0.5–2.0) and `textTransform: String?` (`"none" | "uppercase" | "lowercase" | "capitalize"`; CSS `text-transform` on `body`, excluding `input, textarea, [contenteditable]`). Add both to §6.4's generated CSS and to the harness checks. Both are optional, defaulted `Codable` fields.
- **Q1–Q3 (engine message shape, size limits, iframe injection):** build against the abstract bridge in §9 now. The engine wiring is a later, separate step owned by the engine team. Do not block on it.
- **Q4–Q7:** use the defaults listed in §14.
