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
