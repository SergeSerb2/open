# Little Open App — routing Steps 6 and 7

Implementation branch: `s9/little-open-app`. The branch starts from the Little
Open library (#173), includes external intake (#171), and merges
`s9/peek-app` for its OpenEngine navigation policy. History #172 is on main
and is integrated through the existing `EngineWebContentHost` recorder.
No Chromium tree or distribution changes are part of this work.

## Behavior

One App coordinator owns the sessions. Each page has a standalone Alloy host
made by `EngineWebContentHostFactory`, outside BrowserModel and the sidebar
strip. Close and Profile switch destroy the host. Moving to Today creates or
focuses a standard window and reloads through that window's factory. This is
the same accepted Alloy-to-sidebar boundary used for Chrome-style Peek.

Global and menu entry points share key-down timestamps. The Carbon callback
passes `GetEventTime`; the menu twin passes the initiating NSEvent timestamp.
Two deliveries within the library's 0.05 s guard create one blank window;
a distinct press creates another. The real global shortcut from another app
remains a user hand check.

The Window menu lists sessions in activity order. Its runtime Show/Close All
commands also appear in the Dock menu. Their registry definitions use the
existing code-only category; the static RE menu and its allowlist stay unchanged.

The App's existing ExpirySweeper takes the minimum Today/Little Open deadline
and calls both sweeps. Coordinator activity and Profile policy changes rearm
that scheduler. Little Open writes `littleOpen:` archive locations. Today
education still uses only the Today controller's report.

## Native verification in progress

M5 Pro, built-in 2x panel, recorded engine `f34400e7…`, Debug App, Chrome-style
sidebar with Alloy Little Open pages. Every on-screen run takes
`/usr/bin/lockf /tmp/open-onscreen-e2e.lock`. Builds use `heavy.sh` and export
`OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main`.

The initial native run exposed a late Alloy focus request taking focus from
the blank field. The native Little Open window now keeps renderer focus behind
its open command bar. A subsequent run passed B4, B9, same-press, dedupe,
sweeper, visibility, menus, Profile confirmation/cancel, and Cmd+O with no main
window. It stopped at the native Space picker's automation readiness condition.
The full suite, regression matrix and final verification are still pending.

B10 uses the real S2 19/0011 window capture kept in the shared `.re/` tree.
The page, Profile name, host text and controls are excluded from color samples.
Measured element frames match §9.3. The pill sample is sRGB `#050627` in both
captures, ΔE00 0. The bar and capsule samples stay in the specified ranges.
The reference is private and is never committed. The native Open PNG contains
synthetic fixture data only.

## Remaining acceptance

- `littleopen` three consecutive complete passes.
- `routing`, `peek`, `window`, `sidebar`, `sidebar-completion`, `commandbar`,
  `toolbar`, `numbering`, and `sleep`, with only TANDEM §4 machine exceptions.
- `features-render check` and full final-head `verify-all`.
- Deliberate break/revert proofs for single-timer, visibility and same-press.
- Final checklist and status/plan updates.

## User hand checks

- Press a real ⌥⌘N from another app.
- Click a real external HTTP(S) link in Mail.
- B2: accept and decline the real Set as Default Browser system prompt on a
  user-selected build, then check both HTTP and HTTPS handlers.

## App choices and limits

- Guess: a first external delivery before any App input is a cold delivery.
  `open(1)` can deliver its URL after AppKit reports a default launch. The App
  handles that clock-free case as well as queued URLs and the native launch
  notification. The first real input or earlier external destination ends it.
- The final suite saves and restores `open.library.lastSection` as well as the
  six Little Open/education keys. An early development run omitted that Library
  key; its earlier value was not retained.
- A focused release build was terminated at load1 201 to reduce machine pressure.
  That attempt is incomplete. It does not count as a completed verify-all run.
