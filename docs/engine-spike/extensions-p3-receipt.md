# Extension engine P3 receipt

2026-11-05, M5 Pro, macOS built-in 2× display. Branch `s6/engine-p3`.
The engine root is `~/Developer/open-engine-s8`; the main distribution view
`~/Developer/open-engine-s8-main` was not changed.

## Engine provenance

Before edits, `OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8
Engine/fork/scripts/engine-status` reported 8 PASS, 0 FAIL, 0 WARN:
18 active Open patches, 44 matching overlay files, 23 exported symbols,
117/117 CEF patches. The framework SHA-256 matched main:
`f34400e71412d87a0b268fcd5658a8563cca34f600c8dd17b534a63e76aa7939`.

After P3, the same status command reports 8 PASS, 0 FAIL, 0 WARN:
20 active Open patches, 47 matching overlay files, 24 exported symbols,
117/117 CEF patches. New distribution framework SHA-256:
`7b49090502568f8189aa0e94f7cf23344beec5bed537136eff5f7fce573ad35a`.
The signed App framework and distribution have the same normalized code
SHA-256 `7979934c0d84f4d9fedb3859826d0c7c65919834fc904ec2aee00a0b4e4dd8f2`.

Active series in that root (P3 adds Chromium/0305 and CEF/0305):

```text
chromium/0301-open-headless-browser-window.patch
chromium/0302-open-hidden-browser-ui.patch
chromium/0303-open-hosted-tab-lifecycle.patch
chromium/0304-open-hidden-browser-no-tab-groups.patch
chromium/0305-open-extension-prompts.patch
chromium/0401-open-media-session.patch
chromium/0402-open-video-pip-window.patch
chromium/0501-page-history-swipe-hooks.patch
chromium/0504-page-notification-click.patch
cef/0101-mem-visibility.patch
cef/0104-mem-navigation-history.patch
cef/0105-mem-no-renderer-create.patch
cef/0302-open-hosted-tabs.patch
cef/0303-open-context-menu-submenu-commands.patch
cef/0304-open-extension-popups.patch
cef/0305-open-webstore-downloads.patch
cef/0310-open-adblock-service-owner.patch
cef/0314-open-adblock-cefsimple-smoke.patch
cef/0505-page-website-color-scheme.patch
rust/0001-adblock-vendor.patch
```

Engine apply/build/distrib used `/tmp/open-engine-build.lock`, the scripts'
nice setting, 10 jobs, and a separate session. Release App build used
`OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8 OPEN_AUTOMATION=1
~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh Release`:
`** BUILD SUCCEEDED **`. Both new 0305 hook patches passed clean-file apply round trips: the two
Chromium dialog files and the CEF download file.

## P3 end to end

Each App launch passes `--use-mock-keychain`. Plain suites wait for a foreign
timing-priority flag, then take `/tmp/open-onscreen-e2e.lock`. They run one
suite per call, without an engine or App build from this child in parallel.
The P3 suite requires no network. It signs an ephemeral local CRX3 and sends
it through Chromium's real `CrxInstaller`, validation, consent and registrar.

Command: `tools/e2e/engine_e2e.py --only extensions-p3 --style chrome
--config Release --engine-sha256 7b49090502568f8189aa0e94f7cf23344beec5bed537136eff5f7fce573ad35a`.

| Assertion | Result |
|---|---|
| Registry ready, live metadata and ready/change/commands/install events | PASS |
| X-1: cancel keeps absent; dropping prompt cancels; accept installs; duplicate answer is harmless | PASS |
| Probe's two command shortcuts and action snapshot shortcut | PASS |
| Named command receives the active tab; action command opens with source `command`; unknown command refused | PASS |
| Menu kept across last-tab close/browser recreation cannot select a new menu | PASS |
| X-14: Deny returns false; Allow returns true; Open text and Chromium permissions retained | PASS |
| Disable/enable round trip, action removal/restoration, open popup closes | PASS |
| Registrar reload | PASS |
| X-15: menu removal Cancel keeps; manager removal Accept removes action and closes popup | PASS |
| Manifest icon limits: 2,048² accepted; oversized dimensions, bytes and bit depth refused | PASS |
| Non-default profile installs through its own registry and prompt hook; default remains isolated | PASS |
| No prompt delegate: specific native install dialog appears and installs | PASS |
| Exact owned-process/window cleanup | PASS |

All 14 P3 feature rows passed. Full machine-readable receipt:
[results-extensions-p3-release.json](results-extensions-p3-release.json).

