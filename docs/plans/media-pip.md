# Media controls and Picture in Picture — implementation plan for Open

Status: plan (2026-10-25). Implementers: coding agents with no other
context, plus the engine lead for §6. Follow this file literally. Where
this file says "Open choice", the choice is final for v1 unless the lead
changes it in the appendix. Where it says "guess", build the stated value
and keep it in one token so a later capture can fix it in one edit. Cite
the rule IDs (PP-n) from `docs/re/features-advanced.md` §8 in code
comments where a behavior comes from Arc.

User-visible text never uses the Arc brand (AGENTS.md). Do not copy Arc
assets, code, or data files. SF Symbols are system glyphs and are allowed.
Draw every other glyph yourself. No unit tests (AGENTS.md rule 6): verify
through the offscreen render harnesses and the real app over the
automation channel (§8).

Read first, in this order: `AGENTS.md`; `docs/re/features-advanced.md`
§8 (PP-1…PP-22, the evidence for this plan); `docs/re/features-core.md`
§1.1 rules 6 and 10; `docs/re/design-tokens.md` §1.8;
`docs/re/menus-and-hotkeys.md` "Media and Picture in Picture";
`docs/engine-api.md`; `docs/engine-patches.md` (P1, P6);
`docs/sleep.md`; `docs/plans/memory-fork.md` §12;
`docs/plans/app-shell.md` §4.7, §4.13, §7 (Steps B and G);
`docs/plans/settings-library.md` §2 and §5.5; `docs/design.md` §4–§6;
`docs/automation.md`.

## Goal

Ship Arc's media features in Open:

1. The per-tab audio indicator in sidebar rows, with click-to-mute and
   a recording indicator for tabs that use the camera or microphone.
2. The sidebar media controls: a stack of mini players above the bottom
   bar, one card per media source that plays outside the visible tab.
3. Automatic Picture in Picture when the user leaves a tab that plays
   a video, with Arc's rules, and the Advanced setting that turns it off.
4. A PiP window with Arc's controls and settings menu, and a Document
   PiP window for pages that ask for one.
5. macOS Now Playing and the keyboard media keys, through the engine.

## Success criteria

1. A tab that plays sound shows a speaker in its row. A click mutes or
   unmutes it, and the mute survives quit and relaunch. A tab that uses
   the camera or microphone shows a recording indicator.
2. When a tab plays media and is not the visible tab of its window, a
   mini player appears above the bottom bar of that window within one
   run-loop turn of the engine event. It shows the tab favicon and
   title, play/pause, previous/next track when the page offers them,
   volume, and Picture in Picture for video. It goes away when the
   source stops, closes, or becomes visible.
3. Leaving a tab that plays an audible video opens PiP within 500 ms.
   Returning to the tab closes PiP and the video keeps playing inline.
   Every negative rule in §4.5 holds (setting off, inaudible, disallowed
   host, host turned off, snoozed tab, `disablePictureInPicture`).
4. The PiP window has Close, Minimize, settings menu, play/pause, skip
   ±15 s, scrubber with precision seeking, Back to Tab, and Mute. Its
   menu has exactly Arc's items in Arc's order (PP-8).
5. Control Center shows the playing page's title and artist with
   Open as the app, and the play/pause, next, and previous media keys
   reach the page (manual check by the user, §8.5).
6. A tab that plays media, owns a PiP window, or shows a mini player
   never freezes or discards (`docs/sleep.md` gates).
7. Idle CPU with a paused mini player on screen equals idle CPU without
   it (no timers, no display links). Sidebar scroll p95 stays within
   the `docs/design.md` §11 numbers.
8. `sidebar-render check`, `features-render check`, `openkit
   media-demo`, and the `--only media` e2e suite pass.
   `tools/verify-all.sh` passes for every target that exists.

## Non-goals

- No Arc account, sync, or analytics. Arc's analytics enums (PP-15)
  are evidence only.
- No Cast or remote playback (`MediaRouter` is in the disabled feature
  list of `docs/plans/memory-fork.md`).
- No artwork, artist, or progress bar in the mini player. Arc shows the
  tab title and favicon only (PP-15). Artwork goes only to Now Playing,
  which Chromium owns.
- No new default keyboard shortcuts. Arc has none for media or PiP
  (PP-21).
- No Widevine content in PiP (Widevine is out of v1,
  `docs/engine-patches.md` P4).
- No Meet chat toggle in the Document PiP top bar in v1 (Q12).

## 0. Locked decisions

| # | Decision | Evidence / reason |
|---|---|---|
| D-1 | The media UI is one app-wide store of media sources plus one mini player stack per window. A window shows only its own sources. | PP-14, PP-18: one `MediaControlsDataStore`, one `MediaControlsFeatureController` per window ID. |
| D-2 | The mini player uses the tab title and favicon. It does not use media-session metadata or artwork. | PP-15: the player observes only `title`, `icon`, `mediaSessionState`, `isTabMuted`, `tabURL`. ArcCore has no metadata delegate call (arccore-engine §2.6). |
| D-3 | The mini player stack lives in its own container between the Space pager and the bottom bar. The bottom bar gets no media button. | PP-20; the measured bottom bar is Home, switcher, plus (runtime-observations §1.1). Placement is confirmed by S2 14b/0014: the stack touches the bottom bar, with 8 pt above (§13.3.1). |
| D-4 | Auto-PiP opens on tab leave (tab switch, Space switch, or a split change that stops showing the tab) only. Window minimize, occlusion, and app hide do not open it in v1. | PP-3: occlusion is a separate engine flag; Chromium's `kAutoPictureInPictureOnWindowOccluded` is off by default (`media/base/media_switches.cc:374`). Q4. |
| D-5 | Auto-PiP needs an audible playing video, unless the site rule says `activatesWhenInaudible` (YouTube). | PP-11 (`activatesWhenInaudible` exists only to relax an audible rule). |
| D-6 | Open ships its own site-rule file with the same facts as Arc's `pipDisallowList` and `pipSiteConfigs`, in Open's own JSON format. | PP-11, PP-12. Facts are allowed; the file is not copied (AGENTS.md rule 1). |
| D-7 | Settings: one user-facing toggle (Advanced A-2, existing key `open.advanced.enablePictureInPictureOnLeave`, default ON). The per-host choice lives only in the PiP window menu. Two new app keys (§5). No second store. | PP-13; `docs/plans/settings-library.md` §2.1, D-5. |
| D-8 | Phase 1 uses Chromium's own PiP window (it works today: `docs/engine-spike.md`, "Picture in Picture | pass", a 384×216 `NativeWidgetMacFramelessNSWindow`). Phase 2 replaces it with Open's own window when engine request EM-4 lands. Rules, menu state, and the mini player do not change between phases. | PP-10: Arc hosts the engine's video view in its own window. Shipping behavior first keeps the UI work unblocked. |
| D-9 | Now Playing and media keys come from Chromium's stock system media controls. Open adds no MediaPlayer code of its own. | PP-22. |
| D-10 | Packages never import OpenEngine. Media logic lives in a new `OpenMedia` library over new `OpenWeb` protocols. Views live in `OpenSidebar` (mini players, row indicator) and `OpenFeatures` (PiP windows). Only `App/` joins them to the engine. | `docs/architecture.md`; app-shell D2. |
| D-11 | Every animation uses Core Animation and stops when it ends. Nothing ticks while media is paused or hidden. ~~The marquee runs only while its source plays and its window is visible.~~ Step 3b removes the marquee (§13.2), so the mini player has no repeating animation at all. | AGENTS.md performance budgets (idle CPU near zero). |

## 1. What Arc does (summary of the evidence)

Full rules with evidence: `docs/re/features-advanced.md` §8. In short:

- Row indicator: an animated speaker icon (slash and waves animate on a
  mute change), click to mute; a recording indicator for camera or
  microphone use; Mute/Unmute in the tab menu; "Mute all tabs" and
  "Unmute all tabs" in the command bar (features-core rule 10, PP-19,
  PP-21).
- Mini players: per window, a stack of cards. The controls row contains
  favicon, previous, play/pause, next, and volume (or recording toggles).
  Hover expands every card to show a static title, back-to-PiP, and Close;
  there is no marquee (§13 supersedes the old design; PP-14…PP-17).
- Auto-PiP: leaving a tab with a playing video opens PiP; returning
  closes it. A global setting, a per-host "Turn off" in the PiP menu, a
  disallow list (Slack, Meet, Teams), and per-site control rules apply.
  Meet uses Chromium's own auto-PiP path and gets a Document PiP window
  (PP-3, PP-4, PP-11…PP-13).
- PiP window: Arc's own window around the engine's video view; corner
  Close and Minimize (28 pt), play/pause, skip ±15 s, previous/next
  track, precision scrubber, Back to Tab pill, meeting controls, and a
  settings menu (PP-5…PP-10).
- Minimize hides the PiP window and turns the tab's mini player into the
  control, with an "Open Picture in Picture" button (PP-9, PP-15,
  PP-16).
- Now Playing and media keys: Chromium's system media controls (PP-22).

What no capture shows (all layout below is code constants or guesses):
the mini player, the PiP window, the Document PiP window, the recording
indicator. §11 lists the screenshots the lead must ask the user for.
Update 2026-10-26: capture session 2 shows the mini player at rest,
expanded, and stacked, and the auto-PiP window at rest. Its 33 pt
controls-only card at rest replaces the card described above; §13 is the
mini player spec now.

## 2. Current state (merged tree, origin/main c95be65, 2026-10-25)

Re-verify before you edit: `git log --oneline -3`, then read each file
you change.

| Area | State | Evidence |
|---|---|---|
| Tab model | `Tab.isMuted` is persisted (`TabDTO.isMuted`). `TabLiveState.isAudible`, `isCapturing` are runtime. `BrowserModel.setMuted(tabID:muted:)` registers undo. Arc import maps `savedMuteStatus == "mute"` to `isMuted`. | `Packages/OpenKit/Sources/OpenModel/LiveNodes.swift:10-26,43`; `BrowserModel.swift:524`; `OpenStore/SnapshotDTOs.swift:114`; `OpenImport/ArcImport.swift:392,743` |
| Row indicator | `TabCellView` builds a 20×20 `PlateButton` on demand after the title, y 10, SF `speaker.wave.2.fill` / `speaker.slash.fill` at 11 pt, tint `SidebarRole.rowAccessory`, no hover plate, AX "Mute tab"/"Unmute tab", action `.toggleMute(tabID:)`. Shown when audible or muted. No animation, no tooltip, no recording indicator. | `Packages/OpenKit/Sources/OpenSidebar/SidebarRows.swift:295-307,380-389`; `OpenDesign/Icons.swift:43-44` |
| Mute intents | `SidebarIntent.toggleMute` is model-only (`ModelSidebarActions`). The tab and split menus have Mute/Unmute, enabled when audible or muted. | `SidebarIntent.swift:41`; `ModelSidebarActions.swift:81-83`; `SidebarMenus.swift:94,158` |
| Commands | `mute-all-tabs`, `unmute-all-tabs` are registered (code-only, no keys). No handler in the App yet. `view-media` is the Library media page, not playback. | `OpenCommands/CommandRegistry.swift:297,384-385`; `docs/commands.md:264,310-311` |
| Sidebar layout | `SidebarView.layout()`: pager from the Favorites bottom to `h − 50`, bottom bar 50 pt. No media slot. | `OpenSidebar/SidebarView.swift:82-95` |
| Sleep | `SleepVisibilitySnapshot.pictureInPicture` exists and protects PiP tabs even when the window is minimized. Audio gate plus 60 s grace. `AppVisibilityProvider.pipTabIDs` exists and is never fed. | `OpenSleep/SleepEngine.swift:59-88`; `SleepPolicy.swift:9,25`; `OpenFeatures/AppVisibilityProvider.swift:11,36` |
| Engine | `OEWebContent.audible` (from a page-script probe of media elements; misses Web Audio; P6 replaces it), `muted` (settable), `capturingCamera`, `capturingMicrophone`, change bits `.audio` and `.mediaCapture`. No media session, no PiP API, no Document PiP disposition (`OEOpenDisposition` has no PiP case; CEF has `CEF_WOD_NEW_PICTURE_IN_PICTURE`). `evaluateJavaScript` runs with a user gesture. | `Engine/OpenEngine/include/OpenEngine/OEWebContent.h:31-45,195-204,281-290`; `Engine/OpenEngine/src/OEApp.mm:121-151`; `docs/engine-api.md` |
| Fork | No Open patches applied yet (`Engine/fork/patches/*/series` hold only headers). | `Engine/fork/patches/cef/series` |
| PiP today | `requestPictureInPicture()` from page script works and shows Chromium's own PiP window (Views, frameless, 384×216). In Alloy style CEF routes PiP to `PictureInPictureWindowManager::EnterVideoPictureInPicture`. CEF refuses PiP without user activation for Alloy pages. | `docs/engine-spike/results-features-alloy-fork.json` `picture_in_picture`; `cef/libcef/browser/alloy/alloy_browser_host_impl.cc:1136-1148`; `cef/libcef/browser/browser_platform_delegate.cc:571-574` |
| Now Playing | Not verified in Open. Chromium 156 enables `kHardwareMediaKeyHandling` on macOS and creates `SystemMediaControls` in `MediaKeysListenerManagerImpl`, which is content-layer code that CEF includes. | `media/base/media_switches.cc:659-661`; `content/browser/media/media_keys_listener_manager_impl.cc:328-360` |
| App | Plain M1 shell: copies `tab.isMuted` to the page on creation and `isAudible` from engine changes. The real window lands with app-shell Step B; the S6 sleep adapter with Step G. | `App/BrowserWindowController.swift:405,919`; `docs/plans/app-shell.md` §7 |
| Automation | `tabs` reports `audible`; `mute` command exists; the `features` suite has `audio` and `pip` checks that use a data-URI WAV and a remote WebM. | `docs/automation.md`; `tools/e2e/engine_e2e.py:410-445` |
| Settings | `OpenSettings` exists (M5). `SettingsDefaults.values` registers the app keys, including `open.advanced.enablePictureInPictureOnLeave: true`. The Advanced pane has the A-2 toggle ("Enable Picture in Picture when you leave a video tab"). Nothing reads the key yet. | `Packages/OpenKit/Sources/OpenSettings/SettingsTypes.swift:70-88`; `AdvancedPane.swift:46`; `docs/plans/settings-library.md` §2.1, §5.5 |

## 3. Architecture

### 3.1 Modules and files (create exactly these; edit only what is listed)

| Target | File | Contents |
|---|---|---|
| `OpenWeb` (edit) | `OpenWeb.swift` | `WebContentChange.media` (`1 << 13`) and `.pictureInPicture` (`1 << 14`); value types `WebMediaState`, `WebMediaActions`, `WebMediaAction`; protocols `WebMediaHost` and `WebPictureInPictureHost` (§7.1). |
| `OpenMedia` (new, depends on `OpenModel`, `OpenWeb`) | `MediaSource.swift` | `@MainActor @Observable final class MediaSource` (§4.3 fields). |
| | `MediaSourceStore.swift` | App-wide store: update, remove, ordering, visibility per window, paused auto-dismiss (§4.3). |
| | `AutoPiPPolicy.swift` | Pure decision function and its reasons (§4.5). |
| | `PiPSession.swift` | The PiP session state machine and per-tab snoozes (§4.4.6). |
| | `PiPSiteRules.swift`, `Resources/pip-site-rules.json` | Open's own site-rule file and its matcher (§4.5.4). |
| | `MediaSettings.swift` | Typed access to the three `UserDefaults` keys in §5 (injectable `UserDefaults`). Reads use `object(forKey:) as? T ?? default`, so they work before the App registers defaults. |
| `OpenSettings` (edit) | `SettingsTypes.swift` | Add `"open.pip.autoDisabledHosts": [String]()` and `"open.pip.keepOnTop": true` to `SettingsDefaults.values`. No new Settings UI (D-7). |
| `OpenDesign` (edit) | `FeatureMetrics.swift`, `Palette.swift`, `Typography.swift`, `Motion.swift`, `Icons.swift` | `MiniPlayerMetrics`, `PiPMetrics`, `RowMediaMetrics`; roles; fonts; motion tokens; glyph cases (§4). |
| `OpenSidebar` (edit, now depends on `OpenMedia`) | `MediaControlsView.swift` (new) | The stack container (§4.2). |
| | `MiniPlayerCardView.swift` (new) | One card (§4.2.3). |
| | `MarqueeLabel.swift` (new) | Layer-based marquee (§4.2.5). |
| | `SidebarRows.swift`, `SidebarView.swift`, `SidebarContext.swift`, `SidebarIntent.swift`, `SidebarMenus.swift` | Row indicator upgrade (§4.1), layout slot, `media` and `displayedTabIDs` on the context, `.media(MediaIntent)` intent, menu wording unchanged. |
| `OpenFeatures` (edit) | `PictureInPictureWindowController.swift`, `PiPOverlayView.swift`, `PiPScrubberView.swift`, `PiPMenuBuilder.swift`, `DocumentPiPWindowController.swift` (all new) | Phase 2 PiP window and Document PiP window (§4.4, §4.6). Engine-free: they take an `NSView` and a `WebPictureInPictureHost`. |
| | `AppVisibilityProvider.swift` | Feed `pipTabIDs` and the new `mediaControlTabIDs`. |
| `OpenSleep` (edit) | `SleepEngine.swift` | `SleepVisibilitySnapshot.mediaControls: Set<ItemID>` (default `[]`), unioned in `visibleTabIDs(in:)` (§4.10). |
| `openkit` (edit) | `MediaDemo.swift` (new) | `openkit media-demo` (§8.1). |
| `sidebar-render` (edit) | `MediaScene.swift`, `MediaChecks.swift` (new) | `--media` scenes and MC/RI checks (§8.2). |
| `features-render` (edit) | `PiPScene.swift`, `PiPChecks.swift` (new) | `pip` command and PP checks (§8.3). |
| App | `App/Media/MediaCoordinator.swift` (new) | Owns the store, maps engine events, runs the policy, drives PiP windows and settings, feeds sleep (§7.2). |
| | `App/EngineBridge.swift` | `OEWebContent: WebMediaHost`, `OEPictureInPicture: WebPictureInPictureHost` (phase 2). |
| | `App/Automation/AutomationController.swift` | Commands in §8.4. |
| Tools | `tools/e2e/engine_e2e.py`, `tools/e2e/fixtures/media/*.html` (new) | `--only media` suite and its pages (§8.4). |
| | `tools/verify-all.sh` | Add `media-demo` to `NAMES`. |

`Package.swift`: add `.library(name: "OpenMedia", targets: ["OpenMedia"])`
and `.target(name: "OpenMedia", dependencies: ["OpenModel", "OpenWeb"],
resources: [.copy("Resources/pip-site-rules.json")])`; add `"OpenMedia"`
to the dependencies of `OpenSidebar`, `OpenFeatures`, `openkit`,
`sidebar-render`, `features-render`. On merge conflicts keep both sides
(AGENTS.md rule 10).

### 3.2 Data flow

```text
OEWebContent ──(EngineBridge: WebMediaHost, change .media/.audio/.mediaCapture)──▶ MediaCoordinator (App)
     ▲                                                                                │ update(tabID:, state:, windowID:)
     │ play/pause/next/volume/requestPiP/exitPiP                                       ▼
     └──────────────────────────────── MediaCoordinator ◀── SidebarIntent.media ── MediaSourceStore (OpenMedia, @Observable)
                                         │   ▲                                       │ visibleSources(window, displayed)
     window events (selection, Space,    │   │ AutoPiPPolicy.decide(...)             ▼
     split, close, minimize) ────────────┘   │                         MediaControlsView (OpenSidebar, per window)
                                             │
                     PiPSession (OpenMedia) ─┴─▶ phase 1: Chromium PiP window │ phase 2: PictureInPictureWindowController (OpenFeatures)
MediaCoordinator ──▶ AppVisibilityProvider (pipTabIDs, mediaControlTabIDs) ──▶ SleepController
```

Threading: everything above runs on the main actor. Engine media events
arrive on the main thread (`OEWebContentDelegate` is `NS_SWIFT_UI_ACTOR`).
Step 6 owns window teardown: stop the closing window's sidebar observations,
then call `MediaSourceStore.removeWindow(windowID:)` after moving or removing
its remaining sources. Empty window publications otherwise retain stable
identity until that explicit teardown.

Field-level observation contract (lead review round 2): Step 3 views must
read only the fields they draw. In particular, do not observe video area,
position, or a closed drawer's changing volume merely to build the card list.
`WindowMediaSources.allSources` names the uncapped card candidates;
`visibleSources(windowID:displayed:)` alone applies displayed exclusions and
the three-card cap. Sleep `mediaControls` is exactly that shown-card set plus
eligible non-controllable playing/paused sessions. Displayed, PiP-active,
and fourth controllable sources get no extra mediaControls protection;
OpenSleep's audible and PiP gates remain separate.

No work happens on a timer except the one paused auto-dismiss check
(§4.3), which is a single `DispatchWorkItem` for the earliest deadline.

## 4. Design spec

All sizes are points at sidebar width `W` (default 228). "Card-relative"
means from the card's top-left corner. Colors are token names; never
hard-code values in views.

### 4.1 Row audio indicator and recording indicator

