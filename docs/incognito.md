# Private windows (Section 10)

Each private window owns an in-memory `BrowserModel`, synthetic Profile, one Incognito Space, and an undo manager. It never enters `app.model.windows` and has no SnapshotStore or archive sink. Factories use their injected model for tabs, commands, suggestions, and engine mirrors. Private pages skip persisted history, favicon reports, auto-archive, sleep, session restore, and downloads history. Downloads can still save a file.

`IncognitoSessions` shares one context between private windows of the same requested parent. The last close releases it. The single engine seam is `IncognitoContextProvider.makeContext(parent:)`; today it returns Default OTR and retains the requested parent. Actual parent ancestry and extension behavior wait for 0701. No per-parent engine result is claimed here.

File > New Incognito Window, Shift-Command-N, the command bar, and Open Link in Incognito Window use the same creation path. Command-T/L, Peek, and Split remain private. Option-Command-click opens a tab in the same private window. Command-N opens a normal window. Private unload handlers do not participate in the quit prompt.

The private sidebar follows lead guesses S10-P1–P5: fixed #26232B, forced dark appearance, eyeglasses/title, no Favorites/Pinned/Space switcher/Library, and the measured white 15% placeholder fill. Capture steps for the remaining reference facts are in `followups.md`.

## Acceptance

Native M5 runs use main's engine distribution `af4b3cc3ad1b42439b229d79c8f7a869b13b0d3165733fba6c023e202340d1a5`. The first harness run found three assertion/lifecycle issues; corrected acceptance is reported separately.

| Check | Result |
|---|---|
| `heavy.sh tools/build.sh Debug` | PASS |
| `heavy.sh swift build -c release --package-path Packages/OpenKit` | PASS |
| Real-App `incognito` | 25 PASS, 0 FAIL, 0 interruptions; owned processes and windows cleaned |
| Cookie lifetime | Normal/private isolation in both directions; two private windows share; one close retains; final close resets |
| No Open records | `browser.json` SHA-256, all Open SQLite table row counts, capture/thumbnail inventory, normal model counts, history writes, and download history unchanged after private navigations, close, and download |
| Native 1x light/dark | PASS; real window captures, with empty sidebar pixels within 2 RGB levels of #26232B |
| Source fault: normal model | PASS: `no_snapshot_history_change FAIL`, exit 1, cleanup PASS; [receipt](engine-spike/incognito/negative-model.json) |
| Source fault: disk context | PASS: `cookie_normal_absent_private FAIL`, exit 1, cleanup PASS; [receipt](engine-spike/incognito/negative-disk.json) |
| Required regressions / full verify | Pending |

The suite resets each preference key it uses and restores the persistent values in `finally`. HTTP fixtures, data/cache directories, and ports belong to the run. Keys use `route=app`; Option-Command-click uses engine input dispatch. The quit row checks an actual process exit before harness cleanup.

## Break-and-revert procedure

The negative runs used one temporary Debug build. With `OPEN_INCOGNITO_NEGATIVE=model`, its private factory selected `app.model` instead of the injected private model. With `OPEN_INCOGNITO_NEGATIVE=disk`, the provider returned `OEEngine.shared.defaultContext` instead of `makeEphemeralContext()`. Each run still opened the real window through its native File menu and exercised the real model or cookie path. Both runs had zero interruptions and clean owned-process shutdown.

Each mode ran separately under `/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --config Debug --only incognito`. The modes only select a focused harness flow in committed code; the faulty Swift assignments were restored and are absent from production source. A positive Debug rebuild and full acceptance follow the revert.

## Deferred evidence

- After 0701: per-parent OTR ancestry, cross-parent cookie isolation, allowed spanning/split extensions and native session teardown. Replace only the provider body, then run those engine-dependent rows.
- Section 12: fill SiteControlContext.isIncognito from factory.isIncognito; Boosts disabled in private windows (Arc fact: Boosts can't be installed or used in Incognito Mode)
- Native 2x captures: M5 exposes only the 1x AW2726DM; M1 is held. Lead ruling 16:28 defers these captures. On an authorized native 2x display, check `/tmp/open-onscreen-priority`, then run:

```sh
export OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main
OPEN_INCOGNITO_CAPTURE_SCALE=2 /usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py --config Debug --only incognito
```

The command writes `docs/engine-spike/incognito/private-light-2x.png` and `private-dark-2x.png`. It requires a physical 2x screen; it never upscales a 1x image.
