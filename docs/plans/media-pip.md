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
| D-3 | The mini player stack lives in its own container between the Space pager and the bottom bar. The bottom bar gets no media button. | PP-20; the measured bottom bar is Home, switcher, plus (runtime-observations §1.1). Placement is a guess until screenshot S3. |
| D-4 | Auto-PiP opens on tab leave (tab switch, Space switch, or a split change that stops showing the tab) only. Window minimize, occlusion, and app hide do not open it in v1. | PP-3: occlusion is a separate engine flag; Chromium's `kAutoPictureInPictureOnWindowOccluded` is off by default (`media/base/media_switches.cc:374`). Q4. |
| D-5 | Auto-PiP needs an audible playing video, unless the site rule says `activatesWhenInaudible` (YouTube). | PP-11 (`activatesWhenInaudible` exists only to relax an audible rule). |
| D-6 | Open ships its own site-rule file with the same facts as Arc's `pipDisallowList` and `pipSiteConfigs`, in Open's own JSON format. | PP-11, PP-12. Facts are allowed; the file is not copied (AGENTS.md rule 1). |
| D-7 | Settings: one user-facing toggle (Advanced A-2, existing key `open.advanced.enablePictureInPictureOnLeave`, default ON). The per-host choice lives only in the PiP window menu. Two new app keys (§5). No second store. | PP-13; `docs/plans/settings-library.md` §2.1, D-5. |
| D-8 | Phase 1 uses Chromium's own PiP window (it works today: `docs/engine-spike.md`, "Picture in Picture | pass", a 384×216 `NativeWidgetMacFramelessNSWindow`). Phase 2 replaces it with Open's own window when engine request EM-4 lands. Rules, menu state, and the mini player do not change between phases. | PP-10: Arc hosts the engine's video view in its own window. Shipping behavior first keeps the UI work unblocked. |
| D-9 | Now Playing and media keys come from Chromium's stock system media controls. Open adds no MediaPlayer code of its own. | PP-22. |
| D-10 | Packages never import OpenEngine. Media logic lives in a new `OpenMedia` library over new `OpenWeb` protocols. Views live in `OpenSidebar` (mini players, row indicator) and `OpenFeatures` (PiP windows). Only `App/` joins them to the engine. | `docs/architecture.md`; app-shell D2. |
| D-11 | Every animation uses Core Animation and stops when it ends. Nothing ticks while media is paused or hidden. The marquee runs only while its source plays and its window is visible. | AGENTS.md performance budgets (idle CPU near zero). |

## 1. What Arc does (summary of the evidence)

Full rules with evidence: `docs/re/features-advanced.md` §8. In short:

- Row indicator: an animated speaker icon (slash and waves animate on a
  mute change), click to mute; a recording indicator for camera or
  microphone use; Mute/Unmute in the tab menu; "Mute all tabs" and
  "Unmute all tabs" in the command bar (features-core rule 10, PP-19,
  PP-21).
- Mini players: per window, a stack of cards. Each card has a title row
  (favicon, marquee title, back-to-PiP button, close on hover) and a
  controls row (previous, play/pause, next, volume with a drawer; or
  microphone and camera toggles for a recording source). Hover expands
  the stack (PP-14…PP-17).
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

Lead review decisions (2026-10-26): speaker images share a left anchor at
slot x + 2 pt on one fixed image-view frame in both states. Keep native
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
`C = 4 + stackHeight + 4`. The pager keeps its scroll offset from the
top when `C` changes. Guess (PP-20); fix with screenshot S3.

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

#### 4.2.3 Card layout (`MiniPlayerMetrics`)

