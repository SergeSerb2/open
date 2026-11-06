# Zap and selector package verification

Scope: the real page runtime, OpenBoosts capability coordinator, OpenSiteControl
session, and offscreen/native harnesses. App transport and engine P7/B4 are separate
Section 12 integration gates. No engine or App source changes are included.

The Chrome harness clicks the actual closed-shadow controls through Chrome's DOM
protocol. Page JavaScript cannot inspect that closed root. The native flows use
the real decoder/coordinator/store/planner and an actual NSTextView; the host
boundary is fake. `zap-flows` creates only offscreen windows at the harness's
synthetic coordinates. Full `check` includes its registered native harness under
the on-screen lock.

Negative proof: `negative-browser.txt` records 40 initial independent mutations plus 15 lead-choice mutations of copied
runtime resources, each rejected by the real Chrome flow. The working source was
never changed by those mutations. Native break-and-restore results are recorded in `negative-native.txt`
(11 initial behavior mutations plus the direct-related undo mutation, including every new F13/selector flow row). The new `editor-zap-on` scene has new 1x/2x render receipts. Existing baseline
images, comparators, thresholds, and allowlists were not regenerated or changed.

The original A7 blue-hover-outline expectation changes to the specified yellow
hover tint plus the blue content frame. A11 verifies Cancel leaves no commit or
undo step, the precise action commits one match, and the related action previews
three matches then commits them directly. Both commit choices close the card,
write one selector, and undo in one step. The related label is “Zap all related
elements” and its count lives in the popup band.

The card closes after every choice (Open choice, lead, 2026-11-06). Related commits
do not replace a preliminary precise commit. `zap:replaced` decoding remains in
the native bridge contract. Integration notes are also in `docs/boosts.md`.

Integration hooks:

- `BoostEditorHost.enterSelectorPicker(boostID:tabID:) -> Bool` is required; no default implementation is supplied.
- `BoostEditorSession.pickSelector()` and `insertSelectorAtCaret` let code mode bind
  its button and CSS NSTextView caret. The session exits after selection.
- `endPickerSession()` exits on tab switch, frame destruction, and transport loss.
  `updatePageURL` also exits for same-URL reloads. `finish()` removes its observer.
- The coordinator owns `BoostPickerEvent` and exposes `lastEvent` for adapter
  fan-out. OpenSiteControl retains a public alias with the same name.
- After an accepted reveal, the adapter sends `removeZap(selector:for:)` and
  refreshes the matching pages. The editor registers one undo step from the store.
- `PickerOutbound.listZaps` retains `selectors` and adds a defaulted label map so
  chips on re-entry use persisted labels. Pattern matches must handle that map.
