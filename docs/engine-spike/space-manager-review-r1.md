# Space Manager review r1 pause checkpoint

The dedicated Manager now sends row intents through the live App sidebar handler before model-only fallback. Pinned close/unload keeps the pin, Copy Link reaches the native pasteboard, and Today close keeps its neighbor. Real host Unmute and pinned URL reset use the existing engine handlers. With no live browser, the fallback refuses pinned close/unload, copies links directly, and creates no model or browser window.

Browser create/close mutations now run with undo registration suppressed only for that mutation. The helper restores the caller's prior registration state. Library Cmd+Z immediately after either lifetime step undoes a preceding Space drag exactly once. Saved window IDs match the real shell controllers; the explicit retained-last-window rule is checked separately.

The parent minor fixes from `d5f0959` remain. The superseded command bar hook and early command branches stay removed. Menu, command bar, App command and Space-header entry all pass through the single existing command path. Main #93 and then main `f668a90` (#94 context-menu allowlist and Site Control) were merged. Both appended docs sections and the auto-merged e2e branches are preserved. No StepD or Package.swift conflict occurred.

| Review finding | Result and evidence |
|---|---|
| 1: row routing | Factory first, actual-context model fallback on nil; pinned Delete/close, loaded unload, pasteboard, Today neighbor, host Unmute and reset pass. Old routing fails pinned retention and Copy Link. |
| 2: window undo | Both lifetime mutations use `withoutWindowUndo`. Immediate create/close undo cases pass with one notification, prior Space order and exact saved/shell window IDs. Each old mutation fails its new case. |
| 3: hidden refresh/scroll | Parent visibility guard retained. Passive cache read shows no hidden rebind/build. Visible replacement keeps horizontal origin. |
| 4: appearance | Parent effective-appearance callback retained. App-only Dark/Light updates and restoration pass; no OS setting changes. |
| 5: observed getter | Read-only getter retained. Section entry now fills only a nil cache. Settings preview initially exposed the repeated supplier call; source guard fixes it with no changes to existing checks. Native section click fills the cache. |
| 6: command ownership | Parent single implemented-command path retained. All four real entries pass; no custom bar hook or early branches restored. |
| 7: meaningful checks | Library key/visibility, Escape dismissal and unchanged tabs across Cmd+W are asserted. Invalid reorder is named as an automation boundary self-check. Model-only selection and standard preferences each produce the requested real FAIL. |
| 8: docs | Automation/status/followups updated. Future Delete confirmation remains with the App handler; matching capture comparison remains pending. |
| 9: nits | Parent native undo/redo menu titles, `any NSObjectProtocol`, read-only non-UUID preferences and standard-window fallback retained. Real App build and undo/menu paths pass. |

| Validation | Result |
|---|---|
| Real App build after final main merge | PASS; `postmerge/build.log` |
| Real Manager flow | 41 PASS, 0 FAIL; `postmerge/final-positive-results.json` |
| Intentional early failure with real Library open | Expected FAIL; real manager/provenance PASS and both cleanup receipts PASS |
| Focused package build | PASS, zero warnings/errors (50 s) |
| settings-preview | 37/37 PASS (81 s) |
| sidebar-render | 559/559 PASS (106 s), rerun after final main merge |

| Mutation | Expected real FAIL | Restored |
|---|---|---|
| old-routing | `manager_pinned_delete_retains_pin`, `manager_copy_link_pasteboard` | PASS |
| undo-window-create | `library_undo_after_window_create` | PASS |
| undo-window-close | `library_undo_after_window_close` | PASS |
| model-only-select | `rebound_manager_intents` | PASS |
| standard-preview-prefs | `E5_menu_real_manager` | PASS |

The five negative proofs ran before the final main merge. Both major-fix source files and the complete Manager e2e function region are byte-identical after that merge. Focused checks and both real App flows were rerun afterward. Every mutation is restored byte-for-byte in `finally`. Both major source files match the recorded originals. All negative and positive runs use the pinned new engine, fresh synthetic roots/cache/preferences and real App events. Every cleanup reports zero remaining owned dialogs, processes and windows. Outer/heavy/on-screen locks are retained, with one outer acquisition per active job and no build during an on-screen run.

The recorded Vendor framework SHA256 is `61c9ab17b6b08525af836cca93bba67819bfa1544f04abe5eae3baf4b57b98a8`. Signing-aware embedded and normalized fingerprints are in the [receipt](results-space-manager-review-r1.json). Runtime provenance is the M5 21:38 PDT copy, recorded 21:23:54, main `4c40ebd` plus #93; App source main is `f668a90`.

Local raw receipts, logs and capture-ready rest/hover PNG paths are recorded in that JSON under `.re/space-manager/review-r1/`. No matching C2 Manager reference exists on M1, so no pixel comparison is claimed. Parent/M5 owns remaining review and the counted full merge gate. Earlier full-gate receipts at `7c07aa6`/main `49b5660` remain historical: 18 PASS, three known M1 baseline FAIL rows and the extra private-input `space-pad-compare` SKIP. No new full gate or load campaign was run for this checkpoint.

No extra Site Control/context-menu/extension suite or new full gate was run for this pause. Those protected main changes retain their M5 ownership. No PR or watch is opened. This is a verified, unmerged pause checkpoint.