| Element | Frame (card-relative) / value | Notes |
|---|---|---|
| Card | `[8, …, W − 16, 68]` (212 wide at 228), corner 10, fill `SidebarRole.miniPlayerFill` = `SidebarColors.itemBackground`, hover fill `SidebarColors.itemHoveredBackground` (fade `Motion.hoverFade`) | Insets and radius match row fills (measured, `SpaceListMetrics`). Fill guess. |
| Title row | `[0, 0, cardW, 36]` | |
| Favicon | `[9, 9, 18, 18]`, 16 pt ink, the tab's favicon (same provider as rows) | Lines up with row favicons (x 17 in the sidebar). |
| Title | x 35, baseline 23, right edge `cardW − 9` (minus 26 per visible right button), font `Typography.miniPlayerTitle` = 13 Medium (guess), color: the tab row title color | Marquee §4.2.5. On title-row hover the text cross-fades to "Back to Tab" (0.12 s; guess from `backToTabTitle`, PP-16). |
| Open Picture in Picture | `[cardW − 30, 6, 24, 24]` (left of Close when Close shows), SF `pip` 12 pt, tint `SidebarRole.mediaControlGlyph` | For a video source (`hasVideo`) with no open PiP. Arc names it a back-to-PiP button (`isBackToPIPButtonEnabled`, PP-15); guess: Open shows it for every video source, because the action is the same. Tooltip "Open Picture in Picture". |
| Close | `[cardW − 30, 6, 24, 24]`, SF `xmark` 14 pt | Width 0 when the pointer is outside the card, 24 inside (PP-16); animate width and opacity 0.15 s. Tooltip "Close Mini Player". |
| Controls row | `[0, 36, cardW, 32]`; buttons 24×24 at y 40 | |
| Play group (audio/video source) | Previous `[6]`, Play/Pause `[34]`, Next `[62]` (x positions); without Previous, Play/Pause starts at 6. SF `backward.end.fill`, `play.fill`/`pause.fill`, `forward.end.fill`, 14 pt | Previous/Next show only when the session offers them (PP-15 `hasPreviousTrack`/`hasNextTrack`). Tooltips "Previous Track", "Play"/"Pause", "Next Track". |
| Volume | `[cardW − 30, 40, 24, 24]`, SF `speaker.wave.2.fill` or `speaker.slash.fill` (muted), 14 pt | Tooltip "Adjust Tab Volume". Click toggles the volume drawer when the engine offers tab volume (EM-2); before that it toggles mute. |
| Recording source | Microphone `[6]` (`mic.fill` / `mic.slash.fill`), Camera `[34]` (`video.fill` / `video.slash.fill`), 14 pt; no play group, no volume | Shown only for actions the page offers (EM-1 `toggleMicrophone`, `toggleCamera`). Tooltips "Toggle Microphone", "Toggle Camera". |
| Glyph color | `SidebarRole.mediaControlGlyph` = `CommandBarColors.accessoryForeground` (black 0.50 / white 0.66) | Same values as Arc `PlaybackControlForeground` (design-tokens §1.8). Hover: plate `SidebarRole.buttonHover` 24×24 radius 6. Pressed: `SidebarRole.buttonPressed`. |
| Tooltips | Above the card (`placement: .above`), delay 0.45 s (`MiniPlayerMetrics.tooltipDelay`, from code, PP-6) | |
| Volume drawer | Adds a 28 pt row `[0, 68, cardW, 28]`: `speaker.wave.1.fill` 12 pt at `[9, 74, 16, 16]` (click toggles mute), slider track `[31, 80, cardW − 62, 4]` radius 2, track `SidebarColors.separator`, fill `SidebarRole.mediaControlGlyph`, knob 12 pt white circle with `SidebarColors.tabShadowSelected` shadow; `speaker.wave.3.fill` 12 pt at `[cardW − 25, 74, 16, 16]` (click sets 100 %) | Card height becomes 96. Drawer opens and closes with `Motion.miniPlayerResize` (0.2 s ease-in-out). Values 0…1 in steps of 0.05. Guess layout (PP-16 names the parts). |

