# First run — Welcome, Import from Arc, and default browser

Status: Steps A–D implemented. Steps E/F add background History through the shared App runner, real-App verification and Release timing. Passwords and cookies remain capability OFF; only the count probe runs. This file is the complete brief for the coding agent that implements it. That agent has no other context. Read this file top to bottom, then read each source it names before you edit that area. Do not invent a second design.

User-visible name rule: never use the Arc brand in UI text. "Little Arc" is "Little Open" in Open. The only exception is "Import from Arc" (`AGENTS.md`). Search aliases may keep old names.

Read first, in this order: `AGENTS.md`, `docs/architecture.md` (cold-launch budgets, §Performance budgets), `docs/plans/app-shell.md` §5 (startup sequence; this plan inserts into it, it does not replace it), `docs/model.md` (Import from Arc: sidebar, archive, session, history; secrets consent-gated; idempotency by stable ID), `docs/plans/import-phase2.md` (history reader, secrets crypto, consent token), `docs/plans/settings-library.md` §3.3 and §5.8 (the Settings import wizard — reuse its view models; this plan must not duplicate them), `docs/routing.md` and `docs/plans/routing-little-open.md` §8.4 (default-browser handling), `docs/re/features-core.md` §3.7 (what Arc loads on launch; first-run onboarding is out of scope there except: do not block the sidebar behind sign-in — Open has no account), `docs/re/features-advanced.md` §3.5 and LA-9 (Little Arc first-run education is a separate, later surface; do not build it here), `docs/design.md` (tokens), `docs/automation.md` (the automation channel).

Where this plan and a library doc disagree on that library's own API, the library doc wins and you stop and report the conflict. Where this plan and `docs/plans/settings-library.md` disagree on the import wizard's API, the settings plan wins and you stop and report the conflict.

## Goal

On the first launch of Open (no Open data root yet), show a short, calm three-step flow in its own window — Welcome, Import, Default browser — then land in the real browser window. The import reuses the Settings import wizard's view models and the existing `OpenImport` readers end to end: no second importer, no second consent path, no second default-browser call. A "Start Fresh" path skips the import and lands in the same real window with one default Space. Open replaces Arc's account sign-in with nothing: no sign-in screen, no account step, no "sign in later" text, anywhere in this flow.

## Success criteria