Keep the existing slot logic in `TabCellView.layout()` (the button sits
2 pt after the title text and pushes the title's right edge). Change:

| Item | Spec |
|---|---|
| Speaker button | 20×20 at `x = titleX + min(textWidth, available) + 2`, y 10 (unchanged). Glyph: `NSImageView` with SF `speaker.wave.2.fill` (audible, not muted) or `speaker.slash.fill` (muted) at 11 pt Regular (`docs/design.md` §4). Tint: keep `SidebarRole.rowAccessory` (today's value). Arc passes a `foregroundTintColor` (features-core rule 10); its value is not known, so S9 decides. Hover plate: none (unchanged). |
| Mute change animation | `NSImageView.setSymbolImage(_:contentTransition: .replace.magic(fallback: .replace))`, system duration (≈ 0.25 s). Reduce Motion: no transition. No looping effect while audio plays (D-11). Arc animates slash and waves on change (`SpeakerIcon{slashStart, waveIncrement, waveReappearStart}`); this is the closest system effect. |
| Tooltip | "Mute tab" / "Unmute tab" (guess: Arc's text is a short inline string; its comments are "Tooltip; mutes the tab." / "Tooltip; unmutes the tab."). Placement beside the pointer, as row tooltips (interaction-states §5). Delay `TooltipMetrics.showDelay`. |
| Click | `.toggleMute(tabID:)` (exists). The App sets `OEWebContent.muted` from `tab.isMuted` on every change (§7.2). The row does not select the tab. |
| Recording indicator | Shown when `tab.live.isCapturing` (camera or microphone). 14×20 slot placed directly before the speaker slot (or at the speaker position when no speaker shows). Glyph: a 7 pt filled circle drawn in `SidebarRole.recordingIndicator` (new: light `#F53714`, dark `#F25E6B`, the `CommandBarColors.lockInsecure` pair; guess). Static; no pulse. Tooltip "This tab is using your camera or microphone" (Arc string, PP-19). No click action. |
| Build on demand | Both views are created only when first shown (keep the scroll budget, `docs/design.md` §11). |

`RowMediaMetrics` (OpenDesign): `buttonSize 20`, `gapAfterTitle 2`,
`y 10`, `recordingDot 7`, `recordingSlotWidth 14`, `glyphInsetX 2`.

**Capture session 2 amendment (2026-10-26; follow-up Step 2b to merged #67).**
Arc's row speaker is **leading**, not after the title, and uses outline
glyphs (`docs/re/interaction-states.md` §20.7; `docs/re/capture-session-2-results.md`
C18). Evidence: **S2 12/0022** (audible), **0027** (muted), **0013** (first
frame with audio) = frames of `.re/runtime/sessions/20261026-102922-12-media-row/`.
These rows replace the "Speaker button" row above and the trailing slot logic:

| Item | Spec | Mark, evidence |
|---|---|---|
| Speaker button | 26 × 26 at `[41, y + 7, 26, 26]`, right after the favicon (`[17, y + 11, 18, 18]`), on every row that is audible or muted. AX id parity `sidebarTabCellMuteButton`. | measured (AX frame, S2 12/0013, 0022, 0027) |
| Title | While the speaker shows, the title's AX frame moves from x 43 to x 69 and narrows by 26: Open's text origin moves from 44 to 70 (the 1 pt inset rule of `docs/design.md` §2.3). The right end is unchanged (close-button slot rule). | measured (AX title frames) |
| Glyph | Outline SF Symbols: `speaker.wave.2` (audible) and `speaker.slash` (muted), Regular, sized so the ink is ≈ 19 × 13 and ≈ 16 × 16 (start at 13 pt and fit in Step 2b), centered in the button. Not the `.fill` variants. | ink sizes measured; symbol size fitted |
| Tint | White ≈ 0.65 on the selected row (peak `#B8B8BE`), i.e. the row accessory tone; keep `SidebarRole.rowAccessory` and check it against the peak. | measured (S2 12/0022) |
| When | From the first frame with audio. | measured (S2 12/0013) |
| Hover plate | Like the close button: plate = button frame, radius 6, the row hover plate tone. | **guess** (the pointer did not trigger hover feedback) |
| Tooltip | Unchanged ("Mute tab" / "Unmute tab", guess): the speaker tooltip did not show for the synthetic pointer. | not captured |
| Recording dot | Not captured (the microphone steps were skipped). Keep it in the one placement function; default now **leading** too: a 14 pt slot directly after the favicon, before the speaker, and the title moves right by the slot width as well (**guess**: Arc names `hasLeadingRecordingIndicator`). | guess |
| Click, mute transition, build on demand | Unchanged (§4.1 rows above). | — |

`RowMediaMetrics` after Step 2b: `buttonSize 26`, `buttonX 41`, `buttonY 7`
(row-relative), `titleShift 26`, `recordingSlotWidth 14`, `recordingDot 7`;
`gapAfterTitle` and `glyphInsetX` are deleted.

Lead review decisions (2026-10-26): ~~speaker images share a left anchor at
slot x + 2 pt on one fixed image-view frame in both states.~~ **Superseded
2026-10-26 (capture session 2, C18; review r1 F8):** in the 26 pt leading
button both glyphs are centered (ink x 44–62 audible and 46–61 muted, centers
53.0 and 53.5 against the button center 54, S2 12/0022, 0027); keep one fixed
image-view frame equal to the button, centered. Keep native
replace outside a disable-actions transaction (lead clarification 2026-10-26).
If the unwrapped native call is proven to start no symbol-effect animation,
a finite 0.25 s Core Animation cross-fade is allowed as a fallback (lead
clarification 2026-10-26; record the failed native run in the PR). Reduce
Motion stays static.
Use a 14×20 recording slot, and hide it before the speaker when width is
limited. Keep recording placement in one function until S9 decides its side.

### 4.2 Sidebar media controls (mini player stack)

#### 4.2.1 Placement

`SidebarView` gains `mediaControls: MediaControlsView` between the pager
and the bottom bar:

```text
pager:          y = favTop + favH … h − 50 − C
mediaControls:  [0, h − 50 − C, W, C]
bottomBar:      [0, h − 50, W, 50]
```

`C` is 0 when the window has no visible source. Otherwise
~~`C = 4 + stackHeight + 4`~~ **superseded (Step 3b, §13.3.1):**
`C = 8 + stackHeight` (8 pt above the stack, 0 below; the card touches
the bottom bar). The pager keeps its scroll offset from the top when `C`
changes. ~~Guess (PP-20); fix with screenshot S3.~~ Fact since capture
session 2 (S2 14b/0014).

In the floating-card presentation (sidebar hidden and revealed) the
container works the same way. In a Peek the container dims with the
bottom bar (`SidebarRole.peekBottomBarOpacity`).

#### 4.2.2 Which sources a window shows

A source is one tab with live web content and either an engine media
session in state playing or paused, or camera or microphone capture
(§4.3). Window `X` shows source `S` when all hold:

1. `S`'s web content lives in `X` (its `OEBrowser` is `X`'s).
2. `S` is not displayed in `X`: not the selected tab of `X`'s focused
   Space, not a shown split pane, not the page of an open Peek.
3. `S` has no PiP window that is open and not minimized.
4. `S` is not paused for more than 60 min without user interaction
   (Open choice; Chromium's global media controls hide paused items
   after 60 min: `components/global_media_controls/public/media_session_item_producer.cc:18`).
5. `S` is among the 3 most recent sources of `X` (guess for Arc's
   `maxActiveMediaControls`, PP-18; Q2).

Lead review decisions (2026-10-25): retain playing and paused sessions even
when `isControllable` is false. They get no mini-player card, but their tab
IDs feed sleep protection through `mediaControls`. A paused session expires
at `max(pausedAt, lastInteractionAt) + 60 min` whether or not it is
controllable or has a card. Sleep protection ends at that expiry; interaction
restarts it. A playing session stays protected. Paused recording sources
follow the same expiry. A user Close is separate: that card stays dismissed
until the next transition to playing. A Peek is an auxiliary page with no
tab ID (PK-9), and never gets a mini-player card.

Order: most recent first, by the time the source last started playing or
last got user interaction. Little Open and Peek windows have no sidebar,
so their tabs never show mini players. Incognito windows show their own
sources only.

#### 4.2.3 Card layout (`MiniPlayerMetrics`) — superseded

**Tombstone (2026-10-26).** PR #92 built this table from guesses. Capture
session 2 measured Arc's mini player, and Step 3b (§13) replaces every row.
Do not build from the struck values. They stay here only so a reader can
see what changed.

| Element | Superseded value (#92) | Replaced by (Step 3b) |
|---|---|---|
| Card | ~~`[8, …, W − 16, 68]`, corner 10, fill `SidebarColors.itemBackground`, hover fill `SidebarColors.itemHoveredBackground`~~ | 33 pt at rest, 66 pt expanded; corner 10 continuous (now a fit); fill = the Space palette's `backgroundExtra`, opaque; no hover fill (§13.3.2, §13.4) |
| Title row | ~~`[0, 0, cardW, 36]`, always shown~~ | 33 pt row, shown only while expanded (§13.3.3) |
| Favicon | ~~`[9, 9, 18, 18]` in the title row~~ | controls slot 0: a 16 pt favicon in a 24 pt button (§13.3.2) |
| Title | ~~x 35, baseline 23, 13 Medium, the row title color, marquee~~ | x 14, baseline 22, 13 Regular, `Core.foregroundPrimary`, static tail truncation (§13.3.3, §13.4) |
| Open Picture in Picture | ~~`[cardW − 30, 6, 24, 24]`, `pip` 12 pt Regular~~ | `[cardW − 58, 5, 24, 24]`, `pip` 12 pt Medium (§13.3.3) |
| Close | ~~`[cardW − 30, 6, 24, 24]`, width 0 ↔ 24 on card hover~~ | `[cardW − 34, 5, 24, 24]`, always in the title row (§13.3.3) |
| Controls row | ~~`[0, 36, cardW, 32]`, buttons at y 40~~ | `[0, H − 33, cardW, 33]`, buttons at row y 5 (§13.3.2) |
| Play group | ~~x 6 / 34 / 62 (pitch 28); Previous/Next hidden without the actions~~ | five even slots; Previous/Next always shown, disabled without the actions (§13.3.2) |
| Volume | ~~`[cardW − 30, 40, 24, 24]`, `speaker.wave.2.fill` 14 pt Regular~~ | slot 4, `speaker.wave.3.fill` 14 pt Medium (§13.4.3) |
| Recording source | ~~Microphone x 6, Camera x 34~~ | slots 1 and 2 (guess, §13.7 O5) |
| Glyph color | `SidebarRole.mediaControlGlyph` (kept) | plus a disabled role (§13.4.1) |
| Tooltips | ~~`placement: .above`~~; delay 0.45 s (kept) | `.beside` (§13.4.4) |
| Volume drawer | ~~28 pt row under the controls, card 96~~ | 33 pt row between the title row and the controls row, only while expanded (guess, §13.7 O2) |

Click targets (kept, with one addition): the title, the favicon button
(new, guess), and empty parts of the card select the source tab ("Back to
Tab": selects the tab in its window, switches the window to the tab's
Space, brings the window front). Other buttons do not select.

#### 4.2.4 Stack — superseded

**Tombstone (2026-10-26).** Replaced by §13.3.4: back cards 7 pt up, 5 pt
inset per side per level, opacity `1 − 0.2·i`, not masked, no top edge;
expanded cards 66 pt and 5 pt apart; one card also expands on hover. The
struck rows below are #92's guesses.

| State | Layout (superseded) |
|---|---|
| One source | ~~One card. `stackHeight = 68` (96 with the drawer).~~ |
| Several, pointer outside the container | ~~The front card (most recent) is laid out as above. Card `i` (1, 2) sits behind it, offset up by `5·i` pt, inset `6·i` pt on each side, opacity `1 − 0.3·i`. Only its top 5 pt show. Each back card has a 0.5 pt top edge in `SidebarColors.separator` at the card opacity (review-r1 guess; confirm S6). `stackHeight = 68 + 5·(n − 1)`.~~ Guess from `MiniPlayerViewState{yOffset, widthOffset, opacity}` (PP-14). |
| Several, pointer over the container | ~~Cards lay out top to bottom, oldest on top, front card at the bottom, 6 pt apart. `stackHeight = Σ heights + 6·(n − 1)`.~~ Expand at once on pointer enter; collapse 0.3 s after pointer exit (Arc has an immediate and a debounced hover-off; values guessed; kept in §13.6). Spring `Motion.miniPlayerStack` (response 0.2, damping 1.0; guess from the measured Space spring). The pager shrinks with it (kept; fact in S2 14b/0024). |

#### 4.2.5 Marquee title — removed

**Tombstone (2026-10-26).** Step 3b removes the marquee (§13.2). Arc showed
a static, tail-truncated title with "…" on every captured title (S2
14b/0024; 16/0012, three cards). The PP-17 numbers stay valid as code facts
if a later capture shows scrolling (§13.7 O12). The text below is history.

Our `MarqueeLabel` is a layer: a text layer inside a container with a
gradient mask. When the title is wider than its slot, it scrolls: wait
3 s, move left at 30 pt/s through `textWidth + 32`, jump back (a second
copy of the text 32 pt after the first makes the loop seamless), repeat.
Mask fades: 4 pt on the left, 8 pt on the right. Code numbers 4, 8, 32,
3.0 come from Arc (PP-17); the 30 pt/s speed is a guess for Arc's speed
factor 1.0.

Run the animation (a repeating `CABasicAnimation` group on the text
layer) only when the source is playing, the window is visible and not
miniaturized, the sidebar is shown, the title row is not hovered, and
Reduce Motion is off. Otherwise remove the animation and show the start
of the title with the right fade.

#### 4.2.6 States

Step 3b (§13.5) adds the visual states (rest, expanded, hover, disabled,
light). The rows below still hold, except the struck text.

| State | Mini player |
|---|---|
| Playing | Pause glyph; ~~marquee may run~~ static title (§13.2). |
| Paused | Play glyph; static title; auto-dismiss after 60 min without interaction (§4.2.2). |
| Muted tab | Volume glyph `speaker.slash.fill`. |
| Video source, PiP open | No card (rule 3). |
| Video source, no open PiP (minimized, closed, or auto-PiP off) | Card with "Open Picture in Picture" button. |
| Recording source | Microphone/camera toggles; no play group. |
| Source in another Space of the same window | Card shows (main use: music in one Space, work in another). |
| Source in another window | Card shows only in its own window. |
| Source becomes displayed | Card leaves (§4.2.7). |
| Session ends (no controllable player), tab closes, archives, discards, or crashes | Card leaves. |
| Close (×) clicked | Pause the source, remove the card. The card comes back only when the source plays again. Guess (Q5). |

#### 4.2.7 Transitions

Step 3b (§13.6) is the full transition table. It keeps the rows below
except the struck one, and adds hover expand and collapse.

| Change | Animation |
|---|---|
| First card appears | Container height 0 → `C` with `Motion.rowStructure` (0.22 s ease-in-out); card fades in 0.15 s, starting 0.05 s after the height starts. |
| Last card leaves | Card fades out 0.12 s, then height `C` → 0 in 0.22 s. |
| Card added or removed in a stack | Cards move with `Motion.miniPlayerStack`; the leaving card fades 0.12 s. |
| Play/pause glyph | `.replace` symbol transition (system). |
| Close button reveal | ~~Width 0 ↔ 24 and opacity, 0.15 s.~~ Removed: Close is part of the title row (§13.3.3). |
| Reduce Motion | All of the above become 0.1 s cross-fades without movement. |

### 4.3 Media source model (`OpenMedia`)

`MediaSource` (`@MainActor @Observable`, runtime only, never persisted):

| Field | Type | From |
|---|---|---|
| `origin` | `.tab` / `.auxiliaryPage` | App; auxiliary sources never have cards (PK-9) |
| `tabID` | `ItemID?` | App; nil for an auxiliary page |
| `pageID` | `UUID?` | Runtime auxiliary-page identity; nil for a tab |
| `windowID` | `WindowID` | the window whose `OEBrowser` holds the content |
| `kind` | `.audioVideo` / `.recording` | `.recording` when capturing and no playing session (PP-15) |
| `playback` | `.playing` / `.paused` / `.none` | `WebMediaState.playback` |
| `isControllable` | `Bool` | engine; false suppresses the audio/video card, but not session sleep protection |
| `hasVideo`, `largestVideoArea` | `Bool`, `Double` (CSS px²) | engine |
| `actions` | `WebMediaActions` | engine |
| `isMuted` | `Bool` | `tab.isMuted` |
| `volume` | `Double?` | engine (EM-2); nil when not offered |
| `microphoneOn`, `cameraOn` | `Bool?` | engine |
| `pip` | `.none` / `.active(auto: Bool)` / `.minimized` | `PiPSession` |
| `lastStartedAt`, `lastInteractionAt`, `pausedAt` | `Date?` | store |

`MediaSourceStore` API:

```swift
@MainActor @Observable public final class MediaSourceStore {
    public init(clock: @escaping () -> Date = Date.init, scheduler: any MediaDismissScheduling = DispatchMediaDismissScheduler())
    public private(set) var sources: [ItemID: MediaSource]
    public func update(tabID: ItemID, windowID: WindowID, state: WebMediaState, isMuted: Bool, isCapturing: Bool)
    public func remove(tabID: ItemID)
    public func move(tabID: ItemID, toWindow: WindowID)
    public func removeWindow(windowID: WindowID)
    public func updateAuxiliaryPage(pageID: UUID, windowID: WindowID, state: WebMediaState, isMuted: Bool, isCapturing: Bool)
    public func removeAuxiliaryPage(pageID: UUID)
    public func sourceList(windowID: WindowID) -> WindowMediaSources
    public func sleepProtectedTabIDs(windowID: WindowID, displayed: Set<ItemID>) -> Set<ItemID>
    public func dismiss(tabID: ItemID)
    public func noteInteraction(tabID: ItemID)
    public func setPiP(tabID: ItemID, _ pip: MediaSource.PiP)
    /// Rules 1–5 of §4.2.2, most recent first.
    public func visibleSources(windowID: WindowID, displayed: Set<ItemID>) -> [MediaSource]
    public static let maxVisible = 3            // guess (Q2)
    public static let pausedTimeout: TimeInterval = 3600
}
```

The default scheduler keeps one real `DispatchWorkItem` for the earliest
paused deadline and reschedules it when deadlines change. `media-demo`
injects the same dispatch scheduler with short wall-clock delays, advances
the domain clock, and waits for actual dispatch delivery. Removing the
`asyncAfter` call must fail MS5. Expiry republishes each affected window's
list; it never sets the separate user-dismiss flag. A user-dismissed paused
entry still has a deadline and is removed from the registry at expiry; the
next playing event creates it again. Identical updates do
not replace dictionary entries or publish a window list. A source move
and a close/archive/crash are explicit events, with no final media update
required. Nothing else is timed.

### 4.4 Picture in Picture window

#### 4.4.1 Phase 1 (Chromium's window)

Until EM-4 lands, PiP shows in Chromium's own frameless window. Open
still owns the rules (§4.5), the session (§4.4.6), the mini player, and
sleep protection. Chromium's window offers its own Back to Tab, Close,
and play/pause; its Back to Tab arrives through
`webContentDidRequestFocusFromPictureInPicture` if EM-4's delegate call
exists, else the App learns about it only as a PiP exit. State this limit
in the Step 6 PR.

#### 4.4.2 Phase 2 window (`PictureInPictureWindowController`, OpenFeatures)

| Property | Value |
|---|---|
| Window | `NSPanel`, style `[.borderless, .nonactivatingPanel, .resizable]`, `isFloatingPanel = true`, `hidesOnDeactivate = false`, `isMovableByWindowBackground = true`, `hasShadow = true`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`. Content view layer: corner radius `PiPMetrics.cornerRadius` 12 (guess), masks to bounds. |
| Level | `.floating` when "Keep Window on Top" is on (default, key `open.pip.keepOnTop`), else `.normal`. `toggleAlwaysOnTop` exists in Arc (PP-8); the default is a guess. |
| Content | The engine's `videoView` fills the window. The overlay (§4.4.3) sits above it. |
| Initial size | Fit the video's natural aspect inside `visibleFrame.width / 8` × `visibleFrame.height / 8` on the source window's screen, then clamp to the orientation-aware minimum and 50% maximum. The /8 factor fits capture session 2 item 13 exactly at 2560×1440; it is a guess elsewhere (lead decision, 2026-10-26 11:25). This replaces the earlier Chromium /5 rule. |
| Initial position | Bottom-right of that screen's `visibleFrame`, inset 10 pt from the right and bottom (capture session 2 item 13). Later opens in the same app run reuse the last frame's origin and LONG side, clamped to the current video's limits. Not persisted. |
| Resize | `contentAspectRatio` = natural size; minimum box 284×160 for landscape, rotated to 160×284 for portrait, with the natural aspect preserved. Square remains 284×284. Landscape minimum comes from Chromium `kMinWindowSize` (`video_overlay_window_views.cc:109`); portrait rotation is Open lead design. Maximum is 50% of `visibleFrame` in each dimension (guess). A natural-size change (`didChangePiPVideoResolution`) keeps the width and updates the height. |
| Size class | Compact below 300 pt wide, regular otherwise (guess; Arc has `PIPSizeClassKey`). |

Lead size decision (2026-10-26 02:47 America/Vancouver), amended by the
11:04 and 11:25 lead decisions: preserve aspect and the 50% maximum, and
never reject a valid video because size limits conflict. Use an orientation-aware
minimum box: 284×160 for landscape, 160×284 for portrait. Fit the natural aspect
so both minimum dimensions hold when possible; if the cap cannot contain that
box, relax the minimum so the 50% cap wins. Square remains 284×284. A 9:16 video
can shrink to about 160×284 on every screen in PP6's six-height matrix. Its
maximum on a 900 pt visible height is still about 253×450. AppKit can round
native frames by one point. Compact controls apply below PiPMetrics.compactWidth.

The 09:23 first-open clamp remains, but the 11:25 decision replaces its /5
fit with /8 for both orientations. On 2560×1440, 16:9 opens at 320×180. On
1920×1080, the 240×135 fit clamps up to the 284×160 minimum box. For 9:16,
the /8 fit stays below the rotated minimum through PP6's heights 900, 1010,
1080, 1440, 1600 and 2160. Later opens still reuse the last LONG side and
origin, clamped to the current video's limits and screen. Nothing persists.

Evidence: lead-provided measurements for capture session 2 item 13,
`.re/runtime/sessions/20261026-103015-13-auto-pip`: a 16:9 YouTube video
opened at 320×180 on a 2560×1440 screen, top-origin screen position
(2230,1250), exactly 10 pt from the right and bottom. The /8 factor is a fit
to this one data point, exact there and a guess elsewhere. The raw frames
remain local. PP6 uses fresh CLI processes to read first frames before any
resize, then minimum frames, for both orientations on all six heights; it
also checks the 10 pt bottom-right insets. This avoids static lastFrame
from an earlier fixture contaminating first-open evidence.

#### 4.4.3 Overlay controls (`PiPOverlayView`)

All glyphs white; plates black. Values are guesses except where marked
"code" (PP-6) or "Arc" (PP-5…PP-8). Screenshots S1, S2 will fix them.

| Control | Frame / style | Shows when |
|---|---|---|
| Top scrim | Gradient black 0.5 → 0 over the top 56 pt | Controls visible |
| Bottom scrim | Gradient black 0 → 0.6 over the bottom 64 pt | Controls visible |
| Close | 28×28 circle (code) at `[p, p]`, `p` = 8 compact / 10 regular (code); SF `xmark` 12 pt Semibold; plate black 0.4, hover 0.55 with scale 1.08 (`GrowOnHover`) | Unless the site rule hides Close (Meet, PP-11). Tooltip "Close" (code). |
| Minimize | 28×28 at `[p + 32, p]`; SF `minus` 13 pt Bold | Always (Arc `minimizeEnabled`, default on). Tooltip "Minimize" (code). |
| Settings | 28×28 at `[w − p − 28, p]`; SF `ellipsis` 13 pt Bold; tooltip/AX label "Options"; click opens the menu (§4.4.5) under the button | Always |
| Play/Pause | 48×48 centered; SF `play.fill`/`pause.fill` 28 pt (regular) or 24 pt (compact) | Unless `disablePlayButton` |
| Skip back / ahead 15 s | 40×40 at center ∓ 72 (regular) or ∓ 56 (compact); SF `gobackward.15` / `goforward.15`, 20 pt Regular / 16 pt compact | Unless `disableSkipButton`, the duration is not finite (live), or the width is below 168 pt. Skip ahead is disabled at end-of-media, opacity 0.4 (Open guess from design r1); disabled Skip ahead has no hover plate or grow, while its tooltip remains. Tooltips "Skip back 15 seconds" / "Skip ahead 15 seconds" (Arc). |
| Previous / Next track | 32×32 at center ∓ 120, SF `backward.end.fill`/`forward.end.fill` 16 pt | Regular size only, when the session offers them |
| Back to Tab | Pill, height 24, horizontal padding 10, text "Back to Tab" 12 Semibold white, plate black 0.4 / hover 0.55 / pressed 0.7, at bottom-left on the shared bottom-row center line below | Always (Arc `BackToTabButton`, `PIPPillActionButtonStyle`) |
| Mute | 28×28 at the trailing edge on the shared bottom-row center line below, SF `speaker.wave.2.fill` / `speaker.slash.fill` 13 pt | Always (Arc `toggleMute`) |
| Scrubber | §4.4.4, along the bottom inside `p` | Unless `disableScrubButton` or the duration is not finite |
| Skip Ad | Pill "Skip Ad", style as Back to Tab, bottom-right above Mute | When the session offers `skipAd` (Arc `skipAdButtonVisible`) |
| Meeting row | 32×32 circles centered at the bottom, 12 pt apart: microphone, camera, hang up (plate `#F53714`, SF `phone.down.fill`) | When the PiP reports meeting controls; then the play group hides (Arc `showMeetingControls`) |

Review r1 Open design (2026-10-26 09:23; guesses pending capture session 2):
play, skip and track controls have no plate at rest; hover/pressed plates remain.
A full-window black 0.25 dim appears with controls, in addition to the edge scrims.
Review r2 (lead, 2026-10-26 11:04): only the five center glyphs have a soft
black 0.35 shadow, radius 2 pt, zero offset, painted in their cached bitmap.
This remains a guess until a capture of the controls exists.
When Close is hidden, Minimize takes `[p, p]`. If Play is hidden, pack the
visible track buttons with a 16 pt gap (two track centers at ±24 pt).

Bottom controls share `yc = h − p − offset − 14`, with offset 16 when the
scrubber shows and 0 when it is hidden. Pill/Mute/meeting frames center on
yc. This gives `yc = h − p − 30` with a scrubber. A packed meeting row
centers at `yc − 14 − 6 − 16`.

Open layout detail (provisional until S1/S11): keep the meeting row centered
near the bottom. If it would overlap the always-visible Back to Tab or Mute
controls at a narrow width, stack it one row above them with the 6 pt gap.

Visibility: fade in 0.15 s when the pointer enters or moves; fade out
0.3 s when the pointer leaves, or 2.0 s after the last move while inside
(Arc `movedRecently`, `sustainedMovement`; times guessed). While a menu
is open or the scrubber drags, controls stay. Keyboard focus or
VoiceOver focus inside the window keeps them visible.

#### 4.4.4 Scrubber (`PiPScrubberView`)

Open design (lead decision, 2026-10-26 02:38 America/Vancouver): mouse-down
jumps to the clicked time. Refinement from the 09:23 review decision: a
plain click only seeks; it does not pause/resume. After at least 3 pt movement,
precision dragging pauses if playback was active, starts from that clicked
time and applies
the precision math below. Confirm this behavior against S1/S2. PP4 also
checks click-to-jump followed by a precision drag.

- Bar: `[p, h − p − 4, w − 2p, 4]`, radius 2, track white 0.3, fill
  white 0.9; 6 pt tall while hovered or dragging. Hit area 20 pt tall (Arc
  `draggableHeight`).
- Drag: horizontal movement seeks. Factor `m = min(8, 1 + floor(max(0,
  −dy) / 40))` where `dy` is the vertical distance from the drag start
  (up is negative). Time change = `dx / barWidth · duration / m`.
- While dragging, fade Back to Tab, Mute and Skip Ad out in 0.15 s, restore
  them in 0.15 s on release, and disable their hit testing during the drag.
- Label 11 pt Medium white 0.85, fading in/out over the same 0.15 s as the utility controls, truncated to `w − 2p`, centered 8 pt above the bar while
  dragging: "Drag upwards to seek precisely" when `m < 2`, else
  "Seeking at m× precision" (Arc strings, PP-7).
- The video pauses during the drag and resumes if it was playing
  (PP-7). Seek with `scrubTo` during the drag and `seekTo` at the end.
- Position display updates through one `CADisplayLink` that runs only
  while the controls are visible and the video plays.

#### 4.4.5 Settings menu (`PiPMenuBuilder`) — exact (PP-8)

1. "Keep Window on Top" — check mark = current level. Writes
   `open.pip.keepOnTop` and updates the window level at once.
2. Separator.
3. Only when the source URL has a host:
   - Disabled header: "Picture-in-picture on " + host + ":".
   - "Open automatically" — check mark when the host is not in
     `open.pip.autoDisabledHosts`. Choosing it removes the host.
   - "Turn off" — check mark when the host is in the list. Choosing it
     adds the host (Arc `autoPipTurnedOffUntilReenabled(host:)`).
   - Separator.
   - "Copy URL" — copies the source tab URL to the pasteboard.
4. "Mute" or "Unmute" — toggles `tab.isMuted`.

In an incognito window, "Turn off" and "Open automatically" change an
in-memory list for that window's session only; they never write the
app list (Open choice: no incognito host in persisted state).

Arc shows the radio pair with "Open automatically" always checked in the
decompiled branch; the check-mark rule above is a guess for the "turned
off" state (Q17, screenshot S2).

#### 4.4.6 PiP session (`PiPSession`, OpenMedia)

States follow Arc's `PIPSessionState` (PP-9), reduced to what Open
needs:

```text
idle → requesting(auto|manual) → active(auto|manual) → closed(reason)
                                    │  └→ minimized → requesting(manual) …
                                    └→ (requestFailed) → closed(.failed)
reasons: userClosed, minimized, backToTab, sourceShown, sourceGone, replaced, failed
```

One video PiP exists at a time app-wide (Chromium allows one). A new PiP
replaces the old one; the old session closes with `replaced`.

Per-tab snooze: after `userClosed` or `minimized`, auto-PiP skips that
tab until the tab is displayed again (Open choice; Arc keeps per-host
deadlines whose duration is unknown, PP-13, Q5).

#### 4.4.7 Transitions

| Change | Animation |
|---|---|
| Open | If the source rect is known (EM-4 `sourceBounds`, converted to screen with the source window's frame at leave time): the window frame animates from that rect to its target frame, `Motion.pipPresent` (spring response 0.3, damping 1.0), and the alpha goes 0 → 1 in the first 0.1 s. Else fade in 0.15 s. Arc has `presentationSourceRect` (PP-1 fields); the curve is a guess. |
| Back to Tab | After the tab is shown, the window animates into the video's rect in the content panel (0.25 s), then closes. |
| Close (×) | Fade out 0.15 s. |
| Minimize | Scale 1 → 0.9 and fade out 0.15 s toward the window's bottom-left; the mini player appears in the source window with its normal transition. |
| Reduce Motion | Fades only, 0.15 s. |

### 4.5 Auto-PiP rules (`AutoPiPPolicy`, exact)

#### 4.5.1 Leave events

A leave event for tab `T` fires when `T` stops being displayed in its
window `X` because of: a selection change in `X` (tab switch, Ctrl+Tab,
command bar switch, a new tab), a split change that stops showing `T`
(separating `T` from a shown split while another pane keeps the
selection), or a Space switch in `X`. Closing or archiving `T` itself is
not a leave event (its content closes).
These do not fire a leave event in v1: window minimize, window
occlusion, app hide, app switch, closing `X` (the content dies),
moving focus between panes of a shown split, opening a Peek over `T`
(`T` stays visible behind it), and dismissing a Peek (its page closes)
(D-4).

#### 4.5.2 Open conditions (all must hold)

| # | Condition | Source |
|---|---|---|
| A0 | `T` has no requesting/active session of its own, and `WebMediaState.isPictureInPicture` is false. Same-tab re-requests are idempotent. | Lead review decision, 2026-10-25 |
| A1 | `open.advanced.enablePictureInPictureOnLeave` is true. | PP-13 |
| A2 | `T` has a playing video (`hasVideo`, `playback == .playing`, largest video area ≥ 160×90 CSS px). | PP-3 (`isMediaPlayerActive`); size floor is an Open choice against hidden or tiny videos |
| A3 | `T` is audible (engine `audible`; a user-muted tab still counts, its sound is muted, not absent), or the site rule has `activatesWhenInaudible`. | PP-11, D-5 |
| A4 | `T`'s URL matches no disallow rule. | PP-12 |
| A5 | `T`'s host is not in `open.pip.autoDisabledHosts` (or the incognito window's in-memory list). | PP-8, PP-13 |
| A6 | `T` is not snoozed (§4.4.6). | Open choice |
| A7 | No manual PiP is active for another tab. (An auto PiP for another tab is replaced.) | Open choice |
| A8 | The chosen video does not have `disablePictureInPicture`. | Web standard; Q11 |

If `T` is in HTML fullscreen, Chromium exits fullscreen during the tab
switch; evaluate after that.

#### 4.5.3 Which video and when

- The playing video with the largest visible area at the leave event;
  ties go to the first in document order. (Chromium's own
  `MediaSessionImpl::EnterPictureInPicture` enters PiP only when the page
  has exactly one player, `content/browser/media/session/media_session_impl.cc:1340`,
  so the engine must choose: EM-5.)
- Request at once, in the same run-loop turn as the selection change,
  after the new tab is attached. No delay.
- On failure: log, mark the session `closed(.failed)`, no UI (PP-2).
  No retry until the next leave event.

#### 4.5.4 Site rules (`pip-site-rules.json`, Open's format)

```json
{
  "version": 1,
  "disallow": ["slack.com", "meet.google.com", "teams.microsoft.com"],
  "sites": [
    { "hosts": ["twitch.tv"],        "hide": ["play", "scrub", "skip"] },
    { "hosts": ["meet.google.com"],  "hide": ["close"] },
    { "hosts": ["youtube.com"],      "activatesWhenInaudible": true },
    { "hosts": ["open.spotify.com"], "hide": ["skip", "scrub"] },
    { "hosts": ["netflix.com"],      "hide": ["skip", "scrub"] }
  ]
}
```

Per-host user choices (lead review decision, 2026-10-25): lowercase the
host and remove a leading `www.` before storage. A disabled host matches
itself and its subdomains, using the same suffix boundary as site rules.
Turning off on `www.example.com` covers `example.com`, `www.example.com`,
and `video.example.com`; menus read that same state. Incognito choices
use the same matching in their main-actor session list.

Matching: a rule host matches the URL host or any subdomain of it
(`www.`, `m.`). Arc's own rules match any TLD of the same second-level
name (`youtube.*`, `twitch.*`; PP-11); Open matches the listed
registrable domains only (Open choice: smaller, predictable). The App
accepts `--pip-site-rules=PATH` (Debug builds) to replace the file for
e2e tests.

#### 4.5.5 Close rules

| Event | Auto PiP | Manual PiP |
|---|---|---|
| `T` displayed again in any window (selection, Space switch back, Back to Tab) | Exit PiP, no pause; video continues inline | Stays open (Open choice; Chrome behavior; Q6) |
| Back to Tab (PiP button or mini player title) | Select `T`, then exit, no pause | Same |
| Close (×) | Exit and pause; snooze `T` | Exit and pause |
| Minimize | Exit, no pause; `T` gets a mini player with "Open Picture in Picture"; snooze `T` | Same, without snooze |
| `T` closes, archives, discards, crashes, or navigates its main frame cross-document | Engine closes PiP; session `sourceGone` | Same |
| Setting A-2 turned off while open | Stays open | — |

#### 4.5.6 Meet and sites that register `enterpictureinpicture`

Chromium's `AutoPictureInPictureTabHelper` handles these (PP-4). It needs
to know when the tab becomes active or inactive: EM-6. The page then opens
a Document PiP window (§4.6). Open's own rule skips these sites (A4 for
Meet; for other registering sites the engine reports
`enterAutoPictureInPicture` in the actions and Open's rule yields to
Chromium's).

### 4.6 Document PiP window (`DocumentPiPWindowController`, OpenFeatures)

| Property | Value |
|---|---|
| Trigger | The page calls `documentPictureInPicture.requestWindow()`; the engine reports disposition `newPictureInPicture` with the requested size (EM-7). |
| Window | `NSPanel` like §4.4.2, not aspect-locked, min 284×160, level from "Keep Window on Top". Content size = requested size + top bar. Position: bottom-right, 16 pt inset. |
| Top bar | Height 28 (guess), fill `PiPRole.documentTopBar` (`#212123`, both appearances, design-tokens §1.8), 1 px hairline `PiPRole.documentHairline` (white 0.20) at the bottom. Left: the opener's favicon 16 pt at x 10. Then the opener's host, 12 Medium white 0.85. Right: settings `ellipsis` (menu: "Keep Window on Top", separator, "Picture-in-picture on <host>:" header) and close `xmark`, 20×20 each, 6 pt apart, 8 pt from the edge. Glyphs white 0.85 at rest / 1 on hover; hover plate white 0.12 / pressed white 0.18, radius 5 (Open review-r1 design). Ellipsis tooltip/AX label "Options". |
| Drag | The top bar drags the window (Arc `DocumentPIPGestureMode.acceptOverTopBar`). |
| Close | Closes the child page; Chromium returns elements to the opener. |

### 4.7 macOS Now Playing and media keys

- No Open code (D-9). Chromium sets `MPNowPlayingInfoCenter` (title,
  artist, album, artwork, duration, elapsed time, rate) for the active
  media session and answers `MPRemoteCommandCenter` play, pause, toggle,
  next, previous, and change-position commands.
- The App must not register its own `MPRemoteCommandCenter` handlers.
- Verify with check E-M11 (§8.4) and the manual checks in §8.5. If
  Chromium's controls do not start in CEF, the engine lead adds EM-9.

### 4.8 Keyboard, menus, commands

| Surface | Behavior |
|---|---|
| Default shortcuts | None new (PP-21). |
| Command bar | Wire `mute-all-tabs`: set `isMuted = true` on every tab that has live web content, app-wide, as one undo step. Wire `unmute-all-tabs`: set `isMuted = false` on every tab with `isMuted`, app-wide, one undo step. Scope is a guess (Q10). |
| Tab and split menus | Mute/Unmute (exist), enabled when audible or muted (F0116 shows it disabled on a silent tab). |
| Page context menu | Chromium's own "Picture in picture" item for videos passes through `OEContextMenu` (exists). It starts a manual PiP. |
| PiP window keys (when key) | Space: play/pause. Cmd+W: same as Close (pauses). Esc: nothing. (Open choice; the panel is non-activating, so it is key only after a click.) |
| Media keys | Chromium (§4.7). |

### 4.9 Accessibility

| Element | AX |
|---|---|
| Row speaker | Button "Mute tab" / "Unmute tab" (exists); help = tooltip. |
| Recording indicator | Image, label "This tab is using your camera or microphone". |
| Mini player card | Group; label "<tab title>, <host>, Playing" / "Paused" / "Muted"; role description "media controls". Identifier `media.miniPlayer.<tabID>` (automation). |
| Card title row | Button "Back to Tab, <tab title>". |
| Card buttons | Labels = tooltips: "Previous Track", "Play", "Pause", "Next Track", "Adjust Tab Volume", "Open Picture in Picture", "Close Mini Player", "Toggle Microphone", "Toggle Camera". |
| Volume slider | Slider "Tab Volume", value "NN%", increment 10 %. |
| PiP window | Title "Picture in Picture"; every control is an AX button with its tooltip as label; the scrubber is a slider "Playback position" with value "m:ss of m:ss"; controls stay reachable when hidden visually. |
| Reduce Motion | No marquee, no stack spring, no symbol transition, PiP opens and closes with fades (§4.2.7, §4.4.7). |
| Increase Contrast | Card gets a 1 pt `SidebarColors.separator` stroke; PiP plates go to black 0.6. |
| Announcements | None (a card appearing must not interrupt VoiceOver). |

### 4.10 Sleep and memory

| Case | Rule |
|---|---|
| Playing tab | Audible gate plus 60 s grace (exists). The App calls `tabAudioChanged` on every audible flip (`docs/sleep.md` hard contract). |
| PiP tab (active or requesting) | In `pictureInPicture` of the snapshot (exists); protected even when its window is minimized. |
| Playing or paused session without controls | Feed its tab ID through `mediaControls` even though no card shows. Playing stays protected; paused protection ends at `max(pausedAt, lastInteractionAt) + 60 min`, like a paused card (lead review decision, 2026-10-25). |
| Tab with a shown mini player (including paused and minimized-PiP sources) | New `SleepVisibilitySnapshot.mediaControls`; the App feeds the tab IDs of every card currently shown in a visible window. Protected while shown; the 60 min paused dismiss bounds the cost. |
| Recording tab | `isCapturing` gate (exists). |
| Change delivery | Call the visibility hooks right after a card appears or leaves and after a PiP opens or closes (app-shell §4.7). |

## 5. Data and persistence

All app-scope values go into the settings registry
(`docs/plans/settings-library.md` §2.1). This PR adds the two new rows
there; there is no other store.

| Key | Type | Default | Arc equivalent | Written by |
|---|---|---|---|---|
| `open.advanced.enablePictureInPictureOnLeave` (exists) | Bool | `true` | `autoPipGloballyDisabled` (inverse; absent from the live defaults = on, PP-13) | Settings A-2 |
| `open.pip.autoDisabledHosts` (new) | [String] (lowercase hosts) | `[]` | `autoPipDisabledForHosts` | PiP menu "Turn off" / "Open automatically" |
| `open.pip.keepOnTop` (new) | Bool | `true` | `PIPWindowController.toggleAlwaysOnTop` (persistence unknown) | PiP and Document PiP menus |

Not adopted: `autoPipDisabledDeadlines` (Open snoozes per tab, §4.4.6).
Per-tab mute stays `Tab.isMuted` in the snapshot (`schemaVersion` 1, no
change). Everything in §4.3 and §4.4.6 is runtime only. Import from Arc
does not import the PiP keys: they live in Arc's user defaults, outside
`~/Library/Application Support/Arc` (AGENTS.md rule 5).

Live effect: the coordinator reads the three keys at each leave event
and each menu open. No cache, no observer.

## 6. Engine API requests (for the engine lead's queue)

The shell needs these. Each names the ObjC surface, the Chromium source
it comes from, and an interim path where one exists. Proposed fork
series: `04xx` (the other plans use `00xx`, `01xx`, `03xx`). Effort
numbers are guesses for one engineer who knows Chromium.

| ID | Request | Needed by | Effort (guess) |
|---|---|---|---|
| EM-1a | Interim media state from the page probe (OpenEngine only, stock-CEF compatible) | Step 6 | 2–3 days |
| EM-1b | `OEMediaSession` from Chromium's media session (fork) | Step 8 | 1 week |
| EM-2 | Tab volume | Step 8 (volume drawer) | 2 days |
| EM-3 | Audible callback = P6 (exists in `docs/engine-patches.md`) | Web Audio sources | 1–2 days |
| EM-4 | PiP video view handed to the shell (fork) | Step 10 (phase 2 window) | 2–3 weeks |
| EM-5 | Shell PiP request and exit, with player choice and no user gesture | Step 6 (interim JS), Step 8 (fork) | 2 days |
| EM-6 | Tab activation for Chromium's auto-PiP | Step 11 (Meet) | 1 day after P1 |
| EM-7 | Document PiP disposition | Step 11 | 3–5 days |
| EM-8 | Media change notification bit | Step 6 | with EM-1a |
| EM-9 | Now Playing switch, only if E-M11 fails | — | 1 day |

### EM-1a. Interim media state (OpenEngine renderer probe)

Extend the probe in `Engine/OpenEngine/src/OEApp.mm` (`kAudibleProbe`,
which already hooks media element events in every frame at document
start) to report, per page, through the existing process-message channel:

- `playback`: playing if any element plays; paused if an element that
  played is paused; else none.
- `hasVideo`, `largestVideoArea` (CSS px² of the largest playing video
  that has `videoWidth > 0`), `pipActive`
  (`document.pictureInPictureElement != null`).
- `title`, `artist`, `album` from `navigator.mediaSession.metadata`, and
  `navigator.mediaSession.playbackState`.
- `duration`, `currentTime`, `playbackRate` of the last played element.

Commands through engine-owned scripts (not page-visible globals): play,
pause, seek on the last played element. Previous/next track are not
available in the interim (page action handlers cannot be invoked from
outside); report them as absent. Limit: a page can fake these values.
They drive UI only; no security decision uses them.

### EM-1b. `OEMediaSession` (fork; replaces EM-1a)

```objc
typedef NS_ENUM(NSInteger, OEMediaPlaybackState) {
  OEMediaPlaybackStateNone = 0, OEMediaPlaybackStatePaused, OEMediaPlaybackStatePlaying,
};
typedef NS_ENUM(NSInteger, OEMediaSessionStatus) {
  OEMediaSessionStatusInactive = 0, OEMediaSessionStatusActive,
  OEMediaSessionStatusSuspended, OEMediaSessionStatusDucking,
};
typedef NS_OPTIONS(NSUInteger, OEMediaActions) {
  OEMediaActionPlay = 1u << 0, OEMediaActionPause = 1u << 1,
  OEMediaActionPreviousTrack = 1u << 2, OEMediaActionNextTrack = 1u << 3,
  OEMediaActionSeekBackward = 1u << 4, OEMediaActionSeekForward = 1u << 5,
  OEMediaActionSeekTo = 1u << 6, OEMediaActionSkipAd = 1u << 7, OEMediaActionStop = 1u << 8,
  OEMediaActionEnterPictureInPicture = 1u << 9, OEMediaActionExitPictureInPicture = 1u << 10,
  OEMediaActionEnterAutoPictureInPicture = 1u << 11,
  OEMediaActionToggleMicrophone = 1u << 12, OEMediaActionToggleCamera = 1u << 13,
  OEMediaActionHangUp = 1u << 14, OEMediaActionPreviousSlide = 1u << 15,
  OEMediaActionNextSlide = 1u << 16,
};

NS_SWIFT_UI_ACTOR
@interface OEMediaPosition : NSObject
@property(nonatomic, readonly) NSTimeInterval duration;      // INFINITY for live streams
@property(nonatomic, readonly) NSTimeInterval position;      // at lastUpdated
@property(nonatomic, readonly) double playbackRate;
@property(nonatomic, readonly, copy) NSDate* lastUpdated;
@property(nonatomic, readonly, getter=isEndOfMedia) BOOL endOfMedia;
@end

NS_SWIFT_UI_ACTOR
@interface OEMediaSession : NSObject
@property(nonatomic, readonly) OEMediaPlaybackState playbackState;
@property(nonatomic, readonly) OEMediaSessionStatus status;
@property(nonatomic, readonly, getter=isControllable) BOOL controllable;
@property(nonatomic, readonly) BOOL hasVideo;
@property(nonatomic, readonly) BOOL hasAudio;
@property(nonatomic, readonly) CGSize largestVideoSize;      // CSS px of the largest playing video
@property(nonatomic, readonly) OEMediaActions actions;
@property(nonatomic, readonly, copy, nullable) NSString* title;
@property(nonatomic, readonly, copy, nullable) NSString* artist;
@property(nonatomic, readonly, copy, nullable) NSString* album;
@property(nonatomic, readonly, nullable) OEMediaPosition* position;
@property(nonatomic, readonly, getter=isPictureInPicture) BOOL pictureInPicture;
@property(nonatomic, readonly) BOOL microphoneMuted;
@property(nonatomic, readonly) BOOL cameraOn;
- (void)play;
- (void)pause;
- (void)previousTrack;
- (void)nextTrack;
- (void)seekBy:(NSTimeInterval)delta;
- (void)seekTo:(NSTimeInterval)time;
- (void)scrubTo:(NSTimeInterval)time;
- (void)skipAd;
- (void)stop;
- (void)toggleMicrophone;
- (void)toggleCamera;
- (void)hangUp;
@end

@interface OEWebContent (Media)
/// nil until the page creates a media session.
@property(nonatomic, readonly, nullable) OEMediaSession* mediaSession;
@end
```

Chromium source: `content::MediaSession::Get(WebContents*)`
(`content/public/browser/media_session.h`);
`MediaSession::AddObserver(mojo::PendingRemote<media_session::mojom::MediaSessionObserver>)`
with `MediaSessionInfoChanged` (`playback_state`, `state`,
`is_controllable`, `picture_in_picture_state`, `audio_video_states`,
`microphone_state`, `camera_state`), `MediaSessionMetadataChanged`,
`MediaSessionActionsChanged`, `MediaSessionPositionChanged`
(`services/media_session/public/mojom/media_session.mojom:61-218`);
commands through `media_session::mojom::MediaSession` (`Suspend`,
`Resume`, `PreviousTrack`, `NextTrack`, `Seek`, `SeekTo`, `ScrubTo`,
`SkipAd`, `Stop`, `ToggleMicrophone`, `ToggleCamera`, `HangUp`) as
implemented by `content/browser/media/session/media_session_impl.cc`.
Video sizes: `WebContentsObserver::MediaStartedPlaying(MediaPlayerInfo{has_video, has_audio})`,
`MediaStoppedPlaying`, `MediaResized`, `MediaPictureInPictureChanged`
(`content/public/browser/web_contents_observer.h:924-958`). Arc
equivalent: `ArcWebContentsMediaSession` (arccore-engine §2.6). New CEF
API in the overlay (`cef/include/cef_media_session.h`), guarded with
`CEF_API_ADDED(CEF_API_VERSION_EXPERIMENTAL)`, translator output
regenerated (engine-patches "How the patches are stored").

### EM-2. Tab volume

```objc
@interface OEMediaSession (Volume)
/// 0...1, multiplied into every player of the session. Default 1. Not persisted.
@property(nonatomic) double volume;
@end
```

Chromium has no per-tab volume. Patch `MediaSessionImpl`: add
`user_volume_multiplier_` and multiply it into `GetVolumeMultiplier()`
(`content/browser/media/session/media_session_impl.cc:899-901`), then push
it with `OnSetVolumeMultiplier` to every player as ducking does
(`:885-896`). Web Audio is not covered (state it). Arc equivalent:
`setVolume:error:`.

### EM-3. Audible callback

P6 in `docs/engine-patches.md` (`CefDisplayHandler::OnAudioStateChange`
from `WebContentsObserver::OnAudioStateChanged`, `web_contents_observer.h:805`).
No change to the request; this plan depends on it for Web Audio sources
(check E-M2).

### EM-4. PiP video view for the shell's window

```objc
typedef NS_ENUM(NSInteger, OEPictureInPicturePlaybackState) {
  OEPictureInPicturePlaybackStatePlaying = 0, OEPictureInPicturePlaybackStatePaused,
  OEPictureInPicturePlaybackStateEndOfVideo,
};
typedef NS_OPTIONS(NSUInteger, OEPictureInPictureControls) {
  OEPictureInPictureControlPlayPause = 1u << 0, OEPictureInPictureControlNextTrack = 1u << 1,
  OEPictureInPictureControlPreviousTrack = 1u << 2, OEPictureInPictureControlSkipAd = 1u << 3,
  OEPictureInPictureControlToggleMicrophone = 1u << 4, OEPictureInPictureControlToggleCamera = 1u << 5,
  OEPictureInPictureControlHangUp = 1u << 6, OEPictureInPictureControlNextSlide = 1u << 7,
  OEPictureInPictureControlPreviousSlide = 1u << 8,
};
typedef NS_OPTIONS(NSUInteger, OEPictureInPictureChange) {
  OEPictureInPictureChangeNaturalSize = 1u << 0, OEPictureInPictureChangePlayback = 1u << 1,
  OEPictureInPictureChangeControls = 1u << 2, OEPictureInPictureChangePosition = 1u << 3,
  OEPictureInPictureChangeSourceTitle = 1u << 4, OEPictureInPictureChangeFavicon = 1u << 5,
  OEPictureInPictureChangeMeeting = 1u << 6, OEPictureInPictureChangeMuted = 1u << 7,
};

NS_SWIFT_UI_ACTOR
@interface OEPictureInPicture : NSObject
@property(nonatomic, readonly, weak, nullable) OEWebContent* webContent;
/// Hosts the video surface. Put it in any window; the engine draws into it.
@property(nonatomic, readonly) NSView* videoView;
@property(nonatomic, readonly) CGSize naturalSize;
/// The video element's rect in webContent.view coordinates when PiP started.
@property(nonatomic, readonly) CGRect sourceBounds;
@property(nonatomic, readonly) OEPictureInPicturePlaybackState playbackState;
@property(nonatomic, readonly) OEPictureInPictureControls controls;
@property(nonatomic, readonly) BOOL microphoneMuted;
@property(nonatomic, readonly) BOOL cameraOn;
@property(nonatomic, readonly) BOOL mediaMuted;
@property(nonatomic, readonly, nullable) OEMediaPosition* position;
@property(nonatomic, readonly, copy) NSString* sourceTitle;
@property(nonatomic, readonly, nullable) NSImage* favicon;
/// The shell reports its window frame (screen coordinates) and visibility.
@property(nonatomic) CGRect windowFrame;
@property(nonatomic, getter=isWindowVisible) BOOL windowVisible;
- (void)togglePlayPause;
- (void)nextTrack;
- (void)previousTrack;
- (void)skipAd;
- (void)toggleMicrophone;
- (void)toggleCamera;
- (void)hangUp;
- (void)nextSlide;
- (void)previousSlide;
- (void)seekTo:(NSTimeInterval)time;
- (void)setMuted:(BOOL)muted;
- (void)closePausingVideo:(BOOL)pause;
@end

@protocol OEWebContentDelegate <NSObject>   // additions, all optional
- (void)webContent:(OEWebContent*)webContent didOpenPictureInPicture:(OEPictureInPicture*)pip;
- (void)webContent:(OEWebContent*)webContent pictureInPicture:(OEPictureInPicture*)pip
         didChange:(OEPictureInPictureChange)changes;
- (void)webContent:(OEWebContent*)webContent didClosePictureInPicture:(OEPictureInPicture*)pip;
/// Chromium asked to focus the source (FocusInitiator / CloseAndFocusInitiator).
- (void)webContentDidRequestFocusFromPictureInPicture:(OEWebContent*)webContent;
@end

@interface OEEngineConfiguration (PictureInPicture)
/// YES: PiP uses the shell's window through the delegate above. NO: Chromium's own window. Default NO until EM-4 ships.
@property(nonatomic) BOOL shellHostsPictureInPicture;
@end
```

Chromium source: implement `content::VideoOverlayWindow`
(`content/public/browser/overlay_window.h:41-72`; its setters map one to
one to the properties above, as Arc's `PiPFeature` does, PP-10) in a new
CEF class, and return it from
`ChromeContentBrowserClientCef::CreateWindowForVideoPictureInPicture`
(base: `chrome/browser/chrome_content_browser_client.cc:7488`; hook in
`cef/libcef/browser/chrome/chrome_content_browser_client_cef.cc`).
Commands go to `content::VideoPictureInPictureWindowController`
(`content/public/browser/video_picture_in_picture_window_controller.h:24-88`:
`TogglePlayPause`, `NextTrack`, `PreviousTrack`, `SkipAd`,
`ToggleMicrophone`, `ToggleCamera`, `HangUp`, `RequestMute`, `SeekTo`,
`PreviousSlide`, `NextSlide`, `GetSourceBounds`) and
`content::PictureInPictureWindowController`
(`picture_in_picture_window_controller.h:39-68`: `Close`,
`CloseAndFocusInitiator`, `FocusInitiator`). The hard part is
`SetSurfaceId(viz::SurfaceId)`: embed the surface in an NSView through a
`ui::Compositor` with a surface layer, as
`content/browser/renderer_host/browser_compositor_view_mac.mm` and
`ui/accelerated_widget_mac/` do for page views. Arc equivalent:
`ArcWebContentsMediaSessionPiPController.videoView`,
`sourceElementBounds`, and the `pip*Changed` delegate calls
(arccore-engine §2.6).

### EM-5. Shell PiP request and exit

```objc
@interface OEWebContent (PictureInPictureRequest)
/// Enters PiP for the playing video with the largest visible area. No user gesture needed.
- (void)requestPictureInPictureWithCompletion:(void (^)(BOOL entered))completion
    NS_SWIFT_NAME(requestPictureInPicture(completion:));
- (void)exitPictureInPicturePausingVideo:(BOOL)pause;
@end
```

Interim (no fork): run an engine-owned script with the user gesture that
`evaluateJavaScript` already gives (`docs/engine-api.md`), which picks the
video by §4.5.3 and calls `requestPictureInPicture()`; exit with
`document.exitPictureInPicture()` plus `pause()` when asked. Fork:
choose the player among `MediaSessionImpl`'s normal players by the sizes
from `MediaResized`, call
`MediaSessionPlayerObserver::OnEnterPictureInPicture(player_id)` (today
only the one-player case does this: `media_session_impl.cc:1340-1346`),
and skip the activation check: CEF returns false from
`AllowPictureInPictureWithoutUserActivation()` for Alloy pages
(`cef/libcef/browser/browser_platform_delegate.cc:571-574`). Exit:
`PictureInPictureWindowManager::ExitPictureInPicture()` or the
controller's `Close(should_pause_video)`. Arc equivalent:
`requestPictureInPicture:`, `exitPictureInPicture:error:`,
`skipUserActivationForPiP:`.

### EM-6. Tab activation for Chromium's auto-PiP

```objc
@interface OEWebContent (AutoPictureInPicture)
/// Tells Chromium's auto-PiP helper that this tab became the active (shown) tab of its window, or stopped being it.
- (void)setActiveForAutoPictureInPicture:(BOOL)active;
@end
```

Chromium source: `AutoPictureInPictureTabHelper::OnTabActivatedChanged(bool)`
(`chrome/browser/picture_in_picture/auto_picture_in_picture_tab_helper.h:83`).
CEF attaches the helper to Alloy pages through `TabHelpers::AttachTabHelpers`
(`cef/libcef/browser/alloy/browser_platform_delegate_alloy.cc:206`), but
the helper learns activation from the tab strip, which Alloy pages do not
have. After P1 (tab-strip bridge) the hidden `TabStripModel` may deliver
it; verify first, add this setter only if it does not. Arc equivalent:
`notifyAutoPipTabActivationChanged:error:`.

### EM-7. Document PiP disposition

Add `OEOpenDispositionNewPictureInPicture` and report it through
`webContent:createWebContentFor:` with `OEOpenRequest.requestedFrame` =
the size the page asked for. The shell returns a new `OEWebContent`
whose view it hosts in its Document PiP panel. Chromium/CEF source:
`CEF_WOD_NEW_PICTURE_IN_PICTURE` (`cef/include/internal/cef_types.h`,
near line 1288); `CefBrowserInfoManager::CanCreateWindow` sends it to
`OnBeforePopup` (`cef/libcef/browser/browser_info_manager.cc:157-193`);
Chrome-style pages use default Browser creation for it today. Arc
equivalent: `ADK.OpenDisposition.newPictureInPicture`,
`ArcDocumentPIPWindowControllerViewModel{webContents, browserContextID, browserCreateParams}`.

### EM-8. Change bits

`OEWebContentChangeMedia = 1u << 13` (session state, actions, metadata,
position at most 1 Hz while playing) and
`OEWebContentChangePictureInPicture = 1u << 14` (PiP entered or left).

### EM-9. Now Playing (only if check E-M11 fails)

`OEEngineConfiguration.systemMediaControlsEnabled` (default YES): make
sure `media::kHardwareMediaKeyHandling` stays enabled and
`MediaKeysListenerManagerImpl` starts (`content/browser/media/media_keys_listener_manager_impl.cc:328`).

## 7. App wiring

### 7.1 OpenWeb protocols

```swift
public struct WebMediaActions: OptionSet, Sendable {
    // play, pause, previousTrack, nextTrack, seekBackward, seekForward, seekTo, skipAd, stop,
    // enterPictureInPicture, exitPictureInPicture, enterAutoPictureInPicture,
    // toggleMicrophone, toggleCamera, hangUp
}
public struct WebMediaState: Sendable, Equatable {
    public enum Playback: Sendable { case none, paused, playing }
    public var playback: Playback
    public var isControllable: Bool
    public var hasVideo: Bool
    public var largestVideoArea: Double
    public var actions: WebMediaActions
    public var isPictureInPicture: Bool
    public var microphoneMuted: Bool?
    public var cameraOn: Bool?
    public var volume: Double?        // nil: tab volume not offered (before EM-2)
    public var duration: Double?
}
public enum WebMediaAction: Sendable { case play, pause, previousTrack, nextTrack, seek(to: Double),
    skipAd, toggleMicrophone, toggleCamera, hangUp }
@MainActor public protocol WebMediaHost: AnyObject {
    var mediaState: WebMediaState { get }
    func perform(_ action: WebMediaAction)
    func setVolume(_ volume: Double)
    func requestPictureInPicture() async -> Bool
    func exitPictureInPicture(pausing: Bool)
}
@MainActor public protocol WebPictureInPictureHost: AnyObject {   // phase 2
    var videoView: NSView { get }
    // properties and commands mirror OEPictureInPicture (EM-4)
}
```

`OpenWeb` has no AppKit import today; put `WebPictureInPictureHost` in a
second file that imports AppKit, or pass `videoView` as `AnyObject` and
cast in `OpenFeatures`. Pick one and state it in the PR.

### 7.2 MediaCoordinator (App) — engine event map additions

Extends app-shell §4.13:

| Event | Effect |
|---|---|
| `didChange` `.audio` | `tab.live.isAudible` (exists); sleep `tabAudioChanged` (exists); `store.update`. |
| `didChange` `.media` | `store.update(tabID:windowID:state:…)`; sleep visibility hook if a card appears or leaves. |
| `didChange` `.mediaCapture` | `tab.live.isCapturing` (exists); `store.update` (recording kind). |
| `didChange` `.pictureInPicture` | `PiPSession` update; `AppVisibilityProvider.pipTabIDs`; sleep hook. |
| Model `tab.isMuted` changed | `content.isMuted = tab.isMuted` (engine), `store.update`. |
| Selection, Space switch, split collapse (window controller) | Compute leave events (§4.5.1); for each, `AutoPiPPolicy.decide`; act. Also exit an auto PiP whose tab is now displayed (§4.5.5). Update `SidebarContext.displayedTabIDs`. |
| Tab close, archive, discard, crash | `store.remove`; PiP closes through the engine. |
| `SidebarIntent.media(.play/.pause/…)` | `WebMediaHost.perform`; `store.noteInteraction`. |
| `.media(.backToTab(tabID))` | Select the tab in its window and Space; bring the window front. |
| `.media(.openPictureInPicture(tabID))` | `requestPictureInPicture()`; session `manual`. |
| `.media(.close(tabID))` | `perform(.pause)`; mark the card dismissed until the next `playing`. |
| Phase 2 PiP delegate calls | Create, update, close `PictureInPictureWindowController`. |

`MediaIntent` (OpenSidebar): `play(ItemID)`, `pause(ItemID)`,
`previousTrack(ItemID)`, `nextTrack(ItemID)`, `toggleMute(ItemID)`,
`setVolume(ItemID, Double)`, `toggleVolumeDrawer(ItemID)` (view-local,
no App call), `openPictureInPicture(ItemID)`, `close(ItemID)`,
`backToTab(ItemID)`, `toggleMicrophone(ItemID)`, `toggleCamera(ItemID)`.
`ModelSidebarActions` returns `false` for `.media` (App-only).

Order with app-shell: this wiring needs app-shell Step B (real window and
`EngineWebContentHost`) and Step G (sleep adapter). Start Step 6 below
only after both are merged.

## 8. Verification (no unit tests)

### 8.1 `openkit media-demo` (real CLI over the real library, like `sleep-demo`)

Drives `MediaSourceStore`, `AutoPiPPolicy`, `PiPSession`, and
`PiPSiteRules` with a synthetic model and an injected clock; prints
PASS/FAIL per row; exits non-zero on failure. Add to `verify-all.sh`.

| ID | Check |
|---|---|
| AP1 | Audible playing video, setting on, allowed host → open. |
| AP2 | Setting off → skip (`settingOff`). |
| AP3 | Inaudible video on a normal host → skip (`inaudible`); same on `youtube.com` → open. |
| AP4 | Video below 160×90 → skip. |
| AP5 | `meet.google.com`, `slack.com`, `teams.microsoft.com`, and `www.slack.com` → skip (`disallowed`). |
| AP6 | Host in `autoDisabledHosts` → skip; in the incognito list only → skip in that window, open in a normal window. |
| AP7 | Snoozed tab → skip; after a "displayed" event → open. |
| AP8 | Manual PiP active for another tab → skip; auto PiP active for another tab → open (replace). |
| AP9 | `disablePictureInPicture` → skip. |
| AP10 | Window minimize, occlusion, and app hide produce no leave event (D-4). |
| AP11 | Close-rule table §4.5.5: every row gives the stated session state and pause flag. |
| MS1 | Visible sources exclude the displayed tab, a shown split pane, a Peek page, and an active PiP source; include a minimized-PiP source. |
| MS2 | A source in another window is not visible here; one in another Space of this window is. |
| MS3 | Order is most recent first; the 4th source drops out (max 3). |
| MS4 | A source paused 59 min shows; at 60 min it does not; an interaction at 59 min restarts the 60 min. |
| MS5 | Exactly one pending work item exists for the earliest deadline, and none when nothing is paused. |
| SR1 | Rule matching: `www.twitch.tv` hides play/scrub/skip; `twitch.tv.evil.com` matches nothing. |
| MN1 | PiP menu model for a host-less URL has no header block; with a host it has the exact PP-8 order and titles. |

### 8.2 `sidebar-render` scenes and checks

New flags: `--media "SPEC"` where SPEC is a comma list of
`row=state[:video][:muted][:recording][:paused-min=N]` (rows use the
existing `today:N`/`pinned:N` syntax), `--media-hover expanded|title:N` (§13.8.4),
`--media-drawer N`, `--reduce-motion`. Fake `WebMediaHost`s record the
actions they get.

Renders (commit only our own renders in a PR description, never Arc
frames): one audio card playing; paused; muted; video card with the PiP
button; recording card; drawer open; stack of 3 collapsed and expanded;
rows with speaker, muted speaker, and recording dot; light and dark;
widths 228 and 500.

| ID | Check |
|---|---|
| RI1 | A muted audible row shows `speaker.slash.fill` at the §4.1 frame; a silent unmuted row builds no speaker view. |
| RI2 | Clicking the speaker sends `.toggleMute` and does not change selection. |
| RI3 | A capturing row shows the recording dot before the speaker; its tooltip text is exact. |
| RI4 | The symbol transition runs once per mute change and leaves no animation on the layer afterwards. |
| RI5 | Step 2b: an audible row draws the speaker at `[41, y + 7, 26, 26]` with the outline glyph and the title origin at x 70; `sidebar-render compare` against S2 12/0022 (audible) and 0027 (muted) is within 1 pt and ΔE00 2 for the button frame, glyph ink box and peak, and title start (favicon and title text masked). RI1 and RI3 use the new frames. |
| MC1 | No source → container height 0 and the pager ends at `h − 50` (no layout change from today). |
| MC2 | One source → container `C = 76`, card frame `[8, h − 50 − 72, W − 16, 68]` ± 0.5 pt. |
| MC3 | Each button's frame, glyph, and tooltip match §4.2.3; Previous/Next hide without the actions. |
| MC4 | Close is 0 wide until the pointer enters the card, then 24. |
| MC5 | Clicks send the right `MediaIntent`; the title row sends `.backToTab`; buttons never do. |
| MC6 | Stack of 3: collapsed height `68 + 10`; hover expands to `3·68 + 12`; exit collapses after 0.3 s. |
| MC7 | Marquee runs only for an overflowing title of a playing source in a visible window; Reduce Motion, paused, or hidden → no animation keys on the text layer. |
| MC8 | Idle: with a paused card on screen, the window has no running `CAAnimation`, no display link, and no timer other than the one dismiss work item (§4.3). |
| MC9 | `bench --rows 1000` with one card on screen: scroll p95 within 0.3 ms of the baseline. |
| MC10 | The container is dimmed with the bottom bar while a Peek is open. |

Step 3b replaces MC1–MC10 with the values in §13.8.5 (MC1–MC15). The
numbers above (C = 76, 68 pt cards, the marquee) describe #92 only.

Comparison: once the user provides screenshots S3–S8 (§11), add
`sidebar-render compare` runs for them with the `docs/design.md` §8
targets (layout ≤ 1 pt, fill and text ΔE00 ≤ 2) and update the guessed
tokens.

### 8.3 `features-render pip`

```text
features-render pip --out FILE.png [--size 384x216] [--scale 1|2] [--state playing|paused|ended]
                    [--controls visible|hidden] [--meeting] [--site twitch|meet|youtube|none]
                    [--drag-precision N] [--menu] [--document --top-bar-title TEXT] [--document-hover-options] [--document-pressed-options]
                    [--screen WIDTHxHEIGHT --natural-size WIDTHxHEIGHT --first-open --geometry-report FILE.json]
                    [--hover-skip-ahead]
```

The fake video view paints a gradient with the size written in it.

Lead decision (2026-10-26 03:11 America/Vancouver): `--menu` prints a text
dump of the real system NSMenu and writes it beside the PNG as `.menu.txt`.
Include titles in order, separators, checkmarks, enabled state, key
equivalents/modifiers and submenu nesting. The PNG renders only the PiP
window; do not draw a menu preview. PP checks invoke the real items/actions,
and the PR attaches the native menu text for design review.

| ID | Check |
|---|---|
| PP1 | Compact (284 wide) and regular (384 wide): corner buttons 28×28 at padding 8 and 10. |
| PP2 | Site rule twitch hides play, skip, and scrubber; meet hides Close. |
| PP3 | Controls fade in on a synthesized pointer move and out 2.0 s later; stay while the menu is open. |
| PP4 | Scrubber: a drag up 80 pt shows "Seeking at 3× precision"; a flat drag shows "Drag upwards to seek precisely"; the fake host gets `scrubTo` during and `seekTo` at the end, and play resumes. |
| PP5 | Menu items and order equal §4.4.5 for a URL with a host, and items 1, 2, 4 only for one without; incognito "Turn off" does not write `UserDefaults`. |
| PP6 | Preserve aspect and the 50% maximum; use the orientation-aware minimum in §4.4.2. Fresh-process first-open and minimum checks cover landscape and portrait at heights 900/1010/1080/1440/1600/2160, plus 10 pt bottom-right placement. Check the observed 320×180 on 2560×1440, the clamped minimum on 1920×1080, square on a 900 pt screen, later long-side reuse, and compact controls below 300 pt. |
| PP7 | Back to Tab, Close, Minimize send the right host calls (`closePausingVideo:` YES only for Close). |
| PP8 | Document PiP: top bar 28 pt, colors from §4.6, menu has "Keep Window on Top" and the header. |

### 8.4 App e2e suite `tools/e2e/engine_e2e.py --only media`

Fixtures in `tools/e2e/fixtures/media/`, served by a local
`http.server` on `127.0.0.1` (random port), no binary media files:

- `audio.html`: an `<audio>` element fed by a generated WAV data URI
  (as the `features` suite does), `navigator.mediaSession.metadata`
  (title "Open Test Tone", artist "Open"), and `previoustrack` /
  `nexttrack` handlers that count calls in `window.__counts`.
- `video.html`: a `<video>` whose `srcObject` combines
  `canvas.captureStream(30)` and a Web Audio oscillator through a
  `MediaStreamAudioDestinationNode` (audible video, no file).
- `video-muted.html` (no audio track), `video-nopip.html`
  (`disablePictureInPicture`), `two-videos.html` (160×90 and 640×360,
  ids `small` and `large`), `webaudio.html` (Web Audio only),
  `docpip.html` (a button that calls
  `documentPictureInPicture.requestWindow({width: 400, height: 300})`),
  `meet-like.html` (registers `enterpictureinpicture`).
- Site rules: start the app with `--pip-site-rules=<tmp>.json` that maps
  `127.0.0.1` to `activatesWhenInaudible` or `disallow` per check.

New automation commands (`docs/automation.md` gets the rows):

| Command | Args | Result |
|---|---|---|
| `media` | `tab` | `WebMediaState` fields, `audible`, `muted`, `capturing` |
| `media-action` | `tab`, `action` (`play`, `pause`, `next`, `previous`, `seek`, `volume`, `pip`, `exit-pip`) , `value` | `{ok}` |
| `mini-players` | `window` | Visible sources in order: tab id, kind, playback, buttons shown, card frame |
| `media-click` | `window`, `tab`, `target` (`title`, `play`, `next`, `previous`, `volume`, `pip`, `close`) | Clicks the real card control (events built inside Open, as `mouse` does) |
| `pip` | — | Session state, source tab, auto/manual, window number and frame, level, controls visible |
| `pip-action` | `action` (`close`, `minimize`, `back-to-tab`, `menu`), `item` | Runs the control or a menu item by its title |
| `now-playing` | — | `MPNowPlayingInfoCenter.default().nowPlayingInfo` title/artist/rate/elapsed, `playbackState`, and `isEnabled` of the remote play, pause, next, previous commands (read in-process) |
| `defaults` | `key`, `value` | Read or write one `open.*` key (Debug only) |

| ID | Check |
|---|---|
| E-M1 | `audio.html` plays → `tabs` audible; the row speaker exists (sidebar AX); `mute` → page silent (`audio.muted` stays false, the tab is muted); `save`, relaunch → the tab is muted. |
| E-M2 | `webaudio.html` → audible. Before P6: report `blocked: P6`, never pass. |
| E-M3 | Play audio, select another tab → `mini-players` lists the source within 1 s; select it back → the list is empty. Space switch away → listed. A second window does not list it. Four sources → three listed, newest first. |
| E-M4 | `media-click play/pause` toggles `audio.paused`; `next`/`previous` raise `__counts` (EM-1b; interim → `blocked: EM-1b`). |
| E-M5 | `video.html` playing → select another tab → `pip` active, auto, source = video tab within 500 ms; a new window appears in `windows`; select the video tab back → PiP closed within 500 ms and `video.paused == false`. |
| E-M6 | Negatives, each from a fresh leave: `defaults open.advanced.enablePictureInPictureOnLeave false`; `video-muted.html`; `video-nopip.html`; rules file `disallow 127.0.0.1`; `pip-action menu item="Turn off"` then a new leave → no PiP. With the rule `activatesWhenInaudible 127.0.0.1`, `video-muted.html` → PiP. |
| E-M7 | Close → video paused; next leave of the same tab → no PiP; show the tab, leave again → PiP. |
| E-M8 | Minimize → PiP closed, video playing, `mini-players` lists the tab with `pip` shown; `media-click pip` → PiP active, manual. |
| E-M9 | `pip-action back-to-tab` → the source window is key, the tab is selected, PiP closed, video playing. |
| E-M10 | `two-videos.html` (both playing) → `document.pictureInPictureElement.id == "large"`. |
| E-M11 | `audio.html` playing → `now-playing` title "Open Test Tone", artist "Open", rate 1, `playbackState` playing; pause → paused; play/pause/next/previous commands enabled. Failure → engine request EM-9. |
| E-M12 | Sleep: an audible hidden tab, a PiP source in a minimized window, and a paused mini-player source all stay live past the freeze delay (`sleep` suite helpers); after the card is closed, the paused tab freezes on the normal clock. |
| E-M13 | `docpip.html` click → a Document PiP panel appears (phase 2 window class) with a 28 pt top bar; closing it returns the content (`document.querySelector` finds it again in the opener). Before EM-7: `blocked: EM-7`. |
| E-M14 | `pip-action menu item="Keep Window on Top"` → window level becomes normal, `defaults open.pip.keepOnTop` false; again → floating, true. |
| E-M15 | Idle: a paused card on screen, PiP closed: `metrics` CPU over 30 s is within 0.5 % of the same run without the card. |

Phase 1 runs E-M5…E-M9 against Chromium's PiP window (only checks that
need Open's controls are `blocked: EM-4`). Phase 2 reruns them all.

### 8.5 Manual checks for the user (agents must not drive the desktop)

1. Play a song on a music site in Open, press the keyboard play/pause
   key: playback pauses and resumes.
2. Open Control Center → Now Playing shows Open with the song title and
   artwork; its buttons work.
3. With music playing in Open and in another app, the media keys go to
   the app that played last (system rule).
4. Expand two mini-player cards. Click the top card’s title (Back to Tab) or
   Close, then move the pointer over the tab list. The remaining card must
   collapse. Code review C5 needs this real-pointer check; agents must not
   attempt it or change tracking behavior without its result.

## 9. Implementation order (small PRs; each step: files, then acceptance)

Every PR: merge `origin/main`, run `tools/verify-all.sh`, paste the
table (AGENTS.md rule 10). One library target per PR where the step says
so.

Lead performance decision (2026-10-26 01:44 America/Vancouver, Step 2
review): rows that look the same as before must show no scroll-p95
regression against main. The mixed audible/muted/capturing variant draws
new views and instead has an absolute scroll-p95 budget of 4.2 ms (half
a 120 Hz frame). Compare baseline and head interleaved in one session,
at least five runs each, and report both the median and mean of their
per-run p95 values. If mixed rows exceed 4.2 ms, profile and fix the hot
spot before Step 3; otherwise proceed after the plain-row gate passes.

| Step | Work | Files | Acceptance |
|---|---|---|---|
| 0 | Screenshots S1–S12 from the user (§11), through the lead. Runs in parallel; Steps 1–5 do not wait. | — | Lead files them under `.re/runtime/` (git-ignored) and adds measured values to `docs/re/interaction-states.md`. |
| 1 | `OpenMedia` target: store, policy, session, site rules, settings; `OpenWeb` media types; `OpenSleep` `mediaControls` field; `openkit media-demo`; the two new defaults in `SettingsDefaults` (registry rows are already in settings-library §2.1). | §3.1 rows for `OpenMedia`, `OpenWeb`, `OpenSleep`, `OpenSettings`, `openkit`; `Package.swift`; `tools/verify-all.sh` | `media-demo` all PASS; `sleep-demo` still 105/105; `settings-preview` still PASS; `verify-all.sh` PASS. |
| 2 | Tokens and row indicator: `MiniPlayerMetrics`, `PiPMetrics`, `RowMediaMetrics`, roles, fonts, motion, glyphs; speaker transition, tooltip, recording dot. | `OpenDesign/*` (listed), `OpenSidebar/SidebarRows.swift`, `sidebar-render` RI checks | RI1–RI4 PASS; existing `sidebar-render check` PASS; bench p95 unchanged. |
| 2b | Follow-up to merged #67 (capture session 2, C18): leading 26 × 26 speaker after the favicon, outline glyphs, title shift, recording dot leading (§4.1 amendment). | `OpenDesign/FeatureMetrics.swift` (`RowMediaMetrics`), `OpenDesign/Icons.swift` (outline symbols), `OpenSidebar/SidebarRows.swift` (`TabCellView.layout()`), `sidebar-render` RI checks and a new RI5 | RI1–RI5 PASS; existing `sidebar-render check` PASS; the plain-row and mixed-row scroll budgets of the 2026-10-26 performance decision hold. |
| 3 | Mini player stack in the sidebar with fake hosts. | `OpenSidebar/MediaControlsView.swift`, `MiniPlayerCardView.swift`, `MarqueeLabel.swift`, `SidebarView.swift`, `SidebarContext.swift`, `SidebarIntent.swift`, `ModelSidebarActions.swift`; `sidebar-render` media scenes | MC1–MC10 PASS; renders attached to the PR. |
| 3b | Mini-player redesign from capture session 2 (§13). | `OpenDesign/FeatureMetrics.swift`, `Palette.swift`, `SpaceThemeStyle.swift`, `Typography.swift`, `Icons.swift`, `Motion.swift` (comments); `OpenSidebar/MiniPlayerCardView.swift`, `MediaControlsView.swift`, `SidebarContext.swift`; delete `OpenSidebar/MarqueeLabel.swift`; `sidebar-render` `MediaScene.swift`, `MediaChecks.swift`, `Bench.swift`, new `MediaCompare.swift`, `RenderCLI.swift`; `MediaRenders/step3b/` | MC1–MC15 PASS (§13.8.5); compare runs R1–R4 meet the §13.8.6 targets or name each miss with numbers; MC9 PASS; renders attached. |
| 4 | Phase 2 PiP window and Document PiP window with a fake video view; menu builder. | `OpenFeatures/PictureInPictureWindowController.swift`, `PiPOverlayView.swift`, `PiPScrubberView.swift`, `PiPMenuBuilder.swift`, `DocumentPiPWindowController.swift`; `features-render` pip | PP1–PP8 PASS. |
| 5 | [ENGINE] EM-1a, EM-5 interim, EM-8 (OpenEngine only, stock-CEF compatible). | `Engine/OpenEngine/src/OEApp.mm`, `OEWebContent.mm`, `include/OpenEngine/OEWebContent.h`; `docs/engine-api.md` | `--only features` unchanged; a `media` dump of `audio.html` shows playback and metadata. |
| 6 | [APP, after app-shell B and G] `MediaCoordinator`, `EngineBridge` conformance, event map §7.2, leave events, auto-PiP phase 1, mini player with interim actions, Mute All/Unmute All, sleep feed, automation commands, `--only media`. | `App/Media/MediaCoordinator.swift`, `App/EngineBridge.swift`, `App/Automation/AutomationController.swift`, `docs/automation.md`, `tools/e2e/*` | E-M1, E-M3, E-M5…E-M12, E-M14, E-M15 PASS (phase 1 limits stated); E-M2, E-M4, E-M13 report `blocked`. |
| 7 | [ENGINE fork] EM-1b, EM-2, EM-3 (P6), EM-5 fork path. | `Engine/fork/patches/cef/04xx-*`, overlay `cef/include/cef_media_session.h`, OpenEngine | Engine e2e for each; `docs/engine-patches.md` rows. |
| 8 | [APP] Switch to `OEMediaSession`: previous/next, volume drawer, recording cards. | `App/Media/MediaCoordinator.swift`, `App/EngineBridge.swift` | E-M2, E-M4 PASS; MC checks still PASS. |
| 9 | [ENGINE fork] EM-4. | fork overlay + OpenEngine | Engine check: `videoView` shows frames in a plain test window. |
| 10 | [APP] Phase 2: Open's PiP window replaces Chromium's (`shellHostsPictureInPicture = YES`). | `App/Media/MediaCoordinator.swift`, `App/EngineBridge.swift` | E-M5…E-M10, E-M14 PASS on Open's window; PP checks unchanged. |
| 11 | [ENGINE + APP] EM-6, EM-7; Document PiP and the Meet path. | fork + OpenEngine; App coordinator | E-M13 PASS; `meet-like.html` gets a Chromium auto PiP after a leave. |
| 12 | Polish against screenshots: compare renders, fix tokens, motion. | `OpenDesign/*` | Compare targets met or each miss named with numbers. |

### Step 10/11 lifecycle gate (code review r1)

App wiring remains required before phase-2 video and Document PiP acceptance:

- Tab close, archive, discard and crash must call `dismiss(reason: .sourceGone)`
  on the video PiP controller. The call returns the video without pausing it.
- Closing a Document PiP opener must call `DocumentPiPWindowController.close()`.
- The earlier Step 6 store gate remains: close/archive/discard/crash remove the
  tab source; window teardown stops sidebar observations and calls removeWindow.

The controllers cannot observe a source tab by themselves. Fake-host Step 4
checks prove the effects after these calls, not that future App callers are wired.

## 10. Risks and open questions (lead decisions)

| # | Question | Recommendation |
|---|---|---|
| Q1 | Mini player placement (above the bottom bar) is a guess (PP-20). | Build it there (D-3); confirm with S3. **Resolved 2026-10-26:** the stack sits on the bottom bar's top edge, 8 pt below the tab list (S2 14b/0014, §13.3.1). |
| Q2 | How many mini players show (`maxActiveMediaControls` unknown)? | 3, newest first. |
| Q3 | Paused cards: auto-dismiss after 60 min and sleep protection while shown? | Yes to both (Chromium precedent; bounded memory cost). |
| Q4 | Should window minimize, occlusion, or app hide open auto-PiP? | No in v1 (D-4). Ask the user to test it in Arc (S10). |
| Q5 | What do Close on a mini player and Close on an auto PiP do to playback, and how long does Arc's per-host deadline last? | Both pause. Per-tab snooze until shown instead of a timed host deadline. |
| Q6 | Does a manual PiP close when its tab is shown again? | No (Chrome behavior); Back to Tab closes it. |
| Q7 | Ship phase 1 with Chromium's own PiP window until EM-4? | Yes. The rules and the mini player are the same; only the window chrome differs. |
| Q8 | The volume drawer needs a fork patch (EM-2). | Until EM-2: the volume button toggles mute, no drawer. |
| Q9 | Add an Open-only command for PiP (for example "Picture in Picture" in the command bar)? | No in v1: Arc has none (PP-21), and the page context menu already has Chromium's item. |
| Q10 | "Mute All Tabs" scope. | App-wide: every loaded tab; "Unmute All Tabs": every muted tab. |
| Q11 | Respect `disablePictureInPicture` for auto-PiP? (Arc has `ignoreDisablePiPAttribute:`.) | Respect it always in v1. |
| Q12 | Meet chat toggle in the Document PiP top bar. | Defer; Meet-specific. |
| Q13 | Recording cards (microphone/camera toggles) need EM-1b actions. | Ship with Step 8. |
| Q14 | Do Favorites tiles show an audio badge? | Not in v1 unless screenshot S9 shows one. |
| Q15 | The marquee flag. | ~~Ship on; no setting (Arc's flag is remote config).~~ **Superseded 2026-10-26:** Arc showed a static tail-truncated title in every captured state, so Open ships no marquee (§13.2, §13.7 O12). |
| Q16 | EM-4 is the largest engine item (2–3 weeks guess). Its order versus P1–P3. | Queue after P1; phase 1 covers users meanwhile. |
| Q17 | PiP menu: does "Turn off" get the check mark after it is chosen, or does the menu change? (The decompiled branch always checks "Open automatically".) | Radio pair with the check on the current state (§4.4.5); confirm with S2. |

Risks:

- EM-4 surface embedding may need a Views widget after all. Fallback:
  keep Chromium's window and add Open's overlay as a child window above
  it (`addChildWindow`), with the same controls. State the choice in the
  Step 9 PR.
- The interim probe (EM-1a) can be fooled by the page. It drives UI only.
- `NSPanel` non-activating windows do not get key events until clicked;
  Space for play/pause works only after a click (stated in §4.8).
- If Chromium's Now Playing does not run in CEF, Control Center shows
  nothing; E-M11 detects it.

## 11. Screenshots needed from the user

The lead asks the user for these Arc captures (window screenshots with
`screencapture -l <windowID>` or full-screen, plus the matching AX dump
if the capture session tool is used). Use the default theme in light
and dark where it says so; sidebar width 228. Personal data in the frames
stays in `.re/` and is never committed.

| # | State to capture | Purpose |
|---|---|---|
| S1 | A PiP window from a YouTube video at its default size, pointer over it (controls visible), then pointer away (controls hidden). | §4.4.3 layout, scrims, sizes |
| S2 | The same PiP window with its settings menu open. Then choose "Turn off" and open the menu again. | PP-8 menu, check-mark rule (Q17) |
| S3 | The sidebar with one mini player from an audio site (for example a music site) playing in a background tab, pointer away. Both appearances. | Placement and card layout (§4.2) |
| S4 | The same mini player with the pointer over the title row, then over the controls row. | Hover states, "Back to Tab" swap, close button |
| S5 | The volume drawer open. | Drawer layout |
| S6 | Two and three mini players, pointer away, then pointer over the stack. | Stack offsets and expansion (§4.2.4) |
| S7 | A video tab mini player after pressing Minimize in its PiP window. | Back-to-PiP button |
| S8 | A paused mini player and a muted one. | State glyphs |
| S9 | A tab row while audio plays, after muting it, and a Meet or camera tab row (recording indicator). Also a Favorite tile that plays audio. | §4.1, Q14 |
| S9 review additions | A red-themed Space for recording-dot contrast; whether the dot is leading (`hasLeadingRecordingIndicator`); a playing Favorite tile (`musicIconAnimationView`/`recordingIndicatorView`); whether tint follows the title color; speaker tooltip exact text and case. | D1–D9 review questions; no asset or code extraction in this step |
| S10 | A short screen recording (the user's own recorder) of: leaving a playing video tab (auto-PiP opens), returning (it closes), minimizing the window while a video plays, and switching to another app. | Timings, D-4/Q4 |
| S11 | A Google Meet Document PiP window (if the user has a Meet call). | §4.6 top bar |
| S12 | Settings ▸ Advanced, the PiP row. | Label and position |

Capture session 2 (2026-10-26) answered S3 in Dark with the default
theme, S6, and part of S4 (the expanded card). S3 in Light, the rest of S4,
S5, S7, and S8 are still open; §13.7 lists them with provisional designs.

## 12. Evidence index

- Rules PP-1…PP-22: `docs/re/features-advanced.md` §8.
- Tokens: `docs/re/design-tokens.md` §1.8.
- Menus and tooltips: `docs/re/menus-and-hotkeys.md` "Media and Picture
  in Picture".
- Row indicator and bottom bar: `docs/re/features-core.md` rules 6, 10,
  41.
- Engine surface: `docs/re/arccore-engine.md` §2.6.
- Raw outputs (local only): `.re/media/` (`swift-fields.tsv`,
  `ghidra-media.txt`, `assets-*.json`, `arccore-strings.txt`).
- Chromium 156 sources: paths with line numbers in §2 and §6
  (`~/Developer/open-engine/chromium_git/chromium/src`).
- Mini player captures (local only): capture session 2 items 14b and 16
  (§13.1); analysis scripts in `.re/runtime/analysis-s2/s3b/`.

## 13. Step 3b: mini-player redesign (capture session 2)

Status: design spec, 2026-10-26. This step replaces the card that PR #92
(Step 3) shipped. #92 built a 68 pt card with a title row from guesses.
Capture session 2 measured Arc's mini player, and Arc's design is
different. Where this section and §4.2 disagree, this section wins (lead
decision 2026-10-26, Appendix). §4.2.2 (which sources show) and §4.3 (the
store) do not change.

Labels used below:

- **fact**: measured in a capture frame (the frame is cited).
- **code**: decoded from Arc's types or strings (PP-n).
- **fit**: the best of several candidates against a frame (numbers given).
- **derived**: computed from facts with a stated rule.
- **guess**: Open's provisional design. Keep each guess in one token, so a
  later capture can fix it in one edit.

### 13.1 Evidence

All frames are window-relative points at 1x, in sRGB after the display
profile (`docs/re/interaction-states.md` §20.0; window 1728 × 1084,
sidebar 228, default dark theme, macOS Dark). Frames and crops stay in
`.re/` (git-ignored). The video titles in these frames are not quoted and
must never be committed.

| Ref | Frame | State |
|---|---|---|
| E1 | S2 14b/0012 | The same window with no mini player (background reference). Pager scroll area `[0, 82, 228, 952]`. |
| E2 | S2 14b/0014 | One video source, pointer away: the rest card. |
| E3 | S2 14b/0024 | The pointer on the volume button, just after a click on it: the expanded card, a plate on volume, the tooltip "Adjust Tab Volume". |
| E4 | S2 14b/0025 | 1.2 s later. No plate (the pointer has left): the rest card again (AX still reports 66 pt for this one frame). |
| E5 | S2 14b/0027 | After a click on the card body: the video tab is selected and the card is gone. |
| E6 | S2 16/0005 (pixels: 16/0004) | Three video sources, pointer away: the collapsed stack. |
| E7 | S2 16/0012 (its own PNG; near-identical to 0011) | The pointer on the bottom card's pause button: the expanded stack. |
| E8 | S2 16/0013 | The pointer away (notes 10:46:52): collapsed again. |

Methods (scripts in `.re/runtime/analysis-s2/s3b/`):

- Geometry: the AX `rel` frames in each `ax.json` (`ax.py`, `ax2.py`).
- Coverage: `(bg − px)·(bg − fill) / |bg − fill|²` per pixel, with E1 as the
  background (`meas2.py`).
- Corner: the four corners of E2 and E3 against Core Animation renders of a
  `CALayer` with `cornerRadius` 6…11 and `cornerCurve` `.continuous` or
  `.circular`, drawn at 1x with `render(in:)` (`swift/corner.swift`,
  `cafit.py`). A control on a shape without a shadow: E2's selected tab row
  (`[9, 463, 210, 36]`) fits 12 continuous with RMS 0.059 (12 circular:
  0.080; 11 continuous: 0.116), so the method separates both the radius and
  the curve (`cafitrow.py`). Follow-up outside this step: that is more than
  the radius 10 that `docs/design.md` §2.2 lists for row fills.
- Glyph size and weight: the ink mass (sum of coverage) of each Arc glyph
  against SF Symbols rendered at 12–15 pt in four weights
  (`swift/mass.swift`, `massarc.py`). Ink boxes at 50 % of peak contrast
  (`ink.py`, `swift/ink.swift`).
- Title font: Core Text renders of the same string at 12–14 pt in three
  weights (`swift/text.swift`). The string is read from the local AX dump.
- Symbol names: Arc gives these buttons no labels, so AX reports each
  symbol's default accessibility description. On macOS 26,
  `NSImage(systemSymbolName:accessibilityDescription: nil).accessibilityDescription`
  narrows each description to candidates (`swift/main.swift`). PP-16 names
  and filled ink disambiguate Previous/Next variants.

### 13.2 What happens to #92's parts

| #92 part | Decision | Reason |
|---|---|---|
| 68 pt card: a 36 pt title row that always shows, and a 32 pt controls row | **Change**: a 33 pt controls-only card at rest; 66 pt (title row + controls row) while expanded | C19; E2, E3 |
| Favicon in the title row | **Change**: controls slot 0, as a button | E2 |
| Play group at the left (x 6/34/62), volume at the right | **Change**: five evenly spaced slots | E2; E6 (the rule holds at three card widths) |
| Previous/Next hidden without the actions | **Change**: always shown; disabled without the actions | E2 (AX `disabled`, dim glyphs) |
| Fill `SidebarColors.itemBackground` and a hover fill | **Change**: the Space palette's `backgroundExtra`, opaque. **Remove** the hover fill. | E2, E3 (fill unchanged under the pointer); §13.4.2 |
| Corner 10 | **Keep**. It is now a fit (10 continuous), not a guess. | §13.3.2 |
| No shadow | **Change**: black 0.21, radius 4 | E2 vs E1 |
| Margins 4 above and 4 below (`C = 4 + stack + 4`) | **Change**: 8 above, 0 below | E2 AX |
| Stack: 5 pt up, 6 pt inset, opacity `1 − 0.3·i`, masked to 5 pt, 0.5 pt top edge | **Change**: 7 pt up, 5 pt inset per side, opacity `1 − 0.2·i`, no mask. **Remove** the top edge. | E6 |
| Expanded gap 6 | **Change**: 5 | E7 |
| Hover expands only a stack of 2 or more | **Change**: one card expands too | E3 vs E4; PP-14 |
| Close: 0 ↔ 24 pt width on card hover | **Change**: Close is part of the title row and shows whenever the row shows. **Remove** the width animation. | E7 (Close on all three cards with the pointer on one) |
| Marquee (`MarqueeLabel`) | **Remove**: a static title with tail truncation | E3, E7: "…" on all four titles. The marquee is the mini player's only repeating animation, so removing it also helps idle CPU. |
| "Back to Tab" title swap on title hover | **Keep** (guess) | code `backToTabTitle` (PP-16); not captured |
| Volume drawer: a 28 pt row under the controls | **Change** (guess): a 33 pt row between the title row and the controls row, only while expanded. The code path stays behind EM-2 (Q8). | No drawer seen (E3); §13.7 O2 |
| Glyphs 14 pt Regular, `pip` 12 pt Regular, `speaker.wave.2.fill` | **Change**: Medium weight; `speaker.wave.3.fill` | §13.4.3 |
| Title 13 Medium in the row title color | **Change**: 13 Regular in `ForegroundPrimary` | §13.4.1, §13.4.3 |
| Tooltip placement `.above` | **Change**: `.beside` | E3 |
| Click targets, store rules, max 3, 60 min expiry, Peek dim, Reduce Motion, Increase Contrast | **Keep** | agree with E5 or are Open choices |

### 13.3 Geometry

All values are points at sidebar width `W` (default 228), with a top-left
origin. `cardW` is the card width, `H` the card height.

#### 13.3.1 Container

```text
mediaControls:  [0, h − 50 − C, W, C]
C = 0                           when the window shows no card
C = 8 + stackHeight             otherwise (8 pt above the stack, 0 pt below)
pager:          ends at h − 50 − C (unchanged code path)
hover rect:     [8, 8, W − 16, stackHeight] in container coordinates
```

Evidence (fact): E2 card `[8, 1001, 212, 33]`; its bottom edge is the
bottom bar's top edge (y 1034). The pager scroll area goes from 952 pt
(E1) to 911 pt (E2), so it ends at 993 = 1001 − 8. E3: card
`[8, 968, 212, 66]`, pager 878 pt, ends at 960 = 968 − 8. E6: stack
`[8, 987, 212, 47]`, pager ends at 979. E7: stack `[8, 826, 212, 208]`,
pager ends at 818. The hover rect leaves out the 8 pt gap and the side
insets (guess).

#### 13.3.2 Card and controls row

| Item | Value | Status |
|---|---|---|
| Row height | 33 | fact: E2, E3 (66 = 2 × 33), E7 |
| Card | x 8, width `W − 16`; height 33 at rest, 66 expanded, 99 expanded with the volume drawer | fact (E2, E3); 99 guess |
| Corner | 10, `cornerCurve = .continuous` | fit: RMS coverage error 0.139 at 10 continuous, 0.148 at 9 continuous, 0.163 at 10 circular, 0.199 at 8 continuous (E2); 10 continuous is also best on E3 (0.246). The capture doc's "≈ 6" was a visual estimate. |
| Fill | opaque and uniform (§13.4) | fact: clean samples have modal fill `#050627`, while the sidebar behind it varies; isolated pixels vary by 1–2 channel counts |
| Shadow | black, opacity 0.21, `shadowRadius` 4, offset 0, with a `shadowPath` | fit: E2 against E1 darkens the sidebar by 9.2 % at 0.5 pt, 5.4 % at 2.5 pt, and 2.7 % at 4.5 pt, the same on all four sides. The reveal card's shadow (0.17, radius 4) gives 7.5 / 4.3 / 2.0 %, about 1.25 times less. |
| Controls row | `[0, H − 33, cardW, 33]` | fact |
| Slot `k` (0…4) | button `[x_k, H − 28, 24, 24]`; `x_k = 10 + k·(cardW − 44)/4`, rounded to the backing pixel grid (halves round up) | fact: E2 x 18/60/102/144/186 (card x 8). E6 back cards: 23/63/102/142/181 (card 13…215) and 28/65/102/139/176 (card 18…210). The rule holds at all three widths. |
| Slot use (audio or video source) | 0 favicon, 1 previous, 2 play/pause, 3 next, 4 volume | fact E2 |
| Favicon | 16 × 16, centered in its 24 × 24 button: `[x_0 + 4, H − 24, 16, 16]` | fact E2 (ink x 22…37) |
| Glyphs | the SF Symbol image centered in its 24 × 24 button | image centering is the placement rule; ink-box centers can be offset by up to 1 pt (E2, E3) |
| Hover plate | the whole 24 × 24 button, radius 5 continuous (`MiniPlayerMetrics.buttonPlateRadius`) | fit E3/E7: RMS 0.034 at 5 continuous vs 0.116 at 6; independent design review r1 |

At `W` 228 the slots are at card x 10/52/94/136/178 (pitch 42). At 500
the pitch is 110; at the 164 minimum it is 26, which leaves 2 pt between
buttons (derived from the rule).

#### 13.3.3 Title row (expanded only)

| Item | Value | Status |
|---|---|---|
| Row | `[0, 0, cardW, 33]`, at the top of the card | fact E3 |
| Close | `[cardW − 34, 5, 24, 24]` | fact: E3 `[186, 973]` with the card at x 8, y 968 |
| Open Picture in Picture | `[cardW − 58, 5, 24, 24]`, only for a video source with no open PiP | fact: E3 `[162, 973]`. Hidden for an audio-only source: guess. |
| Title | origin x 14, baseline y 22. Maximum width = `(PiP shown ? cardW − 58 : cardW − 34) − 24` (a 14 pt leading inset and a 10 pt gap before the button). | fact: E3 AX text `[22, 976.5, 130, 16]`; ink x 23…149; the first capital's rows 980…989, so the baseline is 990 (card y 968 → 22). The formula gives 130 at `cardW` 212. |
| Truncation | one line, tail, "…" | fact: E3 and E7 (three titles) |

The mini-player plate radius is a fit from E3/E7, not the separate toolbar
plate measurement. Evidence: `.re/reviews/pr110-scripts/platefit.py` and
`platefit2.py` (32× analytic coverage, calibrated against Open's known 6 pt
plate); 5 continuous RMS 0.034, 6 continuous RMS 0.116.

PP-16's 0 ↔ 24 pt Close width is read as title-row presence under
stack hover. E2 has no title-row buttons, while E7 shows Close on all cards;
there is no per-card width state in the captured states, so Open builds no
Close width animation.

#### 13.3.4 Stack

`n` is the number of cards (1…3). Card `i = 0` is the newest (the front
card, at the bottom).

Collapsed (the pointer is not in the hover rect):

```text
stackHeight     = 33 + 7·(n − 1)                      (33, 40, 47)
card i frame    = [8 + 5i, C − 33 − 7i, W − 16 − 10i, 33]
card i opacity  = 1 − 0.2·i                           (1, 0.8, 0.6)
z-order         = card 0 on top
```

Back cards are not masked. Each one draws its full card, so the card
behind shows through a back card. Only card 0 takes clicks: back cards
return nil from `hitTest` while collapsed. They stay in the accessibility
tree, as Arc's do (E6 lists all three sets of buttons).

Expanded (the pointer is in the hover rect; any `n ≥ 1`):

```text
stackHeight     = Σ h_i + 5·(n − 1)                   (h_i = 66, or 99 with the drawer)
card i frame    = [8, C − Σ_{j ≤ i} h_j − 5i, W − 16, h_i]
opacity         = 1; every card shows its title row
```

From top to bottom the order is the oldest card first and the newest at
the bottom.

Evidence: E6 AX (fact): the stack is `[8, 987, 212, 47]`, the pause buttons
are at y 992/999/1006, and the slot rule gives the card x ranges 8…220,
13…215, and 18…210. Strip colors (fit): E6 shows the third card at
`#14112C` and the second at `#090827`. The model above gives `#15122E`
(ΔE00 0.46) and `#080828` (0.52). #92's masked `1 − 0.3·i` model gives
2.34 and 1.99. The third card's favicon and glyph tops show faintly
through the second card's strip (E6, y 998–1000), so back cards are not
masked (fact). E7 AX (fact): `[8, 826, 212, 208]` = 3 × 66 + 2 × 5; the
gaps at y 892–896 and 963–967 show the sidebar; Close shows on all three
cards.

### 13.4 Colors, type, and glyphs

#### 13.4.1 Roles

Dark values are measured on E2, E3, and E7 (ΔE00 of the token against the
frame). Light values are derived or guessed: no light frame exists.

| Role (token) | Dark | Light | Status |
|---|---|---|---|
| Card fill: `SpaceThemeStyle.miniPlayerFill(_:)` (new) | palette `dark.backgroundExtra`; default theme `#050627` | palette `light.backgroundExtra`; default theme `#FDFDFF` | dark default: fact. Rule: §13.4.2. |
| Glyph: `SidebarRole.mediaControlGlyph` (kept) | white 0.66 | black 0.50 | code PP-16 (`PlaybackControlForeground`); dark fact `#ABAAB5` (ΔE00 0.65) |
| Disabled glyph: `SidebarRole.mediaControlGlyphDisabled` (new) | white 0.22 | black 0.17 | dark fact `#3C3C56` (ΔE00 0.43), which is the glyph at 1/3 opacity; light guess (the same 1/3) |
| Title: `SidebarRole.miniPlayerTitle` (new) = `Core.foregroundPrimary` | white 0.80 | `#0E0F10` at 0.90 (P3) | dark fact `#CDCDD4` (ΔE00 0.24). Light: the catalog token's light value; guess that Arc uses it. |
| Hover plate: `SidebarRole.buttonHover` (`GrayA4`, kept) | white 0.08 | black 0.07 | dark fact `#191938` (ΔE00 0.49); light guess |
| Pressed plate: `SidebarRole.buttonPressed` (`GrayA6`, kept) | white 0.13 | black 0.11 | guess (not captured) |
| Shadow: `MiniPlayerMetrics.shadowOpacity` | opaque black color (alpha 1), layer opacity 0.21, radius 4 | the same | dark fit; light guess; opacity is applied once |
| Increase Contrast border | 1 pt `SidebarColors.separator` | the same | Open choice (kept from #92) |

#### 13.4.2 Theme rule

The card fill is the Space palette's `backgroundExtra` for the sidebar's
content appearance, opaque:

```swift
/// Mini-player card fill (media plan §13.4.2).
public func miniPlayerFill(_ appearance: ContentAppearance) -> RGBA {
    if let palette = palette(for: appearance) { return palette.backgroundExtra.withAlpha(1) }
    return appearance == .dark ? DefaultThemePalette.darkBackgroundExtra : DefaultThemePalette.lightBackgroundExtra
}
```

How the rule was found:

1. Arc computes `dark.backgroundExtra = shadedDark @0.15 over black` and
   `light.title = shadedDark @0.30 over black` (decoded,
   `docs/re/design-tokens.md` §6.5). So in every palette
   `dark.backgroundExtra = light.title × 0.5`.
2. Space 1: `light.title` `#320E00` and `dark.backgroundExtra` `#190700`,
   exactly half (`docs/re/runtime-observations.md` §3.3). Arc paints the
   command bar's (i) circle with `dark.backgroundExtra` (`#190700` exact,
   `docs/commandbar.md`).
3. The default theme has no stored palette. Tooltips paint `light.title`.
   E3's tooltip and the link status bubble (S2 04/0021) are both `#0A0D4F`.
   Half of that is `#050627`: the mini player (E2, E6, E7), the Peek
   control circles (F0090, F0102; `PeekMetrics.defaultControls`), and the
   command bar (i) circle (A0327; `CommandBarRole.defaultInfoFill`).
4. The same default `shadedDark` (`#0A0D4F` / 0.30) predicts `dark.title`
   `#DEDFFF` (the measured default tab title is `#DDDEFF`, ΔE00 0.51) and
   `light.focus` `#9095FF` (the measured light command bar selection is
   `#8E95FF`, S2 20/0018, ΔE00 0.43). So the default theme behaves as one
   palette, and its `light.backgroundExtra` (`shadedDark @0.01 over white`)
   is `#FDFDFF` (derived).
5. Arc passes the Space palette into the media views:
   `MediaControlsFeatureControllerInput{…, colorPalette, …}` and
   `MiniPlayerView{colorPalette, colorScheme, …}` (code, PP-14, PP-16).

How sure:

| Case | Confidence |
|---|---|
| Default theme, dark content | Fact: an exact match on three surfaces. |
| Themed Space, dark content | Derived, high: the role and the × 0.5 identity hold in Space 1 and in the default theme. No themed mini player was captured. |
| Light content (macOS Light with the default theme, or any Space with dark text) | Guess, medium. `PlaybackControlForeground` has a light variant (black 0.50), so the card can be light, and `light.backgroundExtra` is the lightest palette color as `dark.backgroundExtra` is the darkest. The alternative, if a capture disagrees: the card stays `dark.backgroundExtra` with the dark-variant glyphs, as tooltips stay dark. |
| Which appearance applies | Guess: the focused Space's content appearance (`context.appearance(for:)`), the rule for every sidebar element (`docs/design.md` §3.4). |

In the default light theme the card (`#FDFDFF`) sits on the sidebar
bottom (`#E8E0ED`, S2 20/0015; ΔE00 8.7), so it reads as a light card.
Its glyphs (black 0.50) come out `#7E7E80`.

#### 13.4.3 Type and glyphs

The sizes 14 pt and 12 pt are code (PP-16). The Medium weight comes from
the ink-mass fit.

| Item | Value | Evidence |
|---|---|---|
| Title font | `Typography.miniPlayerTitle` = 13 Regular | fit E3: Arc ink 127 × 12, mass 468. Core Text 13 Regular: 126 × 12, 467. 13 Medium: 130 × 12, 530. |
| Previous | `backward.end.fill`, 14 Medium | PP-16 name; AX "Go To End" is consistent but also matches non-fill/alt variants, excluded by PP-16 and filled ink; ink 13 × 11; mass 99.0 (14 Medium 100.4, 14 Regular 91.9) |
| Play / Pause | `play.fill` / `pause.fill`, 14 Medium | Pause: AX id `mediaControlsPauseButton`; ink 9 × 12; mass 79.9 (14 Medium 81.5). `play.fill`: code PP-16, not captured. |
| Next | `forward.end.fill`, 14 Medium | PP-16 name; AX "Go To Start" is consistent but also matches non-fill variants, excluded by PP-16 and filled ink; ink 13 × 11 |
| Volume | `speaker.wave.3.fill`, 14 Medium | AX "Volume Higher" (exactly this symbol's description); ink 19 × 14; mass 105.6 (14 Medium 105.6) |
| Volume, muted | `speaker.slash.fill`, 14 Medium | guess |
| Open Picture in Picture | `pip`, 12 Medium | AX "Picture In Picture Window"; ink 15 × 13; mass 64.3 (12 Medium 64.0) |
| Close | `xmark`, 14 Medium | AX "Close"; ink 11 × 11; mass 42.9 (14 Medium 42.4) |
| Microphone, camera | `mic.fill` / `mic.slash.fill`, `video.fill` / `video.slash.fill`, 14 Medium | names code PP-16; weight guess |
| Drawer ends | `speaker.wave.1.fill`, `speaker.wave.3.fill`, 12 Medium | names code PP-16; size and weight guess |

#### 13.4.4 Tooltips and accessibility

| Item | Value | Status |
|---|---|---|
| Tooltip titles | "Previous Track", "Play" / "Pause", "Next Track", "Adjust Tab Volume", "Open Picture in Picture", "Close Mini Player", "Toggle Microphone", "Toggle Camera" | code PP-16; "Adjust Tab Volume" fact (E3) |
| Delay | 0.45 s | code PP-6 |
| Placement | `.beside`: below and to the right of the pointer, as row tooltips | fact: in E3 the tooltip window `[171, 992, 193, 93]` (with shadow margins) puts the capsule below and right of the pointer on the volume button. #92 used `.above`. |
| Disabled buttons | no tooltip, no plate | guess |
| Favicon button | no tooltip; AX label "Back to Tab" | guess (Arc's button has no label) |
| AX labels | the tooltip titles | Open choice (Arc exposes only symbol descriptions) |
| Default-theme tooltip fill | `#0A0D4F` (E3). Open's default guess `#1C1B22` is wrong. Fix it outside this step (one token, `SpaceThemeStyle.tooltipFill`, sidebar lane). | fact; follow-up |

### 13.5 States

| State | Look and behavior | Status |
|---|---|---|
| Rest (the pointer is not in the hover rect) | the 33 pt controls-only card; a collapsed stack | fact E2, E6 |
| Pointer in the hover rect | expanded: every card shows its title row, and a stack fans out | derived, high: E3 (expanded, with the pointer on volume) against E4 (rest, 1.2 s later, no plate); E7 (stack); PP-14 has one `isExpanded` on `MediaControlsView` and hover-off subjects. The notes say "a click on volume expands", but the synthetic click and the pointer arrived together, so the capture cannot separate them (§13.7 O6). |
| Button hover | the plate (§13.4.1); the tooltip after 0.45 s | fact E3, E7 |
| Button pressed | the pressed plate | guess |
| Disabled (no previous or next track) | the disabled glyph color; no plate; no action; AX disabled | fact E2 (AX `disabled`, `#3C3C56`); no plate: guess |
| Pointer on the card body | no fill change | fact E3 (`#050627` under the pointer) |
| Click on the body, the title, or the favicon | Back to Tab (§4.2.3). The card then leaves, because its tab is now displayed. | body: fact (notes 10:33:43; E5). Favicon: guess. |
| Playing | `pause.fill` | fact |
| Paused | `play.fill`; the card stays (60 min rule, §4.2.2) | guess for the glyph (code name) |
| Muted tab | `speaker.slash.fill` | guess |
| Video source with no open PiP | the PiP button in the title row | fact (every captured source was a video) |
| Audio-only source | no PiP button; the title runs to Close − 10 | guess |
| PiP window shows | no card | fact (S2 13; `interaction-states.md` §20.7) |
| Source is the visible tab | no card | fact (S2 12) |
| Recording source | §13.7 O5 | guess |
| Peek open | the container dims with the bottom bar | Open (kept; MC10) |
| Inactive window | colors unchanged | guess |
| Light content | §13.4 | guess |
| Reduce Motion | 0.1 s cross-fades, no movement | Open (kept) |

### 13.6 Transitions

No capture timed the mini player (the item 21 video has none). Every
timing below reuses an existing `Motion` token and is a guess. Every
animation is a finite Core Animation animation. Nothing runs, redraws, or
waits on a timer while the card is at rest (D-11, MC8, MC9).

| Change | What moves | Timing | Status |
|---|---|---|---|
| Hover in | One card: its top edge moves up 33 pt; its bottom edge stays. A stack: each card moves to its expanded frame, widens, and goes to opacity 1; the slots re-space with the width. The pager's bottom edge moves up by the same amount. | starts on pointer enter; spring `Motion.miniPlayerStack` (response 0.2, damping 1.0) for every frame and opacity change | guess (the end states are fact) |
| Title rows appear | opacity 0 → 1 at their final place; the card's clipped content reveals them as the top edge rises | `Motion.miniPlayerReveal` (0.15 s), ease-out, starting with the spring | guess |
| Hover out | the reverse of hover in | starts `MiniPlayerMetrics.collapseDelay` (0.3 s) after the pointer leaves the hover rect; the same spring | delay guess (PP-14 has a debounced hover-off). E4 and E8 show the collapse finished within about 1.3 s. |
| Title rows leave | opacity 1 → 0 | `Motion.miniPlayerDisappear` (0.12 s), ease-in, starting with the spring | guess |
| First card appears | the container grows 0 → 41 (the pager bottom moves up 41); the card fades in | `Motion.rowStructure` (0.22 s ease-in-out); fade `Motion.miniPlayerReveal` (0.15 s) after `Motion.miniPlayerAppearDelay` (0.05 s) | kept from #92; guess |
| Last card leaves | the card fades out, then the container shrinks 41 → 0 | 0.12 s fade, then 0.22 s ease-in-out | kept; guess |
| Card added to a stack | the new card fades in at slot 0; the older cards move back one level (7 pt up, 5 pt inset, opacity −0.2) | spring; fade 0.15 s | guess |
| Card removed from a stack (Close, the source ends, the tab is shown) | the card fades out; the others move forward one level | fade 0.12 s; spring | guess |
| A 4th source | the oldest card leaves and the new one enters in the same transaction | as above | guess |
| Play ↔ pause glyph | `.replace` symbol transition | system | kept |
| Volume drawer opens or closes | the card grows 66 ↔ 99 (the top edge moves) | `Motion.miniPlayerResize` (0.2 s ease-in-out) | guess |
| Reduce Motion | one container cross-fade covers the whole card subtree; the pager applies its final frame immediately, with no animation. No card/row/button opacity fades or geometry animations. | `Motion.reducedMedia` (0.1 s) | kept |

For context only: capture session 2 measured faster sidebar motion than
our tokens (Space switch spring 0.20 s, folder expand 0.20 s ease-out;
`interaction-states.md` §20.12). If a mini-player capture shows the same,
change `Motion.miniPlayerStack` only.

How to animate: capture each layer's current presentation position, bounds size,
opacity and shadow path before changing its model values whenever a `media.*`
animation is active. Otherwise derive the start position from the old frame and
the layer's `anchorPoint` (AppKit backing layers anchor at `(0,0)`, not the center).
Set the final frames once. Then, in one `CATransaction`, add `CASpringAnimation`s
from the captured on-screen values (`position`,
`bounds.size`, `opacity`, and the shadow layer's `shadowPath`) to each card,
its content view, and each row and button that moved. Add no per-frame
code, display link, or timer. The pager keeps the `.stack` height transition in `SidebarView.layout()`.
Both the pager and container use anchor-correct start positions and retarget from
presentation values during an interruption. Title and drawer rows keep their
on-screen place while the content clip reveals them:
`titleRow.y = bounds.height - cardHeight(expanded: true, drawer: drawerIsOpen)`;
`drawerRow.y = bounds.height - 2 * rowHeight`. The row frame changes use the same
spring as the card; their final expanded positions remain 0 and 33.

Only real media changes (expand, collapse, source add/remove/replacement, or
drawer resize) set a pending transition. The container consumes it once and
passes the animation flag to each card’s next layout. Sidebar width changes
apply frames immediately with implicit actions disabled, and cancel in-flight
media animations in the pager/container/card subtree. Under Reduce Motion,
use one `CATransition(.fade, 0.1 s)` on the container, including source changes
that keep the same height. Never fade a persistent view in from opacity zero.
Hiding the sidebar cancels pending collapse work and resets an unforced stack
to collapsed without animation; showing it does not restore stale expansion.

### 13.7 Open items (provisional designs, to capture later)

Each design below is a guess. Build it in one token or one function.

| # | Item | Provisional Open design | Capture needed |
|---|---|---|---|
| O1 | Paused and muted glyphs | `play.fill` 14 Medium; `speaker.slash.fill` 14 Medium | a paused card and a muted card (S8) |
| O2 | The volume click and the drawer | Q8 stays: until EM-2, a click on volume toggles mute. With tab volume (EM-2, and the fake host in the harness), a click on volume while expanded opens a 33 pt drawer row `[0, 33, cardW, 33]` between the title row and the controls row (card 99). The row holds `speaker.wave.1.fill` 12 Medium at `[10, 38, 24, 24]` (click: toggle mute); a slider `[44, 33, cardW − 88, 33]` with a 4 pt track centered in the row (radius 2; track `mediaControlGlyphDisabled`, fill `mediaControlGlyph`), a 12 pt white knob with the `SidebarColors.tabShadowSelected` shadow, knob centers 6 … trackWidth − 6, values 0…1 in steps of 0.05; and `speaker.wave.3.fill` 12 Medium at `[cardW − 34, 38, 24, 24]` (click: 100 %). Collapsing the stack closes the drawer. | In Arc the click did not mute (E3 keeps `speaker.wave.3.fill`, AX "Volume Higher"), and no drawer showed within about 2 s. Capture: click volume and wait 3 s; then hover the volume button; drag a slider if one shows (S5). |
| O3 | What Close does to playback | Close pauses the media and removes the card. The card comes back when the source plays again (lead Q5, unchanged). | click Close on a playing card and check playback (item 15) |
| O4 | Back to PiP | The PiP button opens a manual PiP for the tab; the card leaves while PiP shows (rule 3). After the user minimizes the PiP, the card comes back with the same button. | minimize a PiP, then click the card's PiP button (S7, item 15) |
| O5 | Recording source | Controls slots 0 favicon, 1 microphone, 2 camera; slots 3 and 4 stay empty. The title row is unchanged. Ships with Step 8 (Q13). | a Meet or camera tab in the background (S9) |
| O6 | One card, hover without a click | It expands (§13.5). | hover a lone card for 3 s without a click |
| O7 | Audio-only source | no PiP button | a music site in the background |
| O8 | Light content and themed Spaces | the §13.4.2 rule | one card in macOS Light (default theme), and one each in a dark-content and a light-content themed Space (step 8 of item 14 was skipped) |
| O9 | Timing | the §13.6 tokens | a screen video of hover in and out, stack expand and collapse, card add and remove |
| O10 | Favicon button | click = Back to Tab; a plate on hover | hover and click the favicon |
| O11 | Title hover | keep #92's "Back to Tab" cross-fade (`Motion.miniPlayerTitle`, 0.12 s) | hover the title of an expanded card |
| O12 | Marquee | off (static truncation). If a capture shows scrolling, restore #92's `MarqueeLabel` from git history with the PP-17 numbers. | keep the pointer on an expanded card with a long title for 5 s or more |

### 13.8 Implementation plan

One PR stacked on `t3/mini-player-capture-redesign` (#109): "Media Step 3b: mini-player redesign from capture session 2". No new
dependencies. No unit tests (AGENTS.md rule 6). Verify with
`sidebar-render check`, offscreen renders, the compare runs in §13.8.6,
and MC9. Run heavy jobs through
`~/Library/Caches/OpenRE/scripts/heavy.sh`.

#### 13.8.1 Files and types

| File | Change |
|---|---|
| `OpenDesign/FeatureMetrics.swift` | Replace `MiniPlayerMetrics` with the block below. |
| `OpenDesign/SpaceThemeStyle.swift` | Add `miniPlayerFill(_:)` (§13.4.2) and `public enum DefaultThemePalette { public static let darkBackgroundExtra = RGBA(hex: 0x050627); public static let lightBackgroundExtra = RGBA(hex: 0xFDFDFF) }` with a comment that cites §13.4.2 (dark: fact; light: derived). |
| `OpenDesign/Palette.swift` | In `SidebarRole`: remove `miniPlayerFill` and `miniPlayerHoverFill`. Add `mediaControlGlyphDisabled = DesignColor(light: .black(0.17), dark: .white(0.22))`, `miniPlayerTitle = Core.foregroundPrimary` (the existing `ForegroundPrimary` token). Keep `mediaControlGlyph` and `mediaDrawerKnob`. |
| `OpenDesign/Typography.swift` | `miniPlayerTitle = FontToken(13, .regular)`. |
| `OpenDesign/Icons.swift` | `mediaPlay`, `mediaPause`, `mediaPrevious`, `mediaNext`, `mediaClose`, `mediaVolumeMuted`, `mediaMicrophone`, `mediaMicrophoneMuted`, `mediaCamera`, `mediaCameraOff`: 14 pt `.medium`. `mediaVolume`: `speaker.wave.3.fill`, 14 pt `.medium`. `mediaPiP`: `pip`, 12 pt `.medium`. `mediaVolumeLow` and `mediaVolumeHigh`: 12 pt `.medium`. Fill `arcInk` with the §13.4.3 ink boxes; note "media plan §13.4.3". Do not change the `pip*` glyphs of the PiP window. |
| `OpenDesign/Motion.swift` | Mini-player spring response 0.2 s, damping 1; keep it a guess until O9. Other motion tokens stay unchanged. |
| `OpenSidebar/MiniPlayerCardView.swift` | Rewrite the layout (§13.8.2, §13.8.3). Expose `titleState: MiniPlayerTitleState` and register `control(named: "favicon")`. |
| `OpenSidebar/Controls.swift` | Add an optional Core Text draw receipt for the title hook; keep `TextLabel` internal. Only the mini-player title installs the receipt. |
| `OpenSidebar/MediaControlsView.swift` | Rewrite the stack math and the hover (§13.8.3). |
| `OpenSidebar/MarqueeLabel.swift` | Delete it. |
| `OpenSidebar/SidebarContext.swift` | `SidebarMediaHover` becomes `case expanded, title(ItemID)` (remove `stack` and `card`). |
| `OpenSidebar/SidebarView.swift` | Keep geometry driven by `requiredHeight`. Anchor-correct animation starts and presentation-based retargeting for pager/container height changes; retain the `.stack` spring path. |
| `sidebar-render/MediaScene.swift` | The flags in §13.8.4. |
| `sidebar-render/MediaChecks.swift`, `MediaMotionChecks.swift`, `MediaLifecycleChecks.swift`, `Checks.swift` | MC1–MC16 (§13.8.5), including native offscreen motion/lifecycle gates and focused `--media-motion-only` and `--media-lifecycle-only` runs. RI checks are unchanged. |
| `sidebar-render/MediaCompare.swift` (new), `RenderCLI.swift` | `compare-media` (§13.8.6). |
| `sidebar-render/OffscreenRenderer.swift` | Preserve `allowsGroupOpacity` when cloning layers, so back cards composite as one image (§13.8.2). |
| `sidebar-render/Bench.swift` | The `--media-card` log line reports the new height (`container 41.0 pt`). |
| `Packages/OpenKit/MediaRenders/step3b/` (new) | `render-scenes.py`, `compare-bench.py` (a copy of step3's that asserts `container 41.0 pt`), `README.md`, our renders, and the compare tables (numbers only). |
| `docs/plans/media-pip.md` §13, `docs/design.md` §22 | Record the results. Change a status to "fact" only with a frame cite. |

`MiniPlayerMetrics`, exact:

```swift
/// Media plan §13 (Step 3b). Capture session 2 frames are cited per value.
public enum MiniPlayerMetrics {
    public static let inset: CGFloat = 8                  // fact E2
    public static let gapAbove: CGFloat = 8               // fact E2: the pager ends 8 pt above the stack
    public static let rowHeight: CGFloat = 33             // fact E2, E3
    public static let cornerRadius: CGFloat = 10          // fit E2, E3; cornerCurve .continuous
    public static let button: CGFloat = 24                // code PP-16; fact E2
    public static let buttonY: CGFloat = 5                // inside a row; fact E2, E3
    public static let buttonPlateRadius: CGFloat = 5      // fit E3/E7: continuous RMS 0.034 vs 0.116 at 6
    public static let slotInset: CGFloat = 10             // first slot x, and the gap after the last slot; fact E2, E6
    public static let slotCount = 5                       // fact E2
    public static let faviconSize: CGFloat = 16           // fact E2
    public static let titleX: CGFloat = 14                // fact E3
    public static let titleBaseline: CGFloat = 22         // fact E3
    public static let titleGap: CGFloat = 10              // title end → first title-row button; fact E3
    public static let closeTrailing: CGFloat = 34         // Close x = cardW − 34; fact E3
    public static let pipTrailing: CGFloat = 58           // PiP x = cardW − 58; fact E3
    public static let stackOffset: CGFloat = 7            // fact E6
    public static let stackInset: CGFloat = 5             // per side, per level; fact E6
    public static let stackOpacityStep: CGFloat = 0.2     // fit E6
    public static let expandedGap: CGFloat = 5            // fact E7
    public static let shadowOpacity: Float = 0.21         // fit E2
    public static let shadowRadius: CGFloat = 4           // fit E2
    public static let collapseDelay: TimeInterval = 0.3   // guess
    public static let tooltipDelay: TimeInterval = 0.45   // code PP-6
    // Volume drawer: guess (§13.7 O2).
    public static let drawerSliderInset: CGFloat = 44
    public static let drawerTrackHeight: CGFloat = 4
    public static let drawerTrackRadius: CGFloat = 2
    public static let drawerKnob: CGFloat = 12
    public static let drawerShadowBlur: CGFloat = 2
    public static let drawerShadowOffset = CGSize(width: 0, height: -1)
    public static let volumeStep: Double = 0.05

    /// Card height: one row at rest, two expanded, three with the drawer.
    public static func cardHeight(expanded: Bool, drawer: Bool) -> CGFloat {
        expanded ? (drawer ? 3 : 2) * rowHeight : rowHeight
    }
    /// Slot k's x in a card of width w, on the backing pixel grid (halves round up). Fact E2, E6.
    public static func slotX(_ k: Int, cardWidth w: CGFloat, scale: CGFloat) -> CGFloat {
        let x = slotInset + CGFloat(k) * (w - 2 * slotInset - button) / CGFloat(slotCount - 1)
        return (x * scale + 0.5).rounded(.down) / scale
    }
}
```

Remove: `verticalInset`, `height`, `titleRowHeight`, `titleTrailing`,
`rightButtonPitch`, `favicon`, `faviconInk`, `rightButtonInset`,
`titleButtonY`, `controlsY`, `controlsInset`, `controlsPitch`,
`stackWidthOffset`, `stackOpacity`, `stackEdge`, `drawerIconX`,
`drawerIconY`, `drawerIcon`, `drawerTrailingIconInset`, `drawerSliderX`,
`drawerSliderY`, `drawerSliderHeight`, `drawerTrackY`, `drawerHeight`, and
every `marquee*` constant.

#### 13.8.2 View tree

```text
MediaControlsView                [0, h − 50 − C, W, C]; no clipping; one tracking area = the hover rect
└─ MiniPlayerCardView × n        z: newest on top; alphaValue = the §13.3.4 opacity
   ├─ shadowLayer (CALayer)      first sublayer, frame = bounds; shadowColor opaque black (alpha 1), shadowOpacity 0.21,
   │                             shadowRadius 4, shadowOffset 0, shadowPath = CGPath(roundedRect: bounds, 10, 10)
   └─ contentView                frame = bounds; fill = miniPlayerFill; cornerRadius 10, cornerCurve .continuous,
      │                          masksToBounds = true; 1 pt separator border only with Increase Contrast
      ├─ titleRow  [0, 0, cardW, 33]           only while expanded (alpha 0 and hidden after the fade otherwise)
      │  ├─ titleLabel: TextLabel              13 Regular, baseline 22, tail truncation, x 14
      │  ├─ pip: MediaControlButton            [cardW − 58, 5, 24, 24]
      │  └─ close: MediaControlButton          [cardW − 34, 5, 24, 24]
      ├─ drawerRow [0, 33, cardW, 33]          only when the drawer is open (O2)
      └─ controlsRow [0, H − 33, cardW, 33]
         └─ favicon (button with a FaviconView), previous, play, next, volume  (or microphone, camera)
```

Put the shadow on its own sublayer: AppKit owns the shadow properties of a
view's backing layer and resets them (the `RevealCardShadowView` pattern).
Use `MiniPlayerMetrics.shadowOpacity` as the only shadow alpha source; do not
also use a 0.21-alpha shadow color. Set `layer.allowsGroupOpacity = true`
on each card, so a back card composites as one image at its opacity. The §13.3.4 fit assumes this.
Without it, the card's own shadow, which also lies under its fill, would
show through the fill. Do not set `shouldRasterize`. MC9's report-only
stack run shows the cost.

#### 13.8.3 Behavior

`MediaControlsView`:

- `isExpanded` becomes true at once when the pointer enters the hover rect,
  for any `n ≥ 1`, or while `forcedMediaHover != nil`. On exit, one
  `DispatchWorkItem` clears it after `collapseDelay`. Cancel the item on
  re-entry, on hide, and on window close (keep #92's mechanism).
- In `measure()`, first set each card's `isExpanded` and level `i`, and
  close drawers when collapsing. Only then sum `cardHeight` values. Layout
  places the §13.3.4 frames and opacity; it does not change expansion state.
  Card `i > 0` returns nil from `hitTest` unless the stack is expanded.
- `requiredHeight = cards.isEmpty ? 0 : gapAbove + stackHeight`.
- Update the tracking area to the hover rect on every layout.
- Delete the `CAShapeLayer` masks and the stack-edge layer.
- Height transitions: `.stack` (spring) for hover changes and for adds and
  removes within a stack; `.structure` for the first and the last card;
  `.drawer` for the drawer.

`MiniPlayerCardView`:

- Inputs: `source`, `isExpanded`, `level`, and `drawerIsOpen` (the drawer
  opens only while expanded).
- `cardHeight = MiniPlayerMetrics.cardHeight(expanded:drawer:)`.
- Layout passes `window?.backingScaleFactor ?? 2` to `slotX`; never hardcode 2.
- Collapse removes the card's ID from `context.mediaDrawers`, so the next
  expansion starts with the drawer closed.
- Previous and Next: always present for an audio or video source;
  `isEnabled = actions.contains(.previousTrack / .nextTrack)`; tint
  `enabled ? mediaControlGlyph : mediaControlGlyphDisabled`. Hide them only
  for a recording source.
- PiP: shown when `isExpanded` and `source.hasVideo`. Close: shown when
  `isExpanded`. No width animation.
- Title: a `TextLabel` with the tab's display title, or "Back to Tab" while
  the title is hovered (a 0.12 s cross-fade, `Motion.miniPlayerTitle`).
- Favicon: a plate button around a `FaviconView`; action `.backToTab`; AX
  label "Back to Tab". Register it as `control(named: "favicon")`.
- Public title hook: `titleState: MiniPlayerTitleState` exposes the title
  frame, baseline, font size, actual drawn text, drawn width, and truncation
  flag. `TextLabel` stays internal. Its optional `onDrawnLine` receipt reports
  the real Core Text line, so MC4/MC7 can read baseline 22 and the actual
  tail ellipsis without replacing the rendering path.
- A click on the body (mouse up inside, not on a button) sends
  `.backToTab` (kept).
- Fill: `context.style(for: focusedSpace).miniPlayerFill(context.appearance(for: focusedSpace))`.
  Keep the observation reads of the theme and the appearance.
- Tooltips: `placement: .beside`, `showDelay: MiniPlayerMetrics.tooltipDelay`.
- No hover fill and no marquee.

#### 13.8.4 Harness flags (`sidebar-render render`)

- `--media "SPEC"` (existing): flags `audible`, `playing`, `paused`,
  `silent`, `muted`, `recording`, `video`, `tracks`, `long`,
  `paused-min=N`.
- `--media-hover expanded|title:N` (replaces `stack` and `card:N`).
- `--media-button-hover ID[:N]` and `--media-button-pressed` (existing; add
  the card index `N`, default 0 = the newest card).
- `--media-drawer N` (existing; it has an effect only with
  `--media-hover expanded`).
- `--media-theme default|red` (existing).
- `--media-title-from-ax PATH` (new): read the last `AXStaticText` value
  inside the mini-player hosting view of a local Arc `ax.json`, and use it
  as the title of every media tab. Never print it or write a text copy to a file.
  Use it only for local compare runs under `.re/`. Never commit a PNG made
  with this flag or any real title; re-render synthetic titles for commit.
- `--crop-media-controls` (existing).

#### 13.8.5 `sidebar-render check`: MC1–MC16

Run them in the composed sidebar at `W` 228, h 900, scale 2, with fake
hosts and native events, as #92 does. Each line prints PASS or FAIL.
Frames are ± 0.5 pt.

| ID | Check |
|---|---|
| MC1 | No source: `C = 0`, and the pager ends at h − 50 (unchanged). |
| MC2 | One source at rest: `C = 41`; card `[8, h − 83, W − 16, 33]`; the pager ends at h − 91. |
| MC3 | Rest controls: five 24 × 24 buttons at card y 5 and x 10/52/94/136/178; the glyphs and tooltip titles of §13.4.3–§13.4.4; placement `.beside`; delay 0.45 s. Without the track actions, Previous and Next are present, `isEnabled == false`, tinted `mediaControlGlyphDisabled`; a synthesized hover shows no plate; a click sends no intent. With the actions they are enabled. |
| MC4 | Hover in (a synthesized `mouseEntered` on the container): the card becomes `[8, h − 116, W − 16, 66]` and `C = 74`; the title row shows: title origin x 14, baseline 22; for a video source PiP `[cardW − 58, 5]` and Close `[cardW − 34, 5]`. An audio-only source has no PiP, and the title's maximum width is `cardW − 58`. Read title frame and baseline through `titleState`. Exit: synchronously assert the card is expanded with one pending item and `pendingCollapseDelay == 0.3`; after the delayed work runs it is 33 pt again, and the title row has no view that takes a hit. Do not infer the configured delay from a 0.15 s fixed sleep. |
| MC5 | Clicks (native events through `window.sendEvent`): Previous, Next, Play/Pause, Volume, PiP, and Close send the §4.2 intents. The favicon, the title, and an empty part of the card send `.backToTab`. No button changes the selection. Volume without EM-2 toggles mute (Q8). Preserve the existing regressions: a retiring card refuses hits during its fade; replacement in one event turn leaves one fresh card; tab close prunes its drawer ID and undo restores a 33 pt card with no drawer. |
| MC6 | Stack of 3 at rest: `C = 55`. Frames `[8, …, 212, 33]`, `[13, …, 202, 33]`, `[18, …, 192, 33]`, each 7 pt above the one in front. Opacities 1, 0.8, 0.6. No layer masks. A back card's strip takes no hit. Back-card slots in container x at scale 2: 23/62.5/102/141.5/181 and 28/65/102/139/176 (at 1x the halves round up: 23/63/102/142/181, as Arc's E6). Hover: `C = 216`; frames from the bottom `[8, C − 66, …]`, `[8, C − 137, …]`, `[8, C − 208, …]`; all opacities 1; every card has Close. Exit: assert one pending collapse with its configured delay exactly 0.3 s, then wait for the real work to produce collapsed C=55. |
| MC7 | Title: a long title draws one line that ends in "…" and fits its maximum width. Read the actual drawn text, truncation flag and width from `titleState`. No `MarqueeLabel` exists in the view tree. The title label's layer has no animation keys at rest, expanded, playing, or paused. |
| MC8 | Idle: a paused card collapsed to 33 pt after a hover cycle ended. The window's layer tree has no animation keys; there is no media timer or display link; `pendingCollapseCount == 0`; `store.pendingWorkItemCount == 1`; CPU ≤ 0.5 % over 2 s. |
| MC9 | `bench --rows 1000 --media-card` (one paused card at rest, container 41 pt) against main with no card: the paired median and 20%-trimmed mean p95 deltas are ≤ 0.3 ms over 12 interleaved pairs (`step3b/compare-bench.py`). If it fails, use the step3 scroll-investigation method (an A/A control and instructions per scroll step) before you call it a regression. Also report, with no gate, one run with a collapsed stack of three paused cards. |
| MC10 | A Peek dims the container with the bottom bar; closing it restores opacity 1. |
| MC11 | Colors: default theme fill `#050627` (dark) and `#FDFDFF` (light); the red theme fills with its parsed `dark.backgroundExtra` and `light.backgroundExtra`; the title, glyph, disabled, and plate colors resolve to the §13.4.1 values (± 0.002 per component). |
| MC12 | Corner and shadow: the content layer has `cornerRadius` 10, `cornerCurve` `.continuous`, and `masksToBounds`. The shadow layer has an opaque black `shadowColor` (alpha 1), `shadowOpacity` 0.21, `shadowRadius` 4, `shadowOffset` zero, and a `shadowPath` equal to the rounded rect of the card bounds after every frame change. |
| MC13 | Drawer (a fake host with volume): a click on volume while expanded gives a 99 pt card, `C = 107`, and a drawer row `[0, 33, cardW, 33]` laid out per O2. Collapse closes it (`C = 41`) and removes its ID from `context.mediaDrawers`; re-expansion does not reopen it. |
| MC14 | Recording source: slots 0/1/2 hold the favicon, the microphone, and the camera; there is no Play, Previous, Next, or Volume. |
| MC15 | Motion regressions in the composed sidebar: the height-animation start equals the current on-screen position for non-centered anchors; at +16 ms the pager stays at its model x/y. Re-enter 50 ms into a real delayed collapse: the container, pager, card, content, title opacity and shadow start from presentation values; at +16 ms the visible card/container height has no backward jump. Title/drawer rows never overlap the controls during motion. Run one- and three-card cases and the drawer. With Reduce Motion OFF, native play/pause image replacement and live AppKit ink are checked. `check --media-motion-only` runs this same focused flow. Transitions run and end: on hover in, the cards, the pager, and the title rows carry animation keys; 0.8 s later no key remains. With Reduce Motion there is one container `CATransition(.fade, 0.1 s)`, no pager animation, and no descendant opacity animation starting at zero. At +16 ms the pager and container remain fully opaque. |
| MC16 | `check --media-lifecycle-only`: hover in/out and a fourth source at unchanged height use one container cross-fade, no opacity-from-zero on any view, and full pager/container opacity at +16 ms. Width drags in both motion modes (400 → 228 pt) fit model and presentation widths immediately with no attached animation keys. Add/remove while expanded gives C=145 → 74 with titles. Hide/show during the collapse delay restores collapsed C=55 with no pending work. |

#### 13.8.6 Comparison with Arc (`docs/design.md` §7 method)

New subcommand:

```text
sidebar-render compare-media --arc FRAME.png --ours RENDER.png --out DIR
                             --state rest|expanded|stack|stack-expanded
                             [--arc-reference E1.png --ours-reference RENDER-NO-MEDIA.png]
                             [--mask X,Y,W,H …]
```

It loads both PNGs into sRGB (Core Graphics converts through the embedded
display profile, §7 step 3). It places the §13.3 metrics in the window
frame (1728 × 1084, `W` 228, bottom bar at y 1034) and measures each
element in both images:

| Element | Measure | Target |
|---|---|---|
| Card edges (each card) | the edges of the fill's ink box | ≤ 1 pt per edge |
| Card fill | the mean of a 6 × 4 sample between slots 2 and 3, and one in the title row right of the title | ΔE00 ≤ 2 |
| Glyphs: Previous, Play/Pause, Next, Volume, PiP, Close | the ink box (50 % of peak contrast against a plane fit to a 1 px ring, §7 step 4) and the core color (≥ 85 % of peak) | box edges ≤ 1 pt; ΔE00 ≤ 2 |
| Title | the ink box's left, top, and bottom edges (the right edge only when both strings are the same), and the core color | ≤ 1 pt; ΔE00 ≤ 2 |
| Hover plate | box edges and a fill sample | ≤ 1 pt; ΔE00 ≤ 2 |
| Back strips (collapsed stack) | a fill sample in the middle of each 7 pt strip, x 40…190 | ΔE00 ≤ 2 |
| Expanded gaps | a row sample at the middle of each 5 pt gap | ΔE00 ≤ 2 |
| Shadow | the darkening at 0.5, 2.5, and 4.5 pt below the front card, as a fraction of the reference without media | within ±1.5 percentage points of Arc (9.2 %, 5.4 %, 2.7 %) |

Masks exclude pixels from fill/background samples and the diff pane only;
ink boxes and glyph/title core colors still use the original pixels. The
local Arc/Open panes remain intact. Masks: the favicon slot of every card;
in E3 the tooltip capsule plus shadow (`--mask 198,1018,30,66`; the real
capsule within the sidebar is x 204–227, y 1025–1051); everything from y
1034 down (the bottom bar shows the user's own Space icons). This leaves
the Volume glyph measurable. Shadow samples below y 1034 are explicitly
exempt from the bottom-bar mask and use the no-media reference. Output: `table.md` (element
names and numbers only) and `side-by-side.png` (Arc | Open | diff × 4). The
side-by-side image has Arc pixels: write `--out` under `.re/` and never
commit it. Commit `table.md` only after you check that it holds no title
text.

Runs (local). Common flags: `--size 1728x1084 --width 228 --scale 1
--appearance dark --media-theme default --media-title-from-ax <the frame's ax.json>`.

| Run | Arc frame | Open render flags | `--state` |
|---|---|---|---|
| R1 rest | E2 (14b/0014) | `--media today:0=playing:video` | `rest` |
| R2 hovered and expanded | E3 (14b/0024) | R1 + `--media-hover expanded --media-button-hover volume` | `expanded` |
| R3 stack collapsed | E6 (16/0004 pixels) | `--media today:0=playing:video,today:1=playing:video,today:2=playing:video` | `stack` |
| R4 stack expanded | E7 (16/0012) | R3 + `--media-hover expanded --media-button-hover play:0` | `stack-expanded` |

In R3 and R4 all Open titles are the same string and Arc's differ, so
compare only the left, top, and bottom title edges there. Use E1 and a
render without `--media` as the shadow references. Pass rule: every
element meets its target, or the PR names each miss with its numbers and
a cause (as `docs/design.md` §8 and §9 do). Light content has no Arc frame:
render it, and keep its values marked guess.

#### 13.8.7 Renders to commit (`MediaRenders/step3b/`, our own only)

At scale 2, `W` 228 and 500, light and dark, default theme: rest (playing
video), paused, muted, disabled tracks, audio-only expanded, video
expanded with the volume plate, button pressed, tooltip, stack collapsed,
stack expanded, drawer (fake volume), recording, the red theme (light and
dark), the 164 pt minimum (rest and expanded), and Increase Contrast.
Re-render the same four R1–R4 states at 1x with synthetic titles for commit.
Every committed PNG must use synthetic titles only. AX-title renders,
even though they contain only Open pixels, stay under `.re/` with the
comparison images and must never be committed.

#### 13.8.8 Order of work

1. Tokens: `MiniPlayerMetrics`, the roles, `miniPlayerFill`, the title
   font, the glyphs. Build.
2. `MiniPlayerCardView`: the rows, the slots, disabled tracks, the favicon
   button, the title label, the shadow layer, the clipped content.
3. `MediaControlsView`: the stack math, hover for `n ≥ 1`, the opacities,
   no masks, the hover rect, the animations.
4. Delete `MarqueeLabel.swift` and fix its references.
5. The harness flags; rewrite MC1–MC15. RI checks stay as they are. Carry
   over all unnumbered current MC regressions unless §13 explicitly replaces
   them, including retiring/replacement hits and drawer prune/undo.
6. `compare-media`; run R1–R4 locally. Tune only values marked guess or
   fit. Never change a fact to make a check pass.
7. Renders, MC9, and `tools/verify-all.sh` through the heavy-job script.
8. Update §13 and `docs/design.md` §22 with the compare tables and any
   changed values.

Acceptance: MC1–MC15 PASS; every other `sidebar-render check` line PASS;
R1–R4 meet the targets or name each miss; MC9 PASS; `tools/verify-all.sh`
PASS.

### 13.9 Initial implementation results (head 85fd361, 2026-10-26)

Implemented on `feature/media-step3b-mini-player`, stacked on #109. The
F1–F11 Muse review corrections above ship with the implementation: one shadow
alpha source, expansion before measurement, explicit masks, the public title
receipt, retained retiring/replacement/drawer-prune checks, and the wording fixes.
`Core.foregroundPrimary` is the existing catalog token used for the title.

| Run / Arc frame | Worst edge error (pt), target ≤1 | Worst ΔE00, target ≤2 | Worst shadow error (pp), target ≤1.5 |
|---|---|---|---|
| R1 / E2 | 0 | 0.56 | 0.91 |
| R2 / E3 | 0 | 0.73 | 0.93 |
| R3 / E6 | 2 | 0.56 | 0.91 |
| R4 / E7 | 2 | 0.86 | 0.93 |

Named misses under §13.8.6's rule: R3's back card 1 strip has a 2 pt
right-edge difference (Arc x=212, Open x=210 in the threshold scan). Cause
(inference): the rounded translucent strip and its background give a different
threshold box; native MC6 verifies the exact full card frames. R4's middle title
has a 2 pt bottom-edge difference (919 vs 921) because the different strings have
different descenders. Its top edge matches and left edge differs by 1 pt. All
other glyph/title edges match; no fact token was changed to hide a miss.

MC9: 12 interleaved pairs against pinned main `f3c9cc5`, with the on-screen
lock held for the entire series. Paired median delta **−0.005 ms**, 20%-trimmed
mean **−0.085 ms** (limit +0.3 ms); PASS. Baseline/head median p95:
2.035/1.980 ms. Three-card stack report-only: 2.22 ms p95. The required 20-pair
A/A control passed at +0.070/+0.121 ms. The initial contended, pre-review run
failed at +0.390/+0.402 ms; its receipt and the pre-merge runs are retained.

`sidebar-render check`: **476 passed, 0 failed**. MC8 idle CPU: **0.011%** over
2 s, no animation keys, no collapse work, one store expiry item.
`tools/verify-all.sh`: **20/20 PASS**, no skips or retries, exit 0, through the
heavy-job wrapper in a detached session after merging main. The final renderer
hash matches the renders, A/A control and MC9 receipts.

All 62 committed PNGs use synthetic titles. No AX-title PNG or real video
title was committed or pushed. Real-title comparisons and Arc/Open/diff images
remain under `.re/`. The CLI rejects AX-title output outside `.re/`. E3's capture
has one extra trailing row (1085 → 1084); it is omitted without moving the origin.
Collapsed E2/E6 have no AX title, so the local runs use E3/E7 titles respectively.
Light/themed fills, drawer and motion retain their provisional labels.

Full numeric tables, render matrix, binary hashes and runtime receipts:
[Step 3b evidence](../../Packages/OpenKit/MediaRenders/step3b/README.md).
The §7 sRGB/plane/ink/CIEDE2000 method is implemented by `compare-media`.

### 13.10 Design review r1 fixes and verification (2026-10-26)

| Finding | Status | Change and evidence |
|---|---|---|
| F1: height-change fly-in | Fixed | Anchor-correct starts for pager/container; new checks compare animation starts with the on-screen position and sample the pager at +16 ms. They fail on `85fd361`. |
| F2: interrupted collapse snaps backward | Fixed | Capture presentation position, size, opacity and shadow path before model changes for container, pager, cards, child views and title fades. Stale title-fade completions are ignored. One- and three-card re-entry checks fail on `85fd361` and pass after the fix. |
| F3: title/drawer overlap controls | Fixed | Pin row frames using the reviewed formulas; the clipped content edge reveals them. Presentation samples during expand, collapse, re-entry and drawer opening show no control-row overlap. |
| F4: plate radius | Fixed | `MiniPlayerMetrics.buttonPlateRadius = 5`, continuous, applied only to mini-player buttons. Spec/design now label the value as an E3/E7 fit. |
| F5: default tooltip fill | Deferred at design review; now inherited from main #113 | The separate token task owns the measured `#0A0D4F` fill. No mini-player-specific token fix. |
| F6: spring response | Fixed, still a guess | Mini-player stack response is 0.2 s, damping 1, based on the measured sidebar spring. O9 still needs a mini-player motion capture. |
| F7: native play/pause coverage | Added | Reduce Motion OFF: check the shipping `NSImageView` path, live AppKit ink, and native-event pause/play replacement. Actual App-window comparison remains with Step 6 integration. |

`tools/verify-all.sh`: **20/20 PASS**, no skips or retries, exit 0, through
`heavy.sh` in a detached session after merging main `d92a695`.
`sidebar-render check`: **525 passed, 0 failed**, including **49 motion checks**.
MC8 idle CPU: **0.014%** over 2 s, no idle animation keys or collapse work.
The focused motion suite passes **49/49**. The identical harness fails the old
`85fd361` production code with **36 failures** (13 PASS), proving the F1/F2 gates
are sensitive to the reported defects.

MC9: **PASS**, 12 interleaved pairs against main `d92a695`, with
`/tmp/open-onscreen-e2e.lock` held across the full series. Paired median delta
**-0.155 ms**, 20%-trimmed mean **-0.275 ms** (limit +0.3 ms).
Baseline/head median p95: 4.350/4.140 ms.
Collapsed 3-card report-only: 3.76 ms p95.

Independent design review confirmed that the R3/R4 2 pt values in the initial
tables are measurement artifacts: rounded-strip ring sampling and different
strings/descenders, respectively. No product geometry correction is needed for
those values. All 62 synthetic renders were regenerated; the raw comparison tables
remain available. Tooltip F5 was deferred at design review; the current main merge inherits the separate #113 token fix.

[Final evidence and review receipts](../../Packages/OpenKit/MediaRenders/step3b/README.md).

### 13.11 Code review r1 fixes and verification (2026-10-26)

| Finding | Status | Change and evidence |
|---|---|---|
| C1: Reduce Motion blink | Fixed | One 0.1 s container CATransition cross-fades the subtree. Pager and child frames apply immediately. Hover in/out and same-height fourth-source checks reject opacity-from-zero and verify full pager/container opacity at +16 ms. |
| C2: width drag trails and re-animates | Fixed | Container/card flags allow animation only for media changes. Width drags cancel existing media animations and apply geometry with implicit actions disabled. 400 → 228 pt drags check every step for no keys and exact model/presentation widths, in both motion modes and expanded/collapsed states. |
| C3: missing assertions | Added | MC6 asserts exit collapse, MC8 asserts collapsed 33 pt rest, MC10 asserts Peek opacity restoration. Expanded add/remove checks assert visible title rows and C=145 → 74. MC15 asserts one root cross-fade and full presentation opacity. |
| C4: hidden sidebar keeps stale expansion | Fixed | Hide cancels collapse work and resets an unforced stack to collapsed without animation. Hide/show within the 0.3 s delay checks C=55, 33 pt cards, no pending collapse, and clean layers. |
| C5: removal under real pointer | Manual check pending | No tracking-area behavior change. §8.5 asks the user to expand two cards, click the top title or Close, move over the tab list, and confirm collapse. The agent cannot confirm this without driving the real pointer. |
| C6: stale flags and dead hitTest branch | Fixed | §8.2 uses expanded\|title:N and points to §13.8.4; the card returns super.hitTest after its visibility/retiring guard. |

`tools/verify-all.sh`: **20/20 PASS**, no skips or retries, exit 0, through
`heavy.sh` in a detached session after merging main `ebea09f`.
`sidebar-render check`: **558 passed, 0 failed**, including **49 motion** and
**30 lifecycle checks**. MC8 idle CPU: **0.013%** over 2 s, collapsed 33 pt,
no idle animation keys or collapse work, one store expiry item.
The identical lifecycle harness fails frozen `3504776` with **18 failures**
(12 PASS) and passes the fixes **30/30**. Existing motion remains **49/49**.

MC9: **PASS**, 12 interleaved pairs against pinned main `ebea09f`, with
`/tmp/open-onscreen-e2e.lock` held across the full series. Paired median delta
**-0.105 ms**, 20%-trimmed mean **-0.135 ms** (limit +0.3 ms).
Baseline/head median p95: 3.100/2.885 ms.
Collapsed 3-card report-only: 3.24 ms p95.

Tooltip F5 was owned by the separate token task. Its fix merged in main #113
and is inherited here; no mini-player-specific tooltip color change was made.
All 62 PNGs were regenerated with synthetic titles and this final renderer.
The §7 comparison tables retain the R3/R4 measurement artifacts accepted by
design review; no geometry token changed. C5 needs the manual §8.5 pointer check.

[Current evidence and review receipts](../../Packages/OpenKit/MediaRenders/step3b/README.md).

### 13.12 Main merge verification (2026-10-26)

Merged main `9e3473c` with a merge commit. The three conflicts were
`MediaControlsView.swift`, `Checks.swift` and `MediaChecks.swift`. Keep the
33/66/99 pt redesign, motion/lifecycle fixes, single-card hover and drawer prune;
retain main’s scheduled-collapse delay receipt, condition-based waits and UUID
preferences suite. `cancelCollapse()` clears both the work item and its delay.
No engine source or key routing was changed by the resolution.

`tools/verify-all.sh`: **20/20 PASS**, no skips or retries, through `heavy.sh`
in a detached session. `sidebar-render check`: **559 PASS, 0 FAIL**.
Focused motion: **49/49**; lifecycle: **30/30**. Two concurrent full sidebar
runs with separate temporary directories and UUID preferences suites each pass
**559/559**. Invalid state/hover CLI cases each exit 1 without writing a PNG.
MC8 idle CPU: **0.023%**, collapsed 33 pt, no idle animation keys or collapse work.

MC9: **PASS**, 12 interleaved pairs against pinned main `9e3473c`, with
`/tmp/open-onscreen-e2e.lock` held across the whole series, after all builds and
focused checks finished. Paired median delta **-0.705 ms**;
20%-trimmed mean **-0.520 ms** (limit +0.3 ms).
Baseline/head median p95: 4.035/3.465 ms.
Three-card report-only p95: 4.11 ms.

All 62 synthetic PNGs were regenerated (62/62 byte-identical to the
previous receipt). R1–R4 numeric comparisons remain unchanged. R3/R4 are the
previously accepted measurement artifacts. No Arc pixels or real-title PNGs
were committed. The renderer hash matches MC9, the render manifest and full
verification.

C5’s real-pointer check and Step 6 real-window snapshots remain pending;
§8.5, `docs/followups.md` and the PR checklist state that scope explicitly.
Historical negative-control receipts describe their original frozen harnesses;
this refresh retains their defect gates and adapts the delay assertions to main.

[Current merge/checklist receipts](../../Packages/OpenKit/MediaRenders/step3b/evidence/main-refresh/README.md).

## Appendix — Lead decisions (2026-10-25)

- Approved as the media controls + Picture in Picture plan. Steps 1–5 start now: they need no App window. Step 6 and later App steps wait for app-shell Step B (#52) and Step G (sleep).
- Q1 Mini players sit above the bottom bar. This is provisional until screenshot S3, then follow Arc. (Resolved 2026-10-26, below.)
- Q2 Up to 3 mini players, newest first.
- Q3 Paused mini players hide after 60 min. A tab stays awake while its mini player shows.
- Q4 Auto-PiP on window minimize, occlusion, or app hide: follow Arc. Screenshot S10 decides. Until then, it is off.
- Q5 Close on a mini player or an auto-PiP pauses the media and skips auto-PiP for that tab until the tab is shown again.
- Q6 A manual PiP stays open when its tab is shown again. Back to Tab closes it.
- Q7 Ship with Chromium's PiP window until EM-4 lands.
- Q8 The volume control is a mute toggle only, until EM-2.
- Q9 No new PiP command or shortcut (Arc has none).
- Q10 "Mute All Tabs" is app-wide.
- Q11 Always respect `disablePictureInPicture`.
- Q12 The Meet chat toggle in Document PiP is deferred.
- Q13 Mic and camera mini players ship with Step 8.
- Q14 No audio badge on Favorites tiles, unless screenshot S9 shows one.
- Q15 ~~The scrolling title is on, with no setting.~~ Superseded 2026-10-26 (below): no marquee.
- Q16 Engine queue: Step 5 (EM-1a, EM-5 interim, EM-8) is OpenEngine-only and goes to the Steps 1–5 implementer, not the engine lead. The fork requests EM-1b, EM-2, EM-3 (P6), and EM-5 (fork path) queue after P2. EM-6 and EM-7 follow them. EM-4 (own PiP window) queues after the ad-block and tab-sleep patch series.
- Q17 The PiP menu check mark shows the current state.
- Screenshots S1–S12: the lead asks the user in one batch with the other plans' screenshot needs. Step 12 waits for them.

## Appendix — Lead decisions (2026-10-26, capture session 2)

- The tab-row speaker is **leading**: a 26 × 26 button with an outline glyph right after the favicon, and the title moves right by 26 (C18; S2 12/0022, 0027). This supersedes the trailing 20 × 20 filled speaker that #67 built. Follow-up Step 2b changes it; the recording dot follows the same leading slot until a capture shows otherwise.
- Out of this amendment (handled separately): the mini player look and the PiP window size.

## Appendix — Lead decisions (2026-10-26)

- **Capture session 2 facts override the 68 pt card design.** Step 3b
  (§13) replaces the card that #92 shipped: a 33 pt controls-only card at
  rest; a 66 pt card with a title row while the pointer is over the
  stack (one card included); 8 pt above the stack and 0 below; back cards
  7 pt up, 5 pt inset per side, opacity `1 − 0.2·i`, not masked; expanded
  cards 5 pt apart; the fill is the Space palette's `backgroundExtra`;
  glyphs are Medium; the title is 13 Regular and static. Struck values in
  §4.2 are tombstones; do not build from them.
- Q1 is resolved: the stack sits on the bottom bar's top edge, 8 pt below
  the tab list (S2 14b/0014).
- Q15 is superseded: Arc showed a static, tail-truncated title, so Open
  ships no marquee. §13.7 O12 says how to restore it if a capture shows
  scrolling.
- Q5 (Close pauses) and Q8 (the volume control toggles mute until EM-2)
  stay. Both are listed for a future capture (§13.7 O2, O3).
