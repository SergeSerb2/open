# Fresh Profile first-navigation regression guard

## Result

The reported blank first document did **not** reproduce on unchanged production
code in 10 separate M5 real-App runs on 2026-11-09. All 10 runs reached the
requested document URL, distinctive title and body marker without a second
navigation. OpenEngine and App code remain unchanged. This does not establish
that the intermittent race is absent or fixed.

Base: `d279ae85` (includes engine update `627745e0`). Framework SHA-256:
`891c23539c5638e89a87195e34780fec2b478bfa242b6775bfd38a334f008e67`.
Every run checked the Vendor hash and embedded framework code identity before
launch. The baseline Debug build passed through `heavy.sh` with
`OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main`.

## Row

`shell_fresh_profile_first_navigation`, in the existing Profiles shell suite,
creates a synthetic Profile through `profiles-shell action=create` (the real
Settings model). It asserts that the Profile has no Space or loaded context,
creates its Space, and opens one unique loopback fixture URL. The final guard
uses the existing load-wait command, then polls the real document for at most
20 seconds. It checks document URL, title, body marker, completion, selected and
visible tab, live and visible page, and the page's actual Profile directory.
There is no `navigate`, reload or retry of the requested URL.

The default guard leaves context creation lazy. The optional
`OPEN_PROFILES_FIRST_NAV_PREPARE_CONTEXT=1` diagnostic reads the new Profile's
credential preferences and aggregate counts before its first document. These
reads do not change preferences or access the user's Profile.

Focused invocation (inside the required screen lock):

```sh
OPEN_AUTOMATION_SKIP_MAC_NOTIFICATIONS=1 OPEN_E2E_NO_CRASH_PROBES=1 \
OPEN_PROFILES_FIRST_NAV_ONLY=1 \
python3 tools/e2e/engine_e2e.py --only profiles --profiles-shell-only \
  --style alloy --stop-on-app-death \
  --engine-sha256 891c23539c5638e89a87195e34780fec2b478bfa242b6775bfd38a334f008e67
```

Wait for `/tmp/open-onscreen-priority` to disappear before taking
`/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock`. Run
`osascript -l JavaScript /tmp/dlg.js` before and after each invocation; stop if
its count is nonzero. All recorded runs used this protocol. No M1 runs, crash
probes, debugger, desktop input, Apple-domain writes or Arc launches were used.

## Unchanged-code receipts

Private receipts are in this checkout's `.re/blank-first-nav/`. Each label has
both a `.json` receipt and a `.log`; `summary.json` indexes the ten attempts.

| M5 runs | Context before first page | Document checks | Reproductions |
|---|---|---|---|
| `before-1` through `before-5` | Cold | 5/5 PASS | 0/5 |
| `before-6` through `before-10` | Prepared by read-only queries | 5/5 PASS | 0/5 |

The first seven attempts waited for the page to become live before evaluating
the document. Attempts 8–10 also used the standard load-wait command immediately
after `open`, to cover an early content request. Every attempt recorded a live,
visible Alloy page, matching Profile context and model/document URLs. Document
arrival took 0.171–0.515 seconds. All ten App cleanups passed, with native dialog
counts zero before and after.

## Source evidence and limits

The suspected sequence is present in the source:

| Evidence | Observation |
|---|---|
| `App/WebContent/EngineWebContentHostFactory.swift:615–625`, `ensureContent` | Creates content with a nil URL, adopts its view, then calls `host.load(tab.url)`. |
| `Engine/OpenEngine/src/OEWebContent.mm:496–535`, `oe_createBrowserNow` | Copies `_pendingURL` into a local CEF URL before browser creation. |
| `Engine/OpenEngine/src/OEWebContent.mm:922–937`, `loadURL` | Replaces `_pendingURL` when no browser exists. |
| `Engine/OpenEngine/src/OEWebContent.mm:614–666`, `oe_browserCreated` | Restores history when present but does not replay a later ordinary pending URL. |

These facts identify a possible lost-request interval. They do not prove that
this interval caused K2's failure. There is no reproduced root cause, production
fix, or fix-removal break-and-revert receipt in this branch.

## Guard validation

| M5 validation | Result | Private receipt/log label |
|---|---|---|
| Baseline Debug build | PASS | `build-baseline.log`, `build/xcodebuild-Debug.log` |
| Deliberately expect a marker absent from the real fixture | Expected FAIL; correct document/model URLs; 20.186-second bounded wait | `broken-guard` |
| Restore the original marker expectation | PASS; clean shutdown | `restored-guard` |
| Full `profiles --profiles-shell-only` suite | 37/37 PASS; no interruptions; clean shutdown | `profiles-shell-full` |

The negative variant changed only the row's expected marker, then restored the
file byte for byte. It proves the guard checks the document rather than only
the model URL. It is **not** evidence of reproducing or fixing the reported
navigation race. Both negative/restored runs recorded zero native dialogs
before and after and passed owned-process cleanup.

The full Profiles shell run used committed e2e code
`7ec39e1907b6a2cea92f843d85ef0902aa3e0754`, with an empty source diff. It
completed in 45.895 seconds under the M5 screen lock. Its dialog counts were
also zero before and after. A final process check found no App instance from
this checkout. No build or check remains running.

The production-change regression suites (`shell`, `littleopen`, and `features`)
and fix-removal break-and-revert were not run: the brief's no-reproduction path
requires no production change. The relevant full Profiles shell suite verifies
the new guard's integration. A full merge gate and PR are outside this
push-only handoff.
