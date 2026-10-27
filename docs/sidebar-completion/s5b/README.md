# S5b: fixed hover-preview delay

Open uses `HoverPreviewMetrics.armDelay = 0.5` seconds. This is an Open
choice, not a calibrated Arc value: the accepted plan cites one sample near
0.42 seconds. The tracker no longer reads `open.general.previewsDelaySeconds`.
Settings no longer registers that key or offers its Delay row. Stored values
stay untouched. The existing `previewsOnHover` source seeding is unchanged.

HP1 seeds `7.0` before the pinned-row flow and `0` before the folder-row flow.
Both flows assert exact equality to `armDelay` and bound the configured
deadline between the hover call's start/end uptime plus `armDelay`. These
assertions inspect the scheduled configuration; they add no delivery-time
check. The existing single wall-clock attempt family stays unchanged.

The [negative proof](negative-proof.txt) records both new assertions failing
with the old key-reading/clamping lines restored. Restoring the fix gives
`checks: 561 passed, 0 failed`. Both proof builds have zero warnings.

The [focused table](focused-summary.txt) includes `settings-preview`,
`profiles`, `sidebar-render`, `sidebar-compare`, and `media-demo`. Its only
failure is the known M1 sidebar color baseline: static-inactive,
selected-pinned, and yellow. Branch and unmodified-main tables are
byte-identical for all 13 states, with zero color drift. Master/source
gating, row-motion not rearming, and MC8/MC9 remain in the real sidebar flow.

Both `docs/settings/checks.txt` and `docs/first-run/checks.txt` are the exact
same output through `SUMMARY 37 checks passed, 0 failed` from this focused
run's actual `settings-preview check`. They contain no delay default. The
same acceptance run rendered the two updated Settings gallery PNGs; their
SHA-256 entries were recomputed from those generated files.

## Reproduce

From the repository root, use the shared machine locks. Run each command
separately; do not build during an on-screen invocation.

```sh
/usr/bin/lockf /tmp/open-m1-validation.lock ~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only settings-preview,profiles,sidebar-render,sidebar-compare,media-demo --keep-logs
/usr/bin/lockf /tmp/open-m1-validation.lock ~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh Debug
/usr/bin/lockf /tmp/open-m1-validation.lock /usr/bin/lockf /tmp/open-onscreen-e2e.lock python3 tools/e2e/settings_previews.py --out /tmp/open-previews-flow-unique
/usr/bin/lockf /tmp/open-m1-validation.lock /usr/bin/lockf /tmp/open-onscreen-e2e.lock python3 tools/e2e/settings_previews.py --out /tmp/open-previews-failure-unique --force-failure
```

The failure invocation must exit 1 with the `FORCED: early failure` message,
`cleanup: PASS`, and no remaining processes or windows in `result.json`.
An earlier setup failure is not this proof. The driver uses the existing
`menu-perform`, `mouse`, `windows`, `snapshot`, `dismiss`, and `quit` commands.
It adds no App automation case and sends no desktop input.

Each driver run clones only our built bundle and gives it a unique bundle
ID for its preferences domain. It uses a fresh data root, cache, profile,
and Unix socket; TCP remote debugging stays disabled. It closes sheets in
`finally`, terminates its own app, checks window-server ownership, and removes
the run's files and preferences. Each output directory must be new.

## App build limitation

The real Debug App build exits 0. Its existing source/configuration emits
Xcode headermap/strip/App Intents diagnostics and six `ExistentialAny`
warnings in `ActivationTrace`, `AppDelegate`, `EngineWebContentHostFactory`,
and `AutomationController`. Those files and `project.yml` are byte-identical
to `origin/main` at `7e689d5`. S5b introduces no App change. The package builds
and verification gate are warning-free; the App build does not satisfy a
literal zero-warning requirement. The parent must resolve that separate
baseline. Full local warning evidence is in `.re/s5b/app-existing-warnings.txt`
and `build/xcodebuild-Debug.log`.

## Real App acceptance

[Normal flow](app-flow.json): PASS. General → Previews opens the specific
480×320 `SheetPresentationWindow`; its master and two source switches write
to the run's isolated preferences. A disabled source refuses the click;
Done closes the sheet. The previously stored delay remains exactly 7.0.
Both [rest](previews-rest@2x.png) and [hover](previews-hover@2x.png) snapshots
are real native 2× window-server captures. The [comparison](comparison.md)
uses the supplied S2 02/0050 read-only and records the accepted Open differences.

[Forced-failure flow](app-forced-failure.json): expected exit 1 at the
explicit `FORCED: early failure while the real Previews sheet is open`.
The `finally` path clicks Done, cancels unexpected native dialogs, and quits
the exact suite-owned App. Normal and failure runs both report cleanup PASS,
zero remaining windows, zero remaining processes, removed roots, and no
forced App termination. No App automation or desktop input was added.

## Review coverage

The parent ran Muse code review 1 on `b9105ab`: production code was correct;
the Settings half needed an automated guard against a restored dead control
or default. The parent added that guard in `settings-preview/main.swift`
and `tools/verification/check.py`. The native rendered sheet must contain
the expected master/source/Done AX labels, no Delay label/value, and no
popup. The real `dump-keys` output must omit the removed default. Missing AX
content fails closed. The renderer now closes its window in `defer` too.

On this M1, SwiftUI returned an empty AX tree until the renderer enabled
its own `AXEnhancedUserInterface` state. That state is scoped to the Previews
render and restored in `defer`. It changes no system accessibility setting
and adds no timing check. The unsuccessful navigation/legacy-tree probes
were removed. No S5b production or App-driver code changed after `b9105ab`; the branch also merged `origin/main`.

The parent ran local Opus design review 1: PASS, no new material visual
defect and no weekly-limit error. The two comparison wording corrections
are included: rest and Done-hover snapshots are identical (the existing
button style changes on press), and the different appearances support no
color-fidelity claim. Existing Settings-wide visual differences remain
baseline backlog. The supplied capture dependency is resolved.

Local parent reports: `/Users/m1-dev/.t3/projects/open/.re/m1-s5b-review-r1.md`
and `/Users/m1-dev/.t3/projects/open/.re/m1-s5b-opus-design-r1.md`.

The initial [pre-review full run](pre-review-full-summary.txt) found three
black command-bar 2× renders in addition to the known M1 baselines. This
was not relabeled as a baseline. A real diagnostic run of unmodified main
and this branch passed 78/78 on each ([receipt](commandbar-diagnostic.txt)).
The final full gate must also pass commandbar-render. No command-bar code
or tolerance changed.

## Settings guard break-and-revert proofs

The [UI-only proof](ui-negative-proof.txt) restores the old General view model
and Delay popup while leaving the fixed tracker and removed default intact.
The actual renderer exits 1: `FAIL Previews sheet restored the removed Delay control`.

The [default-only proof](default-negative-proof.txt) restores only the registry
entry. The actual Settings gate exits 1: `FAIL: removed preview delay default was registered`.
It first renders the real three-switch sheet successfully, so this failure
is independent of the UI guard. Both proofs restore their source in `finally`
and rebuild the real renderer without warnings. The positive
[guard-focused run](guard-focused-summary.txt) passed at both scales; its
[control receipts](previews-controls.txt) come from the real AX walk.