Click targets: the title row and empty parts of the controls row select
the source tab ("Back to Tab": selects the tab in its window, switches
the window to the tab's Space, brings the window front). Buttons do not
select.

#### 4.2.4 Stack

| State | Layout |
|---|---|
| One source | One card. `stackHeight = 68` (96 with the drawer). |
| Several, pointer outside the container | The front card (most recent) is laid out as above. Card `i` (1, 2) sits behind it, offset up by `5·i` pt, inset `6·i` pt on each side, opacity `1 − 0.3·i`. Only its top 5 pt show. `stackHeight = 68 + 5·(n − 1)`. Guess from `MiniPlayerViewState{yOffset, widthOffset, opacity}` (PP-14). |
| Several, pointer over the container | Cards lay out top to bottom, oldest on top, front card at the bottom, 6 pt apart. `stackHeight = Σ heights + 6·(n − 1)`. Expand at once on pointer enter; collapse 0.3 s after pointer exit (Arc has an immediate and a debounced hover-off; values guessed). Spring `Motion.miniPlayerStack` (response 0.3, damping 1.0). The pager shrinks with it. |

#### 4.2.5 Marquee title

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

| State | Mini player |
|---|---|
| Playing | Pause glyph; marquee may run. |
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

| Change | Animation |
|---|---|
| First card appears | Container height 0 → `C` with `Motion.rowStructure` (0.22 s ease-in-out); card fades in 0.15 s, starting 0.05 s after the height starts. |
| Last card leaves | Card fades out 0.12 s, then height `C` → 0 in 0.22 s. |
| Card added or removed in a stack | Cards move with `Motion.miniPlayerStack`; the leaving card fades 0.12 s. |
| Play/pause glyph | `.replace` symbol transition (system). |
| Close button reveal | Width 0 ↔ 24 and opacity, 0.15 s. |
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
| Initial size | Chromium's rule (Arc's is unknown): fit the video's natural aspect inside a box of `visibleFrame.width / 5` × `visibleFrame.height / 5` of the screen that holds the source window, then clamp to the minimum and maximum below (`chrome/browser/ui/views/overlay/video_overlay_window_views.cc:463-505`). Our e2e run got 384×216 from it. |
| Initial position | Bottom-right of that screen's `visibleFrame`, inset 16 pt (guess). Later opens in the same app run reuse the last frame's origin and width. Not persisted. |
| Resize | `contentAspectRatio` = natural size; minimum 284×160 (Chromium `kMinWindowSize`, same file `:109`), maximum 50 % of `visibleFrame` in each dimension (guess). A natural-size change (`didChangePiPVideoResolution`) keeps the width and updates the height. |
| Size class | Compact below 300 pt wide, regular otherwise (guess; Arc has `PIPSizeClassKey`). |

#### 4.4.3 Overlay controls (`PiPOverlayView`)

All glyphs white; plates black. Values are guesses except where marked
"code" (PP-6) or "Arc" (PP-5…PP-8). Screenshots S1, S2 will fix them.

| Control | Frame / style | Shows when |
|---|---|---|
| Top scrim | Gradient black 0.5 → 0 over the top 56 pt | Controls visible |
| Bottom scrim | Gradient black 0 → 0.6 over the bottom 64 pt | Controls visible |
| Close | 28×28 circle (code) at `[p, p]`, `p` = 8 compact / 10 regular (code); SF `xmark` 12 pt Semibold; plate black 0.4, hover 0.55 with scale 1.08 (`GrowOnHover`) | Unless the site rule hides Close (Meet, PP-11). Tooltip "Close" (code). |
| Minimize | 28×28 at `[p + 32, p]`; SF `minus` 13 pt Bold | Always (Arc `minimizeEnabled`, default on). Tooltip "Minimize" (code). |
| Settings | 28×28 at `[w − p − 28, p]`; SF `ellipsis` 13 pt Bold; click opens the menu (§4.4.5) under the button | Always |
| Play/Pause | 48×48 centered; SF `play.fill`/`pause.fill` 26 pt (regular) or 22 pt (compact) | Unless `disablePlayButton` |
| Skip back / ahead 15 s | 40×40 at center ∓ 72 (regular) or ∓ 56 (compact); our own vector glyph (circular arrow with "15", 24 pt) | Unless `disableSkipButton`, or the duration is not finite (live). Tooltips "Skip back 15 seconds" / "Skip ahead 15 seconds" (Arc). |
| Previous / Next track | 32×32 at center ∓ 120, SF `backward.end.fill`/`forward.end.fill` 16 pt | Regular size only, when the session offers them |
| Back to Tab | Pill, height 24, horizontal padding 10, text "Back to Tab" 12 Semibold white, plate black 0.4 / hover 0.55 / pressed 0.7, at bottom-left `[p, h − p − 24 − 16]` | Always (Arc `BackToTabButton`, `PIPPillActionButtonStyle`) |
| Mute | 28×28 at `[w − p − 28, h − p − 28 − 16]`, SF `speaker.wave.2.fill` / `speaker.slash.fill` 13 pt | Always (Arc `toggleMute`) |
| Scrubber | §4.4.4, along the bottom inside `p` | Unless `disableScrubButton` or the duration is not finite |
| Skip Ad | Pill "Skip Ad", style as Back to Tab, bottom-right above Mute | When the session offers `skipAd` (Arc `skipAdButtonVisible`) |
| Meeting row | 32×32 circles centered at the bottom, 12 pt apart: microphone, camera, hang up (plate `#F53714`, SF `phone.down.fill`) | When the PiP reports meeting controls; then the play group hides (Arc `showMeetingControls`) |

