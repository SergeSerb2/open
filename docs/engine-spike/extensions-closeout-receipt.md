# Extensions Section 6 closeout

2026-11-06, M5 Pro. Branch `s6/closeout-docs`.
[Closeout PR](https://github.com/SergeSerb2/open/pull/190).
Main contains [#175](https://github.com/SergeSerb2/open/pull/175),
[#177](https://github.com/SergeSerb2/open/pull/177),
[#179](https://github.com/SergeSerb2/open/pull/179),
[#184](https://github.com/SergeSerb2/open/pull/184), and
[#189](https://github.com/SergeSerb2/open/pull/189).
The plan's Step 1–8 verification notes distinguish those saved PR receipts
from the new checks below.

## What X-27 exercises

The suite loads a per-run copy of the real action-probe fixture named
`Action Probe`, as `extensions-e2` does. Bitwarden's default Cmd+Shift+L
conflict with View Library is temporarily disabled so this row can require
exactly the requested single notice; its enabled state is restored afterward
and in failure cleanup. No installed user extension is changed: the App has
its own disposable data/cache/profile roots.

`ext-shortcuts` finds the actual Shortcuts pane's native More shortcut actions
menu and performs its enabled `Extension Shortcuts` item. It reads the native
notice labels from that same visible pane. `record` / `reset` call the real
`ShortcutsViewModel`, which saves `State/keybindings.json` through
`KeyBindingStore` and calls `AppSettingsActions.keyBindingsDidChange`.
There is no synthetic conflict provider or alternate key router.

The first run found a real Settings singleton defect: `openURL` always opened
a new tab, bypassing the Extensions menu's singleton dispatch. Both calls
opened different Today tabs. The fix routes management/shortcuts URLs through
that existing command path after selecting the Settings Profile's Space.
The initial failure is retained in `.re/extensions-closeout/ui-initial.json`.

| X-27 row | Required evidence |
|---|---|
| `X27_shortcuts_menu_singleton` | Actual menu order includes Extension Shortcuts after Shortcut Help; two invocations select the same Today tab, with another tab selected between them; only one shortcuts tab exists. |
| `X27_binding_input_bounds` | One ASCII key and four modifiers save through the live store; empty/two-byte keys and five modifiers are refused without changing the file. |
| `X27_user_binding_conflict` | Saved New Tab override is Cmd+Shift+U with browser priority. Exact rendered notice: `Action Probe: ⇧⌘U is used by New Tab…, so it is off.` `probe-named` is dropped for `new-tab`. The app-route key opens mode `newTab`; the extension count stays unchanged. |
| `X27_restored_extension_command` | Reset removes the override and native notice; the table no longer drops the command. The next app-route Cmd+Shift+U increments `probe-named` once and opens no command bar. |

Bindings and shared defaults (`open.settings.lastPane`,
`open.shortcuts.defaultPriority`, toolbar and sound settings) reset at start
and restore in `finally`. Key events go through `NSApplication.sendEvent`;
no system mouse/keyboard input is used.

## Negative proof

The proof changes only `ExtensionShortcutTable.rebuild`:

```diff
- let conflict = reserved[key]
+ let conflict: String? = nil // Deliberate X-27 negative proof.
```

The rebuilt real Release App reports `X27_user_binding_conflict FAIL`:
no notice, `dropped=false`, and no conflicting Open command ID. The existing
`X12_default_conflict` also fails. The menu-singleton and restored-extension
rows still pass. This localizes the proof to conflict filtering.
The script restores the exact source bytes in `finally`, rebuilds Release
and Debug, then reruns the real suite.

Raw proof files stay in `.re/extensions-closeout/`: `ui-negative.json`,
`ui-restored.json`, `negative-manifest.json`,
`conflict-filter-negative.patch`, and the corresponding logs. The manifest
records matching before/restored SHA-256 values, both cleanup results and
interruption counts. No deliberate fault remains in the branch.

## Verification commands

App builds use `OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main`
and `OPEN_AUTOMATION=1`, each through `heavy.sh tools/build.sh Debug|Release`.
The engine framework SHA-256 is
`3f45b07b885e03b6aecc461c6b6bff7612814a2ad23b6cf37b2b142d828f0738`.
The first setup build accidentally fetched the default shared distribution
and failed on missing `cef_extension_manager.h`; passing the required main
engine-root environment to the build fixed it. No engine source/build changed.

The real-App command is:

```sh
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/engine_e2e.py \
  --config Release --style chrome --only extensions-ui \
  --extensions "$HOME/.t3/projects/open/.re/ext/unpacked" \
  --engine-sha256 3f45b07b885e03b6aecc461c6b6bff7612814a2ad23b6cf37b2b142d828f0738
```

Every launch uses `--use-mock-keychain`. Suites respect the priority flag,
run one per kept on-screen lock, and never overlap this child's builds.
Builds run in separate sessions through the shared heavy slots. No debugger,
computer use, Arc launch, unit test, baseline or threshold change is involved.

Final command results and the full verification summary are in the PR body;
raw logs stay in `.re/extensions-closeout/`. Reference captures S-1…S-12 and
C1 remain user-owned. X-13 stays BLOCKED on Section 12's SCC presenter;
X-19 execution stays BLOCKED on Section 9's own Chrome-style Little Open page.
Global OS command delivery, packed permission-increase updates, Section 10's
per-Profile UI gaps and Section 11's page-menu Manage hook remain separate
follow-ups. `chrome.sidePanel` remains outside v1 (Q6).

## Closeout results

| Gate | Result | Receipt |
|---|---|---|
| Release `extensions-ui` | 46 PASS, 0 FAIL, 2 BLOCKED (X-13 / X-19 execution only) | `ui-final.json` / `ui-final.log` |
| X-27 negative / restored | Required conflict FAIL, then all core X-27 PASS; identical restored source hash | `negative-manifest.json`, `ui-negative.json`, `ui-restored.json` |
| Debug / Release App | BUILD SUCCEEDED | `build-debug-final.log`, `build-release-restored.log` |
| Targeted verification | Build + settings-preview + commands-dump + extensions-render PASS | `verify-targeted/summary.txt` |
| 1x window pixel rows | All four PASS; comparison worst 1 pt / ΔE00 1.55 | `window-rerun.json` |
| Full verification before PR | 23/23 PASS, no SKIP | `verify-prepr-clean/summary.txt` |
| Owned cleanup | PASS, zero interruptions and remaining processes/windows in UI / window receipts | JSON cleanup and interrupted-attempt records |

Receipt paths in this table are relative to `.re/extensions-closeout/`.
The full pre-PR pass used head `06f6c25e`, load1 5.72→5.96.
The final-head summary and SHA are recorded in PR #190 after committing its
links; App and suite source did not change after the passing UI receipt.
Debug window timing rows were SKIP and the inherited card-material row was
DEFERRED; those do not count as Release performance or material acceptance.

Keep the earlier failures visible: the first full run had two FP expanded-folder
hover eligibility failures in `sidebar-render` (622 PASS / 2 FAIL). The
independently built unchanged-main control and the branch rerun each passed
624/624; the fresh full run also passed. The OpenKit tree is identical on
both refs (`e983e5ed538d672fc2cb6eb3f7a6df858dc89dc0`). This remains an unresolved
transient observation, not a claimed reproducible main failure. No shared
sidebar code, baseline, tolerance or allowlist changed. The initial window
run stopped before comparison because the Release sidebar-render binary was
absent; after the CLI build, its complete rerun passed. All raw attempts stay
in the receipt directory.
