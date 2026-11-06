# Routing (Air Traffic Control) + Little Open — implementation plan for Open

Status: plan for implementation. Implementer: follow this file top to bottom.
Amended 2026-10-26 for Arc capture session 2 (item 19): the Little Open window
now follows the captured frames, title bar, and reuse rule (§1 rows LA-S2-1…5,
§9.2, §9.3, §9.5, §12, Step 6a, §14 Q2, lead decisions). Evidence notation:
**S2 19/0011** = frame 0011 of `.re/runtime/sessions/20261026-103403-19-little-arc/`
(local only; the Space picker frames also show the user's own Space names, which
are never copied into the repo).
Do not read Arc code or copy Arc assets. Build from the behavior facts in this plan.
The implementer has no other context: every type, file, signature, algorithm, and
check you need is in this file. If a signature here conflicts with a real file in the
repo, stop and report the conflict; do not silently redesign.

Reference behavior sources (read them if a rule below seems unclear; this plan is
authoritative where it picks a default the RE docs leave as a guess):

- [features-core.md §6](../re/features-core.md) — Air Traffic Control model, Links pane.
- [features-core.md §3.3](../re/features-core.md) — auto-archive thresholds.
- [features-advanced.md §3](../re/features-advanced.md) — Little Arc behavior LA-1…LA-13.
- [data-model.md §2.7](../re/data-model.md) — `StorableLinkRouting.json` shape on disk.
- [interaction-states.md §18](../re/interaction-states.md) — Links pane rows as captured.
- [model.md](../model.md) — the live model today. [commands.md](../commands.md) — command ids.
- [architecture.md](../architecture.md) — module borders and performance budgets.

How to use this plan:

1. Work the steps in §13 in order. Do not skip ahead. Phase A (Steps 1–4) is
   OpenKit-only and is verifiable without the app. Phase B (Steps 5–7) needs the
   App target and the engine glue; do it only when the App target exists.
2. Each step lists exact files, exact signatures, and acceptance checks.
   A step is done only when its checks pass.
3. No unit tests (AGENTS.md rule 6). Verify end to end: `swift build`, the
   `openkit route` CLI (§11), `openkit roundtrip`, `commands-dump`, and — in
   Phase B — the real app driven by `open -a` and `osascript` (§12).
   Throwaway probes live in `/tmp`, never in the repo.
4. Naming: the user-visible name is **Little Open** everywhere. Never show
   "Little Arc" to the user. The one exception is the existing
   "Import from Arc" surface. Command ids are stable and never renamed
   (see §2.3); only their titles change.

---

## 0. Scope and non-scope

### 0.1 In scope (this plan)

| Area | Deliverable |
|---|---|
| Rename | `RoutingDestination.littleArc` → `.littleOpen` (and siblings in §3), with backward-compatible decoding. Old snapshot JSON keeps loading. |
| New library | `OpenRouting` target in `Packages/OpenKit`: rule evaluation, host normalization, destination resolution, decision log. Logic only. No AppKit windows. |
| CLI | `openkit route` (§11): loads a snapshot, prints the decision for a URL + optional source bundle id. This is the Phase A verification surface. |
| Settings data | `LinksSettingsModel` (§10): rule list editing, default destination, toggles, "test a URL". Data and view-model only. No visual design. |
| Phase B intake | http/https handler registration, "Set as default browser", URL receiving (two paths), source-app detection, handoff to `OpenRouting` (§8). |
| Phase B window | Little Open window, coordinator, "Open in Space", global hotkey wiring, auto-archive sweeper (§9). |

### 0.2 Out of scope (do not build)

- The visual design of the Links settings pane. An Opus designer does it later.
  This plan gives the designer a finished `@Observable` model to bind to (§10).
- Peek, Split View, Site Control Center. Routing destinations are only the
  three in the model today: a Space, the most recent Space, Little Open.
  Arc strings name more destinations ("Open %@ in Split View", "in a new tab",
  Peek — [features-core.md §6.1](../re/features-core.md) rule 2). Do not add
  them. The full Arc destination enum is unverified (LA open question 3).
- Meeting-link special handling ([features-core.md §6.2](../re/features-core.md)
  rule 7, Guess host list). Meet links route like any other link in v1.
- AppleScript creation of Little Open tabs (LA-5, AppleScript milestone M7).
  Note it as a future caller of `LittleOpenCoordinator.open(url:profileID:)`.
- Persisting Little Open sessions across quit in v1 (§9.7). Sessions are
  in-memory. `PersistedLittleBrowserState` exists in Arc; its shape is unknown.
- The downloads tray contents in Little Open (LA-10). Show the button disabled
  in v1; wire it when the downloads milestone lands.

### 0.3 Milestone fit

This plan is M4's "default-browser handling for Little Arc" plus M5's
"Air Traffic Control rules" from [plan.md](../plan.md). Phase A depends only on
M1 (`OpenKit` exists). Phase B depends on the App target and on the engine
assumptions in §7. Phase A must not block on either.

---

## 1. Locked facts from the behavior spec (do not re-derive)