Visibility: fade in 0.15 s when the pointer enters or moves; fade out
0.3 s when the pointer leaves, or 2.0 s after the last move while inside
(Arc `movedRecently`, `sustainedMovement`; times guessed). While a menu
is open or the scrubber drags, controls stay. Keyboard focus or
VoiceOver focus inside the window keeps them visible.

#### 4.4.4 Scrubber (`PiPScrubberView`)

- Bar: `[p, h − p − 4, w − 2p, 4]`, radius 2, track white 0.3, fill
  white 0.9; 6 pt tall while hovered. Hit area 20 pt tall (Arc
  `draggableHeight`).
- Drag: horizontal movement seeks. Factor `m = min(8, 1 + floor(max(0,
  −dy) / 40))` where `dy` is the vertical distance from the drag start
  (up is negative). Time change = `dx / barWidth · duration / m`.
- Label 11 pt Medium white 0.85, centered 8 pt above the bar while
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
| Top bar | Height 28 (guess), fill `PiPRole.documentTopBar` (`#212123`, both appearances, design-tokens §1.8), 1 px hairline `PiPRole.documentHairline` (white 0.20) at the bottom. Left: the opener's favicon 16 pt at x 10. Then the opener's host, 12 Medium white 0.85. Right: settings `ellipsis` (menu: "Keep Window on Top", separator, "Picture-in-picture on <host>:" header) and close `xmark`, 20×20 each, 6 pt apart, 8 pt from the edge. |
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
| Volume slider | Slider "Tab Volume", value "NN %", increment 10 %. |
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
existing `today:N`/`pinned:N` syntax), `--media-hover card:N|title:N|stack`,
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

Comparison: once the user provides screenshots S3–S8 (§11), add
`sidebar-render compare` runs for them with the `docs/design.md` §8
targets (layout ≤ 1 pt, fill and text ΔE00 ≤ 2) and update the guessed
tokens.

### 8.3 `features-render pip`

```text
features-render pip --out FILE.png [--size 384x216] [--scale 1|2] [--state playing|paused|ended]
                    [--controls visible|hidden] [--meeting] [--site twitch|meet|youtube|none]
                    [--drag-precision N] [--menu] [--document --top-bar-title TEXT]
```

The fake video view paints a gradient with the size written in it.

| ID | Check |
|---|---|
| PP1 | Compact (284 wide) and regular (384 wide): corner buttons 28×28 at padding 8 and 10. |
| PP2 | Site rule twitch hides play, skip, and scrubber; meet hides Close. |
| PP3 | Controls fade in on a synthesized pointer move and out 2.0 s later; stay while the menu is open. |
| PP4 | Scrubber: a drag up 80 pt shows "Seeking at 3× precision"; a flat drag shows "Drag upwards to seek precisely"; the fake host gets `scrubTo` during and `seekTo` at the end, and play resumes. |
| PP5 | Menu items and order equal §4.4.5 for a URL with a host, and items 1, 2, 4 only for one without; incognito "Turn off" does not write `UserDefaults`. |
| PP6 | Resize keeps the aspect ratio; the window never gets smaller than 284×160. |
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

## 9. Implementation order (small PRs; each step: files, then acceptance)

Every PR: merge `origin/main`, run `tools/verify-all.sh`, paste the
table (AGENTS.md rule 10). One library target per PR where the step says
so.