The icon cases modify only the installed fixture under this run's isolated
profile after Chromium has sanitized its initially valid icon. They check the
metadata decoder's actual input boundaries. The native fallback respects
Chromium's existing 500 ms Add-button guard; it does not change native UI.

Negative proof on the same engine and App: `OPEN_E2E_P3_CANCEL_INSTALL=1`
deliberately changes an automation install Accept to Cancel. X-1 reports
`FAIL`, `injectedCancel: true`, `installed: false`; cleanup reports `PASS`.
With the flag removed, X-1 and the complete P3 suite report `PASS`.

The real Web Store also worked (extra evidence; not required by the local
gate). A hosted P1 store tab forwards Google Translate's install consent to
the delegate with its requesting page and no native dialog. Cancel returns
to the store. A management install by id then forwards consent, installs a
`fromWebStore` extension, and completes successfully exactly once. Both rows
and owned cleanup pass in
[results-extensions-p3-webstore.json](results-extensions-p3-webstore.json).

That management run first exposed CEF's rejection of a download without a
CEF browser: Chromium's by-id installer uses its own dummy WebContents.
Before CEF 0305 the download failed with `USER_CANCELED`; after the fix it
installs. The hook accepts only `EXTENSION_INSTALLER` downloads from an exact
dummy requestor owned by an active manager call. It keeps CEF's observer/map
bookkeeping and Chrome's target selection, manifest approval and CRX signature
verification. Both new hook patches passed apply round trips.

## Regression gates

All required suites passed on distribution `7b490905…`:

| Suite (`--only`) | Feature rows | Cleanup | Interruptions |
|---|---|---|---|
| `extensions-p3` | 14/14 PASS | PASS | 0 |
| `actions` | 26/26 PASS | PASS | 0 |
| `extensions` | 8/8 PASS | PASS | 0 |
| `tabstrip` | 35/35 PASS | PASS | 0 |
| `features` | 19/19 PASS | PASS | 0 |
| `shell` | 7/7 PASS | PASS | 0 |

The final three suites used the Release App rebuilt after merging external-link
intake from main `8bd3aadb`; earlier suites used the History merge `495a47d3`.
Both Apps have the same verified engine code. The PR records the full
verification summary on the final merged source head.

The tabstrip setup waits for Bitwarden's welcome tab before asserting the
selected tab. Its discard row waits for the sleep controller's actual
eligibility before sending one request. The final receipt records initial
gate `loading`, then a nil gate, successful `chrome.tabs.discard`, and a
sleeping renderer with the same tab id. It keeps the existing 10 s loading
grace and result assertions. The earlier request during that grace correctly
returned `Cannot discard tab`; it is retained as a failed attempt.

The actions key probe uses unbound Control-Shift-D. Main now binds Control-D
to Toggle Developer Mode, so the old unconsumed-key expectation was stale.
The probe retains asynchronous event batches, keeps the same deadline and
Cmd-W app-route check, and saves/resets/restores the shared developer-mode
default. No production key route or threshold changed.

## Limits and next engine work

- E11 popup windows and E12 omnibox events are separate work. Metadata already
  exposes each profile's `omniboxKeyword`; the probe has the planned delayed
  suggestions, deletion, navigation dispositions and cancel counter.
- Chromium's Cocoa accelerator pair encodes Shift in an uppercase letter:
  `Y` plus Command means Command-Shift-Y. The shell's key router must preserve
  that meaning. In-window shortcut routing is the lead's App step.
- Every profile creates Chromium's global command registry. OS-level global
  key delivery is not proved by the in-process execution gate.
- Permission and uninstall requests can carry a native parent only.
  `webContent` then stays nil; `browser` resolves through the same profile's
  hosted pages. The presenter must otherwise choose a window of that profile.
- Chromium 156 has no retained-file/device fields in `InstallPromptData`;
  the two public arrays are empty. Enterprise/parent-approval prompt types
  continue through Chromium's native UI.
- Guess (child): `byUser` identifies fresh non-policy, non-command-line installs;
  the registry observer has no user-gesture argument. Icon decoder safety caps
  (4 MiB encoded, 2,048² pixels, at most 8-bit components) and a maximum of
  32 pending management installs per profile are also child choices.
- Chromium refuses installs into off-the-record profiles. The management API
  reports that refusal before reaching its CHECK; the local-CRX automation
  method returns false. Ordinary non-default persistent profiles pass the gate.
