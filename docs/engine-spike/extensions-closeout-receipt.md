# Extensions Section 6 closeout

2026-11-06, M5 Pro. Branch `s6/closeout-docs`.
[Closeout PR](https://github.com/SergeSerb2/open/pull/new/s6/closeout-docs).
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
  --extensions /Users/serge/.t3/projects/open/.re/ext/unpacked \
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
