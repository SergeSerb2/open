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

## Native verification

M5 Pro, 1x AW2726DM main display, recorded engine `f34400e7…`, Debug App,
Chrome-style sidebar with Alloy Little Open pages. Every on-screen run takes
`/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock`. Builds use `heavy.sh` and export
`OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main`.

The first complete run passed all 30 Little Open rows, with no interrupted
attempts and successful owned-process cleanup. The final three-run streak and
regression matrix run after merging main `8db4ac86` (including #171, #172,
#173 and #174). The Peek navigation policy is from merged branch
`s9/peek-app` at `09f2e1a0`; its PR was not on main when integrated.

B10 uses the real S2 19/0011 window capture kept in the shared `.re/` tree.
The page, Profile name, host text and controls are excluded from color samples.
Measured element frames match §9.3. The pill sample is sRGB `#050627` in both
captures, ΔE00 0. The bar and capsule samples stay in the specified ranges.
The reference is private and is never committed. The native Open PNG contains
synthetic fixture data only.

## Negative proofs

One real-App run deliberately removed the same-press comparison, added a
retained 60-second coordinator Timer, omitted the Little Open visibility feed,
changed the screen inset to 25 pt and changed the pill to red. The checks failed:

| Deliberate break | Observed failure |
|---|---|
| Same-press comparison | Before 1 session; duplicate press 3; next press 4. |
| 60-second poll | Native timer counts: empty 1, Never 1, expiring 2; scheduler count 1. Both timer rows fail. |
| Visibility feed | Visible page reports `visibilityProtected: false`; visibility row fails. |
| Frame inset | All three B9 frame rows fail. |
| Pill color | B10 fails at ΔE00 54.497 (limit 2). |

The same run threw immediately after the exact Profile alert reported visible.
The suite's `finally` closed that alert. Cleanup passed: zero owned windows and
no remaining owned processes. Source files were restored byte for byte from
saved SHA-256 manifests before the accepted build. The temporary throw was
removed as well. No threshold, baseline or allowlist changed.

## Acceptance receipts

The final suite matrix and verify-all receipt are recorded below after completion.

## User hand checks

- Press a real ⌥⌘N from another app.
- Click a real external HTTP(S) link in Mail.
- B2: accept and decline the real Set as Default Browser system prompt on a
  user-selected build, then check both HTTP and HTTPS handlers.

## App choices and limits

- Lead decision: restore all saved windows. Explicitly tag only a freshly
  created launch fallback, clear the tag on input/navigation, and consume it
  at the first external destination. Only an unused fallback closes for Little
  Open. It is removed from the snapshot as well. B6 checks two restored windows,
  a windowless snapshot, input protection and navigation protection. No clock
  or delay classifies the launch.
- The final suite saves and restores `open.library.lastSection` as well as the
  six Little Open/education keys. An early development run omitted that Library
  key; its earlier value was not retained.
- A focused release build was terminated at load1 201 to reduce machine pressure.
  That attempt is incomplete. It does not count as a completed verify-all run.
