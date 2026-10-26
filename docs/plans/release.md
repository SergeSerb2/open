# Release — implementation plan for Open

Status: plan for implementation. Implementer: follow this file top to bottom.
Do not spawn subagents (AGENTS.md rule 8). Do not write unit tests (rule 6).
Verify end to end only: real builds, real signing, real app launch.
This file is the complete context. The implementer has no other context.
If a fact in this file conflicts with a real file in the repo, in
`~/Developer/open-engine`, or in the Chromium source tree, stop and report
the conflict. Do not redesign silently.

Product facts that never change in this plan:

- Product name (user-visible): **Open**. Bundle ID: `io.github.sergeserb2.open`.
- Platform: macOS 26+, arm64 only, Swift 6 + AppKit. Engine: our own
  Chromium 156.0.8078.48 fork with the CEF 8078 embedding layer.
- The Swift shell talks only to `OpenEngine`. Packages never import CEF.
- User-visible text never uses the Arc brand. Exception: "Import from Arc".
- Never copy Arc assets or code. Learn facts from Arc only (sizes, keys,
  behaviors). Every asset in the release is Open-owned or system-provided.

How to use this plan:

1. Work the steps in §11 in order. Steps marked **[USER]** need a credential
   or a consent action from the user (§10). Do every other step first.
2. Each step lists exact files, exact content or commands, and acceptance
   checks. A step is done only when every check passes. Paste real command
   output into the PR description. Do not claim a check you did not run.
3. Write ONLY the files listed in §12, plus the version edits in §8. Do not
   edit engine feature code, `Packages/OpenKit` feature logic, or the
   Chromium tree, except for the one Step 10 packaging patch in §2.6.
4. Long jobs (engine builds) run in their own session so an app restart does
   not kill them (AGENTS.md rule 9). §2.4 gives the exact wrapper. Never
   start a long job as a bare background `&` job.
5. No CI exists and none is added. The whole release runs on the lead's Mac
   through one script, `tools/release.sh` (§9). GitHub is file hosting only.

Authoritative inputs. Read these before you start:

- [architecture.md](../architecture.md) — module borders, performance budgets.
- [engine-fork.md](../engine-fork.md) and [plans/fork-infra.md](fork-infra.md)
  — fork pins, GN args, scripts, Step 10 gate. This plan owns signing,
  notarization, DMG, and updates, which fork-infra §0.2 puts out of scope.
- [engine-spike.md](../engine-spike.md) — measured bundle sizes and the
  "Open Safe Storage" Keychain item (§0.2 below).
- [followups.md](../followups.md) — pre-release license review list (§7 below).
- `project.yml`, `tools/build.sh`, `tools/embed-cef.sh`, `App/Info.plist`,
  `App/Open.entitlements`, `Helper/Info.plist`,
  `Helper/Entitlements/*.entitlements` — the current app build.
- [re/bundle-anatomy.md](../re/bundle-anatomy.md) — how Arc 1.170.0 ships
  (Sparkle feed, helpers, entitlements). Facts only. Do not copy assets,
  bundle IDs, feed URLs, keys, or fonts from Arc.
- Chromium source tree (READ ONLY):
  `~/Developer/open-engine/chromium_git/chromium/src`. Entitlement sources:
  `chrome/app/app-entitlements.plist`,
  `chrome/app/app-entitlements-chrome.plist`,
  `chrome/app/helper-gpu-entitlements.plist`,
  `chrome/app/helper-renderer-entitlements.plist`, and the CEF binary
  distribution README at
  `cef/binary_distrib/cef_binary_156.0.14+g4fa4ab5+chromium-156.0.8078.48_macosarm64_minimal/README.txt`
  in that tree.

---

## 0. Current state (verified 2026-10-25; re-check at Step 1)