1. On a temp data root with no `State/browser.json`, the first window the user sees is the first-run window (§3), shown within the cold-launch budget: sidebar-equivalent first content ≤ 250 ms from process start on an idle M5 Pro release build (`docs/architecture.md`). Detection (§2) never blocks that window.
2. Welcome shows Open's own identity in one sentence and offers exactly two paths: "Import from Arc" and "Start Fresh". No other brand text, no sign-in, no account language. A `grep` gate (§12) proves it.
3. The Import step shows live counts from the §2 probe and three checkboxes — Spaces & tabs, Archive, History — plus Passwords & cookies as a separate row that starts OFF. Turning that row on opens a separate consent step (§5.4) that names the macOS Keychain prompt before any Keychain call and states the import can be done later from Settings. With consent not granted, the code touches no Keychain item (proven by the existing `SecretsImportConsent` token rule in `docs/model.md`, PR #24 corrections).
4. Import runs off the main thread where the readers allow it (§8). The progress UI names the current phase. The user lands in the real window as soon as sidebar + archive finish; history keeps importing in the background and the window stays fully usable (§5.5).
5. The Default browser step offers one button that runs the existing `SettingsActions.setAsDefaultBrowser()` path (`NSWorkspace`, routing plan §8.4). It never runs at launch, never runs without a click, and never blocks finishing. Already-default, declined, and failed outcomes each show their §6 state and still allow "Start Browsing" (the finish action) / "Not Now".
6. After finish, the real window shows the imported Spaces (or one default Space after Start fresh), the focused Space is the first imported Space (or the default Space), and exactly one tab is selected per restored window state, matching `ArcImporter`'s session mapping where it applied one.
7. Re-running the same import later from Settings (Settings → General → "Import from Arc…") adds zero duplicate Spaces, tabs, archive rows, and history visits (§7). The e2e suite proves this by running the import twice and comparing counts.
8. Every §6 error and empty state is reachable and matches its copy: no Arc data, Arc running with locked files, sidebar parse failure, partial import failure, Keychain denial, default-browser failure, snapshot save failure. A failed import never destroys the pre-import model (§6.4 rollback).
9. The synthetic-fixture e2e suite (§10) passes through the automation channel on a temp data root. No committed file, log, screenshot, or doc created by this work contains the user's real URLs, titles, or secrets. The real-data check (§10.4) prints counts only.
10. An Opus designer reviews the three screens against the §3.7 layout spec before merge. This plan fixes layout structure and spacing tokens only; it adds no new colors.

## Non-goals

- No account, login, sign-in, or sync UI, in any step, empty state, or error text (`AGENTS.md` locked decisions; `docs/re/features-core.md` §3.7 rule 25).
- No second import implementation. Sidebar, archive, session, history, and secrets all run through `OpenImport` (`ArcImporter`, `ArcHistoryReader`, `ArcSecretsReader`, `ChromiumCrypto`) behind the Settings wizard's `ImportPlan` / `runImport` action (`docs/plans/settings-library.md` §3.3, §5.8). If a needed piece is missing, add it to the owning library in that library's own step (§11) and report it; never copy reader code into the App target or into a first-run target.
- No new OpenKit library. First-run view model and views live in `OpenSettings` next to the wizard (§2.5); window glue lives in the App target.
- No Little Open intro / NUX (`docs/re/features-advanced.md` LA-9). That surface belongs to the Little Open milestone and shows on the first Little Open window, not here.
- No Easels, Notes, Arc Max AI, Top Sites, or site-engagement import (`docs/plans/import-phase2.md` §2: Top Sites and site engagement are deliberately not imported; Easels and Notes are skipped and counted).
- No secret storage. Until the engine password/cookie store lands (import-phase2 "Secret storage later"), the secrets path validates and counts only, and says so in the UI (§5.4). Never write secret bytes to Settings files, the snapshot, logs, or the first-run state file.
- No change to Arc data. Every Arc read is read-only (`AGENTS.md` rule 5). The probe and the readers copy a locked database to a private temp folder first (§2.4); they never open the live file and never write to the Arc folder.
- No unit tests (`AGENTS.md` rule 6). Verification is end to end through the automation channel (§10) and `settings-preview` renders (§11, Step A).

## 0. Locked decisions

| # | Decision | Why |
|---|---|---|
| D1 | First run is a separate window shown instead of the first standard window. When it finishes, it closes and the normal `showWindowsIfNeeded` path (`App/AppDelegate.swift`) builds the real window from the final model. | `docs/plans/app-shell.md` §5 T2 builds the real window from the snapshot before the engine starts. On first run there is no snapshot; showing the real (empty) window first and then replacing its model would flash an empty sidebar and double the window work. One window at a time keeps the launch budget and the user's focus. |
| D2 | "First run" means: at `prepareData()` time, `<data root>/State/browser.json` does not exist. Compute this once, before `OpenDataRoot.prepare` creates folders, and store it on `AppDelegate` as `isFirstRun`. Never recompute it after any save. | `AppDelegate.prepareData()` already loads through `SnapshotStore` and falls back to `makeDefaultModel()`. A saved default snapshot must not turn a mid-flow relaunch into a "not first run" (see D3), and a completed first run must never re-trigger. File existence is the durable signal; `UserDefaults` alone is not (a copied data root should still offer the import). |
| D3 | Completion is recorded by the successful `SnapshotStore.saveNow` of the post-flow model, plus one `UserDefaults` bool `open.firstRun.completed` (default `false`) written only after that save succeeds. If the process dies before the save, the next launch repeats the first-run flow with the still-default model. Never write the bool earlier. | Quit-mid-flow must not strand the user with an empty browser and no second chance to import. The snapshot is the real state; the bool only lets the automation channel and Settings distinguish "completed" from "has data" for diagnostics (§10). |
| D4 | Reuse the Settings wizard's types: `ImportPlan`, `ImportOutcome`, `SettingsActions.runImport(plan:)`, `setAsDefaultBrowser()`, `isDefaultBrowser()` (`docs/plans/settings-library.md` §3.3). The first-run flow builds an `ImportPlan` from its checkboxes and calls the same `runImport`. If `OpenSettings` has not landed when this work starts, land its Step 1 + the §5.8 wizard view model first (§11, Step A gate). Do not create parallel `FirstRunImportPlan` types. | The brief for this plan: reuse the wizard's view models; the first run must not duplicate them. One consent rule, one idempotency rule, one error vocabulary. |
| D5 | The default-browser step calls only `SettingsActions.setAsDefaultBrowser()` / `isDefaultBrowser()` (App-side `DefaultBrowserService`, routing plan §8.4, wrapping `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)`). Verify the macOS 26 SDK shape (async `throws` vs completion handler) from the SDK headers before writing the call, per routing plan Q1. Never prompt at launch; the call runs only from the step's button. | `docs/plans/app-shell.md` §4.4: "Never prompt at launch." The system prompt belongs to a user click. One service, shared with Settings General G-5 and the `set-default-browser` command. |
| D6 | Start fresh calls the existing `AppDelegate.makeDefaultModel()` (one `Profile(name: "Default")`, one untitled-default `Space`, one `BrowserWindowState`) and nothing else. Do not invent a different starter model, starter tabs, or a welcome tab. Imported welcome items are ordinary tabs (`docs/model.md`); a fresh start has no welcome tab. | `makeDefaultModel()` is the model every fallback path already uses. One definition of "default". |
| D7 | The secrets row is a separate consent step, not a checkbox that silently enables decryption. It starts OFF. ON opens §5.4; only the explicit "Allow and Import Secrets" button creates a `SecretsImportConsent.grantedByUser(reason:)` token (import-phase2 / PR #24 rule). "Skip Secrets" and Cancel create no token and touch no Keychain item. The button text and the step state that the same import can be done later from Settings. | Consent-gated is a hard rule from `docs/model.md` and the settings plan §5.8 Step 3. A pre-checked or one-click path would let a rushed user grant Keychain access without reading the prompt warning. |
| D8 | History import never blocks landing. Sidebar + archive are the landing gate; history runs as a background continuation after the real window exists (§5.5), with progress available in the Library/History surface and the first-run report reachable until it completes. Closing or finishing the flow never cancels a running history import; quitting the app mid-history is safe because batches are transactional and re-runnable (§7). | History is the only phase that can take seconds on a large profile (100k visits target < 3 s, `docs/plans/import-phase2.md` §1.13) and the only one the user gains nothing from watching. The window must be usable first. |
| D9 | All user-visible strings are exactly the strings in §4. Do not paraphrase them in code review. Any string change updates §4 in the same PR. | The implementer has no other context; drifting copy is how "Arc" brand text or sign-in language usually sneaks back in. |
| D10 | Layout uses `OpenDesign` tokens only (`docs/design.md` §2: `Metrics`, `WindowMetrics`, `SidebarColors` roles, SF Pro type scale). This plan names structure and spacing tokens; it defines no new color, font, radius, or icon. Where a needed token does not exist, use the system grouped-form default and leave a `// TODO(design): token` comment for the Opus design pass. | Brief for this plan: visual details follow OpenDesign tokens; an Opus designer reviews the screens before merge. New colors invented by an implementer would fail that review and the `docs/design.md` §8 ΔE targets. |

## 1. Current state (verified 2026-10-25; re-verify before you edit)

Do not trust this section blindly. Run `git log --oneline -3`, `ls App Packages/OpenKit/Sources`, and read the file you are about to change.

| Area | State today | Evidence |
|---|---|---|
| Launch | `App/main.swift` builds `OEApplication`, calls `appDelegate.prepareData()` (model + `OpenDataRoot.prepare` + lock), then `OEEngineConfiguration` + `OEEngine.shared.start`, then `runMessageLoop()`. `App/AppDelegate.swift` `prepareData()` loads via `SnapshotStore.load()`; on any failure it logs and uses `makeDefaultModel()`. Windows build at the first of `applicationDidFinishLaunching` / `engineDidInitialize` via the idempotent `showWindowsIfNeeded()`. | Read both files in full. |
| Default model | `AppDelegate.makeDefaultModel()`: `Profile(name: "Default", dataDirectoryName: "Default")`, `Space(title: "Space", profileID:)`, one standard `BrowserWindowState`. | `App/AppDelegate.swift:93`. |
| Data root | Default `~/Library/Application Support/Open/`; override `$OPEN_USER_DATA` or `--user-data-dir=DIR` (`App/LaunchOptions.swift`). `OpenDataRoot.prepare(root:model:)` takes the data-root `flock`, runs the profile-layout migration, and returns a retained `Preparation` token (`docs/model.md`, Data-root lock). | `docs/automation.md` Enable; `docs/model.md`. |
| Importer | `OpenImport.ArcImporter(arcDirectory:)` (default `~/Library/Application Support/Arc`). `@MainActor func importAll(directoryNamesToAvoid:existingDirectories:) throws -> ArcImportResult` returns `(model: BrowserModel, report: ImportReport, archiveRecords: [ArchivedTabRecord])`. `importModel()` is the sidebar-only convenience. Stable IDs: a UUID Arc ID keeps its UUID; a sentinel string ID gets a deterministic UUID (`ArcImporter.itemID(forArcID:)` / `spaceID(forArcID:)`). Throws only `ImportError.missingSidebar` / `.malformedSidebar`; one bad archive entry never fails the import. | `Packages/OpenKit/Sources/OpenImport/ArcImport.swift:4,75,81,87,134`. |
| Import report | `ImportReport` counts: `totalItems`, `profiles`, `spaces`, `pinnedTabs`, `todayTabs`, `favorites`, `folders`, `splits`, `routingRules`, `skippedEasels/Notes/Unknown`, `orphans`, archive counters (`archiveTotal/Imported/StoredNew/StoredDuplicates`, skipped-by-kind), session counters (`sessionAppliedSelections`, unmapped items/windows, ignored incognito). `accountedTotal` must equal `totalItems`; the CLI exits non-zero on mismatch. | `ArcImport.swift:4`; `docs/model.md` OpenImport. |
| Archive write | The importer returns records; the caller stores them: `ArchiveStore.importRecords(_:) -> (inserted, duplicates)` in one transaction, duplicate IDs keep the stored row. `ProfileArchiveSink` routes by profile (`AppDelegate` wires it). | `docs/model.md` ArchiveStore; `App/AppDelegate.swift:66`. |
| History (phase 2, done) | `ArcHistoryReader` copies `History` (+ WAL, or journal in rollback mode) into a private mode-700 dir, never copies SHM, opens only the copy, retries `quick_check` once after 200 ms, deletes the copy on every path. Meta versions 65–75 accepted. `HistoryStore.importHistoryBatch` writes one checked transaction per ≤ 5,000-visit batch; `history_import_keys` (`<profileDir>:<chromiumVisitID>`) makes re-import insert 0. Streaming overload keeps one batch in flight. | `docs/model.md` "Import from Arc, phase 2 (M8)"; `docs/plans/import-phase2.md` §1. |
| Secrets (phase 2, done, counts-only storage) | `ChromiumCrypto` + `ArcSecretsReader` parse logins, cookies, addresses, cards, form history in memory behind `SecretsImportConsent` (private init; one `grantedByUser(reason:)` factory; all six public APIs require the token). No Keychain API is called without the CLI's `--allow-keychain-access` equivalent consent; without consent the code counts rows only. No secret writer exists yet. | `docs/model.md` M8 + PR #24 corrections. |
| CLI import surface | `openkit import-arc [--arc-dir PATH] --out DIR`, `import-arc-history`, `import-arc-secrets --dry-run [--allow-keychain-access]`, `verify-secrets-fixture`. Counts/hosts only by default; `--show-titles` is the only titles flag and never goes into docs. | `docs/model.md` openkit CLI. |
| Settings wizard (planned, may not be landed) | `docs/plans/settings-library.md` §5.8 defines `ImportWizard.swift` (View + `ImportWizardViewModel`) as a 640×520 sheet on the Settings window: Step 1 Choose (checkboxes with live counts), Step 2 Review + progress, Step 3 Secrets consent (separate), Step 4 Report. State lives in `OpenSettings`; side effects go through `SettingsActions.runImport(plan:)`. `Packages/OpenKit/Sources/OpenSettings/` does not exist yet on this checkout. | Settings plan §3.2, §5.8; `ls Packages/OpenKit/Sources` (no `OpenSettings`). |
| Default browser (planned Phase B) | Routing plan §8.4 `DefaultBrowserService` + §8.2 `CFBundleURLTypes` http/https registration in `App/Info.plist`; bundle id `io.github.sergeserb2.open` (app-shell D7/§4.4). App-shell Step E lands it. Until then `setAsDefaultBrowser()` logs and succeeds (settings plan §3.3 rule: before the engine exists, engine calls log and return success — the same stub rule applies to the default-browser action until Step E lands). | `docs/plans/routing-little-open.md` §8; `docs/plans/app-shell.md` §4.4. |
| Automation | Socket at `<data root>/automation.sock` (0600), Debug always, Release only with `OPEN_AUTOMATION=1`. Client `tools/openctl`; suites in `tools/e2e/engine_e2e.py --only …`, each on a fresh data dir. Commands include `ping`, `tabs`, `spaces`, `space`, `open`, `select`, `snapshot`, `timing`, `save`, `quit`. | `docs/automation.md`. |
| Onboarding in Arc (what we replace) | Arc's first run led with sign-in (account) and product education ("Welcome / Arc 101"; §3.7: "First-run onboarding (Welcome/Arc 101) is out of scope except: do not block the sidebar behind sign-in"). Arc also shows a Little Arc NUX on the first Little window (LA-9) and an ad-blocker picker during onboarding (`AdBlockersSelection`, features-advanced AD-6 — Guess). Open keeps none of these: no sign-in (locked decision), no ad-blocker picker in first run (the Advanced pane owns lists), no Little Open NUX here. | `docs/re/features-core.md` §3.7 rule 25; `docs/re/features-advanced.md` LA-9, AD-6. |

## 2. Detection: is this the first run, and what does Arc hold?

### 2.1 Trigger

In `App/AppDelegate.swift`, `prepareData()`, before `OpenDataRoot.prepare` runs and before any `scheduleSave` can fire:

```swift
let browserJSON = root.appendingPathComponent("State/browser.json")
self.isFirstRun = !FileManager.default.fileExists(atPath: browserJSON.path)
```

- `isFirstRun` is a `private(set) var` on `AppDelegate`, set exactly once here. `showWindowsIfNeeded()` (§5.1) branches on it. Nothing else reads the file to decide.
- A root that exists but has no `browser.json` (for example a crashed first run, D3) is still first run. A root with a `browser.json` is never first run, even if the snapshot is the default model.
- Temp roots from `$OPEN_USER_DATA` / `--user-data-dir` follow the same rule. That is what makes the e2e suite (§10) a true first-run test.
- Add one launch override for measurement and support: `--skip-first-run` in `App/LaunchOptions.swift` (also honored as env `OPEN_SKIP_FIRST_RUN=1`). When set, `isFirstRun` is forced `false` and the default model path runs. Document it in the flag's comment as a test/support switch. `tools/e2e/engine_e2e.py --only measure` passes it so the 250 ms sidebar budget measures the steady-state shell, not this flow (app-shell §5 already budgets an existing profile).

### 2.2 Probe: estimate Arc counts without blocking the window

The probe answers four questions for the Import step: is there Arc data, roughly how much, is Arc running (lock risk), and how many secret rows exist (count only). It is read-only, off the main actor, and never opens a live SQLite file.

New file: `Packages/OpenKit/Sources/OpenImport/ArcProbe.swift` (in `OpenImport`, next to the readers it reuses; no AppKit import; `Sendable` throughout).

```swift
public struct ArcProbeResult: Sendable {
    public var arcDirectoryExists: Bool
    public var sidebarFound: Bool
    public var spaces: Int?          // nil = unknown (file missing or unparsable)
    public var sidebarItems: Int?    // pinned + today + favorites items, structural containers excluded
    public var archiveItems: Int?    // entries in StorableArchiveItems.json; nil = file absent
    public var historyVisits: Int?   // kept-visit estimate from the copied History DB; nil = absent/locked/failed
    public var secretRows: Int?      // login + cookie row count, no Keychain, no decryption; nil = files absent
    public var arcIsRunning: Bool    // informational only; never blocks (see §2.4)
}

public struct ArcProbe {
    public let arcDirectory: URL     // same default rule as ArcImporter
    public init(arcDirectory: URL? = nil)
    public func run() async -> ArcProbeResult   // call from a detached utility task
}
```

Probe steps, in order. Each step failure sets its own field to `nil` and continues; the probe never throws.

1. **Directory and sidebar presence.** `fileExists` on the Arc directory and on `StorableSidebar.json`. If the sidebar file is absent, return `sidebarFound = false` and all counts `nil` (the §6.1 no-data state). Do not stat the user's real path anywhere else.
2. **Sidebar estimate (fast, no model build).** Read `StorableSidebar.json` as `Data` and walk only the top shape the importer already defines: `sidebar.containers[1].spaces` (alternating `[id, object, …]`) for the Space count, and `sidebar.containers[1].items` length for the item count. Do not build a `BrowserModel`, do not map IDs, do not read titles or URLs into any log or result. This is a count of array entries, not an import; label it an estimate in the view model (`"Found: about N items"` copy rule, §4). If the JSON does not parse, `spaces`/`sidebarItems = nil` and `sidebarFound = true` (the file exists; the real parse error belongs to the import attempt, §6.3).
3. **Archive estimate.** If `StorableArchiveItems.json` exists, count its alternating-array entries (`count / 2`). Absent file → `nil` (the importer treats a missing archive file as "not imported", not an error).
4. **History estimate (copied DB, count only).** Reuse the phase-2 copy discipline exactly (`docs/plans/import-phase2.md` §1.9, as corrected in `docs/model.md`: copy `History` + `-wal` in WAL mode or `-journal` in rollback mode into a fresh mode-700 temp dir with mode-600 files, never copy `-shm`, open only the copy, `PRAGMA quick_check` must return `ok`, one 200 ms retry, delete the copy in all paths). Use the existing `ArcHistoryReader` streaming report and keep `keptVisits` as the estimate, as required by §10 F2. Do not return the raw table size: internal schemes, subframes, and invalid times must be filtered by the same reader as import. Any failure (missing file, schema outside 65–75, quick-check failure twice) → `historyVisits = nil`. Make no network request. Print nothing.
5. **Secret row counts (no Keychain).** Open copied `Login Data` and `Cookies` databases with the same copy rules and run `SELECT COUNT(*)` on `logins` and `cookies`. Sum them into `secretRows`. No `ChromiumCrypto` call, no consent token, no decryption. Expired/failed rows are still counted; the label is "passwords and cookies" (§4), not a promise of what will decrypt.
6. **Arc running (hint only).** The App target — not `OpenImport` — fills `arcIsRunning` after the probe returns: `NSWorkspace.shared.runningApplications` contains bundle id `company.thebrowser.Browser`. `OpenImport` never imports AppKit, so `ArcProbeResult.arcIsRunning` defaults `false` and the App overwrites it on the main actor. Running Arc never blocks the import: the copy-first rules exist precisely for this case. The flag only selects the §6.2 hint text.

Timeout: the whole probe is best-effort. The view model starts it in a `.utility` detached task at Welcome appearance and cancels it when the flow is dismissed. If no result has arrived when the user reaches the Import step, the step shows its counts as "Counting…" (§4) and fills them in when the probe lands; the checkboxes and both footer buttons work before any count arrives. The probe must never delay `showWindow` (§8).

For tests, the probe takes the same injectable `arcDirectory` as `ArcImporter`, and `App/LaunchOptions.swift` gains `--arc-dir=PATH` (test/support only; normal launches always use the default Arc path). `tools/openctl` suites pass `--arc-dir` pointing at the §10 fixture. Never point a committed test at the user's real Arc folder.

### 2.3 Where the probe result lives

`FirstRunViewModel` (§2.5) holds `probe: ArcProbeResult?` (`nil` = still counting). Views read it; they never call `ArcProbe`, `FileManager`, or SQLite themselves. The App target creates the view model with the resolved Arc directory (launch option or default) and starts the probe.

### 2.4 Locked-file rule (applies to probe and import alike)

Arc may be running and holding its files. The rule for every read in this plan:

- JSON `Storable*.json` files: read the bytes directly (they are replaced atomically enough for a count and for the importer's lenient parse; a torn read surfaces as the §6.3 parse state, never as a crash).
- SQLite files (`History`, `Login Data`, `Cookies`, `Web Data`): never open the live path. Always the private-copy flow above. If the copy still fails `quick_check` after one retry, that data kind reports "could not be read" (§6.2) and the rest of the import proceeds.
- Never write to, lock, or delete anything inside the Arc folder. Temp copies live under `FileManager.default.temporaryDirectory` with the phase-2 naming and are deleted on success and failure.

### 2.5 Code layout

New target: none. New files, exactly these:

```text
Packages/OpenKit/Sources/OpenImport/
  ArcProbe.swift                 §2.2 count-only probe (OpenImport; no AppKit)
Packages/OpenKit/Sources/OpenSettings/
  FirstRun.swift                 FirstRunViewModel + FirstRunView + step views (§3)
                                 (same file rule as the wizard: view model first, views second)
App/FirstRun/
  FirstRunWindowController.swift NSWindow owner; hosts FirstRunView; no import logic
  AppFirstRunActions.swift       App glue: probe start, runImport hand-off, default-browser
                                 hand-off, finish/start-fresh model swap (§5)
App/Automation/AutomationController.swift   (edit) add the `first-run` command (§10.2)
App/LaunchOptions.swift        (edit) --arc-dir, --skip-first-run
App/AppDelegate.swift          (edit) isFirstRun, first-run branch in showWindowsIfNeeded
App/main.swift                 (edit only if the §5.1 ordering needs the deferred engine start;
                                 follow app-shell §5.1 T2/T3, do not fork the sequence)
tools/e2e/engine_e2e.py        (edit) --only firstrun suite (§10.3)
Packages/OpenKit/Sources/settings-preview/main.swift
                               (edit) render first-run screens (§11 Step A)
```

`FirstRunViewModel` shape (define in `FirstRun.swift`; `@MainActor @Observable final class`). It must reference the wizard's types, not redefine them — if `OpenSettings` does not yet define `ImportPlan`, `ImportOutcome`, or `ImportWizardViewModel`, stop: land settings-library Step 1 and the §5.8 view model first (§11 Step A gate), then write this file against them.

```swift
@MainActor @Observable public final class FirstRunViewModel {
  public enum Step: Sendable { case welcome, importChoices, secretsConsent, importing, defaultBrowser, report, failed }
  public var step: Step = .welcome
  public var probe: ArcProbeResult?            // nil while counting
  public var arcIsRunning = false              // App fills from NSWorkspace (§2.2 step 6)
  // Import choices — the same four toggles the wizard exposes (§5.8 of the settings plan).
  public var includeSpacesAndTabs = true
  public var includeArchive = true
  public var includeHistory = false
  public var includeSecrets = false            // starts OFF (D7); ON routes to .secretsConsent
  public var phaseText = ""                    // current import phase, for the progress UI
  public var progress: Double?                 // nil = indeterminate (all phases except history)
  public var outcome: ImportOutcome?           // set when runImport returns
  public var errorText: String?                // §6 inline errors; set, never thrown to the view
  public var isDefaultBrowser = false          // refreshed on entering .defaultBrowser
  public weak var actions: (any FirstRunActions)?  // App implements; preview logs (§11)
}
```

History starts unchecked and secrets start unchecked, matching the wizard (settings plan §5.8: History OFF, secrets box OFF and OFF means skip). Spaces & tabs and Archive start checked. At least one of the three main checkboxes must be on for "Import" to enable; secrets alone also enables it (it routes through consent first).

`FirstRunActions` is the seam the App implements and `settings-preview` fakes with a logger, in the style of `SettingsActions`. Define it in `FirstRun.swift`; every method is `@MainActor`; no method throws to the view model — failures come back as user text:

```swift
public protocol FirstRunActions: AnyObject {
  func runImport(plan: ImportPlan) async -> ImportOutcome   // same action Settings uses (D4)
  func setAsDefaultBrowser() -> String?                     // nil = started OK; else error text
  func isDefaultBrowser() -> Bool
  func finishFirstRun(imported: Bool)                       // App: swap model if needed, save, close, open real window (§5.6)
}
```

`runImport` and the two default-browser methods are the `SettingsActions` methods of the same names. The App's conformance forwards to the one implementation; do not write a second `runImport` body for first run. The preview fake logs `ACTION runImport spaces=<bool> archive=<bool> history=<bool> secrets=<bool>` and returns a canned `ImportOutcome` built from the synthetic fixture.

## 3. Screens and flow

### 3.0 Flow map

```text
Welcome ──"Import from Arc"──▶ Import (checkboxes) ──[secrets ON]──▶ Secrets consent ──▶ Importing (progress) ──▶ Report ──▶ Default browser ──▶ real window
   │                                │──[secrets OFF]──────────────────────────────────────▶ Importing ──▶ Report ──▶ Default browser ──▶ real window
   └──"Start Fresh"────────────────────────────────────────────────────────────────────────────────────────────────────────────▶ real window (default Space)
Import ──"Not Now"──▶ Default browser ──▶ real window (default Space)
Any step ──window closed / app quit──▶ nothing saved; next launch repeats first run (D3)
Secrets consent ──"Skip Secrets"──▶ Importing (without secrets)      ──"Cancel"──▶ back to Import
Importing ──sidebar import fails──▶ Failed (§6.3) ──"Try Again"──▶ Importing      ──"Start Fresh Instead"──▶ real window
Default browser ──"Not Now"──▶ real window (no system prompt, no state change)
```

Rules that hold on every step: one window, no sheets except the failure alert in §6.3 if the design pass prefers it (default: inline, no sheet); the close button stays enabled and quitting mid-flow is always safe (D3); Escape does nothing (this is not a dismissible panel); no step ever shows a spinner without phase text after 0.5 s.

### 3.1 Window

- One `NSWindow` owned by `App/FirstRun/FirstRunWindowController.swift`, created once by `AppDelegate` when `isFirstRun` is true. Style: `[.titled, .closable, .miniaturizable, .fullSizeContentView]`, `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, title `"Open"` (accessibility and automation), `isRestorable = false`, `tabbingMode = .disallowed`, centered on the main screen at first show. Content: one `NSHostingController` hosting `FirstRunView` (SwiftUI is allowed here — low-frequency panel, `docs/architecture.md`).
- Size: 560 × 520 pt, not resizable. Rationale: it must hold the longest §4 strings without truncation at the system font and stay clearly a welcome surface, not a browser window. The Opus design pass (§3.7) may adjust the size once; code reads it from one constant `FirstRunWindow.size` so the change is one line.
- It is the key window on show. It never becomes a browser window, never appears in `BrowserModel.windows`, and is excluded from the snapshot and from `windows` automation output for standard windows (it reports its own class so §10 can assert it is gone after finish).
- Show order: §5.1. The window is built and shown before `CefInitialize` returns (app-shell T2 rule), with the Welcome step already rendered and the probe running.

### 3.2 Step 1 — Welcome

Content, top to bottom: Open app icon (our own artwork, `NSApp.applicationIconImage`; never Arc art), wordmark "Open", the one-sentence identity, the two path buttons, and the counting line.

- Identity sentence (§4 W-2): one sentence, Open's own identity, no Arc brand, no feature list, no sign-in.
- Primary button: "Import from Arc". It is enabled even before the probe finishes and even when the probe later reports no data — the §6.1 state lives on the Import step, so the user always gets a clear explanation instead of a dead button on Welcome.
- Secondary button: "Start Fresh". One click, no confirmation: builds the default model (D6), saves, closes this window, opens the real window. If the save fails, stay on Welcome and show the §6.5 save error inline.
- Counting line: while `probe == nil`, show the §4 counting text in the secondary text style; when the probe lands, replace it with the found-summary (§4 W-3/W-4) or the no-data line (W-5). The line is informational only; it never gates the buttons.
- If no Arc data exists at all (`sidebarFound == false`), Welcome still shows both buttons ("Import from Arc" leads to the §6.1 explanation with its own "Start Fresh" and "Choose Folder…" exits). Do not hide the import path based on a probe guess.

### 3.3 Step 2 — Import (checkboxes)

Shown when the user chooses "Import from Arc". Content: heading, the Arc-running hint (only when `arcIsRunning`), three checkbox rows, the secrets row, the footer.

- Each checkbox row: checkbox, label (§4), and a found-count line from the probe (`"Found: N Spaces"`, `"Found: N archived tabs"`, `"Found: N visits"`; `"Counting…"` while that field is `nil`; `"Not found"` when the backing file is absent). Counts are estimates (§2.2) and are labeled as found counts, never as promises.
- Rows: Spaces & tabs (spaces, pinned and today tabs, favorites, folders, routing rules — the importer's sidebar unit; it cannot be split further, and the help text says so), Archive, History. History's help text states it can be imported later from Settings, so an unchecked History is never a dead end.
- Secrets row: separate from the three, visually grouped under its own subheading (§4 I-6). It is a checkbox that starts OFF. Checking it does not enable anything by itself: on "Continue" the flow goes to §3.4 first. Unchecking it after consent returns to the plain path. The row's help text names passwords and cookies and says macOS will ask for permission on the next step.
- Footer: "Back" (to Welcome), "Not Now" (skip import entirely → §3.5 with the default model), "Continue" (primary; disabled until at least one checkbox including secrets is on). "Continue" with secrets OFF goes straight to §3.6 progress; with secrets ON goes to §3.4.
- No Arc data (`sidebarFound == false`): replace the checkbox area with the §6.1 empty state (explanation + "Choose Folder…" + "Start Fresh"). "Choose Folder…" opens an `NSOpenPanel` (folders only) and re-runs the probe against the chosen folder; a good folder restores the checkbox state. This is the same folder override the wizard uses (`open.import.lastArcDir` stores the path only; never log titles).
- If the sidebar file exists but did not parse into counts (`spaces == nil` with `sidebarFound == true`), keep the checkboxes enabled and show the §6.3 parse-hint line. The real error, if any, comes from the import attempt, where it can be reported precisely.

### 3.4 Step 3 — Secrets consent (only when the secrets row is on)

A separate step, never a dialog bolted onto the checkbox. Content: heading, what will be read (passwords, cookies, addresses, payment cards — named plainly), the Keychain warning, the do-it-later line, and three buttons.

- The Keychain warning (§4 S-3) states, before any Keychain call: macOS will show a Keychain prompt; choose Allow to continue; Open reads the Arc Safe Storage key once and never asks again in this run (import-phase2: read the key one time). It also states the current limit honestly: until the browser engine can store secrets, this step checks and counts only and copies nothing (§5.4). Do not promise imported passwords in this release.
- Buttons: "Allow and Import Secrets" (primary; creates the consent token and continues to §3.6 with `secretsConsented == true`), "Skip Secrets" (continues to §3.6 with secrets off; the other checkboxes still import), "Cancel" (back to §3.3, secrets row stays checked so the user can reconsider). Closing the window here is the D3 safe quit.
- Denial is not known until the run (the system prompt appears during `runImport`). A denied or failed Keychain read lands in the §6.6 report state; it never blocks the non-secret import and never re-prompts in the same run.

### 3.5 Step 5 — Make Open your default browser

Shown after the import report (or directly after "Not Now" / Start-fresh-with-import-skipped paths that still want the offer — exactly: shown on every path that reaches the end of the flow except a mid-flow quit). Content: heading, one sentence on what "default" means (links from other apps open in Open; Little Open routing note from routing LA-11 kept to one line), the state line, and the buttons.

- On entry, set `isDefaultBrowser = actions.isDefaultBrowser()`. If already default, show the already-default line (§4 B-3) and make the primary button "Start Browsing" (finish); no system call is made.
- Primary button "Make Open your default": calls `actions.setAsDefaultBrowser()` once. Non-nil return → show the error text inline (§6.7) and keep both buttons live. Nil return → re-read `isDefaultBrowser()`; if now default, show B-3 and switch the primary button to "Start Browsing"; if still not default (user declined the system prompt), show the declined line (§4 B-4) once — do not loop the system prompt.
- Secondary button "Not Now": finish with no call and no state change. Either finish path calls `finishFirstRun(imported:)` (§5.6), which saves and opens the real window. This step is an offer, never a gate: no path through this step can fail the first run.

### 3.6 Importing (progress) and Report

One progress view serves the import and, after it, a report view summarizes the outcome before §3.5.

- Progress: determinate bar only during history (visits done / probe estimate); indeterminate otherwise. Phase text (§4 P-1…P-4) always names the current phase: sidebar, archive, history, secrets check. The view has no Cancel button (batches are short and transactional; a half-import is safe and re-runnable, §7 — a Cancel that pretends to undo would lie). The window stays closable (safe quit, D3).
- Landing gate: when sidebar + archive complete, the model swap and snapshot save happen (§5.5) and the real window opens behind this window; the first-run window stays front with the progress view until history (and the secrets check, if consented) finishes or fails. The user can click into the real window at once — sidebar, tabs, search, and navigation all work; only History results grow as batches land.
- Report: counts per kind from `ImportOutcome` (imported, duplicates, skipped by kind, the archive accounted check), plus one line per failed kind (§6). Buttons: "Continue" (to §3.5). If everything failed, the primary button is "Try Again" (back to §3.3 with choices intact) and "Continue" becomes the secondary (to §3.5 on the default model). Never show titles, URLs, usernames, or secret values in the report — counts and hosts only is the project rule; this view shows counts only, not even hosts.

### 3.7 Layout and design tokens (review round 1)

All roles and metrics come from the OpenDesign Settings group and Settings controls. These are Open layout choices, not measurements of source-browser onboarding.

- Window: 560 × 520 pt. Horizontal inset 32 pt; bottom 28 pt. Welcome top inset 28 pt; steps 2–6 top inset 36 pt. Step C must verify title-bar clearance in a real-window capture.
- Welcome: 80 pt icon frame (about 64 pt ink for the application icon), 16 pt gap, `firstRunWordmark` (28 pt semibold), 8 pt gap, centered identity (380 pt maximum), 24 pt gap, two centered 240 × 28 pt buttons with an 8 pt gap, 16 pt gap, centered status. Save error is centered at a maximum width of 380 pt.
- Default buttons use the prominent SettingsButtonStyle: control accent fill and white label while key, normal gray while inactive. Other buttons use the normal style. Height 24 pt, radius 6 pt; Welcome alone uses 28 pt height.
- Import and Report are top-left forms. Pin the heading and footer; scroll only the middle, with automatic indicators. The separate Passwords box has no repeated subheading. Back stays on the left; primary stays on the right. The failed footer is Back / Start Fresh Instead … Try Again.
- Sparse Passwords, Default browser, Failed and Progress steps center their content above the footer, text maximum width 400 pt. Use a 64 pt app icon for Default browser/Progress or a 40 pt secondary SF Symbol for Passwords/Failed. Visual-to-heading gap 16 pt, heading-to-body and body-to-note gaps 8 pt. Progress bar is 320 pt wide, centered; landing note gap 12 pt.
- Report rows show failures in red in the count column, as `Could not be read`. History not requested is `Not selected`. There is one summary note: error or skipped kinds, without a duplicate Passwords footnote.
- Section text uses `SettingsTokens.section`; secondary text uses `SettingsTokens.secondary`. Step changes cross-fade at `Motion.selectionFade`, or cut with Reduce Motion. No sound.
- Controls use their copy as accessibility labels. Return triggers the default button; the progress bar exposes phase text. Verify real-window keyboard order and key/inactive styling in Step C.

## 4. Copy — final English strings

Use these strings exactly (D9). Short and plain. "You" is the user. The source-browser name is allowed in “Import from Arc” and inside the import flow. Welcome status contains no other brand. No string mentions accounts, signing in, or sync. Counts use `.formatted()` with the probe/outcome value (`%d` below denotes a localized, grouped number); use the singular noun for 1; when a count is unknown the string is the "Counting…" or "Not found" variant, never a guessed number.

### 4.1 Welcome

| ID | String |
|---|---|
| W-1 | `Open` (wordmark and window title) |
| W-2 | `Open is a fast, private browser that keeps your Spaces, tabs, and history on this Mac.` |
| W-3 | `Found data to import: %d Spaces, about %d tabs.` (probe landed, `sidebarFound == true`) |
| W-4 | `Checking for data to import…` (probe running) |
| W-5 | `No data found to import on this Mac.` (probe landed, `sidebarFound == false`) |
| W-6 | `Import from Arc` (primary button) |
| W-7 | `Start Fresh` (secondary button) |

### 4.2 Import step

| ID | String |
|---|---|
| I-1 | `Import from Arc` (heading) |
| I-2 | `Choose what to bring into Open. You can import again later from Settings. Nothing here changes your Arc data.` |
| I-3 | `Spaces & tabs` (checkbox) — help: `Spaces, pinned and today tabs, favorites, and folders. These come together.` — found: `Found: %d Spaces` |
| I-4 | `Archive` (checkbox) — help: `Tabs you closed or archived.` — found: `Found: %d archived tabs` |
| I-5 | `History` (checkbox) — help: `Pages you visited. This can take a little longer. You can also do this later from Settings.` — found: `Found: %d visits` |
| I-6 | `Passwords and cookies` (separate checkbox, disabled while capability is OFF) — help: `Saved passwords, cookies, addresses, and cards. macOS will ask for approval on the next step. You can also do this later from Settings.` — found: `Found: %d saved items` |
| I-7 | `Arc is open right now. Open can still import. If anything is missing, quit Arc and import again from Settings.` (only when `arcIsRunning`) |
| I-8 | `Back` / `Not Now` / `Continue` (footer buttons) |
| I-9 | `Counting…` (a found line while its count is `nil` and the probe is running) |
| I-10 | `Not found` (a found line when the backing file is absent) |
| I-11 | `No Arc data found at %@.` (empty state; `%@` is the folder path) — body: `Open looked for the files Arc keeps on this Mac and did not find them. You can pick a different folder, or start fresh.` — buttons: `Choose Folder…`, `Start Fresh` |

### 4.3 Passwords consent step

These strings, S-5, and both I-6 help variants come from the shared `PasswordsImportCopy` used by the Settings import wizard. The capability is OFF in this build. Its checkbox is disabled and excluded from selection; the OFF consent screen is rendered only as a copy reference. First run does not keep a second copy.

| ID | String |
|---|---|
| S-1 | `Passwords and cookies can't be imported yet.` (capability OFF) |
| S-2 | `Open found %d saved items in Arc. Open didn't read or copy them.` (capability OFF); singular: `Open found 1 saved item in Arc. Open didn't read or copy it.` |
| S-3 | `Import passwords and cookies from Arc?` (capability ON) |
| S-4 | `Open will read the passwords, cookies, addresses, and cards Arc saved on this Mac. To unlock them, Open needs Arc's key from your Keychain. macOS will ask for your approval. If you choose Deny, Open reads nothing and imports everything else.` (capability ON) |
| S-5 | `You can skip this step and do it later from Settings.` |
| S-6 | `Continue Without Passwords` / `Cancel`; `Import Passwords and Cookies` appears only with the capability ON |

Additional count/status strings: `Could not be read` (a present file failed); `Import data found. Choose what to bring into Open.` (Welcome with an uncountable sidebar); `Open found the sidebar file, but could not count it. You can try the import or choose a different folder.` (Import hint); `Passwords and cookies can't be imported yet. You can continue without them and import later from Settings.` (capability OFF checkbox help). The default-browser note is `Little Open follows your link routing settings.`

Unknown-count Passwords body (shared with the wizard): `Open didn't read or copy passwords or cookies. You can continue without them.`

### 4.4 Progress and report

| ID | String |
|---|---|
| P-1 | `Importing your Spaces and tabs…` |
| P-2 | `Importing your archive…` |
| P-3 | `Importing your history…` |
| P-4 | `Checking passwords and cookies…` |
| P-5 | `Your browser is ready. History is still importing in the background.` (once the real window is open behind) |
| R-1 | `Import complete` (heading) |
| R-2 | `%d Spaces, %d tabs, %d archived tabs imported.`; omit any failed kind. Singular example: `1 Space, 1 tab, 1 archived tab imported.` If every summary kind failed: `Import finished.` |
| R-3 | `%d items were already in Open and were not copied again.` (duplicates line; shown only when > 0); singular: `1 item was already in Open and was not copied again.` |
| R-4 | `Continue` (report primary); all-failed footer: `Back`, `Start Fresh Instead`, `Try Again` |

### 4.5 Default browser step

| ID | String |
|---|---|
| B-1 | `Make Open your default browser` (heading) |
| B-2 | `Links from other apps will open in Open. You can change this any time in Settings.` |
| B-3 | `Open is your default browser.` (already default, or after a successful set) |
| B-4 | `Open is not your default browser yet. You can set it later in Settings.` (declined or still not default after the call) |
| B-5 | `Make Open your default` (primary) / `Not Now` / `Start Browsing` (finish, shown once B-3 applies) |

### 4.6 Errors and empty states (full text in §6)

| ID | String |
|---|---|
| E-1 | `Open could not read your Arc data.` — body: `The import stopped before it changed anything in Open. You can try again, or start fresh.` — buttons: `Back`, `Start Fresh Instead`, `Try Again` |
| E-2 | `Your Spaces and tabs are in. %d history visits could not be read. You can import history later from Settings.` (partial: history failed after landing) |
| E-3 | `Keychain access was not granted. No passwords or cookies were read. You can try again later from Settings.` |
| E-4 | `Open could not be set as your default browser. You can try again in Settings.` |
| E-5 | `Open could not save your data. Your imported items are still open in the browser window behind this panel. Try again.` (imported path); `Open could not save your data. Try Start Fresh again.` (fresh path) |
| E-6 | `Skipped: 2 Easels` (example); combines nonzero kinds in order: `%d Easels`, `%d Notes`, `%d unsupported items`; singular: `Skipped: 1 Easel` / `1 Note` / `1 unsupported item` |

Report row labels, in order: `Spaces`, `Pinned and Today tabs`, `Favorites`, `Folders`, `Archive`, `History`, `Search engine`, `Passwords and cookies`. Values: the imported count, `Not selected`, `Not imported`, or red `Could not be read`. Partial found totals append ` (partial)` when at least one source profile could not be counted. Only one report note appears (E-2, E-3, E-5 or E-6).

Count grammar also uses `Found: 1 Space`, `Found: 1 archived tab`, `Found: 1 visit`, `Found: 1 saved item`, and `Found data to import: 1 Space, about 1 tab.` Report row labels are category names; both flows use `Search engine`. The Settings Choose help is `Imports your search engine choice only.` Partial-success E-2 text is secondary; failed cells remain red.

## 5. How the flow runs

### 5.1 Startup integration (normative order)

This plan inserts into `docs/plans/app-shell.md` §5.1; the T-labels below are that plan's.

| Phase | First-run change |
|---|---|
| T0 `main.swift` | Unchanged: `OEApplication.shared`, `LaunchTiming.mark("main")`, `ApplePersistenceIgnoreState`, delegate, `keyEquivalentHandler`. No file I/O. |
| T1 data root | `prepareData()` gains the D2 `isFirstRun` computation (one `fileExists`) before `OpenDataRoot.prepare`. Model load behavior is unchanged (absent file → default model). Mark `modelLoaded` as today. |
| T2 first window | If `isFirstRun`: build and show the first-run window (§3.1) and start the §2.2 probe in a detached utility task. Do not build standard windows yet. If not first run: app-shell T2 unchanged. Set `LaunchTiming.mark("sidebarDrawn")` after the first-run window's first display on the first-run path — the budget measures "first content", and on first run this window is the first content. |
| T3 engine start | Unchanged timing (next main-runloop turn after T2). The engine must start even while the first-run window is up: landing (§5.5) creates web content for the selected tab only, and the default-browser action needs no engine but the finished window does. Cold-launch external URLs queued by the routing intake stay queued until the real window exists (app-shell §4.4 rule), then flush. |
| T4 first page | On the first-run path, T4 happens inside `finishFirstRun` (§5.6): after the real window shows, create the host for the selected tab only. |
| T5 lazy systems | Unchanged, and never started for the first-run window: no `HistoryStore`, `FaviconStore`, Boost, ad-block, or sleep work runs until the real window exists. The probe (§2.2) is the only background work in the first-run window, plus the import itself once started. |

Quit order is unchanged (app-shell §5.3). If the user quits during first run, `saveState()` must not save the in-memory default model over the absent snapshot in a way that marks the run complete: before `finishFirstRun` has run, skip `snapshotStore.saveNow` for the default model (guard on a `firstRunFinished` flag on `AppDelegate`; the debounced `scheduleSave` gets the same guard). This is what makes D3 true.

### 5.2 Welcome → Import

`FirstRunWindowController` hosts the view; `FirstRunViewModel.step` drives which step view shows. Choosing "Import from Arc" sets `step = .importChoices`. Choosing "Start Fresh" calls `actions.finishFirstRun(imported: false)` directly (§5.6). The probe result may land at any point; views observe `probe` and update found lines without rebuilding the step.

### 5.3 Building the ImportPlan

On "Continue" (and on the consent step's primary button), the view model builds exactly one `ImportPlan` (wizard type, D4):

| First-run control | `ImportPlan` field (settings plan §3.3/§5.8) |
|---|---|
| Spaces & tabs | spaces-and-tabs toggle |
| Archive | archive toggle |
| History | history toggle |
| Secrets row + consent result | secrets toggle + `secretsConsented` (`true` only from the §3.4 primary button) |
| Arc folder (default or "Choose Folder…") | Arc directory URL |

If the landed wizard's `ImportPlan` does not have a field for one of these, add the field to `ImportPlan` in `OpenSettings` (the owning library) in the same PR and note it; do not wrap or subclass the plan for first run. The App's `runImport(plan:)` implementation — shared with Settings — does the actual work in §5.4 order. First-run code never calls `ArcImporter`, `ArcHistoryReader`, or `ArcSecretsReader` directly.

### 5.4 Import execution (inside `runImport`, shared with Settings)

The App-side implementation behind `SettingsActions.runImport` runs these phases in order. First run and Settings share this body; the first-run progress UI observes its phase callbacks (the App exposes phase/progress through the `FirstRunActions` seam as view-model assignments — implement as an `@MainActor` callback the action invokes, not as polling).

1. **Sidebar + archive (landing gate).** Build the importer for the plan's Arc directory. Because `ArcImporter.importAll` is `@MainActor` and builds a live `BrowserModel`, call it on the main actor after the progress view is already on screen; the parse of a real profile is small (tens to thousands of items) and must not start before the window is interactive. If Spaces & tabs is OFF, skip the model build and keep the current model. Then, per target profile, store `archiveRecords` via `ArchiveStore.importRecords` (one transaction per profile file, duplicate-safe) and fill `archiveStoredNew/Duplicates` in the report. Failures here are §6.3/§6.4. Phase text P-1, then P-2.
2. **Model swap + first save (still the landing gate).** §5.5. After this phase returns, the real window exists and the user can browse.
3. **History (background).** For each imported (or existing) profile with a matching Arc profile directory, stream `ArcHistoryReader`'s awaited batch consumer into that profile's `HistoryStore.importHistoryBatch` (≤ 5,000 per transaction; counts recomputed from visits; `history_import_keys` dedupe). Never hold more than one batch plus the URL map in memory (phase-2 reader rule). Phase text P-3 with determinate progress. Failure is §6.2/E-2: sidebar stays, history retries later from Settings.
4. **Secrets check (only when `secretsConsented`).** Create the consent token inside this phase (never earlier, never stored), then `validateWithKey`-style counting/validation through `ArcSecretsReader` with borrowing callbacks that copy nothing. Store nothing. Phase text P-4. Denial/failure is §6.6/E-3. Without consent this phase does not run and no Keychain symbol is called — the PR #24 external-compile rule is the model: the code path must not even construct the token.

`ImportOutcome` (wizard type) carries the counts the §3.6 report renders: per-kind imported/duplicates/skipped, the archive accounted check result, and `errorText` per failed kind. If the landed `ImportOutcome` cannot express a per-kind failure, extend it in `OpenSettings` in the same PR (report the extension); do not encode failures as magic count values.

### 5.5 Model swap and landing

- If Spaces & tabs imported: replace `AppDelegate.model` with the imported `BrowserModel` as one swap on the main actor. Before the swap, the only model is the default from `prepareData()` — there is no user state to merge on the first-run path. Rewire the same observers `prepareData()` installs (`archiveSink`, `undoManager`, `scheduleSave` observer, `ScriptHost` providers if landed) onto the new model; copy that wiring into one `installModel(_:)` helper used by both `prepareData()` and the swap, so the two paths cannot drift. The Settings path (model already populated) does **not** swap: it merges (§7).
- Write the snapshot with `snapshotStore.saveNow(model:)`. Only after it succeeds: set `open.firstRun.completed = true` (D3), clear the §5.1 save guard, and call the normal window path so the real window builds from the imported model (imported Spaces, session selection). A save failure is §6.5: stay in the flow, model stays in memory, nothing is marked complete.
- Focus: the first window focuses the imported model's focused Space and its `selectedNodeBySpace` selection (session mapping). If the session file applied no selection, select the first Today tab of the first Space; if that Space has no tabs, select its first pinned tab; if it has neither, show the Space empty with the command bar available (Cmd+T). Never select more than one tab, never create a tab the import did not contain.

### 5.6 Finish paths and `finishFirstRun(imported:)`

One App-side method ends every path:

- `imported: true` (import landed): the swap + save of §5.5 already ran; this method closes the first-run window and ensures the real window is key.
- `imported: false` (Start fresh, Not now, all-failed Continue): ensure the model is the default model (D6 — it already is, unless a partial model swap somehow ran; assert, do not rebuild user state), `saveNow`, set the completed bool, clear the save guard, close the first-run window, build the real window.
- Default-browser finish (B-5 "Start Browsing" / "Not Now"): same as above with whichever `imported` value the earlier phases produced.

After the real window shows, flush any queued cold-launch external URLs through the routing intake (app-shell §4.4) and start the T5 lazy systems. The first-run window controller is released; reopening Open never shows it again (D2).

## 6. Error and empty states

Every state below is reachable from the flow and has an automated check in §10 where the automation channel can reach it. No state shows a raw Swift error, a file URL list, a title, or a URL. Log detail goes to stderr with counts only (project privacy rule).

| # | State | When | UI (copy from §4.6) | Recovery |
|---|---|---|---|---|
| 6.1 | No Arc data | Probe: Arc directory or `StorableSidebar.json` absent; also after "Choose Folder…" picks a folder without the sidebar file | Import step empty state (I-11) with the looked-in path | "Choose Folder…" re-probes a picked folder. "Start Fresh" finishes on the default model. Welcome's W-5 line sets expectations before the step. |
| 6.2 | Arc running / locked files | `arcIsRunning`, or a copied SQLite DB fails `quick_check` twice | I-7 hint when running (import proceeds). If History (or a secrets DB) still cannot be read from the copy: that kind reports failed; history case shows E-2 in the report | Proceed with the kinds that read. Quit Arc and re-import the failed kind later from Settings. Never ask the user to quit Arc before trying — the copy path exists for this case. |
| 6.3 | Sidebar parse failure | `importAll` throws `missingSidebar` / `malformedSidebar`, or the snapshot accounted check fails | Failed step (E-1): "The import stopped before it changed anything in Open." Primary "Try Again", secondary "Start Fresh Instead" | Nothing was swapped or saved, so Try Again re-runs from the same choices (for example after choosing a different folder on the Import step). Start Fresh finishes on the default model. |
| 6.4 | Partial import failure | Sidebar landed; archive store, history, or secrets phase failed | Report (R-1) with the failed kind named by its E-2/E-3/E-6 line and its count of skipped items; successful kinds keep their counts | Continue to §3.5. Each failed kind is re-runnable alone from Settings (same `ImportPlan` with only that toggle on). Rollback rule: a failed phase never rolls back a landed phase, and a failed import never deletes or rewrites the pre-import snapshot — on the Settings path the old snapshot stays authoritative until a new `saveNow` succeeds (§7). |
| 6.5 | Snapshot save failure | `saveNow` throws during §5.5/§5.6 (disk full, lock held by a second Open process) | E-5 inline on the current step; the flow does not advance and the completed bool is not written | "Try Again" retries the save with the in-memory model intact. If the data-root lock is held by another Open process, `OpenDataRoot.prepare` has already failed at launch (`AppDelegate` exits with the lock error) — that is an app-launch failure, not a first-run state; do not add a second message for it. |
| 6.6 | Keychain denied or secrets read failed | Consent granted, then the system prompt is denied, or decryption validation fails for all rows | E-3 in the report (and the secrets line of the report shows "not imported") | Non-secret kinds are unaffected. No re-prompt in this run. The user can retry from Settings, which asks for consent again there. |
| 6.7 | Default-browser failure | `setAsDefaultBrowser()` returns error text, or Open is still not default after the call | E-4 inline (error return) or B-4 (declined/still-not-default). Finish buttons stay live | Finish normally. Retry lives in Settings General G-5. Never loop the system prompt. |

Rollback summary (one rule for implementers): the importer builds a new model off to the side; the swap happens once, on the main actor, only after the build succeeds; the snapshot is written once per finish; any failure before the swap leaves the previous model and the previous on-disk snapshot untouched. There is no partial-swap state to roll back from.

## 7. Idempotency — first run and Settings share one rule

Re-running an import must not duplicate. The mechanisms already exist; this plan adds the merge rule for the Settings path and proves both in §10.

- **Stable IDs.** Arc UUID IDs keep their UUID; sentinel IDs map through `deterministicUUID(for:namespace:)` (`ArcImport.swift`). The same Arc item always becomes the same Open item.
- **Archive.** `ArchiveStore.importRecords` keeps the stored row on duplicate ID and reports `(inserted, duplicates)`. A second full import inserts 0.
- **History.** `history_import_keys` (`<profileDir>:<chromiumVisitID>`) plus count recomputation from `visits`: a second import inserts 0 visits and counts do not double (phase-2 §1.12 MUST gate).
- **Sidebar merge (Settings path).** When `runImport` runs against a populated model, merge the imported model into the live one by ID: a Space whose ID already exists keeps the live Space (order, theme edits, profile assignment) and gains only imported items whose IDs are absent; a tab whose ID already exists anywhere in the model is counted as a duplicate and not re-inserted; new Spaces append after existing ones. Implement the merge inside the App's `runImport` (it owns both models) using `BrowserModel` commands only — if a needed command does not exist, add it to `OpenModel` following `docs/model.md` command rules (one undo step, precise `TreeChange` events) in the same PR and say so. The imported model itself is never mutated by the merge.
- **Archived sidebar items.** A tab or Favorite whose stable ID is already a row in the target Profile's ArchiveStore is also already in Open. Query candidate IDs off the main thread, in one batch per Profile before the synchronous merge, and pass the resulting ID sets into `mergeImportedSidebar`. Re-import never brings those archived items back; live-ID rules stay unchanged.
- **Today activity.** Every Today tab newly added by first run or a Settings merge gets `lastActiveAt` set to the import time. The normal auto-archive threshold starts then. Existing live duplicates, pinned tabs and Favorites keep their activity times. Arc data remains unchanged.
- **First-run path.** No merge: the pre-import model is the untouched default, so §5.5 swaps. If the user somehow imported, quit before finishing, and relaunches (still first run by D2, default model again), the swap path runs again and archive/history dedupe makes the repeated writes free. There is no state where first run merges into an imported model.
- **Secrets.** Counts-only (D-non-goal); nothing stored, so nothing can duplicate. When engine secret storage lands, it must dedupe by origin + username at the store API; that is that milestone's gate, not this plan's.
- **Default browser.** `isDefaultBrowser()` is read fresh on step entry; setting an already-default browser is a no-op success (B-3). No state accumulates.

## 8. Performance

Budgets (`docs/architecture.md`, release, M5 Pro, idle machine): first content ≤ 250 ms, first web paint of the restored tab ≤ 700 ms. The first-run window is the first content on this path (§5.1 T2).

| Rule | Detail |
|---|---|
| Window first | `showWindow` for the first-run window happens in T2 with only the Welcome view built. The probe, any JSON read, and any SQLite copy happen after first display, off the main actor (`.utility` detached task). No `FileManager` enumeration of the Arc folder beyond the named files in §2.2. |
| Probe cost | Sidebar/archive estimates are single-file reads of files that are small in practice; history/secrets estimates are one copied-DB `COUNT(*)` each. The probe has no deadline that blocks UI; late results just fill in (§2.2). Measure it in the §10 suite: probe completion on the synthetic fixture < 1 s, and `timing` first-content mark within budget with the probe running. |
| Import threading | `importAll` is `@MainActor` (it builds the live model) — call it only after the progress view is interactive, and never from the Welcome step. History batches run off the main actor through the reader's awaited batch consumer (one 5,000-visit transaction at a time); progress callbacks hop to the main actor. Archive writes run on the stores' serial queues. Secrets validation runs off the main actor with borrowing callbacks. No `Task.detached` for UI work (app-shell §2.4 rule 7) except the probe, which touches no UI. |
| Landing before history | §5.5 swap + save + real window happen after sidebar + archive only. The §10 suite asserts the real window exists and accepts an `open` command while a large-fixture history import is still running. |
| No launch network | No favicon fetch, no list download, no suggestion fetch during first run (app-shell §5.2). The probe and import make no network requests (import-phase2 hard rule 7). |
| Idle cost | No timers in the first-run window. The probe is one-shot; progress updates are event-driven. After finish, first-run objects are released (§5.6). |

## 9. Persistence registry (every key this plan adds; no others)

| Key / file | Type | Default | Written when |
|---|---|---|---|
| `open.firstRun.completed` (`UserDefaults`) | Bool | `false` | Only after the finish `saveNow` succeeds (D3). Read by diagnostics/automation only; the flow trigger is D2 file existence. |
| `open.import.lastArcDir` (`UserDefaults`) | String (path) | none | On a successful import finish when the Arc folder was not the default (same key the wizard uses, settings plan §2.1). Path only; never logged with data. |
| `<root>/State/browser.json` | snapshot | — | The finish save (imported or default model). No first-run-only fields are added to the snapshot; `schemaVersion` stays 1. |
| Per-profile `State/history.sqlite3`, `State/archive.sqlite3` | SQLite | — | Written by the existing stores during import, through their normal paths. |

No `first-run.json`, no step-progress file, no "last shown step" key: a mid-flow quit restarts at Welcome by design (D3), and the flow is three steps.

## 10. Acceptance through the automation channel

No unit tests. All checks drive the real app through the socket (`docs/automation.md`) on a temp data root, plus `settings-preview` renders for layout (Step A). Never drive the desktop. Never use the user's real Arc data in a committed fixture, screenshot, or log line.

### 10.1 Synthetic Arc fixture (build it in the suite; commit only the builder)

`tools/e2e/engine_e2e.py --only firstrun` builds a fixture Arc folder under the suite's temp dir (mode 700, deleted after the run; the builder code is committed, the data is not):

```text
<fixture>/StorableSidebar.json          2 Spaces ("Alpha", "Beta"), 3 pinned tabs, 2 today tabs,
                                        1 favorite, 1 folder, 1 easel (skipped), 1 welcome item
<fixture>/StorableWindows.json          1 window focused on Space 1
<fixture>/StorableLinkRouting.json      1 hostContains rule -> most recent Space; default Little Open
<fixture>/StorableArchiveItems.json     3 entries (1 manual, 1 auto, 1 easel skipped)
<fixture>/User Data/Default/History     SQLite, meta version 70: 6 visits (3 kept, 1 internal scheme,
                                        1 subframe, 1 invalid time) — reuse the phase-2 F1 shape
<fixture>/User Data/Default/Login Data  1 login row (synthetic, example.com)
<fixture>/User Data/Default/Cookies     2 cookie rows (example.com)
```

Every URL is `example.com` / `example.org` / `example.net`. Every title is synthetic ("Example …"). Build the SQLite files with the system `sqlite3` in Python at suite start (the phase-2 CLI fixtures prove the shape); build the JSON from Python dicts following `docs/re/data-model.md` alternating-array shapes. A second, larger history fixture (5,000 visits) backs the §8 landing check; generate it the same way, no committed binary.

### 10.2 New automation surface (minimal)

Add exactly one command in `App/Automation/AutomationController.swift`:

| Command | Args | Result |
|---|---|---|
| `first-run` | — | `{ "active": Bool, "step": String, "completed": Bool }` — whether the first-run window is up, the view model's current step name, and the D3 bool. Before the window exists and after it closes: `active: false` with the last known step, or step `none` on a non-first-run launch. |

Everything else uses existing commands: `tabs`, `spaces`, `space`, `open`, `wait`, `timing`, `snapshot`, `save`, `quit`, and `key` (drive the flow's buttons by accessibility label through `key`/AX where the harness already supports it; if a button cannot be reached, add the smallest `first-run` action arg — `first-run action=import|fresh|continue|…` — and document it in `docs/automation.md` in the same PR; do not add per-button commands).

Launch wiring: the suite starts the app with `--user-data-dir=<temp root> --arc-dir=<fixture>` (new LaunchOptions in §2.5) and `OPEN_USER_DATA` pointing at the same temp root. First suite run per temp root is a first run by D2; the suite quits and relaunches on the same root to prove the flow does not repeat.

### 10.3 Suite checks (`--only firstrun`; all must pass)

| # | Check | Proves |
|---|---|---|
| F1 | Fresh temp root + fixture: launch → `first-run` reports `active: true, step: welcome`; `snapshot` PNG saved for the designer review | §3.1, §5.1 T2 |
| F2 | Probe lands: Welcome found line shows the fixture counts (2 spaces). Open the Import step: found lines show 2 spaces / 3 archived / 3 kept-visit estimate (probe counts kept visits only after filtering — assert the number the probe contract produces, not the raw table size) | §2.2 |
| F3 | Import with Spaces & tabs + Archive on, History off, Secrets off → report counts match the fixture; `spaces` shows Alpha/Beta; `tabs` shows the imported tabs with the session selection; easel counted skipped, welcome item present as a tab | §5.4, §5.5, success criteria 6 |
| F4 | Continue → default-browser step: with the stubbed action (pre-Step-E builds log-and-succeed) assert the step shows B-3 after the call, or B-2 + buttons before it; finish → `first-run` `active: false`; real window present; `quit` + relaunch same root → `first-run` `active: false`, imported Spaces still present | §3.5, §5.6, D2/D3 |
| F5 | Second run of the same import from the model level: invoke Settings-path `runImport` again (or relaunch with a wiped `open.firstRun.completed` but the same populated root — use whichever seam the implementation exposes; the counts are the assertion): new archive rows 0, new history visits 0, duplicate counts equal the first run's imported counts, no duplicate tab IDs in `tabs` | §7 |
| F6 | Start-fresh path: new temp root, Welcome → "Start Fresh" → real window with exactly 1 Space (the default), 0 imported tabs; relaunch does not repeat the flow | §3.2, D6 |
| F7 | No-data path: `--arc-dir` points at an empty folder → Import step shows I-11; "Start Fresh" finishes; no crash; stderr contains no titles | §6.1 |
| F8 | Locked-file path: fixture History held open by a background writer (the phase-2 WAL technique) during import → sidebar lands, history either imports from the copy or reports E-2; the app stays responsive (`ping` answers during import) | §6.2, §8 |
| F9 | History landing: 5,000-visit fixture, History on → real window accepts `open url=https://example.org` and `wait` succeeds before history progress completes; after completion, a command-bar history query (existing `open` + suggest surface, or `first-run` outcome counts) shows the imported visits counted once | §5.5, D8 |
| F10 | Secrets path: checking Passwords & cookies routes to the consent step (step name asserted); "Skip Secrets" imports the rest; a fake-keychain counter in the preview harness (Step A) proves zero Keychain calls without consent. On the real app, do not grant real Keychain access in automation; the consent-then-counts path is covered by the existing `verify-secrets-fixture` CLI check staying green | §3.4, D7 |
| F11 | Mid-flow quit: launch fresh root, reach the Import step, `quit` without finishing → relaunch shows `step: welcome` again and the root still has no completed snapshot from the flow | D3, §5.1 save guard |
| F12 | Timing: `timing` first-content mark ≤ 250 ms median of 5 on an idle machine (report loaded-machine numbers as upper bounds only); first paint of the selected imported tab ≤ 700 ms after finish | §8 |
| F13 | Copy gate: `grep` the built app's first-run strings (and this plan's §4) — no "Arc" outside "Import from Arc", no "Little Arc", no "sign in"/"account" in flow copy (§12 gate 4) | AGENTS.md naming |

Screenshots: save Welcome, Import, Secrets consent, Progress, Report, and Default browser PNGs (`snapshot` on the first-run window, then the real window) next to the suite JSON under the existing results convention. They are review artifacts for the Opus designer, from the synthetic fixture only, and are not committed if the results folder is git-ignored — follow the existing suite convention and state it in the PR.

### 10.4 Real-data dry run (manual, counts only, never committed)

Once per implementation (and in the PR description as counts only): run the release `openkit` CLI read-only against a **copy** of the live Arc JSON files and History, exactly as `docs/model.md` verification does — `openkit import-arc --arc-dir <copy> --out <temp root>`, `import-arc-history`, `import-arc-secrets --dry-run` (no `--allow-keychain-access`). Acceptance: sidebar accounted check passes, archive accounted check passes, history repeat inserts 0, secrets report shows counts with "keychain: not requested". Then optionally launch the real app once against a **temp** Open root with `--arc-dir` at the copied folder and walk the flow by hand. Delete the temp roots. Paste only counts into the PR. Never launch against the user's real Open root for this check, never commit the output, never paste `--show-titles` output anywhere.

## 11. Implementation order (small PRs; each step: files, then acceptance)

Work in order. A step starts only when the step before it passes. Every PR: merge `origin/main` first, run `tools/verify-all.sh`, paste its summary table into the PR (`AGENTS.md` rule 10). One library target per PR where the table says so; `Package.swift` merge conflicts keep both sides. No step adds a unit test.

| Step | Work | Files | Acceptance |
|---|---|---|---|
| A. Wizard dependency + preview renders | Gate: `OpenSettings` exists with `ImportPlan`, `ImportOutcome`, `SettingsActions`, and the §5.8 `ImportWizardViewModel` (settings-library Steps 1–7 cover this; if they have not landed, land settings Step 1 + the wizard view model first as its own PR under that plan). Then add `FirstRun.swift` (view model + step views, §3) with the fake-actions logger, and render the six screens in `settings-preview`. No App wiring yet. | `Packages/OpenKit/Sources/OpenSettings/FirstRun.swift`, `Packages/OpenKit/Sources/settings-preview/main.swift` (edit) | `settings-preview render` writes the six first-run PNGs (Welcome, Import, Secrets, Progress, Report, Default browser) at 1x/2x from the synthetic fixture; the fake action log shows `ACTION runImport … secrets=false` for the skip path and zero Keychain calls. Opus designer reviews these PNGs before Step C starts (fix layout in this step; colors stay tokens). |
| B. Probe | `ArcProbe` (§2.2) with the copy-first count reads; wire no UI. Verify through a throwaway `/tmp` probe binary or the `openkit` CLI style the repo already uses — do not add a permanent CLI command unless the settings wizard needs the same counts (it does: §5.8 Step 1 "live counts" — share this probe there instead of a second counter). | `Packages/OpenKit/Sources/OpenImport/ArcProbe.swift` | Probe against the §10.1 fixture (built by hand under `/tmp` for this step) returns the exact counts; probe against an empty folder returns `sidebarFound = false`; probe against the WAL-locked fixture still returns history counts from the copy. Runtime on the fixture < 1 s. |
| C. First-run window (no import yet) | `isFirstRun` (D2), `--skip-first-run` / `--arc-dir`, the §5.1 save guard, `FirstRunWindowController`, `AppFirstRunActions` with Start fresh + finish wired (`finishFirstRun(imported: false)`), Welcome step live with probe counts. Import buttons navigate steps but `runImport` still forwards to the Settings stub. | `App/AppDelegate.swift`, `App/LaunchOptions.swift`, `App/main.swift` (if needed), `App/FirstRun/*` | Manual + automation smoke: fresh temp root shows Welcome within budget (`timing`), Start fresh lands in the real window with one default Space, relaunch does not repeat, mid-flow quit repeats (F11 by hand). `--only shell` still passes. |
| D. Import + report + landing | The shared `runImport` body (§5.4 phases 1–2: sidebar, archive, model swap via `installModel(_:)`, save), progress + report steps, §6.3/§6.4/§6.5 states. Settings General G-6 calls the same body (wire it if the Settings window exists; otherwise prove the body through first run and note the Settings hook as pending that plan's Step 8). | `App/FirstRun/AppFirstRunActions.swift`, App `SettingsActions` conformance file (per settings plan §3.4 placement), `App/AppDelegate.swift` (`installModel`) | Suite F1–F7 pass. Accounted checks pass on the fixture. A sidebar-corrupt fixture lands on E-1 with the default model untouched. |
| E. History background + secrets check | §5.4 phases 3–4: streamed history import after landing with progress, secrets consent → token → counts-only validation, §6.2/§6.6 report lines. Depends on routing Step E only for the real default-browser service; the stub is fine here. | Same action files; `OpenSettings/FirstRun.swift` (progress/report wiring) | Suite F8–F10 pass. `verify-secrets-fixture` still green. The 5,000-visit landing check (F9) passes; the window answers `ping` throughout. |
| F. Default-browser step + hardening | §3.5 against the real `DefaultBrowserService` when app-shell/routing Step E has landed (verify the SDK shape first, D5); otherwise keep the log-and-succeed stub and name the gap in the PR. Full suite, timing medians, `tools/verify-all.sh`. | `App/FirstRun/*`, `docs/automation.md` (document `first-run` command) | Suite F1–F13 pass including F12 medians on an idle machine. The real-data dry run (§10.4) is pasted as counts in the PR. Designer re-reviews the real-app PNGs from the suite. |

If the app shell (app-shell plan) has not landed when Step C starts, the "real window" in the acceptance lines is whatever `showWindowsIfNeeded` builds today (the M1 shell); the flow, swap, and save behavior are identical. Do not block this plan on the shell rewrite, and do not build a second window controller here.

## 12. Global acceptance gates (every PR)

1. `tools/build.sh Debug` and the step's suites pass. Release build for the timing step (F).
2. `tools/verify-all.sh` summary pasted in the PR. SKIP only for targets that do not exist yet.
3. No new unit tests. No third-party dependency without a written reason in the PR.
4. Swift 6 strict concurrency clean: no warnings. `grep` the diff for `Arc` in user-visible strings (allow "Import from Arc" and search aliases only), for `Little Arc` (same rule), for "sign in" / "account" in flow copy, and for any copied Arc asset. The probe and import diff must contain no `print`/log of a title, URL, username, or secret value.
5. Performance: no step may regress the app-shell `measure` marks by more than 10 % without naming it in the PR. The first-run path is measured separately (F12); the steady-state path must stay on the `--skip-first-run` budget.
6. Privacy: every fixture, screenshot, and PR paste uses `example.com`-family hosts and synthetic titles only. Real-data output is counts only and the temp roots are deleted (§10.4).

## 13. Risks and open questions

These do not block Step A. Each names its default. Implementers: build the stated default; do not invent another answer.

| # | Question | Default in this plan | Decide by |
|---|---|---|---|
| Q1 | Has `OpenSettings` (with `ImportWizardViewModel`, `ImportPlan`, `ImportOutcome`) landed when this work starts? | No on this checkout. §11 Step A is a hard gate: land the wizard view model under the settings plan first. | Step A |
| Q2 | `ArcImporter.importAll` is `@MainActor`. On a very large profile (thousands of items), could the main-actor parse hitch the progress window? | Accept for v1: the parse runs after the progress view is interactive, real profiles are small, and the model build must be on the main actor anyway. If F12 or manual testing shows a hitch, the fix is a lenient background pre-parse in `OpenImport`, proposed as its own change — never a copied parser in the App. | Step D |
| Q3 | macOS 26 SDK shape for `setDefaultApplication(at:toOpenURLsWithScheme:)` (routing Q1). | Read the SDK headers at Step F; use what they declare. Until then the action logs and succeeds (settings plan stub rule) and §3.5 still shows its states against the stub. | Step F |
| Q4 | Window size 560 × 520 and the one-sentence identity (W-2) are Open choices, not measured Arc values (Arc's onboarding is not being cloned; §1). | Ship them; the Opus design review (§3.7) may change the size once via `FirstRunWindow.size` and may re-word W-2 within the §4 rules (one sentence, no brand except the button, no sign-in). Any change updates §4 in the same PR. | Step A review |
| Q5 | When the engine secret store lands, the secrets step's S-4 line ("copies nothing") becomes false. | That milestone updates S-4 and the §5.4 phase-4 body to store through the engine APIs (never Chromium SQLite directly, import-phase2 decision) and adds a stored-count line to the report. This plan's consent flow does not change. | Engine secret-store milestone |
| Q6 | Should "Not Now" (skip import) still show the default-browser step? | Yes (§3.5: every completed path shows it once). It is one extra click, it is the only moment most users will ever be asked, and Settings remains the retry path. | Step F review |

The landed importer resolves sidebar references plus unused profile metadata. Its `sourceProfileDirectories` mapping is authoritative for History; source directory names remain separate from collision-safe Open destination names. This replaces the former Q7 default.

## Appendix — evidence index (for reviewers; implementers do not need to re-derive)

- No sign-in in first run: `AGENTS.md` locked decisions ("Open has no Arc account, login, or sync"); `docs/re/features-core.md` §3.7 rule 25 ("do not block the sidebar behind sign-in — Open has no account"). Arc's Welcome/Arc 101 onboarding is named there and in §3.5 rule 18 (`showCommandBarOnNewlyCreatedWindows`, onboarding string) — Open replaces it with §3 of this plan.
- Import scope and idempotency: `docs/model.md` OpenImport (stable IDs, archive `importRecords` duplicates, accounted checks), phase-2 M8 section (copied-DB history reader, `history_import_keys`, consent token, counts-only secrets), PR #24 corrections (consent required by all six secret APIs; probe with `kSecUseAuthenticationUIFail` before any prompt; counts-only output).
- Wizard reuse: `docs/plans/settings-library.md` §3.3 (`SettingsActions.runImport(plan:)`, `ImportPlan`, `ImportOutcome`), §5.8 (wizard steps, History OFF default, secrets box OFF, "macOS will show a Keychain prompt. Choose Allow to continue.", "A failed import keeps the old snapshot.").
- Default browser: `docs/plans/routing-little-open.md` §8.4 (`DefaultBrowserService`, `NSWorkspace`), LA-11 ("Only the external-link entry point needs default-browser status… Settings must say so next to the toggle" — §3.5 B-2 is that line, shortened), `docs/plans/app-shell.md` §4.4 ("Never prompt at launch").
- Startup and budgets: `docs/plans/app-shell.md` §5.1 (T0–T5, window before `CefInitialize`, `sidebarDrawn` mark), `docs/architecture.md` Performance budgets (250 ms / 700 ms, M5 Pro, idle).
- Little Open NUX excluded: `docs/re/features-advanced.md` LA-9 (`LittleBrowserNUXView`, first Little window) — a Little Open milestone surface, not first run.

## Appendix — Lead decisions (2026-10-25)

- Approved. Implementation starts after the Settings + Library PR (OpenSettings wizard types) and app-shell Steps A + B merge; Step A of this plan re-checks those types first.
- `importAll` main-actor hitch: move any work over O(100) items off the main actor; measure with the largest fixture.
- Window size and W-2 wording: decided by the Opus design review of the rendered screens.


### Execution decisions (2026-10-25 user brief)

Implement Steps A and B now, then stop. The designer reviews all six screen pairs before Step C. This overrides the earlier Step-A design gate before B and the app-shell prerequisite for A/B. Build only with `nice -n 10 swift build -c release -j 6` in Packages/OpenKit. The user's naming rule removes the source-browser name from Welcome status lines; it remains allowed inside the import flow. The shared Settings Passwords copy and capability gate override the older S-strings and button names above. No real data or Keychain access is needed for A/B. Steps C–F, real-window automation and launch timing remain pending.

### Review round 1 decisions (2026-10-26)

The user approved the round-1 copy changes in §4 and the 560 × 520 pt size. The unavailable Passwords checkbox is disabled in both flows. Capability-ON consent still requires an explicit allow action; previews never invoke it. Both flows share the importer’s Archive filters and complete profile metadata merge. Readable per-profile History and saved-item counts survive another profile’s failure, marked partial. These corrections override the older raw-Archive count and secrets-only navigation instructions above. The utility probe remains model-free; Steps C–F remain outside this PR.

### Review round 2 decisions (2026-10-26)

Prominent style now covers all Settings default buttons and standalone sheet renders inherit the app’s base Settings style. Count strings use `.formatted()` with singular forms; R-2 omits failed kinds. Import row heights are minimums. The default-browser status has a fixed slot. Welcome with no data or a fresh save error makes Start Fresh the accent/default action. Step C entry criteria in docs/first-run.md record save retry/window-behind copy, real progress appearance/animation, and traffic-light clearance; no code for those criteria lands in A/B.