| ID | Fact | Where it lands |
|---|---|---|
| ATC-1 | Routing state = ordered rule list + a default destination. Persisted in Arc as `StorableLinkRouting.json`. ([features-core.md §6.1](../re/features-core.md) rule 1) | Already in `BrowserModel.routingRules` / `defaultDestination`. `OpenRouting` evaluates them; it does not own persistence. |
| ATC-2 | First matching rule wins. ([features-core.md §6.1](../re/features-core.md) rule 4, Guess from ordered state + `addRule`; the strongest reading. Runtime-verify later, do not hedge in code.) | §5.4 |
| ATC-3 | Match kinds in the live model: `.hostContains`, `.hostEquals`, `.urlPrefix`. Importer maps Arc `contains` → `.hostContains`, `equals`/`exact` → `.hostEquals`, `prefix` → `.urlPrefix`. ([model.md](../model.md), [data-model.md §2.7](../re/data-model.md)) | §5.2, §5.3. Do not add match kinds. |
| ATC-4 | Destinations in the live model: `.space(SpaceID)`, `.mostRecentSpace`, `.littleArc` (renamed `.littleOpen` by this plan). ([model.md](../model.md)) | §3, §5.5 |
| ATC-5 | Source-app condition: RE shows a `sourceComponents` field and hints rules can consider the source app, but marks it **Guess** — "Do not ship source-app rules until verified." ([features-core.md §6.1](../re/features-core.md) rule 3). On disk, the only observed component is `urlMatch` ([data-model.md §2.7](../re/data-model.md), LA-12). | §4.3: carry the field, evaluate it, never import it, hide the picker. See the decision there. |
| ATC-6 | External-link decision order: (1) first matching rule, (2) default destination, (3) the default counts as Little Arc only when the "external links in Little Arc" toggle is on; otherwise the most recent main window. (LA-13) | §5.5 step R6 |
| ATC-7 | The observed Arc default destination on this Mac is Little Arc with a most-recent-Space context: `defaultDestination: { littleArc: { _0: { mostRecent: {} } } }`. ([data-model.md §2.7](../re/data-model.md), LA-12) | §5.5: a `.littleOpen` resolution carries the most recent Space's profile as a hint. |
| LA-1 | Little Arc is a small separate window, minimal chrome: compact toolbar, command-bar-style URL field, downloads tray, profile indicator. No sidebar, no Space switcher, no tab strip. One window shows one page. Autosave name `.littleWindowAutosaveFrame`, size key `LittleBrowserWindow_size`. | §9.3 |
| LA-2 | External links (Arc as default browser) open in Little Arc when the toggle is on and no rule routes elsewhere. Same link again resurfaces the existing window; do not duplicate. | §8, §9.2 dedupe |
| LA-3 | Global shortcut from anywhere opens a fresh Little Arc ready for search/URL. Default Cmd+Opt+N (high-confidence, not spelled out in strings). User can change or disable it. | §9.5. The wrapper already exists: `GlobalHotkeyService` in `OpenCommands`. |
| LA-4 | Opt+Cmd-click a link inside the browser opens it in Little Arc. Toggle-gated. | §9.5, Phase B, engine-gated |
| LA-6 | "Open in Arc" move control: menu of Spaces. Choosing one creates a real tab in that Space of the main window, selects it, closes the Little window. Guess: if the main window is closed, moving opens it. | §9.4. This plan adopts the guess. |
| LA-7 | One Profile per Little window, shown in the toolbar. Switching profile reloads with that profile's data; confirm unless bypassed. | §9.3 |
| LA-8 | Stale Little windows auto-archive after a threshold; the page is kept in the archive (Library filter "Little Arc"). Threshold options are the §3.3 list: Never, 1h, 6h, 12h, 24h, 7d, 30d. | §9.6 |
| LA-9 | First Little window shows a dismissible intro, a bounded number of times. | §9.3 (show once) |
| LA-11 | Only the external-link entry point needs default-browser status. The other entry points work regardless. Settings must say so next to the toggle. | §8.4, §10 |
| SET-1 | Links pane holds: external-links-in-Little-Arc toggle (Guess default ON), default destination (Guess Most Recent Space), the rule list, Peek toggles (out of scope here), Little Arc hotkey row, "Archive Little Arcs after" threshold. ([features-core.md §7.2 Links](../re/features-core.md), [interaction-states.md §18](../re/interaction-states.md)) | §10 |
| SET-2 | Captured Links pane shows "Archive Little Arcs after: 6 hours (default)" and Profiles shows "12 hours (default)" for Today tabs. ([interaction-states.md §18](../re/interaction-states.md)) | §3.4: Little Open default becomes 6h. Today stays 12h. Factory default is still an open question (§14 Q3); the "(default)" label in a captured shipping Settings UI is the best evidence available. |
| LA-S2-1 | First frame: ⌥⌘N opens a 490 × 329 window at the screen's top-right, 20 pt from the right edge and 20 pt below the menu bar (screen (2050, 50) on a 2560 × 1440 display with a 30 pt menu bar). It is a bare command bar: field `[53, 20, 380, 23]`, a close "x" `[443, 19, 26, 26]`, five 50 pt suggestion rows, no title bar. The size stays 490 × 329 while typing. ([interaction-states.md §20.10](../re/interaction-states.md); S2 19/0003–0010) | §9.3 |
| LA-S2-2 | After a page loads, the same window grows to 1185 × 832 at (1355, 50): it grows left and down and keeps its top-right corner. (S2 19/0011; `windows.tsv` window id unchanged) | §9.3 |
| LA-S2-3 | Each ⌥⌘N opens a **new** window at the same first frame (490 × 329 at (2050, 50)), on top of the earlier one; the earlier window had a loaded page. (S2 19/0029; notes 10:34:58) | §9.2, §9.5 |
| LA-S2-4 | Title bar, 47 pt: window buttons at `[9 / 32 / 55, 16, 16, 16]`; a URL capsule `[84, 8, W − 289, 31]` (right edge W − 205) that holds the Profile chip (AX `littleBrowserProfileIndicator`: 14 pt icon at x 97 + the Profile name at x 114), the host centered (`[497.5, 15.5, 129, 16]` at W 1185), and a copy-link button `[W − 228, 16, 16, 16]`; then a dark pill `[W − 196, 8, 188, 30]` with "Open in **\<Space\>** ⌘O" (AX button `[994, 15, 148, 17]`) and a chevron `[W − 29, 15, 16, 16]` (tooltip "More Spaces"). No back, forward, reload, or URL text field. The page fills `[0, 47, W, H − 47]` edge to edge. (S2 19/0011, 0025; pixel bounds of the capsule and pill measured on 0011) | §9.3 |
| LA-S2-5 | The chevron opens a dark popover (≈ 244 wide, at the window's top-right): a "Search Spaces…" field, then the Spaces with their icons on colored rounded squares, the current Space first and highlighted, rows 46 pt apart. (S2 19/0023) | §9.3, §9.4 |
| LA-S2-6 | On disk Arc anchors the window by its top-right corner: `style.little.session.preferredFrame = {anchor: {topRight: …}, size: …}`, `entryPoint: {externalLink: true}` also for ⌥⌘N, `shouldShowProfileIndicators: true`. The stored values (topRight (2544, 1394), size 500 × 300, AppKit points) match **neither** observed frame: the bar state's top-right is (2540, 1390) at 490 × 329, and the page state is 1185 × 832. That is one reason §14 Q2 stays open. ([interaction-states.md §20.10](../re/interaction-states.md); `appsupport/s2-little-arc-open/StorableWindows.json`) | §9.3 (frame model); import plan (window style) |

---

## 2. Package and file inventory

### 2.1 New target (the only build-system edit in Phase A)

Edit exactly one existing build file in Phase A:
[Package.swift](../../Packages/OpenKit/Package.swift).

Add one library product and one target. `OpenRouting` depends on `OpenModel`
**only** (for `SpaceID`, `ProfileID`, `WindowID`, `RoutingRule`,
`RoutingMatch`, `RoutingDestination`, `DefaultDestination`, `WindowStyle`).
Do not add dependencies on `OpenStore`, `OpenImport`, `OpenSuggest`, or
`OpenCommands`. Snapshot loading stays in callers; shortcut types stay in the
App layer. This keeps the evaluator usable from the CLI, the App, and a future
settings process without dragging stores or Carbon along.

```swift
// In products: add
.library(name: "OpenRouting", targets: ["OpenRouting"]),

// In targets: add
.target(name: "OpenRouting", dependencies: ["OpenModel"]),

// In the openkit executable target: add "OpenRouting" to dependencies.
```

That last change is Phase A Step 4 (§13). Steps 1–3 must build without it.

### 2.2 New files (create exactly these)

```text
Packages/OpenKit/Sources/OpenRouting/
  RoutingTypes.swift       §4   request, source, snapshot, resolved destination, decision
  HostNormalizer.swift     §5   host + URL canonicalization, match primitives
  RuleEvaluator.swift      §5   RoutingEvaluator: ordered evaluation + resolution
  DecisionLog.swift        §6   RoutingDecisionLog ring buffer + logger protocol
  DecisionFormatter.swift  §6   one-line and multi-line human descriptions
  LinksSettingsModel.swift §10  Links pane data / view-model (no views)

Packages/OpenKit/Sources/openkit/
  RouteCLI.swift           §11  `openkit route` (new file; wire in main.swift)
```

Phase B new files (App target; create only when the App target exists, §13 Step 5):

```text
App/Info.plist                                  §8.2 (edit if it already exists)
App/ExternalLink/ExternalLinkIntake.swift       §8.5
App/ExternalLink/DefaultBrowserService.swift    §8.4
App/ExternalLink/SourceAppResolver.swift        §8.6
App/LittleOpen/LittleOpenWebContent.swift       §7 (engine adapter only)
```

2026-10-26 (review r1, F7): `LittleOpenSession`, `LittleOpenCoordinator`, and
`LittleOpenWindowController` live in `OpenFeatures/` (the M4 plan's Step 6
built them there: `Packages/OpenKit/Sources/OpenFeatures/LittleOpen*.swift`).
Do not create App copies. Only the engine adapter stays in the App target.
The registry ids are `new-little-open-window` and `little-open-global`
(`OpenCommands/CommandRegistry.swift`); §2.3 and §3.5 keep the pre-rename
names for history.

If the App target already has an `AppDelegate` (or equivalent), edit it in
place for §8.3 and §9.5 instead of creating a parallel delegate. Never create
a second `NSApplication` delegate.

### 2.3 Naming rules

- User-visible text: "Little Open" only. This includes menu titles, settings
  labels, window titles, toasts, and the decision formatter's output.
- New Swift identifiers: `LittleOpen` / `littleOpen`. New persisted JSON keys:
  `littleOpen`. New UserDefaults keys: prefix `open.links.` (§10.4).
- Command **ids never change** ([commands.md](../commands.md): "a stable `id`
  (never rename a shipped id)"). These ids keep their Arc-derived spelling
  forever; they are not user-visible:
  `new-little-arc-window`, `little-arc-global`, `open-in-current-space`,
  `set-default-browser`, `air-traffic-control`.
  Only their `title` fields change (§3.5).
- The string `"littleArc"` may survive in exactly three places after this plan:
  (a) legacy-decode branches in §3.2, (b) the Arc importer reading Arc's own
  JSON keys in `OpenImport` (Arc's format, not ours), (c) comments that cite
  an Arc fact. Acceptance check in Step 1 enforces this.
- Bundle id: this plan writes `app.open` where a bundle id is needed. If the
  App target already defines a different bundle id, keep the existing one and
  substitute it in every command in §12. Do not change a shipped bundle id to
  match this plan.

### 2.4 Files the implementer must read before coding (already in repo)

| File | Why |
|---|---|
| `Packages/OpenKit/Sources/OpenModel/Containers.swift` | The routing enums and `ProfileSettings` you rename in §3. Lines 104–131 today. |
| `Packages/OpenKit/Sources/OpenStore/SnapshotDTOs.swift` | The persisted DTO twins of those enums. Lines 100–125 and the mapper at 243–289. |
| `Packages/OpenKit/Sources/OpenModel/Identifiers.swift` | `Identifier<Tag>` shape. Reuse `SpaceID` etc.; never copy them. |
| `Packages/OpenKit/Sources/OpenModel/BrowserModel.swift` | `newTab(in:url:title:at:)` (line 473), `focusSpace(windowID:spaceID:)` (line 1118), `routingRules`, `defaultDestination`. Phase B calls these; Phase A never edits this file except through `Containers.swift` types it references. |
| `Packages/OpenKit/Sources/OpenCommands/GlobalHotkey.swift` | `GlobalHotkeyService.register(shortcut:action:)` / `unregister()`. Phase B wiring only. |
| `Packages/OpenKit/Sources/openkit/SuggestCLI.swift` | The argument-parsing and snapshot-loading style `RouteCLI.swift` must mirror. |

---

## 3. Step 1 — Rename `.littleArc` to `.littleOpen` with compatible decoding

Do this step first, before `OpenRouting` exists. It touches four existing
files. Nothing else in this step.

### 3.1 What renames, and what deliberately does not

| Today | After this step | Notes |
|---|---|---|
| `RoutingDestination.littleArc` | `RoutingDestination.littleOpen` | In `OpenModel/Containers.swift`. |
| `DefaultDestination.littleArc` | `DefaultDestination.littleOpen` | Same file. |
| `RoutingDestinationDTO.littleArc` | `RoutingDestinationDTO.littleOpen` | In `OpenStore/SnapshotDTOs.swift`. |
| `DefaultDestinationDTO.littleArc` | `DefaultDestinationDTO.littleOpen` | Same file. |
| `WindowStyle.littleArc` | `WindowStyle.littleOpen` | Raw value also changes; §3.3. |
| `ProfileSettings.littleArcAutoArchiveAfter` | `ProfileSettings.littleOpenAutoArchiveAfter` | Persisted key compat in §3.4. |
| `ProfileSettingsDTO.littleArcAutoArchiveAfter` | `ProfileSettingsDTO.littleOpenAutoArchiveAfter` | DTO stored property renames; its JSON key compat in §3.4. |
| Arc importer output `.littleArc` | `.littleOpen` | `OpenImport/ArcImport.swift` returns our model types, so it follows. Its Arc-side string keys (`"littleArc"` in Arc's JSON) do **not** change. |
| `StorableLinkRouting.json` handling | Unchanged | That is Arc's file name and Arc's keys. Import only. |
| Command ids | Unchanged | §2.3. |
| Snapshot `schemaVersion` | Stays `1` | Same precedent as `mostRecentSpace` ([model.md](../model.md)): enum decoding needs only the cases in the payload — but only because §3.2 makes decode accept both spellings. Do not bump the version. |

### 3.2 Compatible decoding for the four routing enums

Swift's synthesized `Codable` for enums with associated values encodes
`.littleOpen` as `{"littleOpen":{}}` and `.space(id)` as `{"space":{"_0":…}}`.
After the rename, synthesized decoding rejects every existing file. Give each
of the four enums (`RoutingDestination`, `DefaultDestination`,
`RoutingDestinationDTO`, `DefaultDestinationDTO`) a custom
`init(from:)` / `encode(to:)` pair. Implement exactly this shape
(shown for `RoutingDestination`; the other three are identical except the
`.space` payload type — `SpaceID` in the live enums, `String` in the DTOs):

```swift
public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: RoutingDestinationCodingKey.self)
    guard let key = container.allKeys.first, container.allKeys.count == 1 else {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath,
                                  debugDescription: "RoutingDestination: expected one key"))
    }
    switch key.stringValue {
    case "space":
        let nested = try container.nestedContainer(
            keyedBy: RoutingDestinationSpaceKey.self, forKey: key)
        self = .space(try nested.decode(SpaceID.self, forKey: .value))
    case "littleOpen", "littleArc":   // "littleArc" = files written before the rename
        self = .littleOpen
    case "mostRecentSpace":
        self = .mostRecentSpace
    default:
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath,
                                  debugDescription: "RoutingDestination: unknown key \(key.stringValue)"))
    }
}
```

Rules for all four implementations:

- Define the two helper `CodingKey` enums once per enum, `private`, in the
  same file as the enum. `RoutingDestinationCodingKey` needs cases
  `space`, `littleOpen`, `mostRecentSpace` with `stringValue` passthrough;
  because decode accepts a legacy spelling, decode `allKeys.first.stringValue`
  as a `String` (as above) instead of switching on the typed key. Encode
  switches on `self` and writes exactly one key: `space`, `littleOpen`, or
  `mostRecentSpace`. Never encode `littleArc`.
- `DefaultDestination` has no `mostRecentSpace` *case name collision problem*:
  it has `.mostRecentSpace`, `.littleOpen`, `.space(SpaceID)`. Same code.
- DTOs: identical, with `String` in place of `SpaceID`.
- Keep the enums' `Hashable, Sendable` conformances. Custom `Codable` does not
  affect them.
- Unknown keys must throw (as above). Do not silently map an unknown
  destination to `.mostRecentSpace`: a future Arc or Open destination the
  reader does not know must fail loudly in the CLI, not mis-route links.
  (The Arc *importer* keeps its own lenient parse; that is a different file
  and a different contract. Do not "align" them.)

### 3.3 `WindowStyle`

`WindowStyle` is a `String`-raw enum persisted through `WindowDTO.style`
(a plain `String`). Change the case to `littleOpen` with raw value
`"littleOpen"`. Then fix the one decode site,
`SnapshotMapper.window(from:)` in `SnapshotDTOs.swift`, to accept the legacy
raw value:

```swift
style: WindowStyle(rawValue: dto.style)
    ?? (dto.style == "littleArc" ? .littleOpen : .standard),
```

Do not put a compatibility shim inside `WindowStyle` itself; `rawValue`
lookups elsewhere (the importer maps Arc's `"littleArc"` style key at
`ArcImport.swift` today) must see only the new spelling. Update the importer
site to assign `.littleOpen`.

### 3.4 `ProfileSettings` and its DTO

Rename the stored property in both `ProfileSettings` (live, `Codable`) and
`ProfileSettingsDTO`. Both persist under a key with the property's name, so
both need a custom decode that tries the new key, then the legacy key, then
the default. Implement with explicit `CodingKeys`:

```swift
// In ProfileSettings (Containers.swift) and ProfileSettingsDTO (SnapshotDTOs.swift),
// with the type's own other keys unchanged:
private enum CodingKeys: String, CodingKey {
    case autoArchiveAfter
    case littleOpenAutoArchiveAfter
    case littleArcAutoArchiveAfter   // legacy, decode-only
    case searchEngineID
}
```

Decode `littleOpenAutoArchiveAfter` as
`try container.decodeIfPresent(…​.self, forKey: .littleOpenAutoArchiveAfter)
?? container.decodeIfPresent(…​.self, forKey: .littleArcAutoArchiveAfter)
?? .sixHours`.
Encode only `.littleOpenAutoArchiveAfter`. Where the type uses synthesized
coding today, write the full custom `init(from:)` / `encode(to:)` for that
type; do not change any other field's encoding.

Two defaults change in this step, both deliberate:

- `ProfileSettings.init` default for the renamed property: `.twelveHours`
  today → **`.sixHours`** (SET-2). Existing files store the value explicitly,
  so only fresh profiles see the change.
- The decode fallback above is also `.sixHours`, so a hand-trimmed file with
  neither key behaves like a fresh profile.

Leave `autoArchiveAfter` (Today tabs) at `.twelveHours`. Do not touch it.

### 3.5 Command titles (user-visible rename only)

In `Packages/OpenKit/Sources/OpenCommands/CommandRegistry.swift`, change
only `title` strings. Ids, shortcuts, scopes, menu paths stay byte-identical:

| id | New title |
|---|---|
| `new-little-arc-window` | `New Little Open Window` |
| `little-arc-global` | `Show Little Open (Global)` |
| `open-in-current-space` | `Open Little Open or Peek in…` |

`commands-dump` compares the built menu against
`Sources/OpenCommands/Resources/expected-menu.json` (extracted from Arc).
After this change it will report these three titles as different. That is
expected and correct: the expected file describes Arc, and Open's brand
differs on purpose. Handle it in `ExpectedMenu.swift`: add an explicit
allowlist of `(id, arcTitle, openTitle)` triples for exactly these three ids,
treated as matching. Any other title difference still fails. Do not edit
`expected-menu.json`; it is RE evidence.

### 3.6 Step 1 acceptance checks

Run from `Packages/OpenKit`:

```bash
nice -n 10 swift build -c release -j 6        # zero warnings, zero errors
swift run openkit roundtrip <DIR>             # on a snapshot written BEFORE this change: prints "roundtrip OK"
swift run openkit dump <DIR>                  # same pre-change snapshot loads; routing lines print
swift run commands-dump                       # exit 0; the only title diffs are the three in §3.5
grep -rn "Little Arc" Packages/OpenKit/Sources --include="*.swift" | grep -v OpenImport
# → no output. ("Import from Arc" and Arc-format comments are the only survivors;
#    OpenImport may keep Arc key strings per §2.3.)
```

The pre-change snapshot is the point of the first two checks: if no old
snapshot exists on this Mac, create one first by checking out the tree before
this step into `/tmp`, building `openkit` there, and running
`openkit commands-demo /tmp/routing-old-snapshot`. Keep that folder for
Step 4. This is an end-to-end decode check on a real file, not a unit test.

---

## 4. `OpenRouting` value types — `RoutingTypes.swift`

Create `Packages/OpenKit/Sources/OpenRouting/RoutingTypes.swift`.
Swift 6, strict concurrency. `import Foundation` and `import OpenModel` only.
No AppKit, no Carbon, no `OpenStore`. Every type here is a value type,
`Sendable`. Nothing in this file touches `BrowserModel` (it is `@MainActor`);
callers copy the values the evaluator needs into `RoutingSnapshot` (§4.3).

### 4.1 The request

```swift
/// Where a link came from, as far as the OS told us. §8.6 produces this.
public struct RoutingSource: Hashable, Sendable {
    /// Bundle id of the sending app, lowercased at creation. Nil when unknown.
    public var bundleID: String?
    /// Sender PID from the AppleEvent. Nil on the `application(_:open:)` path.
    public var pid: Int32?
    /// Display name for logs and the decision formatter. Never used for matching.
    public var displayName: String?

    public init(bundleID: String? = nil, pid: Int32? = nil, displayName: String? = nil)
    /// True when a source-app rule could ever match this source.
    public var isKnown: Bool { bundleID != nil }
    public static let unknown = RoutingSource()
}

/// One link to route. Built by the intake layer (§8) or the CLI (§11).
public struct RoutingRequest: Hashable, Sendable {
    public var url: URL
    public var source: RoutingSource
    /// When the link arrived. Injected so evaluation is deterministic in the CLI.
    public var receivedAt: Date

    public init(url: URL, source: RoutingSource = .unknown, receivedAt: Date = Date())
}
```

### 4.2 The source-app condition on rules (carried, not imported)

ATC-5 decision, implemented exactly like this:

- Add one stored property to `RoutingRule` in `OpenModel/Containers.swift`:
  `public var sourceBundleID: String?`, with `init` parameter
  `sourceBundleID: String? = nil` appended **last** so every existing call
  site compiles unchanged. Add the same optional property to
  `RoutingRuleDTO` in `SnapshotDTOs.swift` and map it in both directions in
  `SnapshotMapper` (`nil` stays `nil`; never write an empty string — the
  mapper normalizes `""` to `nil`).
- Compatibility: `RoutingRule` and `RoutingRuleDTO` use synthesized `Codable`
  today. A new optional stored property decodes old payloads that lack the
  key as `nil` (synthesized decoding uses `decodeIfPresent` for optionals).
  Verify this in Step 1's roundtrip check by keeping the pre-change snapshot:
  it has rules without the key. Do not write custom `Codable` for the rule
  structs; §3.2's custom code is only for the destination enums they contain.
- Normalization: wherever a `sourceBundleID` is set (settings save, evaluator
  entry), store and compare it trimmed and lowercased. Bundle ids are
  case-insensitive in practice; pick lowercase as the canonical form and say
  so in a comment.
- The Arc importer does **not** populate it. Arc's observed component is only
  `urlMatch` ([data-model.md §2.7](../re/data-model.md)). The importer already
  counts a rule as skipped when no component imports; keep that. Do not guess
  Arc's source-component key spellings.
- The settings view-model (§10) carries the field as data. The future visual
  designer decides whether to show a source-app picker; until a runtime check
  in Arc proves the picker exists, the data ships and the picker does not.
  This is the "reserve the capability, do not claim parity" reading of ATC-5.

### 4.3 Snapshot inputs (what the evaluator is allowed to see)

```swift
public struct RoutingSpaceSnapshot: Hashable, Sendable {
    public var id: SpaceID
    public var title: String
    public var profileID: ProfileID
    public init(id: SpaceID, title: String, profileID: ProfileID)
}

public enum RoutingWindowKind: Hashable, Sendable { case standard, littleOpen }

public struct RoutingWindowSnapshot: Hashable, Sendable {
    public var id: WindowID
    public var kind: RoutingWindowKind
    /// The Space this window currently shows. Ignored unless kind == .standard.
    public var focusedSpaceID: SpaceID
    public init(id: WindowID, kind: RoutingWindowKind, focusedSpaceID: SpaceID)
}

/// Everything evaluation needs, copied out of the live model by the caller.
/// `windows` order is frontmost-first AS SUPPLIED BY THE CALLER (§5.5 R3).
public struct RoutingSnapshot: Sendable {
    public var spaces: [RoutingSpaceSnapshot]          // sidebar order
    public var windows: [RoutingWindowSnapshot]        // frontmost first
    public var rules: [RoutingRule]                    // ordered; first match wins
    public var defaultDestination: DefaultDestination
    /// Arc's "Links from other apps open in Little Arc" toggle (ATC-6).
    public var externalLinksInLittleOpen: Bool

    public init(spaces: [RoutingSpaceSnapshot], windows: [RoutingWindowSnapshot],
                rules: [RoutingRule], defaultDestination: DefaultDestination,
                externalLinksInLittleOpen: Bool)
}
```

Caller contract (write it in the doc comment, implement it in §8/§11):

- The App builds `windows` from `NSApp.windows` in front-to-back order,
  filtered to windows it manages, mapping `WindowStyle.littleOpen` to
  `.littleOpen`. `BrowserModel.windows` array order is **not** z-order;
  never pass it through unexamined.
- The CLI has no z-order. It passes `BrowserModel.windows` with standard
  windows first, in stored order, and documents that the first standard
  window stands in for the frontmost one. `--most-recent` (§11) overrides.
- `spaces` with a duplicate id: callers must not produce them. The evaluator
  treats the first occurrence as canonical and ignores later ones (§5.5).

### 4.4 The answer

```swift
/// Why the evaluator chose what it chose. Printed by the CLI, shown by the
/// settings test field, written to the decision log. Never user-marketing text.
public enum RoutingVia: Hashable, Sendable {
    case rule(index: Int, id: RuleID)        // 0-based index into snapshot.rules
    case defaultDestination
    /// The chosen destination named a Space that no longer exists.
    case fallbackMissingSpace(requested: SpaceID)
    /// defaultDestination was .littleOpen but the external-links toggle is off (ATC-6).
    case defaultSuppressedByToggle
    /// No Spaces exist at all. The caller must bootstrap one and retry (§5.6).
    case noSpaces
    /// The URL is not http/https. The caller drops the link.
    case rejectedNonHTTP(scheme: String?)
}

/// The resolved, executable destination. This is what Phase B acts on.
public enum ResolvedDestination: Hashable, Sendable {
    /// Open a Today tab in this Space. `profileID` is that Space's profile.
    case space(spaceID: SpaceID, profileID: ProfileID)
    /// Open (or resurface) a Little Open window. `profileHint` is the profile
    /// of the most recent Space (ATC-7); nil only when there are no Spaces.
    case littleOpen(profileHint: ProfileID?)
}

/// One rule considered during evaluation, for the log and the test field.
public struct RuleTrace: Hashable, Sendable {
    public var index: Int
    public var ruleID: RuleID
    public enum Outcome: Hashable, Sendable {
        case matched
        case hostMismatch
        case sourceMismatch          // rule names a source app; request source differs
        case sourceUnknown           // rule names a source app; request source is unknown
        case targetSpaceMissing      // matched on URL+source, destination Space is gone
    }
    public var outcome: Outcome
}

/// The full result of one evaluation. `Codable` so the CLI can print JSON (§11).
public struct RoutingDecision: Sendable {
    public var request: RoutingRequest
    /// Normalized host of the request URL, when it has one (§5.1).
    public var normalizedHost: String?
    public var traces: [RuleTrace]           // one per rule, in order, stops after a match
    public var via: RoutingVia
    public var resolved: ResolvedDestination? // nil exactly when via is .noSpaces or .rejectedNonHTTP
    public var evaluatedAt: Date
}
```

Give `RoutingDecision`, `RuleTrace`, `RoutingVia`, `ResolvedDestination`,
`RoutingRequest`, and `RoutingSource` `Codable` conformance as well
(`Hashable` alone is not enough for `--json` in §11). `RoutingSnapshot` is
input-only: `Sendable` only, no `Codable`.

Failure model: evaluation never throws. Every outcome — including a bad URL
and an empty Space list — is a `RoutingDecision` with a `via` that explains
it. Callers switch on `via`; there is no error channel to forget.

---

## 5. Matching and evaluation — `HostNormalizer.swift`, `RuleEvaluator.swift`

### 5.1 Host normalization (implement exactly)

Create `Packages/OpenKit/Sources/OpenRouting/HostNormalizer.swift`:

```swift
public enum HostNormalizer {
    /// Canonical host for equality/containment, or nil when there is none.
    public static func canonicalHost(_ raw: String?) -> String?
    /// Canonical host of a URL (nil for about:, file:, hostless URLs).
    public static func canonicalHost(of url: URL) -> String?
    /// Canonical form of a stored match pattern (§5.2).
    public static func canonicalPattern(_ raw: String) -> String
    /// Canonical URL string for prefix matching (§5.2).
    public static func canonicalURLString(_ url: URL) -> String
    public static func canonicalPrefixPattern(_ raw: String) -> String
}
```

`canonicalHost` algorithm, in order. Apply the same steps to URL hosts and
to stored patterns (a pattern may arrive as a bare host, a host with a port,
or accidentally as a full URL — the settings UI validates, the evaluator
must still not crash):

1. Nil or empty after trimming whitespace → nil.
2. If the string contains `://`, parse it with `URLComponents` and take
   `.host`. Else if it contains `/`, `?`, or `#`, take the substring before
   the first such character (patterns only; URL hosts never contain them).
3. Lowercase the whole string. (Hosts are case-insensitive; `URL.host()`
   already lowercases, stored patterns do not.)
4. Strip one trailing dot (`example.com.` → `example.com`). Repeat until no
   trailing dot remains. An all-dots result → nil.
5. Strip a `:port` suffix: if the string contains `:` and everything after
   the last `:` is digits, drop both. (IPv6 literals keep their brackets;
   routing rules against IPv6 literals are out of scope — they simply never
   match a pattern a user would type. Do not add IPv6 pattern support.)
6. Strip exactly one leading `www.` label, if present
   (`www.example.com` → `example.com`; `www.www.example.com` →
   `www.example.com`). This is the www-equivalence rule: `www.` is treated
   as presentation, not identity. It applies to **both** sides of every host
   comparison, so it can never make two different registrable domains equal —
   it only removes one leading `www.` label from each.
7. Strip one leading `*.` if present (a user pasting a wildcard pattern gets
   the plain host). Strip leading/trailing dots left by any step above.

No IDNA/punycode transform of your own: `URL` already yields punycode hosts
for http/https URLs, and patterns are compared against that form. A pattern
typed in Unicode will not match its punycode host; note this in §14 Q5
rather than adding an IDNA dependency.

`canonicalURLString` (for prefix matching only — deliberately different from
the host form because a prefix is a literal string claim):

1. Parse with `URLComponents`. Lowercase scheme and host.
2. Host: lowercase, strip trailing dots, strip the default port
   (`:80` for http, `:443` for https). Keep `www.` — a prefix pattern means
   exactly what it says. Keep a non-default port as `:port`.
3. Reassemble as `scheme://host[:port]path?query`. Path and query verbatim
   (case-sensitive). Drop the fragment. Empty path becomes `/`.
4. If parsing fails, fall back to the URL's `absoluteString` lowercased only
   in its scheme-and-host prefix — in practice, return `absoluteString` and
   let the prefix test fail naturally. Never trap.

`canonicalPrefixPattern`: if the pattern contains `://`, run it through the
same `canonicalURLString` steps (parse it as a URL first). If it has no
scheme, treat it as `host[/path…]`: canonicalize the host part with the
prefix rules above (no www-stripping) and keep the rest verbatim; compare
against the request's canonical string with its scheme removed. State the
choice in code: scheme-less patterns match both http and https. That matches
how users write rules ("meet.google.com/room" should not care about scheme).

### 5.2 What each match kind means

Stored patterns stay as the user typed them (trimmed). All comparison uses
the canonical forms from §5.1. `H` = canonical host of the request URL,
`P` = canonical pattern. If `H` is nil, no host rule matches.

| Kind | Test | Matches | Does not match |
|---|---|---|---|
| `.hostEquals(P)` | `H == P` (both www-stripped) | `example.com` ↔ `www.example.com`, any path, any port | `sub.example.com`, `example.com.evil.test` |
| `.hostContains(P)` | `H.contains(P)` (both www-stripped) | pattern `google.com` matches `mail.google.com`; pattern `meet.google.com` matches `meet.google.com` | pattern `example.com` does **not** match `notexample.com`? — it does: `contains` is a substring test, and `notexample.com` contains `example.com`. This is Arc's `contains` semantics as imported; the settings test field (§10) exists so users see it. Do not "fix" it into a suffix test: imported Arc rules rely on the literal meaning. Document the surprise in the settings model (§10.3 validation warning), not in the matcher. |
| `.urlPrefix(P)` | canonical URL string `hasPrefix` canonical pattern (§5.1) | `https://example.com/docs` matches `…/docs`, `…/docs/a`, `…/docs?x=1` | `…/docsify` — it **does** match, because prefix is literal. Same rule as hosts: literal, visible in the test field, not silently "improved". |

Empty pattern (after trimming) never matches any kind. A rule with an empty
pattern is a settings-validation error (§10.3); the evaluator treats it as
`.hostMismatch` and moves on, so a corrupt snapshot cannot route everything
to one Space.

### 5.3 Source condition (checked before the host test)

For each rule, in this order:

1. If `rule.sourceBundleID` is non-nil (normalized: trimmed, lowercased):
   - request source bundle id nil → trace `.sourceUnknown`, rule does not match.
   - request source bundle id (lowercased) ≠ rule's → `.sourceMismatch`, no match.
   - equal → continue to the host test.
2. If `rule.sourceBundleID` is nil, the source never blocks the rule.

Rationale for checking source first: the trace then tells the truth
("this rule was never about your URL") and short rules stay cheap. Either
order gives the same match result; this order gives the better log.

### 5.4 Evaluation algorithm — `RoutingEvaluator`

Create `Packages/OpenKit/Sources/OpenRouting/RuleEvaluator.swift`:

```swift
public struct RoutingEvaluator: Sendable {
    public var logger: (any RoutingLogging)?
    public init(logger: (any RoutingLogging)? = nil) { self.logger = logger }

    public func evaluate(_ request: RoutingRequest, in snapshot: RoutingSnapshot) -> RoutingDecision
}
```

`evaluate` steps. No step throws. The function is pure except for the one
`logger?.record(decision)` call at the end.

- **R1. Scheme gate.** If `request.url.scheme` lowercased is not `http` or
  `https` (including a nil scheme): return a decision with
  `via = .rejectedNonHTTP(scheme:)`, `resolved = nil`, empty traces.
  The intake layer (§8) only ever builds http/https requests, so this gate
  protects the CLI and future callers.
- **R2. Canonicalize.** `H = HostNormalizer.canonicalHost(of: request.url)`.
  An http/https URL should always have a host; if it does not, continue with
  `H = nil` (host rules will miss, prefix rules may still hit).
- **R3. Most-recent Space.** Compute `mostRecent` once (§5.5). Keep it for
  resolution even if no rule needs it.
- **R4. Ordered scan.** For each rule at index `i` in `snapshot.rules`:
  apply §5.3, then the §5.2 host/prefix test. Record a `RuleTrace` for every
  rule considered. On the first rule that matches both: stop scanning
  (traces end there — later rules are not "considered") and resolve its
  destination (§5.5). Exception: a rule that matches on URL+source but whose
  `.space` destination names a missing Space records `.targetSpaceMissing`
  and scanning **continues** to the next rule. A stale rule must not swallow
  the link, and must not win just to fall back (§5.5 R7 explains the via).
- **R5. No rule resolved.** Resolve `snapshot.defaultDestination` (§5.5),
  with the ATC-6 toggle rule.
- **R6. Build and log.** Fill `RoutingDecision` (`evaluatedAt = request.receivedAt`
  — use the request's clock, not `Date()`, so CLI output is stable), call
  `logger?.record(decision)`, return it.

### 5.5 Resolution (destination → executable target)

Helper, private to `RuleEvaluator.swift`:

```swift
private func space(_ id: SpaceID, in snapshot: RoutingSnapshot) -> RoutingSpaceSnapshot?
// First occurrence wins on duplicate ids (§4.3).
private func mostRecentSpace(in snapshot: RoutingSnapshot) -> RoutingSpaceSnapshot?
```

`mostRecentSpace` algorithm (**R-MR**):

1. Consider only snapshot windows with `kind == .standard`, in supplied
   (frontmost-first) order.
2. Return the first window's `focusedSpaceID` resolved through `space(_:)`,
   skipping windows whose Space no longer exists.
3. If no window yields a Space, return `snapshot.spaces.first`.
4. If `snapshot.spaces` is empty, return nil.

Resolve a `RoutingDestination` (**R-D**):

| Destination | Result |
|---|---|
| `.space(id)`, Space exists | `.space(spaceID: id, profileID: that Space's profileID)` |
| `.space(id)`, Space missing | No result. The scan/fallback logic (R4/R7) handles it. |
| `.mostRecentSpace` | `.space(mostRecent…)` ; nil only when there are no Spaces. |
| `.littleOpen` | `.littleOpen(profileHint: mostRecent?.profileID)` |

Resolve the default (**R7**), in order:

1. If a rule matched but its Space was missing, remember
   `requestedMissing: SpaceID`. It decides the `via`, not the target.
2. `defaultDestination == .space(id)` with the Space present →
   that Space. With it missing → the most-recent Space, and if
   `requestedMissing` is also set, the first missing id wins the `via`.
3. `defaultDestination == .mostRecentSpace` → the most-recent Space.
4. `defaultDestination == .littleOpen`:
   - toggle on → `.littleOpen(profileHint: mostRecent?.profileID)`,
     `via = .defaultDestination` (or `.fallbackMissingSpace` if step 1 set it).
   - toggle **off** (ATC-6) → the most-recent Space,
     `via = .defaultSuppressedByToggle` (or `.fallbackMissingSpace`).
5. `via` when a rule resolved cleanly is `.rule(index:id:)`; when the default
   resolved with nothing missing, `.defaultDestination`.
6. If every path needs a Space and there are none: `resolved = nil`,
   `via = .noSpaces` — unless the resolved target is `.littleOpen`, which
   needs no Space (`profileHint = nil`) and still resolves. Read that again:
   with zero Spaces and a Little Open default (toggle on), the link still
   opens. With zero Spaces and any Space default, the caller bootstraps (§5.6).

### 5.6 Caller obligations for the two nil-result cases

- `.noSpaces`: the App creates the first Space (title `Space 1`, default
  profile) through the normal `BrowserModel` bootstrap it already uses on
  first run, rebuilds the snapshot, and evaluates **once** more. A second
  `.noSpaces` is a bug: log it and open Little Open with a nil hint rather
  than looping. The CLI prints the decision and exits 0 — it never creates
  Spaces in a snapshot it was only asked to inspect.
- `.rejectedNonHTTP`: drop the link. Log via the decision. Never hand a
  non-http(s) URL to the engine from the routing path.

### 5.7 Performance

Evaluation is O(rules) with O(1) canonicalization per rule pattern; patterns
canonicalize on every call (no cache) in v1. Budget: 100 rules against one
URL must stay under 1 ms on an M-series Mac — trivially true for string work
this small; do not add a pattern cache until a profile shows a need.
`evaluate` allocates the trace array only; it must not touch the file system,
the network, or `BrowserModel`.

---

## 6. Decision log and formatter — `DecisionLog.swift`, `DecisionFormatter.swift`

Routing bugs present as "my link opened in the wrong place" with no other
symptom. The decision log is the debugging surface for that report. It is
part of the deliverable, not a debug extra.

### 6.1 Types

Create `Packages/OpenKit/Sources/OpenRouting/DecisionLog.swift`:

```swift
/// Sink the evaluator writes to. The App adapts this to os.Logger plus the
/// in-memory log below; the CLI passes nil and prints the return value.
public protocol RoutingLogging: Sendable {
    func record(_ decision: RoutingDecision)
}

/// Bounded in-memory history of recent decisions. Newest last.
public final class RoutingDecisionLog: RoutingLogging, @unchecked Sendable {
    public static let capacity = 200
    public init()
    public func record(_ decision: RoutingDecision)   // appends; drops oldest past capacity
    public func snapshot() -> [RoutingDecision]       // copy, oldest first
    public func clear()
}
```

Implement `RoutingDecisionLog` with an `NSLock` and a plain array
(append, and `removeFirst` when over capacity — 200 elements makes the
O(n) shift irrelevant; do not build a ring-buffer index scheme). All public
methods are safe from any thread. The evaluator may run on the main actor in
the App and off it in the CLI; the log must not assume either.

What gets logged is the whole `RoutingDecision`: request (URL, source),
normalized host, every trace, the via, the resolved target, and the time.
Do not log page titles, cookies, or anything fetched from the page — the log
holds URLs the user clicked, which is exactly the sensitivity level of a
history entry. State that in the type comment. The log is never persisted
to disk in v1 and never leaves memory. (Persisting it is a future debugging
feature and needs a privacy decision first; §14 Q6.)

### 6.2 Formatter

Create `Packages/OpenKit/Sources/OpenRouting/DecisionFormatter.swift`:

```swift
public enum RoutingDecisionFormatter {
    /// One line, for log files and the settings test result summary.
    /// Example: "https://meet.google.com/abc → Space “Work” via rule #1 (hostEquals)"
    public static func oneLine(_ decision: RoutingDecision,
                               spaceTitles: [SpaceID: String]) -> String
    /// Multi-line, for `openkit route` (§11): url, host, source, one line per
    /// trace, final decision, via. Exact layout is specified in §11.3.
    public static func report(_ decision: RoutingDecision,
                              spaces: [RoutingSpaceSnapshot]) -> String
}
```

Rules:

- Space names come from the caller (`spaceTitles` / `spaces`); the formatter
  never invents a name. An unknown Space id prints as
  `Space <first 8 chars of the UUID>`.
- A Little Open result prints as `Little Open`.
- The via prints in plain words: `via rule #2`, `via default destination`,
  `via default (Little Open off → most recent Space)`,
  `via fallback (rule's Space is gone)`, `no Spaces`, `rejected (not http/https)`.
  Rule indices in human output are **1-based** (`#1` is `rules[0]`); the
  `via` enum stores 0-based. Convert in the formatter only.
- The formatter is also the settings test field's output (§10.5). One
  formatter, three callers (log, CLI, settings). Do not fork its strings.

---

## 7. Engine assumptions (the glue contract)

`docs/engine-api.md` is being written by another agent and may not exist yet.
Phase A needs nothing from the engine. Phase B needs exactly the surface
below. Design against this list; when the real `OpenEngine` API lands, write
one adapter file (`App/LittleOpen/LittleOpenWebContent.swift`) that conforms
the real engine object to `LittleOpenWebContentProviding`. Do not redesign
`OpenRouting`, the coordinator, or the window controller to fit a draft
engine API — adapt at the adapter, the same rule the Boosts plan uses.

| ID | Assumed capability | Used by |
|---|---|---|
| E1 | Create a web content view for a profile: given a `ProfileID` (mapped by the App to a CEF request context), return an `NSView` that can load a `URL`. | Little Open window, main-window tab open |
| E2 | Load / reload / go back / go forward / stop on that view, and read its current `URL` and title. | Little Open toolbar, Open-in-Space (needs the *current* URL after redirects) |
| E3 | Navigation callbacks: URL changed, title changed, loading changed, favicon changed. Any delivery mechanism (delegate, closure, AsyncStream) is fine. | Session `lastActiveAt`, window title, move-to-Space |
| E4 | A navigation-decision hook that reports the target URL and the modifier flags before a click navigates, and can cancel the navigation. | Opt+Cmd-click (LA-4) only. If E4 does not exist, LA-4 ships disabled; nothing else blocks. |
| E5 | The main window can show/focus a Space and select a tab by id (`BrowserModel.focusSpace` + selection already exist; the window controller side is App code, not engine). | Open-in-Space, Space routing |
| E6 | Downloads started in a web view are observable somewhere central (count + list). | LA-10 tray (deferred; §0.2) |

`LittleOpenWebContentProviding` (defined in the adapter file, Phase B):

```swift
@MainActor
public protocol LittleOpenWebContentProviding: AnyObject {
    var view: NSView { get }
    var currentURL: URL? { get }
    func load(_ url: URL)
    func reload()
    func goBack()
    func goForward()
    var onURLChange: ((URL) -> Void)? { get set }
    var onTitleChange: ((String) -> Void)? { get set }
}
```

If the real engine is delegate-based, the adapter holds the closures and
forwards delegate calls. The coordinator (§9.2) sees only this protocol.

---

## 8. Phase B — External link intake (App target)

Everything in §8–§9 is App-target code. It starts at Step 5 (§13), after the
App target exists. `OpenRouting` itself never imports AppKit.

### 8.1 Flow, end to end

```text
Other app / Finder / `open https://…`
  → LaunchServices (only because Open is registered for http/https, §8.2,
    and is the default browser if the user set it, §8.4)
  → Path 1: kAEGetURL AppleEvent → SourceAppResolver (§8.6) → source known
    Path 2: application(_:open:) → source unknown
  → ExternalLinkIntake.handle(urls:source:) (§8.5) — dedupe, queue if cold
  → RoutingRequest + RoutingSnapshot (built from BrowserModel + NSApp.windows)
  → RoutingEvaluator.evaluate → RoutingDecision (logged, §6)
  → execute (§8.7): Space tab / Little Open (§9) / bootstrap / drop
```

### 8.2 Registering as an http/https handler — `App/Info.plist`

Add (or merge into the existing) `CFBundleURLTypes` with exactly one entry:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleTypeRole</key>
    <string>Viewer</string>
    <key>CFBundleURLName</key>
    <string>app.open</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>http</string>
      <string>https</string>
    </array>
    <key>LSHandlerRank</key>
    <string>Default</string>
  </dict>
</array>
```

Rules:

- `CFBundleURLName` equals the bundle id (§2.3). If the target's bundle id
  differs, use that id here too — LaunchServices matches on it.
- `LSHandlerRank` `Default` is a *claim* that Open can handle these schemes.
  It does not make Open the default browser; only §8.4 does, with the user's
  consent through the system prompt. Do not use `Owner` (that asserts Open
  created the type) and do not add `CFBundleDocumentTypes` for web pages —
  Open claims schemes, not file types.
- Register **only** `http` and `https` in v1. Adding `ftp`, `file`, or
  custom schemes is a separate product decision.
- After changing Info.plist, the running app's registration is stale until
  relaunch. Acceptance (§12) always quits and relaunches the built app
  before testing link delivery. For a dev build that LaunchServices has not
  seen, `lsregister -f <path to Open.app>` once is acceptable developer
  setup; never ship it as an app behavior.

### 8.3 Receiving URLs — two paths, one funnel

In the app delegate (existing file; create `App/AppDelegate.swift` only if
the target has none):

1. `applicationWillFinishLaunching`: install the AppleEvent handler **here**,
   not in `DidFinishLaunching` — a `kAEGetURL` event that launches the app
   arrives before `DidFinishLaunching`, and a handler installed late misses
   the cold-launch link:

```swift
NSAppleEventManager.shared().setEventHandler(
    self,
    andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
    forEventClass: AEEventClass(kInternetEventClass),
    andEventID: AEEventID(kAEGetURL))
```

2. `handleGetURLEvent(_:withReplyEvent:)` (`@objc`): read the direct object
   (`keyDirectObject`) as a string, build a `URL`, resolve the source with
   `SourceAppResolver.source(from:)` (§8.6), and call
   `intake.handle(urls: [url], source: source)`. If the string does not parse
   as a URL, log and return — never trap on a malformed event from another app.
3. `application(_:open:)` (the `NSApplicationDelegate` method taking `[URL]`):
   call `intake.handle(urls: urls, source: .unknown)`. This path carries no
   sender identity; that is a fact of the API, not a bug to work around.
4. Also implement `application(_:openFile:)` **only** to reject gracefully:
   Open registers no document types (§8.2), so if a `.webloc` or `.url` file
   arrives by another route, extract its URL if the format is trivially
   readable and hand it to the intake as unknown-source; otherwise log and
   return `false`. Do not build a file-format importer here.

Both paths converge on the intake. No other code in the app receives URLs.

### 8.4 "Set as default browser" — `App/ExternalLink/DefaultBrowserService.swift`

```swift
@MainActor
public final class DefaultBrowserService {
    public init()
    /// True when Open is the handler the system would use for this scheme.
    public func isDefault(forScheme scheme: String) -> Bool
    /// Attempts both schemes. Returns per-scheme results; never throws.
    public func makeDefault() async -> [String: Bool]
}
```

Behavior:

- Wire the existing command id `set-default-browser` ("Set as Default
  Browser", Open menu) to `makeDefault()`. Do not add a second menu item.
- `isDefault`: build a probe URL (`https://example.com/` for https,
  `http://example.com/` for http), ask
  `NSWorkspace.shared.urlForApplication(toOpen:)`, and compare the returned
  bundle's id with `Bundle.main.bundleIdentifier`. Any nil → false.
- `makeDefault`: for each of `http`, `https`, call the macOS 26
  `NSWorkspace` API that sets the default application for a URL scheme with
  `Bundle.main.bundleURL`. **API assumption (verify against the macOS 26 SDK
  at Step 5, before writing this file):** the async form
  `setDefaultApplication(at:toOpenURLsWithScheme:)` that throws. If the SDK
  in this checkout only offers the completion-handler form, use it and wrap
  it in a continuation. Either way: one call per scheme, sequentially,
  catching per scheme so an http success survives an https failure.
- The system shows its own confirmation dialog. That dialog is the consent
  UI. Do not pre-prompt with a custom alert that duplicates it, do not poll
  for the result, and do not retry silently. After both calls, re-check
  `isDefault` for each scheme and report the truth (menu item state, and the
  Links-pane status line in §10.4: "Open is your default browser." /
  "Open is not your default browser." + a "Set as Default Browser" button).
- If Open is not the default, external links will not arrive (LA-11). Every
  other feature in this plan still works. `makeDefault` failing (user
  declines the system dialog) is a normal outcome: log it once, show the
  not-default status, do not nag again this launch.

### 8.5 Intake — `App/ExternalLink/ExternalLinkIntake.swift`

```swift
@MainActor
public final class ExternalLinkIntake {
    public init(model: BrowserModel,
                evaluator: RoutingEvaluator,
                decisionLog: RoutingDecisionLog,
                executor: LinkDestinationExecutor)
    /// Both §8.3 paths call this. Safe before the first window exists.
    public func handle(urls: [URL], source: RoutingSource)
    /// Call once the model is loaded and windows are restored.
    public func markReady()
}
```

`LinkDestinationExecutor` is a small App-side protocol (define it in this
file) with the three §8.7 actions, so the intake never imports the Little
Open coordinator's concrete type:

```swift
@MainActor
public protocol LinkDestinationExecutor: AnyObject {
    func openInSpace(_ url: URL, spaceID: SpaceID)
    func openInLittleOpen(_ url: URL, profileHint: ProfileID?)
    func bootstrapFirstSpace() -> Bool   // true if a Space now exists
}
```

Intake rules:

- **Filter at the door.** Keep only http/https URLs (the evaluator would
  reject the rest anyway; filtering here keeps the dedupe table clean).
  An empty filtered list returns silently.
- **Dedupe.** Maintain `[(key: String, at: Date)]` where
  `key = normalizedURL + "|" + (source.bundleID ?? "?")` and
  `normalizedURL` is `HostNormalizer.canonicalURLString(url)` plus the
  original query. Drop an arrival whose key matches an entry younger than
  **2 seconds**. Purge entries older than 2 seconds on each call. Why this
  exists: on some launch paths the same click can surface through both
  §8.3 paths; the window is short so two deliberate clicks on the same link
  3 seconds apart still open twice. (Little Open's own resurface dedupe in
  §9.2 then collapses the second open anyway; Space routing intentionally
  opens a second tab on a genuine second click.)
- **Cold-launch queue.** Until `markReady()`, append to `pending` and
  return. `markReady()` drains the queue in arrival order. Rationale: a
  link that launches Open must wait for the snapshot load; dropping it is
  the one unforgivable failure in this feature.
- **Snapshot per link.** For each URL, build a fresh `RoutingSnapshot`
  (§4.3 caller contract: `NSApp.windows` front-to-back, standard first in
  z-order as AppKit reports it; spaces and rules from `BrowserModel`;
  `externalLinksInLittleOpen` from the §10.4 defaults key). Windows change
  between two queued links; a stale snapshot would mis-resolve
  `.mostRecentSpace`. Build it inside the loop, not before it.
- **Execute or explain.** Act per §8.7. Every URL produces exactly one
  decision-log entry, including dropped duplicates (log the first, count
  the rest in a `duplicatesDropped` counter exposed for debugging; do not
  write a log line per duplicate).

### 8.6 Source-app detection — `App/ExternalLink/SourceAppResolver.swift`

```swift
public enum SourceAppResolver {
    /// Best-effort source of a kAEGetURL event. Main-actor not required;
    /// NSRunningApplication lookup is thread-safe. Keep it synchronous and fast.
    public static func source(from event: NSAppleEventDescriptor) -> RoutingSource
}
```

Algorithm:

1. Read the sender PID:
   `event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value`
   (`keySenderPIDAttr` is the Carbon constant for `'spid'`). Modern
   alternative where available: the audit-token
   attribute (`keySenderAuditTokenAttr`) yields data that
   `NSRunningApplication` cannot consume directly — prefer the PID; use the
   audit token only if the PID attribute is absent, converting it with
   `audit_token_to_pid` (libbsm). State the preference in a comment; do not
   link libbsm speculatively — if `keySenderPIDAttr` is unavailable in the
   macOS 26 headers, stop at Step 5 and report it (§14 Q1). The PID path is
   the plan; the audit token is the documented fallback, not a parallel build.
2. `NSRunningApplication(processIdentifier: pid)` → `bundleIdentifier`
   (lowercase it) and `localizedName`. A nil app (sender already quit) gives
   `RoutingSource(bundleID: nil, pid: pid, displayName: nil)` — the pid is
   still worth logging.
3. A pid ≤ 0 or a missing attribute gives `.unknown` with the pid if any.
   Never guess a bundle id from the event's other attributes.
4. Note the consequence in the file header: source-conditioned rules
   (§5.3) can only match links that arrive via the AppleEvent path. Links
   via `application(_:open:)` have unknown source and correctly fail
   source-conditioned rules (`.sourceUnknown`). That asymmetry is inherent
   to the two macOS delivery APIs; the decision log makes it visible.

### 8.7 Executing a decision (App glue)

For each decision, switch on `resolved` / `via`:

| Decision | Action |
|---|---|
| `.space(spaceID, _)` | `executor.openInSpace`: find or create the main window (if none exists, create one showing that Space — LA-6's guess, adopted), `focusSpace` it, then `BrowserModel.newTab(in: spaceID, url: url, at: 0)` and select the new tab. Bring Open forward only because a link click activated it; never steal focus for links the app itself generates. |
| `.littleOpen(profileHint)` | `executor.openInLittleOpen` → §9.2 (dedupe/resurface lives there). |
| `.noSpaces` | `executor.bootstrapFirstSpace()`; on true, rebuild the snapshot and re-evaluate once (§5.6). On a second `.noSpaces`, open Little Open with a nil hint and log the anomaly. |
| `.rejectedNonHTTP` | Nothing. The log entry is the record. |

`newTab(at: 0)` puts the routed tab at the top of Today, matching how new
tabs land (newest first). Routed tabs are ordinary Today tabs after this:
they auto-archive, close, and restore like any other. Routing decides where
a link *lands*; it owns nothing after landing.

---

## 9. Phase B — Little Open window

### 9.1 Session model — `OpenFeatures/LittleOpenSession.swift`

One window shows one page (LA-1). A session is that page, outside any Space:

```swift
@MainActor
public final class LittleOpenSession: Identifiable {
    public let id: WindowID                 // also the NSWindow's identity
    public let tab: Tab                     // OpenModel.Tab, in no Space
    public var profileID: ProfileID
    public let createdAt: Date
    public var lastActiveAt: Date           // drives auto-archive (§9.6)

    public init(tab: Tab, profileID: ProfileID)
}
```

Deliberate choices:

- The session holds a real `Tab` so title, URL, mute, and archive payloads
  behave exactly like sidebar tabs. The tab is **not** inserted into any
  Space, folder, split, or Favorites — `BrowserModel` never sees it until
  Open-in-Space (§9.4) creates its replacement. A Little Open tab therefore
  has no `parentByID` entry; never pass its id to `BrowserModel` commands.
- Sessions are **not** added to `BrowserModel.windows` in v1 (§0.2). The
  coordinator (§9.2) is the only owner. Snapshot DTOs stay untouched.
- The coordinator's session list, ordered by `lastActiveAt` descending, is
  the "Today-like list" for Little Open: it is what the Window menu shows,
  what Show/Close All act on, and what the sweeper archives from. There is
  no list inside the Little Open window itself (LA-1: no tab strip).

### 9.2 Coordinator — `OpenFeatures/LittleOpenCoordinator.swift`

```swift
@MainActor
public final class LittleOpenCoordinator: LinkDestinationExecutor {
    public init(model: BrowserModel,
                archiveSink: (any ArchiveSink)?,
                makeWebContent: @escaping (ProfileID) -> any LittleOpenWebContentProviding)

    /// Sessions, most recently active first. The Today-like list (§9.1).
    public private(set) var sessions: [LittleOpenSession]

    public func open(url: URL, profileHint: ProfileID?)
    public func openBlank(focusURLField: Bool, keyDownTimestamp: TimeInterval? = nil)
    public func moveToSpace(sessionID: WindowID, spaceID: SpaceID)
    public func close(sessionID: WindowID, archiveReason: ArchiveReason?)
    public func showAll()
    public func closeAll()
    @discardableResult public func archiveExpired(now: Date) -> Int
    public func nextExpiry(now: Date) -> Date?
}
```

Behavior:

- **Open with dedupe (LA-2).** Normalize the URL with
  `HostNormalizer.canonicalURLString` (fragment-insensitive: canonical form
  already drops fragments). If a live session's current URL canonicalizes
  equal, resurface it: `makeKeyAndOrderFront`, update `lastActiveAt`,
  return. No new window, no reload. Otherwise create a session
  (`profileHint` ?? the default profile — the first profile, or the profile
  of the most recent Space when the hint is nil), build its web content
  through `makeWebContent`, load the URL, show the window (§9.3).
- **Blank open (LA-3, LA-S2-3).** `openBlank` always creates a **new**
  window at the first frame (§9.3), with its command bar field focused when
  `focusURLField` is true. Arc does this for every ⌥⌘N (S2 19/0029: the
  second window opened at the same first frame over a loaded first window).
  The earlier "reuse a key blank window" rule is removed (2026-10-26). A
  second ⌥⌘N while a blank first-frame window is key was not captured; it
  also opens a new window (guess, same rule). Double-fire guard (one key
  press reaching both the global hotkey and the menu twin, §9.5): the
  coordinator ignores an `openBlank` whose triggering key-down timestamp
  equals the previous call's within 0.05 s. A real second press always
  opens a second window.
- **No main window (task-critical case).** Nothing in `open` requires a main
  window. Little Open works with zero standard windows: the coordinator
  creates only its own window. `openInSpace` (§8.7) and `moveToSpace` (§9.4)
  are the two paths that create a main window when none exists.
- **Close.** `close(sessionID:archiveReason:)`: a nil reason means "just
  close" (user closed the window, Open-in-Space already saved the page as a
  tab). A non-nil reason archives first (§9.6) through `archiveSink` with
  one `ArchiveEntry` (tab, reason, `originalLocation: "littleOpen:\(id)"`,
  spaceID nil, profileID the session's). `closeAll` closes with a nil
  reason — quitting or explicit Close All is not an archive event.
- **Show/Close All (LA-5).** `showAll` orders every session window front.
  Both are wired to Dock-menu and Window-menu items the App target already
  builds; if those menus do not exist yet, add them under the existing
  command-registry pattern with new ids `show-little-open-windows` /
  `close-little-open-windows` (titles "Show Little Open Windows" /
  "Close Little Open Windows"). Registering new ids is allowed; renaming
  shipped ones is not (§2.3).
- **Profile switch (LA-7).** From the window's profile control (§9.3):
  confirm with the existing inter-profile warning copy pattern ("Each
  Profile has different browser data, so this webpage might look a little
  different." — proven string, restated) unless the bypass flag
  (`open.links.littleOpenProfileSwitchConfirmed`, §10.4) is set. On confirm:
  set `profileID`, rebuild the web content for the new profile, reload the
  current URL. The old web content is destroyed, not kept warm.

### 9.3 Window and chrome — `OpenFeatures/LittleOpenWindowController.swift`

`NSWindowController` + `NSWindowDelegate`, one per session (the M4 plan built
it in `OpenFeatures`; the App only creates the coordinator). Capture session 2
(LA-S2-1…6) replaced the 2026-10-25 guesses (720 × 540, centered, cascade,
shared autosave frame, 40 pt toolbar). Values are window points; `W` and `H`
are the window's width and height; frames are from the window's top-left.

**Two states of one window.** A Little Open window starts as a bare command
bar (the *bar state*) and becomes a small browser window (the *page state*)
when its first navigation commits. It is the same `NSWindow` (Arc keeps one
window id, S2 19/0003 → 0011).

| Aspect | v1 value | Mark, evidence |
|---|---|---|
| Bar state frame | 490 × 329. Top edge 20 pt below the top of the screen's `visibleFrame` (below the menu bar), right edge 20 pt left of `visibleFrame.maxX`. Screen: the one that holds the mouse pointer. The size stays 490 × 329 while typing. | measured (S2 19/0003–0010: screen (2050, 50) with a 30 pt menu bar); `visibleFrame` and the pointer's screen are guesses (one display, Dock not on the right) |
| Bar state content | The command bar panel fills the window: the panel's input row (field `[53, 20, W − 110, 23]`, 380 wide), its separator, and five 50 pt rows (329 = 79 + 50 × 5, the main bar's formula). A close button "x" with a plate at `[W − 47, 19, 26, 26]` in the place of the (i) button; no (i) and no privacy footer here. The window's own shadow and corner replace the panel's. No title bar and no window buttons. Esc and "x" close the window (no archive). | layout measured (S2 19/0003); Esc guess; no-footer Open choice (the footer stays in the main bar) |
| Bar state mode | A new `CommandBarMode.littleOpen`: the empty query and typing work like `.newTab`; Return or a row click loads the result in this window (never a Today tab); "Switch to Tab" rows switch to that tab in the main window and close this window. | Open choice (Arc's empty rows are its own help links, S2 19/0003; Open shows its normal empty-query rows) |
| Page state frame | On the first committed navigation: 1185 × 832, top-right corner fixed (it grows left and down), clamped to the screen's `visibleFrame` minus 20 pt on each side. One frame change, no animation. | size and anchor measured (S2 19/0011); the trigger (commit), clamp, and no animation are guesses (frames 1.2–1.6 s apart) |
| Later windows | Every new window opens in the bar state at the same first frame, on top of the others. No cascade. | measured (S2 19/0029) |
| Frame model | Anchor by the top-right corner, like Arc's `preferredFrame.anchor.topRight` (LA-S2-6). A user move or resize applies to that window only. No autosave name in v1: new windows always use the fixed frames above. | anchor measured; per-window only guess (Arc's `LittleBrowserWindow_size` value is still unknown, §14 Q2) |
| Minimum size | Page state 360 × 240. The bar state is not resizable. | Plan choice |
| Style | `.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView`; transparent title bar; `titleVisibility = .hidden`. Bar state: the three standard buttons hidden, not resizable, movable by background. Page state: the buttons show at `[9 / 32 / 55, 16, 16, 16]` (3 pt left of the main window's 12 / 35 / 58). No sidebar, no tab strip, no Space switcher. | measured button frames (S2 19/0011); mechanism guess; LA-1 |
| Title bar (page state) | 47 pt. Measured fill (sRGB, S2 19/0011, default dark theme): ≈ `#202335` … `#2F2B38`, varying by about ±8 levels across the bar, so it is probably a translucent material over the window background (**guess**). Which Space theme colors it is not known (both test Spaces had the default theme): v1 lead decision (2026-11-05): fixed solid `#272A37`, no Space tint and no visual-effect view (guess). | height measured (page starts at y 47); fill range measured away from text and corners |
| URL capsule | `[84, 8, W − 289, 31]` (right edge W − 205), radius 8 continuous (visual). Measured fill ≈ `#383948` … `#42414D` (sRGB, S2 19/0011, away from text), lighter than the bar; probably translucent like the bar (**guess**). v1 lead decision (2026-11-05): solid `#3D3D4A`. It holds the Profile chip at its left, the host in the middle, and the copy-link button at its right. A click on the host opens the command bar over this window in `.editCurrentURL` mode, panel width min(766, W − 40) (guess: Cmd+L does the same). | frame measured (pixel bounds on S2 19/0011); click guess |
| Profile chip | Profile icon 14 pt at `[97, 17]` and the Profile name (13 Medium, white ≈ 0.8) at x 114, inside the capsule; shown only when two or more Profiles exist (guess, like the Space Manager chip). Click: the profile menu (LA-7, §9.2). | frames measured (AX `littleBrowserProfileIndicator`); visibility rule and click guess |
| Host | The page host without `www.`, 13 Regular, centered between the chip's right end and the copy-link button (`[497.5, 15.5, 129, 16]` at W 1185, center x 562). | frame measured; centering rule fitted |
| Copy-link button | `[W − 228, 16, 16, 16]`, SF `link` glyph; click copies the URL; the library shows no toast (lead decision 2026-11-05). | frame measured; action and toast guess (same as the main window) |
| "Open in" pill | Dark capsule `[W − 196, 8, 188, 30]`, opaque fill `#050627` (sRGB, uniform across the pill, S2 19/0011). Left part: a button "Open in **\<Space\>**" + keycap "⌘O" (`[W − 191, 15, 148, 17]`); a 1 pt divider; right part: a chevron button `[W − 29, 15, 16, 16]`, tooltip "More Spaces". `<Space>` = the most recently focused Space of the window's Profile (guess: it showed the main window's focused Space). The button and ⌘O run §9.4 with that Space. | frames and text measured (S2 19/0011, 0025); Space choice guess |
| Space picker | The chevron opens a dark popover (≈ 244 wide) anchored at the window's top-right: a "Search Spaces…" field (focused; typing filters by Space title), then every Space of the window's Profile with its icon on a colored rounded square, the current Space first and highlighted, rows 46 pt apart. Return or a click runs §9.4 with that Space. Esc closes the popover. | layout measured (S2 19/0023); filter, Profile scope, and keys guess |
| Back, forward, reload | No buttons. ⌘[ / ⌘] / ⌘R work through the key router (guess: not captured). | absence measured |
| Downloads | No button while there are no downloads (Arc stores `downloads: []`); downloads stay deferred (§0.2). | absence measured; trigger guess |
| Title | The page title when loaded; "Little Open" in the bar state. It is not drawn (hidden title); the Window menu and AX use it. | Plan choice (Arc's AX title is "Space 1" before load) |
| First-run intro (LA-9) | A dismissible banner under the title bar in the first page-state window, once per install: our own words, one line plus "Got it". Gate: `open.links.littleOpenNUXSeen` (§10.4). | LA-9 |

**Little Open command bar intents** (2026-10-26, review r1 F5). The
`CommandBarDelegate` of a Little Open window's bar is its
`LittleOpenWindowController`, for the bar state and for the overlay bar of the
page state (host click or Cmd+L). Window-level work goes through two new
coordinator closures that the App sets: `onSwitchToTab: (ItemID, SpaceID?) -> Void`
and `performCommand: (String, SpaceID?) -> Void`.

| Intent | Bar state | Page state (overlay bar) | Mark |
|---|---|---|---|
| `.open(url, _, modifiers)`, `.search(_, url, _, _, modifiers)` | Load `url` in this window's host; the first commit switches to the page state | Load `url` in this window's host | Open choice: modifiers and destination are ignored (one page per window) |
| `.switchToTab(id, spaceID)` | `coordinator.onSwitchToTab(id, spaceID)` (the App selects the tab in a main window, creating or focusing one as in §9.4 step 5), then close this window with no archive | Same, and this window closes with no archive (the page was not moved) | Open choice |
| `.runAction(id, spaceID)` | `coordinator.performCommand(id, spaceID)` (the App's `CommandDispatcher`); the bar's `isActionEnabled` hides commands that need a standard window | Same | Open choice |
| `.copy(text)` | Pasteboard only; no toast (Little Open has no toast center in v1) | Same | Open choice |
| `.dismissed(.escape)` | Close this window (blank, no archive) | Close the overlay bar; focus returns to the page | Esc closes the bar state: guess |
| `.dismissed(.clickOutside)` | Not sent: the embedded bar fills the window | Close the overlay bar | — |
| `.dismissed(.programmatic)` | No action | No action | — |
| `.openSearchSettings`, footer | Not sent: Little Open shows no (i) and no footer | Same | Open choice |
| The close "x" | Same as `.dismissed(.escape)` | Not shown | measured position (S2 19/0003) |

Web content fills `[0, 47, W, H − 47]` edge to edge in the page state, with no
10 pt inset and no inner corner (LA-S2-4: page pixels reach x 0, x W − 1, and
y 47 on S2 19/0011); the window's corner clips it. The controller forwards E3
callbacks: URL change → `tab.url`, `session.lastActiveAt = now`, and the host
text; title change → `tab.title`, window title. The first committed navigation
switches the window to the page state. Window becoming key also updates
`lastActiveAt`. Closing the window calls
`coordinator.close(sessionID:archiveReason: nil)` — user close is not an
archive (auto-archive, §9.6, is the archiving path; manual close in Arc is
the `manual` archive reason per the data-model report's guess — v1 chooses
*no* archive on manual close so Close never surprises; §14 Q7 flags the
Arc-truth check).

### 9.4 Open in Space (LA-6) — exact algorithm

`moveToSpace(sessionID:spaceID:)`. Callers (§9.3): the "Open in \<Space\>"
pill button and ⌘O pass the pill's Space; a Space picker row passes its Space.

1. Resolve the session and the target Space. Missing either → log, return.
2. Take the page's **current** URL from the web content (E2 — after
   redirects), not `tab.url` (which is also updated by E3; they should
   agree — prefer the web content's live value, fall back to `tab.url`).
3. Duplicate check: walk the target Space's pinned and today (recursively
   through folders and split panes, using `BrowserModel`'s node access —
   read `model.spaces`, never the private index) for a tab whose canonical
   URL (§9.2's form) equals the page's. If found: select that tab, focus
   the Space (step 5), close the Little Open window with a nil archive
   reason, return. LA open question 5 asks whether Arc dedupes; v1 does,
   because creating a second identical tab is the only outcome a user
   would call a bug.
4. Otherwise `model.newTab(in: spaceID, url: currentURL, title: tab.title, at: 0)`.
   Placement is **Today, top**. (Pinned placement is the RE's guess-level
   alternative; Today is where an unpinned moved page belongs. §14 Q8.)
5. Ensure a main window shows the Space: if a standard window exists,
   `focusSpace` it to `spaceID` and make it key; if none exists, create the
   main window on that Space first (LA-6 guess, adopted), then focus.
6. Select the new (or found) tab so the user lands on the page.
7. Close the Little Open window (`close(sessionID:archiveReason: nil)`).
   The page now lives as a tab; archiving it too would duplicate it in the
   Archive. This ordering — create/select first, close second — means a
   failure in step 4 leaves the Little Open window untouched.

### 9.5 Entry points wiring

| Entry | Wiring | Gate |
|---|---|---|
| External link routed to Little Open (LA-2) | §8.7 → `coordinator.open(url:profileHint:)`. | Routing decision; needs default-browser status to receive the link at all (LA-11). |
| Global hotkey (LA-3) | `GlobalHotkeyService` (OpenCommands, already built) registered by the App with the `little-arc-global` command's effective shortcut (default Cmd+Opt+N) **only while** `open.links.littleOpenHotkeyEnabled` (§10.4) is on. Action: `coordinator.openBlank(focusURLField: true)` on the main actor. Re-register when the user changes the shortcut or toggles the setting; `unregister()` when it turns off (the service cleans up on deinit — the App still unregisters explicitly so a quit never leaves a stale Carbon registration). | Opt-in setting, default ON (§10.4). Carbon signature `'OPEN'`, id 1, is already the service's. |
| Menu "New Little Open Window" | Existing command id `new-little-arc-window` (Cmd+Opt+N window-scope twin) → `openBlank(focusURLField: true)`. | None. |
| Opt+Cmd-click (LA-4) | E4 hook: if modifiers contain `[.command, .option]` and the §10.4 toggle is on, cancel navigation and `coordinator.open(url:profileHint: currentSpaceProfile)`. | Toggle `open.links.optionCommandClickLittleOpen`, default ON (Guess). Ships only when E4 exists (§7). |
| Dock/Window menus (LA-5) | §9.2 Show/Close All. | None. |
| Command `open-in-current-space` (Cmd+O) | When the key window is a Little Open window in the page state, it runs §9.4 with the Space named in the window's "Open in" pill (the pill shows the "⌘O" keycap, S2 19/0011). It does not open the picker; the chevron does. In the bar state it does nothing. | Key window is Little Open. Changed 2026-10-26 (was: open the move menu). |

Hotkey conflict note: the global registration and the window-scope twin
share Cmd+Opt+N by design (a known Arc collision, [commands.md](../commands.md)).
`GlobalHotkeyService` firing while Open is frontmost must not double-open.
The blank-reuse rule that used to absorb the second trigger is gone (every
⌥⌘N opens a new window, LA-S2-3), so the coordinator coalesces the two
triggers of one key press by their key-down timestamp (§9.2). guess: a
registered Carbon hot key consumes the key-down, so the menu twin may never
fire; the guard is still required because the order is not guaranteed.

### 9.6 Auto-archive sweeper (LA-8)

- Lead decision 2026-11-05: the coordinator has no polling timer. The App's
  single `ExpirySweeper` drives `archiveExpired(now:)`, including at launch.
  `nextExpiry(now:)` returns the earliest `lastActiveAt + Profile interval`,
  or nil for no expiring sessions (Never is excluded). The App uses `onChange`
  to reschedule after session creation, close, activity and Profile changes.
  Changing the Profile policy also requires the App to reschedule.
- Rule: for each session where `now - lastActiveAt` reaches its **profile's**
  `settings.littleOpenAutoArchiveAfter.seconds` (nil seconds = Never =
  skip), close with `archiveReason: .autoArchived`. Process expirations in
  `lastActiveAt` ascending order. Return the count.
- `lastActiveAt` updates on: creation, resurface, URL change, window key.
  It does **not** update on a timer, on title changes, or while the page
  plays media — v1 has no media exception ( Arc's keep-alive list belongs to
  tab discarding, core §3.4; do not borrow it without evidence).
- Archiving writes through `ArchiveSink` (§9.2 close). The Archive UI's
  "Little Arc" filter (§3.6 of the core report) distinguishes these rows by
  the `littleOpen:` location prefix. Restore of such a record lands in the
  focused Space's Today via `BrowserModel.restoreArchivedTab`'s existing
  fallback (its `NodeParent(archiveLocation:)` parse fails for the prefix
  and falls through — verify in Step 7's checks; do not add a NodeParent case).

### 9.7 What happens when no main window is open (summary, normative)

| Trigger | Result |
|---|---|
| External link → Little Open | Little Open window only. No main window is created. |
| External link → Space | Main window created on that Space, tab opened and selected (§8.7). |
| Global hotkey | Little Open blank window only. |
| Open in Space from Little Open | Main window created if needed (§9.4 step 5). |
| Last main window closes while Little Open windows live | Nothing. Sessions persist; the app stays running (standard macOS browser behavior — Little Open windows are real windows). |
| Quit with Little Open windows open | `closeAll` (no archive). Windows do not restore next launch in v1 (§0.2). |

Lead decision (2026-11-05, §9.7): restore all saved standard windows unchanged.
A cold Little Open link opens on top and takes key. “No main window is created”
means no additional main window is created for that link; it never means closing
saved windows. The one exception is a fresh default main window created only
because the snapshot had no standard windows. Mark that window explicitly at
creation. If the first external destination is Little Open, close that fallback
only while it has received no user input or navigation. Keep saved windows in
the snapshot. Do not use a clock or delay to infer launch intent. B6 covers both
saved-window and windowless snapshots, plus input/navigation protection of the
fresh fallback.

---

## 10. Settings UI data — `LinksSettingsModel.swift` (no views)

Create `Packages/OpenKit/Sources/OpenRouting/LinksSettingsModel.swift`.
This is the Links pane's data and logic. A designer builds the visual pane
later by binding to this model; do not create SwiftUI views in this plan.
`@MainActor @Observable`, matching `OpenModel`'s live-object style.

### 10.1 Types

```swift
public struct SpaceOption: Hashable, Sendable, Identifiable {
    public var id: SpaceID
    public var title: String
}

/// Editable form of one rule. The view edits drafts; the model converts.
public struct RuleDraft: Hashable, Sendable, Identifiable {
    public var id: RuleID
    public enum MatchKind: String, CaseIterable, Sendable {
        case hostContains, hostEquals, urlPrefix
    }
    public var matchKind: MatchKind
    public var pattern: String                    // as typed; trimmed on save
    public enum DestinationKind: String, CaseIterable, Sendable {
        case space, mostRecentSpace, littleOpen
    }
    public var destinationKind: DestinationKind
    public var spaceID: SpaceID?                  // used only when kind == .space
    public var sourceBundleID: String             // "" = any source (§4.2)

    public init(from rule: RoutingRule)
    /// Nil when the draft cannot become a rule (§10.3 errors decide display;
    /// this returns nil exactly on a §10.3 *error*, never on a warning).
    public func makeRule() -> RoutingRule?
}

public enum RuleIssue: Hashable, Sendable {
    case emptyPattern(ruleID: RuleID)
    case patternHasSpaces(ruleID: RuleID)
    case prefixNotParseable(ruleID: RuleID)
    case missingSpace(ruleID: RuleID)             // destination Space deleted
    case duplicateOf(ruleID: RuleID, otherIndex: Int)  // warning, not an error
    case containsIsSubstring(ruleID: RuleID)           // warning (§5.2)
}
```

`RuleIssue` severity: the first four are **errors** (block save of that rule;
the rule is kept in the list, marked, and excluded from the evaluator's
snapshot until fixed — never silently dropped from the user's list). The
last two are **warnings** (save proceeds).

### 10.2 The model

```swift
@MainActor
@Observable
public final class LinksSettingsModel {
    public var drafts: [RuleDraft]
    public var defaultDestinationKind: RuleDraft.DestinationKind
    public var defaultSpaceID: SpaceID?
    public var externalLinksInLittleOpen: Bool
    public var littleOpenHotkeyEnabled: Bool
    public var optionCommandClickLittleOpen: Bool
    /// Per-profile Little Open auto-archive choice lives on ProfileSettings
    /// (§3.4); the pane edits the *current* profile's value through here.
    public var littleOpenAutoArchiveAfter: AutoArchiveInterval

    public var spaces: [SpaceOption]
    public var isDefaultBrowser: Bool             // refreshed by the App (§8.4)
    public var testURLString: String
    public var testSourceBundleID: String         // "" = unknown source
    public var testMostRecentSpaceID: SpaceID?    // which Space "most recent" means in a test
    public private(set) var testDecision: RoutingDecision?

    public init(snapshot: RoutingSnapshot, spaces: [SpaceOption],
                isDefaultBrowser: Bool)
    public func issues() -> [RuleIssue]
    public func addRule()                          // appends a hostEquals draft, empty pattern
    public func deleteRule(id: RuleID)
    public func moveRule(from: Int, to: Int)       // order IS priority (ATC-2)
    /// The rules as the evaluator should see them now (valid drafts only,
    /// in list order), plus the default. The App writes these into
    /// BrowserModel and scheduleSave()s; the model itself does no I/O.
    public func currentRouting() -> (rules: [RoutingRule], defaultDestination: DefaultDestination)
    /// Runs the real evaluator against the current drafts. No test-only logic.
    public func runTest()
}
```

### 10.3 Validation (implement exactly)

Per draft, on every `issues()` call (cheap; called on edit, not per keystroke
render — the view debounces, the model does not care):

- `pattern` trimmed empty → `.emptyPattern` (error).
- `pattern` contains a space → `.patternHasSpaces` (error). Hosts and URL
  prefixes never contain literal spaces; this catches pasted titles.
- `matchKind == .urlPrefix` and the pattern contains `://` but does not
  parse as a URL with a host → `.prefixNotParseable` (error).
- `destinationKind == .space` and (`spaceID` nil or not in `spaces`) →
  `.missingSpace` (error).
- Same (matchKind, canonical pattern, destination, source) as an earlier
  draft → `.duplicateOf` (warning). Compare canonical patterns (§5.1) so
  `Example.com` duplicates `example.com`.
- `matchKind == .hostContains` → `.containsIsSubstring` (warning, always).
  The warning text (designer's copy, data here): the rule matches any host
  containing the text, including unrelated hosts that merely contain it.
  This warning is the user-facing mitigation for §5.2's literal semantics.

`makeRule()` maps kinds to `RoutingMatch` / `RoutingDestination` directly,
lowercases `sourceBundleID` ("" → nil), and returns nil on any error-severity
issue for that draft. `currentRouting()` compacts `makeRule()` over drafts
and builds the `DefaultDestination` from the kind fields (`.space` with a
missing Space degrades to `.mostRecentSpace` — and `issues()` must surface
that as `.missingSpace` on a synthetic draft; implement by validating the
default through a temporary draft so the user sees the problem).

### 10.4 Persistence split (who owns what)

| Setting | Owner | Key / path |
|---|---|---|
| Rules + default destination | `BrowserModel.routingRules` / `.defaultDestination`, via the snapshot (already persisted). The App copies `currentRouting()` into the model and calls `scheduleSave`. | `State/browser.json` (existing) |
| `externalLinksInLittleOpen` | `UserDefaults` | `open.links.externalInLittleOpen`, default `true` (ATC-6 / SET-1 Guess ON) |
| `littleOpenHotkeyEnabled` | `UserDefaults` | `open.links.littleOpenHotkeyEnabled`, default `true` (LA-3) |
| `optionCommandClickLittleOpen` | `UserDefaults` | `open.links.optionCommandClickLittleOpen`, default `true` (LA-4 Guess) |
| Little Open auto-archive | `ProfileSettings.littleOpenAutoArchiveAfter` (per profile, §3.4) | Snapshot (existing). Default `.sixHours` (SET-2). |
| Profile-switch bypass (LA-7) | `UserDefaults` | `open.links.littleOpenProfileSwitchConfirmed`, default `false` |
| NUX seen (LA-9) | `UserDefaults` | `open.links.littleOpenNUXSeen`, default `false` |

Register the defaults with `UserDefaults.register(defaults:)` at App launch
(Phase B). The CLI reads the same keys with the same fallbacks so `openkit
route` and the App agree when the user has never opened Settings.

When Open is not the default browser, the pane shows the §8.4 status line
next to the external-links toggle (LA-11): the toggle stays editable (it
takes effect once Open is default), and the status text explains why links
are not arriving. The model carries `isDefaultBrowser`; the App refreshes it
on pane appearance and after `makeDefault()`.

### 10.5 Test a URL

`runTest()` builds a `RoutingRequest` from `testURLString` (prepend
`https://` when the text has no scheme and contains a dot; if it still does
not parse, set `testDecision = nil` and expose `testInputIsValid == false` —
add that computed property), a source from `testSourceBundleID`
(empty → `.unknown`), and a `RoutingSnapshot` whose windows are a single
synthetic standard window focused on `testMostRecentSpaceID`
(default: the first Space) so `.mostRecentSpace` means something concrete
without a live window. It evaluates with a logger-less `RoutingEvaluator`
and stores the decision. The view renders
`RoutingDecisionFormatter.report(_:spaces:)` (§6.2) verbatim. The test never
opens anything, never writes the decision log, and never mutates rules.

---

## 11. Phase A verification surface — `openkit route`

Create `Packages/OpenKit/Sources/openkit/RouteCLI.swift`; wire
`case "route": runRoute(args: rest)` in `openkit/main.swift` and add
`"OpenRouting"` to the `openkit` target's dependencies (§2.1). Mirror
`SuggestCLI.swift`'s argument style and error handling (stderr + exit codes).

### 11.1 Interface

```text
openkit route DIR <url> [--source BUNDLE_ID] [--most-recent SPACE]
                      [--external-little-open on|off] [--json]
                      [--expect-destination space:<uuid>|littleOpen|mostRecentSpace]
```

- `DIR` is a snapshot root (the folder that holds `State/browser.json`), as
  in `openkit dump`. Load with `SnapshotStore(root:).load()`; no snapshot →
  stderr `error: no snapshot at <DIR>`, exit 1.
- `<url>` positional, required. An argument that does not parse as a URL
  after the §10.5 scheme-prepend convenience → usage to stderr, exit 2.
- `--source` sets `RoutingSource(bundleID:)` (lowercased). Absent → unknown.
- `--most-recent` takes a Space UUID or an exact Space title. It orders the
  snapshot's windows so a standard window focused on that Space is first.
  Unknown value → stderr, exit 2. Without it, the first standard window in
  the stored snapshot stands in as frontmost (§4.3) and the report says so.
- `--external-little-open` overrides the toggle for this run (default: read
  the §10.4 UserDefaults key with its registered fallback).
- `--json` prints the `RoutingDecision` as JSON (sorted keys) instead of the
  §11.3 report. Exit codes unchanged.
- `--expect-destination` is the scripted acceptance hook: `space:<uuid>`
  (that exact Space), `mostRecentSpace` (the Space §5.5 resolves as most
  recent), or `littleOpen`. Mismatch → exit 1 (the report still prints).
  Match or absent flag → exit 0. Usage errors exit 2. This flag replaces
  any need for unit tests of the evaluator: the checks in §13 drive it.
- Building the evaluator's snapshot from the live model happens on the main
  actor (`SnapshotStore.load()` already returns a `@MainActor` model —
  follow how `runDump` bridges into `MainActor.run`).

### 11.2 What the CLI proves

The same `RoutingEvaluator` the App runs. Nothing in `RouteCLI` reimplements
matching: it builds `RoutingSnapshot` + `RoutingRequest`, evaluates, prints
`RoutingDecisionFormatter.report`. If the CLI and the App ever disagree, the
bug is in snapshot construction, and the report's header (§11.3) shows the
inputs so the difference is visible.

### 11.3 Report layout (implement exactly)

```text
url: https://meet.google.com/abc-def
host: meet.google.com
source: com.apple.mail (pid —)        ← "source: unknown" when no --source
windows: 1 standard (frontmost = stored order)   ← or "most-recent override: Work"
rules:
  #1 hostEquals(google.com) [source: any] -> Space “Personal” … host mismatch
  #2 hostContains(meet.google.com) [source: any] -> Little Open … matched
decision: Little Open (profile hint: Personal profile)
via: rule #2
```

Per-trace line outcomes print as: `matched`, `host mismatch`,
`source mismatch`, `source unknown (rule needs com.example.… )`,
`target Space missing — skipped`. A run with no rules prints `rules: (none)`.
The final two lines always print, including for `.noSpaces`
(`decision: none`) and `.rejectedNonHTTP` (`decision: rejected`).

---

## 12. Phase B acceptance checks (with the real app)

Run these only in Steps 5–7, against the built `Open.app`. Substitute the
real bundle id / app path (§2.3). Do not drive the user's desktop; agent-run checks use the automation socket, shell commands, or `open` deliveries; no check drives the desktop — state reads, plus link deliveries the test itself causes.

Setup (once per build under test):

```bash
APP=/path/to/Open.app          # the built bundle under test
BID=app.open                   # its bundle id
quit open first: osascript -e "tell application id \"$BID\" to quit" || true
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$APP"
```

| # | Check | Command / action | Pass |
|---|---|---|---|
| B1 | Handler registered | `open -a "$APP" https://example.com/route-check` with Open set as default (B2 done first on a dev profile) **or**, without changing the user's default: `osascript -e 'tell application id "app.open" to open location "https://example.com/route-check"'` | Open launches/foregrounds and the URL lands per the current rules (default: Little Open). Repeat with Open already running and with Open quit (cold-launch queue, §8.5). |
| B2 | Set as default | In Open: Open menu → Set as Default Browser; accept the **system** dialog. Then `open https://example.com/default-check` from Terminal. | The link opens in Open (per rules). Declining the system dialog leaves the previous browser default and Open's Links status reads not-default (§8.4). |
| B3 | Source detection | `open -a "$APP" https://example.com/from-terminal` (sender: Terminal/`open`), then trigger the same URL from another app (for example a Mail draft link) if available. | Decision log (§6, surfaced by whatever debug UI the App exposes; at minimum the unified log via `log show --last 5m --predicate 'subsystem == "app.open"'` if the App logs there) shows the Terminal run's source bundle id and `unknown` for any `application(_:open:)` delivery. A rule with that source (§4.2, created in Settings data) matches only the known-source delivery. |
| B4 | Little Open lifecycle | Agent path, through the automation socket only (2026-10-26, F11): `menu-perform id=new-little-open-window`; `key window=<number> text=example.com\r` (synthetic key events sent inside the app); then deliver one external URL twice with `open -a "$APP" <url>` (a delivery the test causes). User-run only: a real ⌥⌘N press from another app (agents never drive the desktop; `hotkey-state` shows the global hotkey registered). | Fresh Little Open with the field focused; page loads; the second delivery resurfaces the same window (`little-open-state` session count unchanged). |
| B5 | Open in Space | Through the socket or user-run: In that window: press ⌘O (the pill's Space); in a second Little Open page window, open the chevron picker, type part of another Space's title, press Return. | Main window appears (created if it was closed), focused on the chosen Space (the pill's Space for ⌘O, the picked Space for the picker), page present as the top Today tab and selected; Little Open window closed; no archive row created for it (`openkit archive-list` on the data dir shows no new row). |
| B6 | No-main-window matrix | Quit Open. `open -a "$APP" <URL-that-routes-to-Little-Open>`: only a Little Open window. Close all main windows, leave Little Open open: app stays running. Then Open in Space: main window is created. | Each row of §9.7's table holds. |
| B7 | Auto-archive | Step 7 adds a debug-only menu item "Archive Expired Little Open Windows Now" (Help → Troubleshooting pattern). It calls the same `archiveExpired(now:)` the Timer calls, with `now` advanced by 31 days so a 1-hour-threshold window counts as expired without waiting. Set the threshold to 1 hour, open a Little Open page, run the item. Then set Never, reopen the page, run the item again. | First run: window closes; `openkit archive-list` shows the page; restoring it lands in the focused Space's Today (§9.6). Second run: window stays. The debug item is the only clock shortcut; production code never advances `now`. |
| B9 | Frames (LA-S2-1…3) | Through Open's automation socket only; no desktop input and no System Events (AGENTS.md rule 4). `menu-perform id=new-little-open-window` (the window-scope twin of the global hotkey) → `little-open-state` (new automation command, Step 6: per session the id, window number, screen frame, state `bar` / `page`, and the screen's `visibleFrame`) → read 1. `key window=<that number> text=example.com\r` (synthetic key events sent with `NSWindow.sendEvent` inside the app), `wait` until `little-open-state` reports `page` → read 2. `menu-perform id=new-little-open-window` again → read 3. The Carbon global hotkey is not pressed: `hotkey-state` must report `registered: true`. | First read: one Little Open window 490 × 329 whose right edge is 20 pt left of the screen's visible right edge and whose top is 20 pt below the menu bar. Second: the same window 1185 × 832 with the same top-right corner. Third: a second window 490 × 329 at the first frame; the first window is unchanged. |
| B10 | Title bar (LA-S2-4) | `features-render render --scene little-page` and the App `snapshot` of a page-state window, compared with S2 19/0011 by the `docs/design.md` §7 method (page masked, Profile name masked). | Every element of LA-S2-4 within 1 pt. Pill fill within ΔE00 2 of `#050627`. Bar and capsule (probably translucent, guess): every sampled pixel inside the measured range widened by 4 levels per channel (bar `#202335` … `#2F2B38`, capsule `#383948` … `#42414D`); no ΔE00 target until the material is modeled. |
| B8 | Default-off routing | Toggle "Links from other apps open in Little Open" off, default destination Little Open. Deliver an external link. | Link lands as a tab in the most recent Space (§5.5 R7); decision log via reads `defaultSuppressedByToggle` in formatter words. Toggle back on: next link opens Little Open. |

Record the output of B1–B8 in the PR description (commands + one-line
results). A check that cannot run (for example B3's second sender is
unavailable) is reported as unverified with the reason — never replaced by
a unit test (AGENTS.md rule 6, thread testing rule).

---

## 13. Implementation order

Each step: files, then acceptance. A step is done only when its checks pass.
Steps 1–4 are Phase A. Steps 5–7 are Phase B (App target required).

### Step 1 — Rename with compatible decoding (§3)

Files: `OpenModel/Containers.swift`, `OpenStore/SnapshotDTOs.swift`,
`OpenImport/ArcImport.swift` (destination/style sites only),
`OpenCommands/CommandRegistry.swift` (three titles),
`OpenCommands/ExpectedMenu.swift` (title allowlist),
plus the `RoutingRule.sourceBundleID` addition (§4.2 — do it here, while the
DTO mapper is open).

Acceptance: §3.6, all five commands. The pre-change snapshot roundtrips.

### Step 2 — `OpenRouting` core (§4–§6)

Files: `Package.swift` (target + product only, §2.1),
`OpenRouting/RoutingTypes.swift`, `OpenRouting/HostNormalizer.swift`,
`OpenRouting/RuleEvaluator.swift`, `OpenRouting/DecisionLog.swift`,
`OpenRouting/DecisionFormatter.swift`.

Acceptance:

```bash
nice -n 10 swift build -c release -j 6   # zero warnings, zero errors
```

In this step, `swift build` and a read-through of §5's tables against the
code are the check. Logic is verified through Step 4's CLI. Do not merge
Step 2 without Step 4 landing in the same PR, so the unverified gap never
ships. Do not add probe files to the repo; any throwaway probe lives in `/tmp`.

### Step 3 — Settings data model (§10)

Files: `OpenRouting/LinksSettingsModel.swift`.

Acceptance: `swift build` clean. Behavior (validation, conversion, test
evaluation) is verified through the same code path the CLI exposes: the
Step-4 report and `LinksSettingsModel.runTest` share `RoutingEvaluator`;
once Step 4 passes its table (§13 Step 4), spot-check `runTest` from a
`/tmp` probe that builds the model from an imported snapshot and prints the
formatter output for two URLs. Keep the probe in `/tmp`.

### Step 4 — `openkit route` (§11)

Files: `openkit/RouteCLI.swift`, `openkit/main.swift` (one case),
`Package.swift` (openkit depends on `OpenRouting`).

Fixture: reuse `/tmp/routing-old-snapshot` (Step 1) or produce a fresh one
with `openkit import-arc --out /tmp/routing-fixture` (the live import holds
one most-recent-Space rule). Read its Space ids/titles from
`openkit dump /tmp/routing-fixture` first; substitute them below.

Acceptance (every row must match; run with `--expect-destination` so the
exit code carries the verdict):

| # | Invocation shape | Expected |
|---|---|---|
| A1 | `route DIR https://example.com/` (no rule matches) | Default resolution; exit 0. |
| A2 | `route DIR https://www.example.com/` against a snapshot whose rule is `hostEquals(example.com)` → known; construct the rule by editing a **copy** of the fixture's `State/browser.json` (the copy is the fixture; never edit the original import). | Matches (www-equivalence, §5.2). |
| A3 | Same rule, URL `https://sub.example.com/` | No match → default. |
| A4 | Rule `hostContains(google.com)` → Space X; URL `https://mail.google.com/` | Matches Space X (substring). |
| A5 | Two rules for the same host, first → Little Open, second → Space X; matching URL | Little Open (first match wins, ATC-2). |
| A6 | Rule with `--source` set on the rule (edited fixture) ; run without `--source`, then with the matching `--source` | Without: `source unknown`, falls through. With: matches. |
| A7 | Default `.littleOpen`; run with `--external-little-open off`, then `on` | off → most-recent Space; on → Little Open (§5.5 R7). |
| A8 | `route DIR ftp://example.com/` | `decision: rejected`, exit 0. |
| A9 | Rule → deleted Space id (edited fixture) plus a later matching rule | First rule traces `target Space missing — skipped`; second rule wins (§5.4 R4). |
| A10 | `--json` on A1's inputs | Valid JSON; `via` and `resolved` agree with the text report. |
| A11 | `swift run openkit roundtrip DIR` and `commands-demo DIR` on the fixture | Both still pass (the rename and the new optional field broke nothing). |

### Step 5 — Intake and default browser (§8)

Prerequisite: the App target builds and launches. Verify §8.4's API
assumption against the SDK first; if it fails, stop and report (§14 Q1).

Files: `App/Info.plist` (§8.2), app delegate (§8.3),
`App/ExternalLink/DefaultBrowserService.swift`,
`App/ExternalLink/ExternalLinkIntake.swift`,
`App/ExternalLink/SourceAppResolver.swift`, App executor conformance (§8.7 —
its Little Open half may forward to a stub that logs until Step 6).

Acceptance: §12 B1, B2, B3, B8 (B8's Little Open leg may assert the log line
until Step 6 lands the window). Cold-launch delivery (Open quit → click →
link lands) is part of B1 and is not optional.

Verification update (2026-11-05, Section 9): Step 5 App code and the `routing`
suite are implemented; see [the App receipt](../routing.md#phase-b-step-5--app-intake-2026-11-05).
B1 uses `open -a <exact built bundle>` in both warm and cold cases; cold uses
`-n` plus this suite's data-root arguments. The test covers normal fast cold
launch and a test-only two-second slow-readiness handoff to observe pending →
drained state. Queue and dedupe have intentional break-and-revert proofs.
B3 proves the actual sender PID; `open` has often exited before bundle-id
lookup, so a real Mail/Messages click and known-bundle rule matching remain
user hand checks. B8 covers two-window front-to-back order and both toggle
states. B2 is user-only: no test invokes the default setter. Little Open still
uses the small recorded stub seam until Step 6. The lead's `.noSpaces` choice
for Step 5 is bootstrap once, then Little Open with a nil hint.

### Step 6 — Little Open window (§9.1–§9.5)

Files (2026-10-26, F7: the first three already exist in `OpenFeatures`;
Step 6 wires them, it does not recreate them): `OpenFeatures/LittleOpenSession.swift`,
`OpenFeatures/LittleOpenCoordinator.swift`,
`OpenFeatures/LittleOpenWindowController.swift`,
`App/LittleOpen/LittleOpenWebContent.swift` (E-adapter, §7),
`App/Automation/AutomationController.swift` (new `little-open-state` command, §12 B9),
hotkey + entry-point wiring (§9.5), executor's Little Open half (real now).

Acceptance: §12 B4, B5, B6, B9, B10. Plus: with no main window open, the global
hotkey opens a usable Little Open window (part of B6's table).

### Step 6a — Little Open to capture session 2 (library; can run now)

The M4 plan's Step 6 already built `LittleOpenSession`, `LittleOpenCoordinator`,
and `LittleOpenWindowController` in `OpenFeatures` with the 2026-10-25 guesses
(720 × 540 centered, cascade, shared autosave frame, 40 pt toolbar, blank
reuse, 10 pt inset page). This step changes them to §9.2–§9.5 as amended on
2026-10-26. It needs no App target.

Files: `OpenFeatures/LittleOpenWindowController.swift` (bar and page states,
frames, title bar, full-bleed page), `OpenFeatures/LittleOpenTitleBarView.swift`
(new: capsule, Profile chip, host, copy-link, "Open in" pill, chevron),
`OpenFeatures/LittleOpenSpacePicker.swift` (new: the popover),
`OpenFeatures/LittleOpenCoordinator.swift` (no blank reuse, no cascade,
same-press guard, `onSwitchToTab` and `performCommand` closures, the screen
provider below), `OpenDesign/Metrics.swift` (`LittleOpenMetrics`: every frame
of §9.3), `Package.swift` (`OpenFeatures` gains the `OpenCommandBar`
dependency; keep both sides on conflict), `features-render` (scenes
`little-bar`, `little-page`, `little-picker`; check L1 rewritten, new L4–L7),
`docs/m4.md` (Little Open limits).

`OpenCommandBar` files (review r1 F5):

| File | Change |
|---|---|
| `CommandBarTypes.swift` | Add `CommandBarMode.littleOpen` (raw value "littleOpen"); its `suggestMode` (an exhaustive `switch`) maps it to `.newTab` |
| `CommandBarController.swift` | Treat `.littleOpen` like `.newTab` for the empty input and the placeholder; its destination is `.currentTab` (line with `r.mode == .editCurrentURL ? .currentTab : .newTab`); `present` takes a presentation parameter (below) |
| `CommandBarView.swift` | New `CommandBarPresentation`: `.overlay` (today) and `.embedded(width:)`: the panel sits at the host view's origin, fills it, and draws no shadow and no backdrop (the window has its own) |
| `InputRowView.swift` | In `.embedded`, the trailing accessory is a close "x" button at `[W − 47, 19, 26, 26]` (with a plate) instead of (i) |
| `OpenDesign/CommandBarTokens.swift` | `CommandBarMetrics.littleOpenWidth` 490, `littleOpenRows` 5 (329 = 79 + 50 × 5), close-button frame |

Other users of `CommandBarMode` that the new case reaches: `Presentation.row(_:mode:currentSpaceID:currentURL:currentTitle:)` (mode-dependent row text; `.littleOpen` = `.newTab`); `commandbar-render` `Flows.swift`, `Scenes.swift`, `Stage.swift` (add a `little-open` scene and flows; existing ones unchanged); the App's `AppCommandBarSession.stateForAutomation` (reports `mode.rawValue`, so automation can now see "littleOpen") and `didChangePresentation` (compares with `.newTab` only, unaffected). No App file switches exhaustively over `CommandBarMode`.

Screen provider for L1 (review r1 F5): `LittleOpenCoordinator` gains an init
parameter `screenProvider: () -> LittleOpenScreen`, where
`struct LittleOpenScreen { var frame: CGRect; var visibleFrame: CGRect }` in
AppKit screen coordinates. The default reads the `NSScreen` that holds
`NSEvent.mouseLocation`. Frames are computed from the provider only.
`features-render` passes a fixed value and never orders a window front
(`presentWindows = false`, as today): offscreen only, never the real desktop.
The App e2e (B9) uses the real screen through the automation socket.

Acceptance:

| # | Check (`features-render check`, offscreen, real views) |
|---|---|
| L1 | `openBlank` with `screenProvider` returning `LittleOpenScreen(frame: [0, 0, 2560, 1440], visibleFrame: [0, 0, 2560, 1410])` (AppKit coordinates; a 30 pt menu bar), offscreen: one window 490 × 329 whose AppKit frame is `[2050, 1061, 490, 329]` (= top-left screen point (2050, 50)) in the bar state (no window buttons, field focused, "x" at `[443, 19, 26, 26]`, no (i)); a second `openBlank` makes a second window at the same frame; the same canonical URL opened twice still resurfaces (LA-2). Replaces the old "720x540" and "blank reuse" checks. |
| L4 | A committed navigation turns the window into the page state at 1185 × 832 with the top-right corner unchanged; the web content frame is `[0, 47, W, H − 47]`; LA-S2-4 element frames within 0.5 pt at W 1185 and at W 800. |
| L5 | The pill shows the most recent Space's title; pressing it (or `open-in-current-space`) calls `moveToSpace` with that Space; the chevron opens the picker; typing filters rows; Return calls `moveToSpace` with the highlighted Space. |
| L6 | Two `openBlank` calls with the same key-down timestamp make one window; two with timestamps 0.2 s apart make two. |
| L7 | Bar intents (table in §9.3) with a fake host: `.open` and `.search` load in this window and ignore modifiers; `.switchToTab` calls `onSwitchToTab` once and closes the window; `.runAction` calls `performCommand` once; `.copy` writes the pasteboard. Non-navigation selections restore the focused embedded bar if the session survives in bar state; an action callback can close the session without restoring it. `.dismissed(.escape)` and the "x" close a bar-state window and only close the overlay bar in the page state. |
| L8 | `nextExpiry(now:)` chooses the earliest per-Profile deadline, nil for Never/no sessions; activity sends `onChange`; exact-deadline expiry writes `.autoArchived`, `littleOpen:<id>`, nil Space and the supplied timestamp to the real SQLite ArchiveStore. |

Step 6a verification log (2026-11-05): library implementation on
`s9/little-open-library`. `features-render check --only little-open` exercises
real unordered AppKit windows, the embedded/overlay command bar, picker input,
model moves, and a temporary SQLite ArchiveStore. New PNGs use synthetic data
under `Packages/OpenKit/FeatureRenders/little-open/`. Final counts, negative
proofs and the complete gate receipt are recorded there in `verification.md`.
The App still shows `showLittleOpenStub`; Step 6b owns App wiring, global/menu
key delivery, the App sweeper, and B9/B10 native-window comparison. No engine
build, Arc launch, desktop input or unit tests are part of Step 6a.
PR review added four L7 flows for blank calculator/action selections, later
navigation and an action callback that closes the session. The old source
fails the two control-restoration rows; the corrected library passes all
51 Little Open rows in the 564-row features flow, plus 19 idle rows. The
post-review Debug App build also passes. The receipt distinguishes the full
pre-review gate from the focused post-review verification.

Then `tools/verify-all.sh` and the B10 compare once the App can show the window.

### Step 7 — Sweeper, menus, polish of behavior (§9.6–§9.7)

Files: shared App `ExpirySweeper` (one minimum Today/Little Open deadline),
Show/Close All menu items (§9.2),
NUX banner (§9.3), Links-pane App wiring (bind the future designer's pane —
or a minimal functional pane if none exists yet — to `LinksSettingsModel`,
write `currentRouting()` into `BrowserModel` on save, refresh
`isDefaultBrowser` per §10.4).

Acceptance: §12 B7, and re-run B1–B6, B8 as a regression pass. Re-run
Phase A's A1–A11 as well: the evaluator did not change, so any failure here
means App-side snapshot construction drifted (§11.2).

---

## 14. Open questions (for the parent / user, not the implementer)

The implementer builds what §1–§13 say. These questions change the plan only
if the parent answers before the relevant step starts.

| # | Question | Plan's current choice | Deadline |
|---|---|---|---|
| Q1 | macOS 26 SDK shape for `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)` (async throws vs completion handler) and availability of `keySenderPIDAttr` in the headers. (§8.4, §8.6) | Async-throws assumed; PID path assumed. Verify at Step 5 before writing the files. | Step 5 |
| Q2 | Little Open default size/position and whether the frame is shared across windows. (§9.3) | **Answered by capture session 2 (LA-S2-1…3):** a 490 × 329 command-bar window at the screen's top-right (20 pt insets), growing to 1185 × 832 after load with the top-right fixed; every ⌥⌘N opens a new window at the first frame. Still open: whether 1185 × 832 is a fixed default or Arc's stored `LittleBrowserWindow_size` (one capture cannot tell), and the rule on other screen sizes. v1 uses fixed values and no autosave. | Step 6a |
| Q3 | Factory defaults: external-links-in-Little-Open on/off fresh, default destination fresh, Little Open auto-archive fresh. (§3.4, §10.4) | On / most-recent (via toggle logic) / 6h from the captured "(default)" labels. Needs a fresh-profile Arc check. | Steps 1, 7 |
| Q4 | Bundle id of the App target. This plan writes `app.open`. (§2.3, §8.2) | Keep whatever the App target already ships; substitute in §12. | Step 5 |
| Q5 | Unicode (non-punycode) host patterns do not match. (§5.1) | Accepted v1 limitation; revisit if Settings users hit it. | — |
| Q6 | Persist the decision log to disk for support? It holds clicked URLs. (§6.1) | Memory-only v1. | — |
| Q7 | Does manual close of a Little Arc window archive the page in Arc? (§9.3) | v1: no archive on manual close. | Step 6 |
| Q8 | Open-in-Space placement: Arc may offer pinned placement too. (§9.4) | v1: Today top only. The captured picker lists Spaces only, no sections (LA-S2-5), which agrees; where Arc puts the tab was not captured. | Step 6 |
| Q9 | Source-app rule picker: Arc's editor exposure is unverified (ATC-5). | Data carried end to end; no picker until a runtime check proves Arc has one. | Designer pass |
| Q10 | Does `docs/engine-api.md` (E1–E6, §7) match the real engine surface, especially E4 (modifier-aware navigation hook for Opt+Cmd-click)? | LA-4 ships only if E4 exists. | Step 6 |










## Appendix — Lead decisions (2026-10-25)

- Q1: read the macOS 26 SDK headers in Xcode 27.1 for the exact `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)` and AppleEvent sender attribute shapes; use what the SDK declares.
- Q2: start with 720×540 and the shared autosave frame; a later capture session will refine it.
- Q3: fresh-profile default destination for external links = Little Open (Arc's default per docs/re/features-advanced.md).
- Q4: app bundle identifier = `io.github.sergeserb2.open` (helpers: `io.github.sergeserb2.open.helper[.gpu|.renderer|.plugin|.alerts]`).
- Q10: waits for the OpenEngine API; Phase B owns it.
- Phasing: Phase A (Steps 1–4) now. Phase B (Steps 5–7) after the App target lands.

## Appendix — Lead decisions (2026-10-26, capture session 2)

These supersede the 2026-10-25 entries where they conflict. Evidence: §1 rows LA-S2-1…6; `docs/re/interaction-states.md` §20.10; `docs/re/capture-session-2-results.md` C15 and §2.8.

- Q2 superseded: Little Open first opens as a 490 × 329 command-bar window at the screen's top-right (20 pt from the right edge, 20 pt below the menu bar: y 50 on the capture display), then grows to 1185 × 832 after load with its top-right corner fixed. This replaces the 720 × 540 centered guess and the shared autosave frame.
- Each ⌥⌘N opens a **new** window at the same first frame. The blank-window reuse rule is removed; a same-press guard prevents the global hotkey and its menu twin from opening two windows for one key press.
- The page-state title bar is Arc's: window buttons, a URL capsule with the Profile chip, the centered host, and a copy-link button, then an "Open in \<Space\> ⌘O" pill with a chevron that opens a Space picker with "Search Spaces…". No back, forward, reload, URL text field, or toolbar row. ⌘O opens the page in the pill's Space.