| ID | Fact | Evidence |
|---|---|---|
| C-1 | Marketing version `0.1.0`, build `1`, in `project.yml` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`). `App/Info.plist` maps them to `CFBundleShortVersionString` / `CFBundleVersion`. | `project.yml` base settings |
| C-2 | Local builds are ad-hoc: `CODE_SIGN_IDENTITY: "-"`, `CODE_SIGN_STYLE: Manual`, `DEVELOPMENT_TEAM: ""`, `ENABLE_HARDENED_RUNTIME: NO`. The `project.yml` comment already says release needs a Developer ID identity, Hardened Runtime, and per-helper entitlements. | `project.yml` base settings |
| C-3 | Bundle IDs today use the `app.open` prefix: app `app.open.browser`, engine `app.open.engine`, helpers `app.open.browser.helper` + `.gpu` / `.renderer` / `.plugin` / `.alerts`. The lead's final IDs use `io.github.sergeserb2.open` (fork-infra Appendix, `Engine/fork/branding/README.md`). Release must migrate the IDs (§4.1) before any Developer ID signing, because the Team ID + bundle ID pair is baked into signatures, Keychain access, and Sparkle checks. | `project.yml`; `Engine/fork/branding/README.md` |
| C-4 | Five helper apps exist: `Open Helper`, `Open Helper (GPU)`, `Open Helper (Renderer)`, `Open Helper (Plugin)`, `Open Helper (Alerts)`. `tools/embed-cef.sh` copies the CEF framework plus all five into `Open.app/Contents/Frameworks/` and ad-hoc signs only what it copied. | `project.yml` `CEFHelper` template; `tools/embed-cef.sh` |
| C-5 | Current entitlements. App (`App/Open.entitlements`): device audio-input, camera, location, bluetooth, usb, print — no code-signing (CS) exceptions. Helpers: generic and GPU `allow-jit` only; Renderer `allow-jit` + `allow-unsigned-executable-memory`; Plugin `allow-unsigned-executable-memory` + `disable-library-validation`; Alerts empty. | `App/Open.entitlements`; `Helper/Entitlements/*.entitlements` |
| C-6 | Upstream Chromium mac entitlements in this tree: app gets device entitlements only (audio-input, bluetooth, camera, print, usb, location, photos-library); GPU and Renderer helpers get `allow-jit` only. Google Chrome adds a second app file with Keychain groups (`*.webauthn`, `*.webauthn-uvk`, `*.secure-payment-confirmation`) and restricted developer entitlements. CEF's distrib README requires the framework, `icudtl.dat`, and the V8 snapshot, and marks locale `.lproj` folders and SwiftShader as optional. | Read-only reads in §0 header |
| C-7 | Bundle size, Release, stock CEF: `Open.app` 329 MB with all locales; 279 MB with `OPEN_KEEP_LOCALES="en"`. Parts: CEF binary 226 MB, 220 locale folders 50 MB, `resources.pak` 20 MB, `icudtl.dat` 10 MB, `Libraries/` 16 MB (SwiftShader). | [engine-spike.md](../engine-spike.md) §Bundle size |
| C-8 | Release GN args are checked in: `Engine/fork/gn/release.args.gn` = `is_official_build=true`, `symbol_level=1`, `chrome_pgo_phase=2`, `use_thin_lto=true`, `proprietary_codecs=true`, `ffmpeg_branding="Chrome"`, `enable_widevine=false` (lead decision: Widevine out of v1, needs a Google license). Dev args stay `is_official_build=false`, `chrome_pgo_phase=0`. Release out dir: `out/Release_Official_arm64`. Dev out dir: `out/Release_GN_arm64`. | `Engine/fork/gn/*.args.gn`; `Engine/fork/VERSIONS` |
| C-9 | PGO: `engine-bootstrap` sets `checkout_pgo_profiles=True`. The revision-matched profile named by `chrome/build/mac-arm.pgo.txt` is not downloaded. The engine lead must fetch it before Step 2; this is tracked in `docs/followups.md`. `engine-build --config release` already refuses to run `gn gen` when the profile is missing. | fork-infra §5.2, §6.5; live tree listing |
| C-10 | Step 10 gate is real: `engine-distrib --config release` stops with `release packaging not wired yet: CEF's make_distrib expects out/Release_GN_arm64`. Both `cef/tools/make_distrib.py` (`Release` + `_GN_arm64`) and `automate-git.py` (`get_build_directory_name`) hard-code that dir. Dev output can never prove release. | `Engine/fork/scripts/engine-distrib`; read-only grep of both Python files |
| C-11 | Ad-hoc signed builds use Chromium's mock key (`configuration.useMockKeychain = !CodeSignature.hasTeamIdentifier` in `App/main.swift`). Developer ID builds use the real Keychain item **"Open Safe Storage"**. The shared "Chromium Safe Storage" item hung Release page loads; never use it. | [engine-spike.md](../engine-spike.md) §Bugs; `App/main.swift` |
| C-12 | No Sparkle dependency exists yet. The update command surface does: `OpenCommands` defines `check-for-updates` ("Check for Updates…", Open menu) and `settings` ("Settings…", Cmd+,), and `docs/commands.md` lists both. The hand-written `App/MainMenu.swift` Open menu today has only About, Hide, Quit; the OpenKit `MenuBuilder` already emits Settings + Check for Updates. Whoever lands the app-shell menu owns the visible rows; this plan owns the updater object they call (§6.5). | `Packages/OpenKit/Sources/OpenCommands/`; `App/MainMenu.swift` |
| C-13 | Standard About panel: the Open menu's "About Open" calls `orderFrontStandardAboutPanel:`. It shows marketing version + build from `Info.plist` and the contents of `Contents/Resources/Credits.rtf` when present. No Credits file exists yet. §7 generates one. | `App/MainMenu.swift`; `ls App/Resources/` (only `Open.sdef`) |
| C-14 | Origin remote is `https://github.com/SergeSerb2/open.git`. No GitHub Pages, no Releases, no tags exist for releases yet. Pages and Releases are hosting only; nothing builds there. | `git remote -v` |
| C-15 | License review list (followups.md): adblock-rust MPL-2.0, uBlock Origin resources/scriptlets GPL-3.0, Public Suffix List MPL-2.0, Chromium/CEF BSD, proprietary codecs in release builds. `Engine/fork/licenses/THIRD_PARTY.md` has one row (adblock 0.8.11, planned). The bundled `public_suffix_list.dat` keeps its MPL-2.0 header. | [followups.md](../followups.md); `Engine/fork/licenses/THIRD_PARTY.md` |

### 0.1 Lessons that are rules in this plan

| Rule | Why |
|---|---|
| Sign inside-out, one identity, one pass, in `tools/release.sh` only | Xcode's ad-hoc pass in `tools/embed-cef.sh` is for local runs. Two signing authorities produce mixed Team IDs, and Library Validation then blocks the CEF framework at launch. |
| Never ship a dev engine as a release engine | C-10. An `is_official_build=false` framework has no LTO/PGO, keeps DCHECK-era layout, and fails the Step 10 proof in §2.6. |
| dSYMs stay on this Mac, never in the DMG | Symbols double the download and expose internals. Notarization does not need them. Crash reports need them here (§2.5). |
| The Sparkle private key lives in the login Keychain only | Whoever holds it can sign updates for every installed copy. It never enters the repo, a release asset, or a log (§6.2). |
| Placeholders are labeled placeholders | DMG background, icon slot, and release-notes template ship as plain Open-owned placeholders until a designer delivers finals. Never fill them with Arc art (AGENTS.md rule 1). |

---

## 1. Release pipeline at a glance

One command, `tools/release.sh`, runs these phases in order on this Mac.
Every phase is idempotent: re-running skips finished work and exits 0.
`--dry-run` runs the same phases with an ad-hoc identity and stops before
notarization and production update signing (§9).

```text
engine (official build, §2) ──> distrib + fetch (§2.6) ──> app build (§5)
  ──> locale trim (§2.7) ──> inside-out sign (§4) ──> verify (§4.5)
  ──> notarize app + staple (§3.2)
  ──> DMG + notarize DMG + staple (§3.3) ──> checksum (§3.4)
  ──> Sparkle appcast + deltas (§6) ──> acceptance (§9.4) ──> publish (§8.4)
```

Naming. One release is named by three values, set once in §8.1:

- Marketing version: SemVer, e.g. `1.0.0` (`MARKETING_VERSION`).
- Build number: one increasing integer, e.g. `101` (`CURRENT_PROJECT_VERSION`).
  Sparkle compares this value, never the marketing version.
- Engine stamp: `Chromium 156.0.8078.48 · CEF 4fa4ab5` (from
  `Engine/fork/VERSIONS`). It appears in About and in release notes only.

Outputs of one release (all under `build/release/<marketing>-<build>/`,
git-ignored like the rest of `build/`):

```text
Open.app/                 signed + stapled app (the same bits that ship)
Open-<marketing>.dmg      notarized + stapled disk image (the download)
Open-<marketing>.dmg.sha256
Open-<marketing>.delta    Sparkle delta from the previous build (if any)
appcast.xml               generated feed (uploaded to GitHub Pages)
release-notes.md          uploaded beside the DMG; linked from the feed
symbols/                  dSYMs + framework symbol archive (NEVER uploaded)
RELEASE-MANIFEST.txt      versions, hashes, identity, profile names, sizes
```

Size budget (arm64, default locales in §2.7): app ≤ 300 MB, DMG ≤ 300 MB.
The script warns above 285 MB and fails above 320 MB. Rationale: English-only
measures 279 MB today (C-7); the budget leaves room for Open's own growth
and fails long before an all-locale accident (329 MB) can ship.

---

## 2. Engine release build (official)

Goal: a CEF binary distribution built with `Engine/fork/gn/release.args.gn`,
proven by `cefsimple`, packaged by the Step 10 fix in §2.6, and consumed by
the app through `tools/fetch-engine.sh`. Do not hand-run `gn`, `ninja`, or
`gclient`. Use the fork scripts; they hold the writer lock, cap jobs at 10
with `nice` + `caffeinate`, and record state under
`~/Developer/open-engine/.open-engine-state/`.

### 2.1 Final GN args (already checked in; verify, do not reinvent)

`engine-build` copies `gn/dev.args.gn` into the out dir, appends
`gn/release.args.gn`, then runs `gn gen`. The merged release values are:

```gn
is_official_build=true
is_debug=false
is_component_build=false
dcheck_always_on=false
symbol_level=1
blink_symbol_level=0
v8_symbol_level=0
treat_warnings_as_errors=false
target_cpu="arm64"
proprietary_codecs=true
ffmpeg_branding="Chrome"
enable_widevine=false
chrome_pgo_phase=2
use_thin_lto=true
thin_lto_enable_optimizations=true
```

Rules:

- Widevine stays off (C-8). Turning it on needs a Google Widevine licensee
  agreement first; that is a user decision (§10), never a flag flip.
- `proprietary_codecs=true` + `ffmpeg_branding="Chrome"` stay. They enable
  H.264/AAC. The license consequence is tracked in §7, not solved here.
- `treat_warnings_as_errors=false` stays while this Mac runs a beta OS and
  SDK newer than Chromium 156 expects (fork-infra F-10).
- Dev args must also carry `disable_fieldtrial_testing_config=true` once
  the first patched build lands (followups.md). Release args inherit it
  through the dev base file. Check at Step 2; if it is missing from
  `dev.args.gn`, stop and report — do not add it inside this plan's PR.
- arm64 only. No universal build until the lead asks; it doubles build time.

### 2.2 PGO profiles

- Source: Chromium's published profiles for this exact revision.
  `engine-bootstrap` already sets `checkout_pgo_profiles=True` in `.gclient`;
  the profile file is named by `chrome/build/mac-arm.pgo.txt` and lives in
  `chrome/build/pgo_profiles/`. Never collect or commit our own profile in v1.
- Gate: `engine-build --config release` already fails before `gn gen` with
  `release: no PGO profile found; set chrome_pgo_phase=0 explicitly in gn/release.args.gn or add the profile`
  when the profile is absent.
  Do not bypass the gate by shipping phase 0 and calling it release.
  If the gate fires, the release stops; record the exact message in the PR.

### 2.3 Symbol handling

- `symbol_level=1` is the release setting: enough for crash symbolication,
  small enough to keep link times sane. Blink and V8 stay at 0.
- After the build (§2.4), copy symbols out of the out dir before any clean:

```bash
OUT=~/Developer/open-engine/chromium_git/chromium/src/out/Release_Official_arm64
REL=build/release/<marketing>-<build>/symbols
mkdir -p "$REL"
# Framework dSYM (name may carry the framework name; keep whatever exists):
find "$OUT" -name "*.dSYM" -maxdepth 4 -print0 | while IFS= read -r -d '' d; do
  ditto "$d" "$REL/$(basename "$d")"
done
# Breakpad-style symbol archive if the build produced one:
find "$OUT" -name "*.sym" -maxdepth 4 -exec cp {} "$REL/" \; 2>/dev/null || true
du -sh "$REL"
```

- Rules: symbols live only under `build/release/…/symbols/` on this Mac and
  in the lead's local archive. They are never copied into `Open.app`, the
  DMG, a GitHub Release, or the appcast. `tools/release.sh` fails if it
  finds a `.dSYM` inside the app bundle (§9.4, check A-9).
- Keep symbols for every shipped build number forever on at least one local
  disk. A crash report from build N is useless without build N's symbols.

### 2.4 Build commands (exact)

Run the proof build detached, in its own session (AGENTS.md rule 9):

```bash
python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
  Engine/fork/scripts/engine-build --config release --target cefsimple
tail -f ~/Developer/open-engine/logs/build-release-*.log
```

Acceptance for the proof build: exit 0; the summary block prints
`config=release`; `out/Release_Official_arm64/cefsimple` exists and is newer
than the log start. Then the smoke check (fork-infra §10.3, section A)
against the release out dir: launch `cefsimple` on `https://example.com`,
require it alive at 10 s, no `FATAL` or `Check failed` in stderr, then
terminate only that PID. Record the log path in the PR.

### 2.5 Strip policy

- Do not run a separate `strip` on the framework, the app, or any helper.
  The official GN build already strips according to `symbol_level`; a second
  strip breaks the code signature and can remove the V8 snapshot mapping.
- The only size levers in v1 are locales (§2.7), ThinLTO, and PGO. If the
  size budget (§1) fails, stop and report which part grew (`du -sh` the
  framework, `Resources/`, `Libraries/`). Do not delete `icudtl.dat`,
  `resources.pak`, either `chrome_*_percent.pak`, the V8 snapshot, or
  `gpu_shader_cache.bin`: CEF needs them (C-6).
- SwiftShader (`Libraries/libvk_swiftshader.dylib`, ~16 MB) stays in v1.
  It is the software-rendering fallback. Revisit only with crash data.

### 2.6 Step 10: package an official-build distribution

This section resolves the C-10 gate. CEF's tooling hard-codes
`out/Release_GN_arm64`, so an official build in `out/Release_Official_arm64`
cannot be packaged today. Do these tasks in order; S10-3 is the only engine
tree change in this plan.

- **S10-1. Prove the official `cefsimple`** (§2.4). No packaging work before
  this passes.
- **S10-2. Record the constraint.** In the PR, quote the real outputs of
  `Engine/fork/scripts/engine-distrib --config release --dry-run` and the
  release run's stop message (C-10). Reviewers must see the gate, not a claim.
- **S10-3. Patch CEF's distrib input (one small patch, fork rules).**
  Add ONE patch to `Engine/fork/patches/cef/` (series + manifest per
  fork-infra §3.2/§6.4) that teaches `cef/tools/make_distrib.py` to honor
  the environment variable `OPEN_CEF_BUILD_DIR_SUFFIX`:
  when set (e.g. `_Official_arm64`), `build_dir_release` becomes
  `out/Release<value>` and `build_dir_debug` becomes `out/Debug<value>`;
  when unset, behavior is byte-identical to upstream. Touch no other logic.
  Then, in `Engine/fork/scripts/engine-distrib`, replace the hard stop for
  `--config release` with: export
  `OPEN_CEF_BUILD_DIR_SUFFIX=_Official_arm64`, run the same
  `automate-git.py --minimal-distrib-only` flow as dev, discover exactly one
  updated child under `cef/binary_distrib/`, and record it in
  `.open-engine-state/distrib.txt` exactly as dev does. `automate-git.py`
  itself also hard-codes its build dir, but distrib runs with `--no-build`,
  so only `make_distrib.py` reads the out dir; if a real run proves
  otherwise, stop and report instead of patching `automate-git.py` (it lives
  outside the Chromium repo and has no patch series).
  Follow fork-infra §8 for the patch round-trip: edit the tree, add the
  manifest block, `engine-refresh-patches`, revert the tree edit,
  `engine-apply`, confirm the patch lands. One patch per PR where practical.
  Prohibited shortcut: never copy `out/Release_GN_arm64` (dev) output, or a
  dev distrib, into a release path. The release distrib's README must show
  the same CEF/Chromium commits as `Engine/fork/VERSIONS`, and
  `engine-status` must pass against the release out dir.
- **S10-4. Produce the release distrib.**

```bash
python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
  Engine/fork/scripts/engine-distrib --config release --run
tools/fetch-engine.sh --run
ls Vendor/cef/Release/"Chromium Embedded Framework.framework"
```

  Acceptance: `distrib.txt` names the new official distrib; `Vendor/cef/`
  holds its framework binary; repo `git status` shows no tracked changes
  from the fetch (`Vendor/cef/` is git-ignored). Record `du -sh` of the
  distrib and of the framework binary in the PR.
- **S10-5. Note the fallback.** If S10-3's patch cannot land (for example,
  CEF rewrites `make_distrib.py` on a rebase), the only approved fallback is
  to build the official args directly in `out/Release_GN_arm64` for the
  distrib run: save `args.gn`, write the merged release args, `gn gen`,
  build, distrib, then restore the dev `args.gn` and `gn gen` again.
  State in the PR that this costs one near-full dev rebuild afterward.
  Never present the fallback's output as coming from
  `out/Release_Official_arm64`.

After S10-4, `CEF_SOURCE=fork tools/build.sh Release` and
`tools/release.sh` consume the official engine with no further engine work.

### 2.7 Locale trimming

- Source of truth: a new committed file `tools/release-locales.txt`, one
  locale per line, `#` comments allowed. Initial content (Step 3):

```text
# CEF locales shipped in release builds. One per line.
# Always keep en: Chromium falls back to it. Add a locale only when the
# shell UI or a shipped feature actually uses it.
en
```

- `tools/release.sh` reads this file, always adds `en` if missing, sorts
  the list, and passes it as `OPEN_KEEP_LOCALES="en …"` to the app build.
  `tools/embed-cef.sh` already turns that value into rsync include/exclude
  rules over `Resources/*.lproj`; no embed change is needed.
- "System languages" rule: when the user asks to ship the languages of the
  build Mac, add the output of
  `defaults read -g AppleLanguages | tr -d ' ()"' | tr ',' '\n'` (first
  component of each entry, e.g. `en-CA` → `en`) to the file in the same PR.
  The committed file, not the Mac, decides what ships. Reviewers see every
  added locale as a diff line with its size cost (~0.23 MB per locale at
  C-7's 50 MB / 220 locales).
- Acceptance: with the initial file, the built app contains
  `en.lproj` only under the framework's `Resources/`; `du -sh Open.app`
  lands within the §1 budget. Shipping all 220 locales in a release build
  is a failure, not a preference.

---

## 3. Notarization, stapling, and DMG

Read this section together with §4 (signing). Order is fixed: sign (§4),
notarize the app, staple the app, build the DMG from the stapled app,
notarize the DMG, staple the DMG. Never notarize an unsigned or ad-hoc app.

### 3.1 One-time credential setup [USER]

The user creates an app-specific password at appleid.apple.com, then the
implementer stores the notary credentials once (never in the repo):

```bash
xcrun notarytool store-credentials "open-notary" \
  --apple-id "<user Apple ID email>" \
  --team-id "<10-char Team ID>" \
  --password "<app-specific password>"
```

The profile name `open-notary` is the only credential name this plan uses.
It lives in the login Keychain. No Apple ID, password, or Team ID value is
committed, logged, or pasted into a PR. Verify without exposing secrets:

```bash
xcrun notarytool history --keychain-profile "open-notary" | head -5
```

Exit 0 with a submission table (possibly empty) proves the profile works.

### 3.2 Notarize and staple the app

```bash
REL=build/release/<marketing>-<build>
ditto -c -k --keepParent "$REL/Open.app" "$REL/Open-app-notarize.zip"
xcrun notarytool submit "$REL/Open-app-notarize.zip" \
  --keychain-profile "open-notary" --wait
# On failure: xcrun notarytool log <submission-id> --keychain-profile "open-notary"
xcrun stapler staple "$REL/Open.app"
xcrun stapler validate "$REL/Open.app"
```

Rules: `--wait` blocks until Apple answers (minutes). A `Rejected` status
stops the release; save the full `notarytool log` output under `$REL/` and
fix the named binary or entitlement. Do not resubmit unchanged. Delete the
temporary ZIP after stapling; the app, not the ZIP, ships.

### 3.3 DMG creation

Tool: `hdiutil` only. `create-dmg` is not a dependency; if it happens to be
installed, do not use it, so every release has one reproducible path.

Staging layout (built by `tools/release.sh`; names are exact):

```text
$REL/dmg-staging/
  Open.app                  -> the signed + stapled app (copied with ditto)
  Applications              -> symlink to /Applications
  .background/background.png  placeholder, see below
```

Create, notarize, and staple the image:

```bash
hdiutil create -volname "Open <marketing>" -srcfolder "$REL/dmg-staging" \
  -ov -format UDZO "$REL/Open-<marketing>.dmg"
xcrun notarytool submit "$REL/Open-<marketing>.dmg" \
  --keychain-profile "open-notary" --wait
xcrun stapler staple "$REL/Open-<marketing>.dmg"
xcrun stapler validate "$REL/Open-<marketing>.dmg"
hdiutil verify "$REL/Open-<marketing>.dmg"
```

- Background and icon slots are placeholders in v1: commit
  `assets/release/dmg-background.png` (660×400, Open-owned solid background
  with the text "Open — drag to Applications", drawn by the implementer
  with no Arc art, font, or color sampling) and reference it from the
  staging folder. Finder window geometry and icon positions need a Finder
  AppleScript pass; do not add one in v1. Note the missing polish in the
  release PR; users still get a correct drag target from the symlink.
- The volume name carries the marketing version only (`Open 1.0.0`), so a
  mounted old and new release are easy to tell apart.
- Never ship the `.app` alone, a ZIP of the app, or an unstapled DMG as
  "the release". The stapled DMG is the only download (§8.4).

### 3.4 Checksum

```bash
(cd "$REL" && shasum -a 256 "Open-<marketing>.dmg" > "Open-<marketing>.dmg.sha256")
shasum -a 256 -c "$REL/Open-<marketing>.dmg.sha256"
```

The `.sha256` file is uploaded beside the DMG (§8.4) and its value is pasted
into the GitHub Release notes, so users can verify without trusting the
feed. `tools/release.sh` recomputes the hash after stapling; a hash made
before stapling is wrong by construction and must fail the run.

---

## 4. App release signing (Hardened Runtime)

### 4.1 Identity and bundle ID migration (do first)

1. Migrate IDs in `project.yml` (Step 4): `bundleIdPrefix: io.github.sergeserb2`,
   app `PRODUCT_BUNDLE_IDENTIFIER: io.github.sergeserb2.open`,
   OpenEngine `io.github.sergeserb2.open.engine`, helpers from the
   `CEFHelper` template as `io.github.sergeserb2.open.helper` with suffixes
   `.gpu`, `.renderer`, `.plugin`, `.alerts`. Keep helper product names
   (`Open Helper`, `Open Helper (GPU)`, …) unchanged: CEF finds helpers by
   bundle layout, users never see the names.
   The CEF framework keeps `org.cef.framework`. Do not rename it.
2. Confirm `git grep "app\.open\.browser"` shows no remaining ID after the
   edit (comments excluded). A mixed-ID bundle fails Library Validation.
3. Release identity: `Developer ID Application: <Name> (<TeamID>)` from the
   user's Developer ID certificate (§10). `tools/release.sh` takes it as
   `OPEN_SIGN_IDENTITY` (full name string) with `--identity` as an override.
   The script never guesses among multiple Developer ID identities; if
   `security find-identity -v -p codesigning` lists more than one, it stops
   and names them. Team ID is read from the identity, never typed by hand.
4. `project.yml` keeps `CODE_SIGN_STYLE: Manual` and ad-hoc defaults for
   local builds. Release signing happens only inside `tools/release.sh`
   (§9), so `tools/build.sh` output stays runnable on any Mac.

### 4.2 Entitlements per binary (exact release content)

Edit the six existing files in place (Step 5). They are also used by Debug
builds; every value below is inert without Hardened Runtime, so no separate
release copies exist. Justifications cite C-5/C-6. Two bans apply to all
six: never add `com.apple.security.get-task-allow` (debug-only; notarization
rejects it) and never add `com.apple.security.cs.allow-dyld-environment-variables`.

**App — `App/Open.entitlements`.** Upstream app set (C-6) + our existing
`usb`, plus `photos-library` which upstream ships and photo pickers need.
No CS exceptions: the browser process runs no JIT, and same-Team CEF code
passes Library Validation, so `disable-library-validation` on the main app
would only weaken the release. Restricted Chrome-only entitlements
(`com.apple.application-identifier`, `associated-domains`,
`web-browser.public-key-credential`, Keychain groups) are excluded in v1;
WebAuthn platform credentials get their own tested follow-up.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.device.audio-input</key>
	<true/>
	<key>com.apple.security.device.bluetooth</key>
	<true/>
	<key>com.apple.security.device.camera</key>
	<true/>
	<key>com.apple.security.device.print</key>
	<true/>
	<key>com.apple.security.device.usb</key>
	<true/>
	<key>com.apple.security.personal-information.location</key>
	<true/>
	<key>com.apple.security.personal-information.photos-library</key>
	<true/>
</dict>
</plist>
```

**`Helper/Entitlements/helper.entitlements` (generic) and
`helper.gpu.entitlements` (GPU):** unchanged from today — `allow-jit` only.
Matches upstream GPU/renderer helper shape (C-6); the GPU helper runs
ANGLE/Metal shader JIT, the generic helper hosts utility processes.

**`Helper/Entitlements/helper.renderer.entitlements`:** unchanged —
`allow-jit` + `allow-unsigned-executable-memory`. V8 in the renderer
generates executable code under the Hardened Runtime; without the second
key, pages crash on first JIT. This is the one helper that must never lose
the unsigned-memory exception.

**`Helper/Entitlements/helper.plugin.entitlements`:** unchanged —
`allow-unsigned-executable-memory` + `disable-library-validation`.
The plugin helper loads third-party plugin code that does not carry our
Team ID; it is the only binary that may disable Library Validation.

**`Helper/Entitlements/helper.alerts.entitlements`:** unchanged — empty
dict. The alerts helper shows notifications; it runs no JIT and loads no
plug-ins. An empty entitlement file is a decision, not an omission.

Frameworks get no entitlement file: `OpenEngine.framework`, the CEF
framework binary, Sparkle, and every `.dylib` are signed with the runtime
option and no entitlements (§4.3). Adding entitlements to a library is a
signing error the verifier may not catch until notarization.

### 4.3 Inside-out signing order (exact)

`tools/release.sh` signs in this order, every item with
`codesign --force --timestamp --options runtime --sign "$IDENTITY"`.
`--entitlements <file>` is added only where §4.2 names one. Sign a bundle
only after everything inside it is signed; never use `--deep` to sign
(it hides ordering and entitlement mistakes — `--deep` is for verify only).

1. Every `*.dylib` under `Chromium Embedded Framework.framework/Libraries/`
   (today: the SwiftShader Vulkan loader set), sorted by path.
2. `Chromium Embedded Framework.framework` (the bundle; its binary is
   signed as part of the bundle seal).
3. Sparkle innermost-first, when Sparkle is present (§6):
   `Sparkle.framework/Versions/B/Autoupdate`, then
   `XPCServices/Downloader.xpc`, `XPCServices/Installer.xpc`,
   `Updater.app`, then `Sparkle.framework` itself. Preserve Sparkle's own
   XPC entitlements: re-sign with no `--entitlements` override so the
   existing entitlement seal is kept where the tool supports it; if a
   macOS version refuses, stop and report the exact error.
4. `OpenEngine.framework`.
5. The five helper apps in `Contents/Frameworks/`, each with its §4.2 file:
   `Open Helper.app`, `Open Helper (GPU).app`,
   `Open Helper (Renderer).app`, `Open Helper (Plugin).app`,
   `Open Helper (Alerts).app`.
6. `Open.app` last, with `App/Open.entitlements`.

Dry-run mode (§9) runs the identical order with identity `-` (ad-hoc) and
`--timestamp=none` (ad-hoc signatures cannot use Apple's timestamp server).
Everything else — order, entitlements, runtime option — is identical, so a
dry run proves the real run's shape.

### 4.4 Library Validation and Keychain consequences

- Hardened Runtime turns on Library Validation by default: the app loads
  only Apple code or code with our Team ID. That is why §4.1's ID migration
  and §4.3's single identity matter, and why only the plugin helper opts out.
- After Developer ID signing, `App/main.swift`'s
  `CodeSignature.hasTeamIdentifier` is true, so the engine uses the real
  **"Open Safe Storage"** item (C-11). First launch on a new release build
  may show one Keychain prompt; repeated prompts on every launch mean the
  signature changed between builds — treat that as a release defect.
- Sparkle under Library Validation loads because it is re-signed with our
  identity in §4.3 step 3. An ad-hoc dry-run build may refuse to load
  Sparkle locally; that is expected (Sparkle's own setup notes call this
  out for ad-hoc signatures) and is reported as a dry-run limitation, not
  fixed by disabling validation in release.

### 4.5 Verification commands (all must pass; paste output in the PR)

```bash
APP=build/release/<marketing>-<build>/Open.app
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|Runtime"
# Expect: Authority chain ends at Developer ID Certification Authority,
# TeamIdentifier = the user's Team ID (never "not set" in release),
# flags include "runtime".
for h in "$APP"/Contents/Frameworks/"Open Helper"*.app; do
  codesign -d --entitlements - "$h" | head -20
done
spctl -a -vvv --type execute "$APP"   # after stapling: "accepted", source=Notarized Developer ID
```

Before notarization, `spctl` must say `rejected` (not yet notarized) while
`codesign --verify` already passes. Claiming Gatekeeper acceptance before
stapling is a false check; the release is accepted only with both green.

---

## 5. App release build

### 5.1 Build settings

`tools/release.sh` builds through the existing `tools/build.sh` path with
release values passed on the command line, so no second build system exists:

```bash
CEF_SOURCE=fork OPEN_KEEP_LOCALES="<from §2.7>" tools/build.sh Release
```

`project.yml` gains a `Release` config entry (Step 6) with exactly:

```yaml
    Release:
      ENABLE_HARDENED_RUNTIME: YES
```

Nothing else changes in `project.yml` signing settings. The Xcode build
still ad-hoc signs what `tools/embed-cef.sh` copies; §4.3 then re-signs the
copied app in place. Set `ENABLE_HARDENED_RUNTIME` so any future Xcode-only
archive already carries the runtime flag, but treat §4.3 as the authority.

`OPEN_AUTOMATION` stays off for release: the automation socket is Debug-only
unless explicitly requested, and a shipped build must never contain it.
`tools/release.sh` fails if the release log or binary shows the automation
socket compiled in (§9.4, check A-10). Check with:
`strings build/Release/Open.app/Contents/MacOS/Open | grep -c automation.sock`
must be 0 in release (the string lives in the socket path construction).

### 5.2 Info.plist keys (app)

Edit `App/Info.plist` (Step 6). Keep every existing key; add exactly:

```xml
	<key>SUFeedURL</key>
	<string>https://sergeserb2.github.io/open/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string>PASTE_PUBLIC_KEY_FROM_GENERATE_KEYS</string>
	<key>SUEnableAutomaticChecks</key>
	<true/>
	<key>SUScheduledCheckInterval</key>
	<integer>28800</integer>
	<key>OpenChromiumVersion</key>
	<string>156.0.8078.48</string>
	<key>OpenCEFCommit</key>
	<string>4fa4ab516dacf6c49fc7e6e70d2b7ebce29fa35f</string>
	<key>OpenEngineStamp</key>
	<string>Chromium 156.0.8078.48 · CEF 4fa4ab5</string>
```

- `SUFeedURL` / `SUPublicEDKey` / check keys are Sparkle's contract (§6).
  The placeholder public key is replaced once, in the key-generation step
  (§6.2 [USER consent]); after that it changes only on key rotation.
- `SUScheduledCheckInterval` 28800 = 8 hours. This matches the interval
  Arc ships (bundle-anatomy §1, fact) and is frequent enough for a browser.
- The three `Open*` keys are Open's own. Bump them with `VERSIONS` on every
  engine rebase; §8.1 makes that a checklist line. `OpenCEFCommit` is the
  full hash; `OpenEngineStamp` is its display form. Never type either from
  memory: copy from `Engine/fork/VERSIONS`.
- Helper `Info.plist` (`Helper/Info.plist`) gets no new keys. Its
  `LSUIElement` and version mapping already serve release.

### 5.3 About panel (engine version visible)

The standard About panel (C-13) shows marketing version + build. To show
the engine stamp without a custom window, Step 6 also:

1. Generates `App/Resources/Credits.rtf` content through §7 (acknowledgements
   header carries the engine stamp). Commit the generator, not the RTF;
   `tools/release.sh` regenerates the RTF into the built app's Resources
   before signing (§9). A plain `tools/build.sh` build without the RTF
   still shows a correct About panel, just without acknowledgements.
2. Leaves the "About Open" action as `orderFrontStandardAboutPanel:`.
   Do not build a custom About window in this plan.

Acceptance: on the signed release app, About shows `Version <marketing>
(<build>)` and the Credits area starts with the §7 header including
`OpenEngineStamp`. Read the stamp back with
`/usr/libexec/PlistBuddy -c "Print :OpenEngineStamp" Open.app/Contents/Info.plist`.

---

## 6. Updates: Sparkle 2

Decision: Sparkle 2, EdDSA-signed feeds and deltas, hosted on GitHub.
Rejected: a custom updater (we would own download, verification, install,
and rollback for a browser — too much security surface) and Mac App Store
updates (Open is Developer ID only; Chromium does not fit the sandbox).
Arc ships Sparkle 2.9.4 the same way (bundle-anatomy §3, fact); Open uses
its own feed, key, and hosting. Never copy Arc's feed URL or public key.

### 6.1 Dependency (one new dependency, with reason)

Add Sparkle as a Swift Package Manager dependency, pinned exactly:

- In `project.yml` `packages:`, add
  `Sparkle: { url: https://github.com/sparkle-project/Sparkle, exactVersion: <PIN> }`
  where `<PIN>` is the latest stable Sparkle 2.x release at implementation
  time (Step 7 records the chosen version in the PR; do not float on a
  branch or a range). Link product `Sparkle` to the `Open` target only,
  Embed & Sign. No other target links it.
- Reason (also the PR's dependency note): the standard macOS updater —
  EdDSA verification, delta updates, notarization-compatible XPC install —
  with no telemetry and no account. Size cost is one framework (~3 MB class;
  measure the real one in the PR).
- Tools: `generate_keys`, `sign_update`, `generate_appcast` ship inside the
  SwiftPM artifact and, for scripts, in the standalone release archive.
  Step 7 downloads the pinned release archive once, verifies its SHA-256
  against the GitHub release page value recorded in the PR, and installs
  the three tools to `~/Developer/open-release-tools/sparkle-<PIN>/bin/`
  (outside the repo). `tools/release.sh` calls them by absolute path from
  `OPEN_SPARKLE_TOOLS` (default that directory). Never commit Sparkle
  binaries or tools to the repo.

### 6.2 Keys [USER consent]

EdDSA (ed25519) key pair, generated once on this Mac, only with the user's
explicit consent (it becomes the trust root for every installed copy):

```bash
~/Developer/open-release-tools/sparkle-<PIN>/bin/generate_keys
# Prints the public key. Paste it into App/Info.plist SUPublicEDKey (§5.2).
~/Developer/open-release-tools/sparkle-<PIN>/bin/generate_keys -x /tmp/open-sparkle-export.txt
```

- The private key goes to the login Keychain (account
  `org.sparkle-project.Sparkle`). It is never written to the repo, a release
  folder, a log, or a backup file the script creates. The `-x` export above
  exists only so the user can store one offline backup (password manager or
  printed copy) and must be deleted from `/tmp` in the same session.
- Losing the private key means shipped apps can never verify a future
  update: the fix would be a manually downloaded release with a new key.
  Say this to the user before generating. Rotating means shipping one
  release signed with the old key whose `SUPublicEDKey` introduces the new
  key; do not rotate casually.
- Dry runs never touch this key. §9's dry run generates a throwaway key in
  `$TMPDIR`, signs the test feed with it, validates the XML, and deletes it.

### 6.3 Feed format (appcast)

`generate_appcast` writes the feed; this plan fixes its inputs and hosting,
not its internals. One item per release. The generated `appcast.xml` must
contain, per item (verify with `grep` before upload, §9.4 check A-12):

```xml
<item>
  <title>1.0.0</title>
  <link>https://sergeserb2.github.io/open/release-notes/1.0.0.html</link>
  <sparkle:version>101</sparkle:version>
  <sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
  <pubDate>Sat, 25 Oct 2026 20:00:00 -0700</pubDate>
  <enclosure url="https://github.com/SergeSerb2/open/releases/download/v1.0.0/Open-1.0.0.dmg"
             sparkle:edSignature="…" length="…" type="application/octet-stream"/>
  <sparkle:deltas>
    <enclosure url="https://github.com/SergeSerb2/open/releases/download/v1.0.0/Open100-101.delta"
               sparkle:deltaFrom="100" sparkle:edSignature="…" length="…"
               type="application/octet-stream"/>
  </sparkle:deltas>
</item>
```

Rules: `sparkle:version` is the build number (§8.1), never the marketing
version. `minimumSystemVersion` is `26.0` while macOS 26+ is the platform.
Release notes are one Markdown file per release (§8.3) rendered to HTML by
`generate_appcast`'s notes handling (a same-named `.md`/`.html` beside the
archive) or linked with `<sparkle:releaseNotesLink>`; pick whichever the
pinned tool emits and verify the link resolves before upload.
Run `generate_appcast` over a folder that holds only this release's DMG,
its delta, and its notes file, with `--download-url-prefix
https://github.com/SergeSerb2/open/releases/download/v<marketing>/` and
`--link https://sergeserb2.github.io/open/` (exact flags per
`generate_appcast -h` of the pinned version; record them in the PR).

### 6.4 Hosting (GitHub Releases + GitHub Pages)

The locations below depend on the user's §10 U-8 decision. `SergeSerb2/open`
is currently private. Its release assets are not public downloads, and
private-repository Pages requires a paid GitHub plan. The proposed feed URL
`https://sergeserb2.github.io/open/appcast.xml` is conditional on U-8, not
an established public endpoint. If the user chooses a public mirror, update
the feed and archive URLs in the app, appcast and release tools to that
chosen repository before U-5 or the first public release.

- Archives on GitHub Releases of `SergeSerb2/open` (C-14): one Release per
  tag (§8.2) holding `Open-<marketing>.dmg`, its `.sha256`, and every
  `.delta` for that build. Releases host large files; Pages does not.
- Feed on GitHub Pages as a project site for the same repo, which serves
  `https://sergeserb2.github.io/open/appcast.xml`. Commit only
  `appcast.xml` (and `appcast-beta.xml`, §6.6) plus release-notes HTML to a
  dedicated `gh-pages` branch (or `docs/` on that branch); never commit a
  DMG to git. Enable Pages once [USER] (§10): repo Settings → Pages →
  deploy from the `gh-pages` branch. The feed URL is stable across releases;
  only its content changes, so shipped apps keep finding updates.
- Upload order matters: Release assets first, feed last. A feed that names
  a missing DMG breaks every checker for hours. `tools/release.sh` prints
  this order and stops before any upload (§9); uploads are manual `gh`
  commands the user runs or approves (§8.4). No token enters the script.
- Rollback: to pull a bad release, remove its `<item>` from `appcast.xml`,
  commit, and let Pages redeploy. Installed copies then see the previous
  build as latest. Never delete the GitHub Release until the feed no longer
  references it (delta sources may still point there).

### 6.5 In-app UI hooks (small Swift addition)

Step 8 adds one file, `App/UpdaterController.swift` (App target only):

- Owns `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate:
  nil, userDriverDelegate: nil)` for the whole app lifetime, created in
  `AppDelegate.applicationDidFinishLaunching`. Its `checkForUpdates(_:)`
  action is the target of the existing `check-for-updates` command (C-12).
- Menu: when the hand-written `App/MainMenu.swift` still owns the Open menu,
  add `Check for Updates…` (no shortcut) below Settings once Settings
  exists; when the OpenKit `MenuBuilder` owns the menu, its row already
  exists and must target the same action. Either way there is exactly one
  menu item, titled "Check for Updates…", and it is enabled only when
  `updater.canCheckForUpdates` allows (Sparkle's standard controller
  handles this binding).
- Settings › General: add one row, "Check for Updates…" (button calling the
  same action), plus the channel control in §6.6. Settings is low-frequency
  UI, so SwiftUI there follows the architecture rule.
- Background behavior comes from `Info.plist` (§5.2): automatic checks on,
  8-hour interval. The updater shows Sparkle's standard UI. Do not build a
  custom update window, progress view, or "what's new" surface in v1.
- Ad-hoc and Debug builds: the same code runs against the production feed.
  That is intentional — it proves the hook — but never point a test build
  at a test feed by editing `Info.plist`; use §6.6's channel default.

### 6.6 Channels

- Two feeds, same appcast shape: `appcast.xml` (stable) and
  `appcast-beta.xml` (beta). A build belongs to exactly one item list; a
  build made with `--config beta` (§9.1) appears only in the beta feed,
  then is promoted by copying its item into the stable feed unchanged.
- Selection: `SPUUpdaterDelegate.allowedChannels(for:)` returns `["beta"]`
  when UserDefaults key `OpenUpdateChannel` is `"beta"`, else `[]` (stable).
  Tag beta items with `<sparkle:channel>beta</sparkle:channel>` so stable
  clients ignore them even if feeds are merged by mistake.
- Settings › General segmented control "Release channel: Stable / Beta"
  writes `OpenUpdateChannel`. Default is Stable. Switching takes effect on
  the next scheduled or manual check; no relaunch code is needed.
- Delta rule across channels: `generate_appcast` makes deltas from the
  previous build in the same folder. Keep the previous DMG of the same
  channel in the generation folder, or the run emits no delta — a missing
  delta is valid (clients fall back to the full DMG) but must be noted in
  the release PR, since browser DMGs make deltas the common path.

---

## 7. License compliance artifacts

The release ships one About › Acknowledgements surface, generated from one
inventory. Counsel review before the first public release is a user gate
(§10); this section builds the artifacts that review reads. No legal advice
is given here — the inventory states facts (name, version, license, source)
and the reviewer decides.

### 7.1 Source inventory (one file, human-reviewed)

Create `docs/release/licenses.md` (Step 9) with exactly this table header
and at least these rows. Every row names the version actually linked or
bundled at build time; a version bump updates its row in the same PR.

| Component | Version | License | How Open uses it | Source / offer |
|---|---|---|---|---|
| Chromium | 156.0.8078.48 | BSD-style (Chromium license) | Engine core | Full credits in the CEF distrib `CREDITS.html` (`about_credits`); source: chromium.googlesource.com |
| CEF | 156.0.14+g4fa4ab5 (branch 8078) | BSD (CEF `LICENSE.txt`) | Embedding layer | `Vendor/cef/LICENSE.txt` at build time; source: github.com/chromiumembedded/cef |
| adblock (Brave adblock-rust) | 0.8.11 | MPL-2.0 | Network + cosmetic matching, browser process | Vendored sources in `Engine/fork/patches/rust/` when Step 8 of fork-infra lands; license text `Engine/fork/licenses/MPL-2.0.txt`. If the crate is not yet vendored, the row reads "not yet linked" and the acknowledgement omits it. |
| Public Suffix List | bundled `public_suffix_list.dat` pin | MPL-2.0 | URL-vs-search decisions (`OpenSuggest`) | File header stays intact in the bundle; upstream: publicsuffix.org |
| uBlock Origin resources / scriptlets | (pin at bundling time) | GPL-3.0 | Scriptlet + resource replacements for ad blocking | Include this row ONLY when those assets actually ship. GPL-3.0 full text + corresponding source offer required (§7.3). If they do not ship, state that in the PR instead of listing them. |
| FFmpeg (Chromium bundled) | Chromium 156 pin | LGPL-2.1 (Chromium build) | H.264/AAC via `proprietary_codecs=true` | Covered by Chromium credits; patent note below |
| Sparkle | §6.1 pin | MIT | Update framework | github.com/sparkle-project/Sparkle; MIT text in its LICENSE |
| Filter lists (EasyList, EasyPrivacy, …) | `list-pins.txt` pin | Each list's own license (EasyList family: dual GPL/BSD-class terms per list) | Ad-block data, not code | Upstream URLs in `Packages/OpenKit/Sources/OpenAdBlock/Resources/catalog.json`; lists are downloaded data, acknowledged by name |

Patent note (state verbatim in the inventory, do not soften): release builds
enable proprietary codecs. H.264/AAC patent licensing for distribution is
not granted by any open-source license above and is part of the §10 user
gate. The plan ships the acknowledgment; it does not clear the patent risk.

### 7.2 Acknowledgements file (generated, shown in About)

- Generator: `tools/generate-acknowledgements.py` (Python 3, stdlib only,
  Step 9). Input: `docs/release/licenses.md` + the CEF distrib
  `CREDITS.html` when present. Output: a Credits RTF written to the path
  given as its argument (release passes the built app's
  `Contents/Resources/Credits.rtf`) with this
  exact structure: line 1 `Open <marketing> (<build>)`, line 2 the
  `OpenEngineStamp` value, then one paragraph per inventory row (component,
  version, license name), then the full MPL-2.0, GPL-3.0 (only when §7.1's
  conditional row ships), MIT, and CEF BSD texts, in that order.
  License texts come from committed copies under `docs/release/licenses/`
  (`MPL-2.0.txt`, `GPL-3.0.txt`, `MIT-Sparkle.txt`, `BSD-CEF.txt`), copied
  from upstream at Step 9 — never typed from memory.
- `tools/release.sh` runs the generator into the built app before signing
  (§9). The committed repo holds the generator + inventory + texts, not a
  stale RTF. The standard About panel (C-13) displays the RTF with no Swift
  change. Also emit a plain-text twin,
  `build/release/<marketing>-<build>/Acknowledgements.txt`, uploaded to the
  GitHub Release so the acknowledgements are readable without installing.
- Settings › About (when Settings exists) shows the same file through a
  read-only text view. Do not maintain a second copy of the text in Swift.

### 7.3 Source-offer notes (MPL/GPL)

- MPL-2.0 (adblock, PSL): file-level copyleft. If Open modifies an MPL file,
  the modified file stays MPL-2.0 and its source must be available. The
  vendored patch in the repo plus the public GitHub repo satisfies the
  offer for unmodified vendored code; the Acknowledgements names the repo
  URL and the crate version. Any Open edit to an MPL file is committed as
  source in the same repo — never shipped as a binary-only change.
- GPL-3.0 (uBO assets, only when shipped): corresponding source for the
  shipped asset form must be offered. The release must either (a) bundle
  the assets in source (text) form with the GPL-3.0 text in §7.2, or
  (b) not ship them. There is no (c). Record which in the release PR.
- Chromium/CEF BSD: reproduce the copyright + license in §7.2 (CEF text) and
  the full `CREDITS.html` twin on the GitHub Release. Do not strip
  `LICENSE.txt` or credits from the CEF framework's Resources.
- Before the first public release, the user confirms (§10) that this
  posture was reviewed. Until then, releases are local-only (§10.2).

---

## 8. Versioning, release notes, tagging

### 8.1 Versioning scheme

- Marketing version (`MARKETING_VERSION` in `project.yml`): SemVer
  `MAJOR.MINOR.PATCH`. MAJOR for engine or data-format breaks, MINOR for
  features, PATCH for fixes. Pre-1.0 (`0.x`) may break in MINOR. Users see
  this in About, the DMG name, and the GitHub Release title.
- Build number (`CURRENT_PROJECT_VERSION`): one integer, increased by 1 for
  every build that leaves this Mac, beta or stable. Never reuse, never
  decrease. Sparkle compares only this (§6.3). Keep it small and dense
  (101, 102, …), not date-based, so delta names stay readable.
- Beta marking: betas share the scheme; the channel (§6.6) is the only
  difference. Do not encode "beta" in the marketing version or build number.
- Engine stamp (§5.2 `Open*` keys) moves only on an engine rebase PR, in
  the same commit as `Engine/fork/VERSIONS`. A release PR that bumps the
  engine without the stamp (or vice versa) fails review.
- Bump procedure (release PR, in order): edit `MARKETING_VERSION` and/or
  `CURRENT_PROJECT_VERSION` in `project.yml`; edit the `Open*` keys only if
  the engine moved; write release notes (§8.3); run `tools/release.sh`.
  Version edits and code changes never mix in one commit.

### 8.2 Tagging

- One annotated tag per shipped build on `main`: `v<marketing>` for stable
  (e.g. `v1.0.0`), `v<marketing>-beta.<build>` for beta. The tag message is
  `Open <marketing> (<build>) · <engine stamp>`.
- Tag only after §9.4 acceptance passes on the tagged commit and
  `tools/verify-all.sh` passes on `main` (AGENTS.md rule 10: merge
  `origin/main` first; paste its summary table into the PR).
- Tags are created and pushed by the user or with the user's approval in
  the release session. This plan never requires force-pushing or history
  edits; a wrong tag is superseded by a new build number, never moved.

### 8.3 Release notes

One file per release: `docs/release/notes/<marketing>.md`, committed with
the version bump. Template:

```markdown
# Open <marketing> (<build>)

Engine: <OpenEngineStamp>. macOS 26+, Apple Silicon.

## Changes
- <user-visible change, one line each; no internal refactor names>

## Fixes
- <user-visible fix>

## Known issues
- <honest limitation, or "None known">
```

`tools/release.sh` copies this file beside the DMG for `generate_appcast`
(§6.3). The GitHub Release body is this file plus the DMG SHA-256 line.
Write notes for users: name Spaces, tabs, and settings as the app names
them; never use the Arc brand except "Import from Arc".

### 8.4 Publish sequence (manual, user-approved)

`tools/release.sh` stops after §9.4 and prints these commands. The user
runs them (or approves them) in order:

```bash
gh release create v<marketing> --title "Open <marketing>" \
  --notes-file docs/release/notes/<marketing>.md \
  build/release/<marketing>-<build>/Open-<marketing>.dmg \
  build/release/<marketing>-<build>/Open-<marketing>.dmg.sha256 \
  build/release/<marketing>-<build>/*.delta \
  build/release/<marketing>-<build>/Acknowledgements.txt
# Then publish the feed (gh-pages branch): copy appcast.xml over, commit, push.
```

If `gh` is absent, use the GitHub web UI with the same files and order.
Feed last, always (§6.4). Announce nothing until `curl -fsI
https://sergeserb2.github.io/open/appcast.xml` returns 200 and one installed
copy has updated itself from the feed (§9.4, check A-13).

---

## 9. `tools/release.sh` — the local release script

### 9.1 Interface (exact)

```text
tools/release.sh [--dry-run] [--config stable|beta] [--skip-engine]
                 [--skip-notarize] [--identity "<full identity name>"]
Env: OPEN_SIGN_IDENTITY, OPEN_SPARKLE_TOOLS, OPEN_ENGINE_ROOT,
     OPEN_BUILD_JOBS (default 6)
No arguments: production run (requires Developer ID + open-notary profile).
--dry-run: ad-hoc identity, no notarization, throwaway Sparkle key.
           Runs the whole pipeline shape without any credential.
--skip-engine: reuse the recorded fork distrib in Vendor/cef/.
           Without it, the script requires distrib.txt to name an
           official (Release_Official) distrib and fails otherwise.
--skip-notarize: sign + DMG only (internal testing; output is labeled
           NOT-NOTARIZED in RELEASE-MANIFEST.txt and must not publish).
--config beta: generate appcast-beta.xml; stable generates appcast.xml.
```

Conventions match the repo: `#!/bin/bash`, `set -euo pipefail`, macOS
`/bin/bash` 3.2 safe (guard empty arrays under `set -u`), logs to
`build/release/<marketing>-<build>/release.log`, one `die` helper that
names the failed phase. The script reads versions from `project.yml`
(`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`) and the engine stamp from
`App/Info.plist`; it never hard-codes a version string (search the diff for
`1.0.0`/`156.0` — hits allowed only in comments).

### 9.2 Phases (in order; each logs start/end and is skippable on re-run
only when its output stamp matches the current inputs)

1. **Preflight.** macOS + arm64; Xcode, `xcodegen`, `python3`, `gh`
   (warn only) present. Identity resolved (§4.1) or `-` in dry run.
   Notary profile probe (`notarytool history`) unless dry run or
   `--skip-notarize`. Sparkle tools dir exists (§6.1). Free space ≥ 5 GB.
2. **Engine.** Unless `--skip-engine`: require
   `~/Developer/open-engine/.open-engine-state/distrib.txt` to name a
   distrib whose framework passes §2.6 provenance (README commits match
   `VERSIONS`), run `tools/fetch-engine.sh --run`, then archive symbols
   (§2.3). With `--skip-engine`: verify `Vendor/cef/` already holds that
   framework binary, else die with the §2.6 commands.
3. **Version + notes.** Read versions; require
   `docs/release/notes/<marketing>.md` to exist; require the build number
   to be greater than the highest `sparkle:version` in the current feed
   (fetched from the Pages URL when online; warn when offline).
4. **Acknowledgements.** Run §7.2's generator (outputs staged for phase 6).
5. **App build.** `CEF_SOURCE=fork OPEN_KEEP_LOCALES="<list>" tools/build.sh
   Release` (§5.1). Copy `build/Release/Open.app` to
   `build/release/<marketing>-<build>/Open.app` with `ditto`.
6. **Bundle hygiene.** Copy `Credits.rtf` into the app's Resources; confirm
   locale set matches §2.7 (`ls` the framework `Resources/*.lproj`); confirm
   no `.dSYM`, no `*.delta`, no test fixture inside the app.
7. **Sign.** §4.3 in order. Then §4.5's `codesign --verify --deep --strict`.
8. **Notarize app.** §3.2 (skipped in dry run / `--skip-notarize`, logged
   as SKIP with the reason).
9. **DMG.** §3.3 staging + create; notarize + staple the DMG under the same
   skip rule; `hdiutil verify`; checksum §3.4 (recomputed after stapling).
10. **Appcast.** Stage DMG + previous same-channel DMG (if present under
    `build/release/`) + notes; run `generate_appcast` (§6.3) with the
    production key, or the throwaway key in dry run; validate the XML with
    `xmllint --noout` and the §6.3 field checks (script greps).
11. **Manifest.** Write `RELEASE-MANIFEST.txt`: marketing, build, engine
    stamp, identity (name + Team ID, or `ad-hoc (dry run)`), notary
    submission IDs, file sizes, SHA-256 values, locale list, Sparkle pin,
    previous build (delta source), and every SKIP with its reason.
12. **Summary.** Print the §9.4 table with real results and, for production
    runs, the §8.4 publish commands. Exit 0 only when no FAIL exists.

### 9.3 Dry-run mode (no credentials at all)

`tools/release.sh --dry-run` must succeed on a Mac with no Developer ID
certificate, no notary profile, and no Sparkle production key:

- Identity `-`, `--timestamp=none`, otherwise identical signing (§4.3).
- Notarization phases report SKIP (credential absent by design).
- Appcast phase uses a throwaway EdDSA key under `$TMPDIR`, then deletes it.
  The dry-run feed is written to the release folder only; it is never
  uploaded and its signatures verify against no shipped app.
- The dry-run app launches locally. Because it is ad-hoc, it uses the mock
  Keychain path (C-11) and may not load Sparkle under Library Validation
  (§4.4); both are logged as known dry-run limits, not failures.
- Purpose: prove order, entitlements, locales, sizes, DMG, and feed shape
  before any [USER] item in §10 exists. A green dry run is the gate for
  asking the user for credentials.

### 9.4 Acceptance checks (the release is done only when all applicable
rows pass; SKIP allowed only where the mode says so)

| # | Check | Command / evidence | Dry run |
|---|---|---|---|
| A-1 | Engine provenance | Distrib README commits = `VERSIONS`; `engine-status` PASS on release out dir | same |
| A-2 | App launches | Open the signed app, load `https://example.com`, title + sidebar tab correct, quit clean | same |
| A-3 | Helpers run | `pgrep -fl "Open Helper"` during A-2 shows renderer + GPU helpers; no crash dialogs | same |
| A-4 | Signature | §4.5 `codesign --verify --deep --strict` exit 0; Team ID present | Team ID absent (ad-hoc) is expected; verify still exit 0 |
| A-5 | Gatekeeper | `spctl -a -vvv` on app + DMG: accepted, Notarized Developer ID | SKIP (not notarized) |
| A-6 | Staple | `xcrun stapler validate` on app + DMG exit 0 | SKIP |
| A-7 | Size | `du -sh` app + DMG within §1 budget; warn/fail lines in log | same |
| A-8 | Locales | Framework `Resources/` holds exactly the §2.7 list (+ `en`) | same |
| A-9 | No symbols in bundle | `find Open.app -name "*.dSYM"` empty | same |
| A-10 | No automation socket | §5.1 `strings … grep -c automation.sock` = 0; release log has no automation line | same |
| A-11 | DMG mounts clean | `hdiutil attach` the DMG, launch the app from the mount once, detach | same |
| A-12 | Feed shape | `xmllint --noout appcast.xml`; greps for `sparkle:version` = build, edSignature present, enclosure URL returns 200 after §8.4 | XML + greps only (URLs local) |
| A-13 | Real update | Previous shipped build + "Check for Updates…" installs this build (delta when offered) | SKIP (no shipped predecessor) |
| A-14 | About + acknowledgements | §5.3: About shows version/build; Credits start with engine stamp; `Acknowledgements.txt` matches inventory versions | same |
| A-15 | No secrets in outputs | `git status` clean of release artifacts; `grep -R "SUPublicEDKey" ` shows public key only; no private key file under `build/release/` | same |

A-2/A-3/A-11 use the app's own automation/e2e surface where it exists
(`tools/e2e/engine_e2e.py` patterns) or a manual launch with process and log
inspection. Never drive the user's desktop (AGENTS.md rule 4; verify-all
rule). Record each row's real output in the release PR.

---

## 10. What the user must provide

Nothing in §§2–9 needs the user until the marked [USER] gates. Do all other
steps first, prove them with a green `--dry-run` (§9.3), then ask for this
list in one message. Costs are in USD, checked on Apple's public pages at
plan time; re-check before quoting them to anyone else.

### 10.1 Required for a public release

| # | Item | Exact action | Cost | Blocks |
|---|---|---|---|---|
| U-1 | Apple Developer Program membership | Enroll (individual) at developer.apple.com; the Apple ID becomes the Team owner | $99/year | U-2, U-3, all notarization |
| U-2 | Developer ID Application certificate | In Xcode Settings → Accounts, or the developer portal: create a "Developer ID Application" certificate; install it in the login Keychain. Confirm with `security find-identity -v -p codesigning` (must list `Developer ID Application: …`) | Included in U-1 | §4 signing, §3 notarization |
| U-3 | Notary credentials | Create an app-specific password at appleid.apple.com, then run §3.1's `store-credentials "open-notary"` with the Apple ID + Team ID + that password | Free | §3.2, DMG notarization |
| U-4 | Sparkle key consent + backup | Approve one §6.2 `generate_keys` run; paste the printed public key into `SUPublicEDKey` (implementer can paste; user approves); store the `-x` export in a password manager, then delete the `/tmp` file | Free | All update signing |
| U-5 | GitHub Pages enablement | Depends on U-8. In the public repository chosen there, enable deploy from the `gh-pages` branch (§6.4). Requires repo admin, which the user holds. The proposed `sergeserb2.github.io/open/appcast.xml` URL depends on that choice | Free for a public repo; private-repo Pages needs a paid GitHub plan | Feed hosting at the location selected under U-8 |
| U-6 | License + patent + security review confirmation | Read §7's inventory (MPL-2.0 source offer, conditional GPL-3.0 assets, proprietary-codec patent note) and the ad-block crate security review (adblock, regex, aho-corasick: docs/engine-patches.md "Security review", including the list-parsing fuzz follow-up), and confirm in writing in the release PR that the posture was reviewed (counsel optional, user's call) | Free (own review) | First public release only |
| U-7 | Publish approval per release | Approve the tag (§8.2) and run or approve the §8.4 `gh release create` + feed commit | Free | Each public release |
| U-8 | Public source and download location | Make `SergeSerb2/open` public, or create a public mirror repo (for example `SergeSerb2/open-releases`) that holds the release DMGs, the appcast (GitHub Pages), and the MPL-covered source files. Pages on a private repo needs a paid GitHub plan, and private release assets are not publicly downloadable. The user chooses; no location is selected by this plan | Depends on the user's choice | U-5, first public release, MPL source offer |

U-8 is unresolved: `gh repo view SergeSerb2/open --json visibility` reports
`PRIVATE`. The public-repository source-offer statement in §7.3 is
conditional on U-8; the current private repository does not satisfy it for
public recipients. Record the selected public source location in
`docs/release/licenses.md`, publish the exact shipped MPL-covered sources
there, and verify anonymous access to the sources, DMGs and feed before
public distribution. No repository is made public or created by this plan.

Hosting evidence: [GitHub Pages availability](https://docs.github.com/en/pages/getting-started-with-github-pages/what-is-github-pages)
and [release read-access requirement](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases).

Free-tier note: GitHub Releases and Pages for a public repo cost nothing.
No domain, no server, no CI runner, and no App Store fee beyond U-1 exists
in this plan. Team ID value itself is not secret, but it is never typed by
the implementer — it is read from U-2's identity (§4.1).

### 10.2 What works without any of U-1…U-8

- Everything except public distribution: `tools/release.sh --dry-run`
  (ad-hoc signing, SKIP notarization, throwaway update key), local launch
  and helper checks (A-2/A-3/A-11), DMG mount checks, feed-shape checks,
  About/acknowledgements checks, and `tools/verify-all.sh`.
- Limits without credentials: Gatekeeper rejects the app on any other Mac
  (quarantine), `spctl` acceptance (A-5) and the real-update check (A-13)
  cannot pass, and no build may be linked publicly as "the release".
  Local-only builds are labeled ad-hoc in `RELEASE-MANIFEST.txt`.

---

## 11. Implementation order (acceptance per step)

Work top to bottom. [NOW] steps need no user item; [USER] steps wait for §10.

| Step | Work | Acceptance (all must pass) |
|---|---|---|
| 1 [NOW] Re-verify facts | Re-run §0's evidence reads (`project.yml`, entitlements, `VERSIONS`, live distrib listing, PGO file). Note drift in the PR; stop on conflict | Every C-row re-confirmed or drift quoted verbatim |
| 2 [NOW] Engine proof | §2.4 release `cefsimple` build + smoke A against `Release_Official_arm64` | Build summary `config=release` exit 0; smoke log free of `FATAL`; symbols archived per §2.3 |
| 3 [NOW] Locales file | Create `tools/release-locales.txt` (§2.7 initial content) | File committed; a build with it shows only `en.lproj` in the framework |
| 4 [NOW] Bundle IDs | §4.1 `project.yml` migration to `io.github.sergeserb2.open…` | `tools/build.sh` Debug still builds + launches; no `app.open.browser` ID remains (comments excluded) |
| 5 [NOW] Entitlements | §4.2: rewrite `App/Open.entitlements`; confirm the five helper files already match (edit only on drift) | `plutil -lint` on all six; Debug build launches; renderer page with JIT (any JS-heavy site) does not crash |
| 6 [NOW] App release build | §5: `Release` config entry, `App/Info.plist` keys (placeholder public key), About stamp readback | Release app builds; `PlistBuddy` prints the stamp; About shows version/build on the ad-hoc app |
| 7 [NOW] Sparkle dependency + tools | §6.1: pin Sparkle, link to Open, install CLI tools to `~/Developer/open-release-tools/` with recorded SHA-256 | App builds with Sparkle embedded; `generate_appcast -h` runs from the pinned tools dir; size delta recorded |
| 8 [NOW] Updater UI | §6.5/§6.6: `App/UpdaterController.swift`, menu + Settings › General hooks, channel defaults | "Check for Updates…" exists once, invokes Sparkle UI (error reaching the placeholder feed is a pass at this step); channel control writes `OpenUpdateChannel` |
| 9 [NOW] License artifacts | §7: `docs/release/licenses.md`, `docs/release/licenses/*.txt`, `tools/generate-acknowledgements.py`, first `docs/release/notes/` template instance | Generator emits RTF + TXT; About Credits show stamp + rows; conditional GPL row handled per §7.1 |
| 10 [NOW] Step 10 packaging | §2.6 S10-1…S10-5 (S10-3 patch + `engine-distrib` release wiring) | Official distrib recorded; `tools/fetch-engine.sh --run` fills `Vendor/cef/`; provenance check A-1 passes |
| 11 [NOW] Release script | §9: `tools/release.sh` (all phases + `--dry-run`), `assets/release/dmg-background.png` placeholder | `tools/release.sh --dry-run` exit 0 with §9.4 rows green or mode-SKIP; `bash -n` clean; second run is a no-op (stamps) |
| 12 [USER] Credentials | §10 U-1…U-5 (+ U-6 before first public release): cert, `open-notary` profile, real `SUPublicEDKey`, Pages on | `find-identity` lists Developer ID; `notarytool history` exit 0; feed URL returns 404-then-200 across enablement (not an error page redirect) |
| 13 [USER] First production release | Bump versions (§8.1), notes (§8.3), `tools/release.sh`, §9.4 full table, tag (§8.2), publish (§8.4) | A-1…A-15 green (A-13 on the second release; first release records "no predecessor"); `spctl` accepted on a second Mac or a fresh user account when available, else same-Mac evidence labeled as such |

One PR per step where practical (fork-infra rule). Every PR description
pastes real command output for its acceptance rows. Before any PR:
merge `origin/main`, run `tools/verify-all.sh`, paste its summary table
(AGENTS.md rule 10). No step in this plan adds a unit test.

---

## 12. File inventory (write ONLY these, plus §8 version edits)

New files:

```text
tools/release.sh
tools/release-locales.txt
tools/generate-acknowledgements.py
App/UpdaterController.swift
assets/release/dmg-background.png
docs/release/licenses.md
docs/release/licenses/MPL-2.0.txt
docs/release/licenses/GPL-3.0.txt
docs/release/licenses/MIT-Sparkle.txt
docs/release/licenses/BSD-CEF.txt
docs/release/notes/<marketing>.md        (one per release, §8.3)
```

Edited files:

```text
project.yml                               (bundle IDs §4.1, Release config §5.1, Sparkle §6.1)
App/Info.plist                            (§5.2 keys; Open* stamps on rebases)
App/Open.entitlements                     (§4.2)
App/AppDelegate.swift                     (updater ownership, §6.5; minimal diff)
App/MainMenu.swift                        (only if it still owns the Open menu, §6.5)
Helper/Entitlements/*.entitlements        (only on drift from §4.2)
Engine/fork/scripts/engine-distrib        (§2.6 S10-3 release wiring)
Engine/fork/patches/cef/series            (+ manifest + one patch, §2.6 S10-3)
docs/plans/release.md                     (this plan; status updates only)
```

Everything else is generated under `build/release/` (git-ignored), fetched
into `Vendor/cef/` (git-ignored), or installed under
`~/Developer/open-release-tools/` (outside the repo). If an implementation
step seems to need a file outside this list, stop and report.

---

## 13. Risks and open questions

| Risk | Impact | Handling in this plan |
|---|---|---|
| `make_distrib.py` patch (S10-3) breaks on CEF rebase | Release packaging blocks again | Patch is env-gated and byte-identical when unset (§2.6); S10-5 fallback is documented with its rebuild cost |
| PGO profile missing for a future Chromium pin | Release gate fires; no official build | §2.2 stops the release honestly; never ship phase 0 as release. New pin must bring its published profile |
| Sparkle private key lost | Shipped apps can never auto-update past that point | §6.2 offline backup [USER]; rotation path stated; key never in repo |
| Notarization rejects a helper or Sparkle XPC entitlement | Release stops late | §4.2 keeps exceptions minimal and per-role; §3.2 saves the full `notarytool log`; dry run cannot catch this — first production run is scheduled with slack |
| Proprietary-codec patent exposure (H.264/AAC) | Distribution risk, not a build failure | §7.1 states it verbatim; U-6 gates the first public release on review. Flags stay as the fork's lead decision set them |
| GPL-3.0 uBO assets bundled carelessly | Copyleft obligation missed | §7.1 conditional row + §7.3 either/or rule; absence must be stated, not implied |
| Keychain prompt repeats every launch | Users read it as malware behavior | §4.4: stable Developer ID signature + "Open Safe Storage" (C-11); repeated prompts = release defect |
| Feed published before assets | Every installed copy errors on check | §6.4/§8.4 order: Release assets first, feed last; A-12 verifies URLs after upload |

Open questions (defaults stated; lead may override in the release PR):

| # | Question | Default in this plan |
|---|---|---|
| Q-1 | Final Sparkle pin + tools SHA-256 | Latest stable 2.x at Step 7; recorded in that PR (§6.1) |
| Q-2 | Ship SwiftShader (16 MB) in v1? | Yes (§2.5); revisit with crash data |
| Q-3 | DMG Finder layout (icon positions, window size) | Placeholder background only (§3.3); polish later without changing the pipeline |
| Q-4 | Beta cadence and promotion rule | Copy-the-item promotion (§6.6); no auto-promotion |
| Q-5 | WebAuthn Keychain groups + restricted entitlements | Excluded in v1 (§4.2); separate tested follow-up |

None of Q-1…Q-5 blocks Steps 1–11. Only §10 blocks Step 13.

---

## Sources

- Sparkle documentation (setup, EdDSA keys in the Keychain, `generate_keys`,
  `generate_appcast`, delta updates, Library Validation note for ad-hoc
  builds): https://sparkle-project.org/documentation/
- Fork, GN, and Step 10 facts: [plans/fork-infra.md](fork-infra.md),
  [engine-fork.md](../engine-fork.md), `Engine/fork/gn/release.args.gn`.
- Sizes, Keychain item, helper set: [engine-spike.md](../engine-spike.md).
- Arc shipping facts (learn, do not copy): [re/bundle-anatomy.md](../re/bundle-anatomy.md).
- Chromium/CEF entitlement and distribution facts: read-only files listed
  in the header of this plan (paths inside
  `~/Developer/open-engine/chromium_git/chromium/src`).

*End of plan. Implementation starts at §11 Step 1.*






## Appendix — Lead decisions (2026-10-25)

- Approved as the M9 plan. Implementation is scheduled after app-shell integration (so the pipeline packages the real window), starting with the credential-free `tools/release.sh --dry-run`, entitlements, Acknowledgements, and versioning. The official engine build waits for the engine lead's patch series (it occupies the shared Chromium tree for hours).
- Sparkle 2 is an approved third-party dependency (reason: industry-standard signed updates; MIT license).
- Items needed from the user are tracked in the plan; nothing is purchased or created on the user's behalf.