| Step | Work | Files | Acceptance |
|---|---|---|---|
| 0 | Screenshots S1–S12 from the user (§11), through the lead. Runs in parallel; Steps 1–5 do not wait. | — | Lead files them under `.re/runtime/` (git-ignored) and adds measured values to `docs/re/interaction-states.md`. |
| 1 | `OpenMedia` target: store, policy, session, site rules, settings; `OpenWeb` media types; `OpenSleep` `mediaControls` field; `openkit media-demo`; the two new defaults in `SettingsDefaults` (registry rows are already in settings-library §2.1). | §3.1 rows for `OpenMedia`, `OpenWeb`, `OpenSleep`, `OpenSettings`, `openkit`; `Package.swift`; `tools/verify-all.sh` | `media-demo` all PASS; `sleep-demo` still 105/105; `settings-preview` still PASS; `verify-all.sh` PASS. |
| 2 | Tokens and row indicator: `MiniPlayerMetrics`, `PiPMetrics`, `RowMediaMetrics`, roles, fonts, motion, glyphs; speaker transition, tooltip, recording dot. | `OpenDesign/*` (listed), `OpenSidebar/SidebarRows.swift`, `sidebar-render` RI checks | RI1–RI4 PASS; existing `sidebar-render check` PASS; bench p95 unchanged. |
| 3 | Mini player stack in the sidebar with fake hosts. | `OpenSidebar/MediaControlsView.swift`, `MiniPlayerCardView.swift`, `MarqueeLabel.swift`, `SidebarView.swift`, `SidebarContext.swift`, `SidebarIntent.swift`, `ModelSidebarActions.swift`; `sidebar-render` media scenes | MC1–MC10 PASS; renders attached to the PR. |
| 4 | Phase 2 PiP window and Document PiP window with a fake video view; menu builder. | `OpenFeatures/PictureInPictureWindowController.swift`, `PiPOverlayView.swift`, `PiPScrubberView.swift`, `PiPMenuBuilder.swift`, `DocumentPiPWindowController.swift`; `features-render` pip | PP1–PP8 PASS. |
| 5 | [ENGINE] EM-1a, EM-5 interim, EM-8 (OpenEngine only, stock-CEF compatible). | `Engine/OpenEngine/src/OEApp.mm`, `OEWebContent.mm`, `include/OpenEngine/OEWebContent.h`; `docs/engine-api.md` | `--only features` unchanged; a `media` dump of `audio.html` shows playback and metadata. |
| 6 | [APP, after app-shell B and G] `MediaCoordinator`, `EngineBridge` conformance, event map §7.2, leave events, auto-PiP phase 1, mini player with interim actions, Mute All/Unmute All, sleep feed, automation commands, `--only media`. | `App/Media/MediaCoordinator.swift`, `App/EngineBridge.swift`, `App/Automation/AutomationController.swift`, `docs/automation.md`, `tools/e2e/*` | E-M1, E-M3, E-M5…E-M12, E-M14, E-M15 PASS (phase 1 limits stated); E-M2, E-M4, E-M13 report `blocked`. |
| 7 | [ENGINE fork] EM-1b, EM-2, EM-3 (P6), EM-5 fork path. | `Engine/fork/patches/cef/04xx-*`, overlay `cef/include/cef_media_session.h`, OpenEngine | Engine e2e for each; `docs/engine-patches.md` rows. |
| 8 | [APP] Switch to `OEMediaSession`: previous/next, volume drawer, recording cards. | `App/Media/MediaCoordinator.swift`, `App/EngineBridge.swift` | E-M2, E-M4 PASS; MC checks still PASS. |
| 9 | [ENGINE fork] EM-4. | fork overlay + OpenEngine | Engine check: `videoView` shows frames in a plain test window. |
| 10 | [APP] Phase 2: Open's PiP window replaces Chromium's (`shellHostsPictureInPicture = YES`). | `App/Media/MediaCoordinator.swift`, `App/EngineBridge.swift` | E-M5…E-M10, E-M14 PASS on Open's window; PP checks unchanged. |
| 11 | [ENGINE + APP] EM-6, EM-7; Document PiP and the Meet path. | fork + OpenEngine; App coordinator | E-M13 PASS; `meet-like.html` gets a Chromium auto PiP after a leave. |
| 12 | Polish against screenshots: compare renders, fix tokens, motion. | `OpenDesign/*` | Compare targets met or each miss named with numbers. |

## 10. Risks and open questions (lead decisions)

| # | Question | Recommendation |
|---|---|---|
| Q1 | Mini player placement (above the bottom bar) is a guess (PP-20). | Build it there (D-3); confirm with S3. |
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
| Q15 | The marquee flag. | Ship on; no setting (Arc's flag is remote config). |
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

## Appendix — Lead decisions (2026-10-25)

- Approved as the media controls + Picture in Picture plan. Steps 1–5 start now: they need no App window. Step 6 and later App steps wait for app-shell Step B (#52) and Step G (sleep).
- Q1 Mini players sit above the bottom bar. This is provisional until screenshot S3, then follow Arc.
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
- Q15 The scrolling title is on, with no setting.
- Q16 Engine queue: Step 5 (EM-1a, EM-5 interim, EM-8) is OpenEngine-only and goes to the Steps 1–5 implementer, not the engine lead. The fork requests EM-1b, EM-2, EM-3 (P6), and EM-5 (fork path) queue after P2. EM-6 and EM-7 follow them. EM-4 (own PiP window) queues after the ad-block and tab-sleep patch series.
- Q17 The PiP menu check mark shows the current state.
- Screenshots S1–S12: the lead asks the user in one batch with the other plans' screenshot needs. Step 12 waits for them.
