# Page-chrome leftovers: real-App evidence (2026-11-07)

`Manage Extensions` now appears on page, link, image and selection targets. Editable fields omit it. The existing `manage-extensions` command opens the extensions page as a selected Today tab. The only binding in another section's file is the weak-owner closure in `EngineWebContentHostFactory.pageContextMenuHooks`.

The position is **GUESS**, per the Section 11 lead, pending the user's S-9 capture. With no extension contributions, the item has its own separator group immediately before Inspect. With contributions, it follows them in their group. Title evidence: `docs/re/features-advanced.md` EX-18. No Arc menu-order acceptance is claimed.

Alert, confirm and prompt text, and the prompt default, now use a 10,240-byte UTF-8 bound. Size no longer cancels a dialog. Open reserves three bytes for `…` and cuts only at a complete UTF-8 scalar. Queue eight, URL, node, depth and all other limits remain unchanged. The engine request remains the completion owner; only the text passed to AppKit is bounded.

Chromium applies an upstream **character-count** cap to messages without a mark or cut flag. For 10,241 ASCII input characters, the real callback already contains 10,240 unmarked bytes. Open preserves that text. Open adds `…` **only when Swift cuts the received UTF-8 text**. The over-byte fixture uses multibyte characters below Chromium's character cap. No engine change is needed or included.

## Final source and engine

Runtime source head: `5d932ea75a44d6b0356cf5003a7bb1d17d3d1db3`. It includes main `7f405f3b3e5ccf5716d2664b1f6e91e36b219df3`. The final commit adds only this receipt and status docs.

M5 engine distribution SHA-256: `2ecaeadab71b3da3e5bc65a3f5b77d80c7958e9d0faa8cd305a0fa29496ebb10`. Distribution and embedded engine code share fingerprint `da92acc15f9d4b325cc715634d80abacf48493fa864c8f8e53ff282c11948081`. Both final M5 suites recorded a clean runtime source tree. JSON result hashes and per-case evidence are committed in [pagechrome-leftovers-receipt.json](pagechrome-leftovers-receipt.json). Raw local artifacts are under `.re/leftovers/`.

## Real-App functional results

| Run | Machine | Result | Local JSON |
|---|---|---|---|
| Final Debug build | M5 | PASS | `.re/leftovers/postmerge-build-m5.log` |
| Final context-menus | M5 | 35 PASS, 0 FAIL | `.re/leftovers/postmerge-context-m5.json` |
| Final page-chrome | M5 | 60 PASS, 3 baseline FAIL | `.re/leftovers/postmerge-page-chrome-m5.json` |
| Unchanged merged main, three failed rows | M5 | Same three FAIL | `.re/leftovers/main-page-chrome-m5.json` |

Final runs and the unchanged-main comparison have zero interrupted attempts and successful owned-process cleanup. The three failures are `little_dialog_early_once`, `little_permission_dismiss_miniaturize`, and `little_permission_dismiss_navigate`: the expected answer/permission event records are absent. The unchanged main comparison uses the same M5 engine. Those failures remain open; this change does not modify their event paths. Earlier M1 trials reproduced the same failures with an older engine and are retained as separate evidence, not the basis for the M5 baseline classification.

`cm_manage_extensions` checks all five targets both without and with a real extension contribution (ten cases), plus the real app-command action. All positive target cases assert exact adjacency/separators and one copy of the title. Both editable cases assert absence.

`dialog_message_limit` checks alert, confirm and prompt; `dialog_prompt_limit` checks prompt defaults. All fifteen cases prove a specific visible native sheet, exact displayed text/byte count, and the native OK answer reaching the originating page:

| Input | Expected displayed text | Bytes |
|---|---|---:|
| 10,240 ASCII bytes | unchanged | 10,240 |
| `x` + 5,120 copies of `é` (10,241 received bytes) | `x` + 5,118 copies of `é` + `…` | 10,240 |
| 10,235 ASCII bytes + eight emoji | ASCII prefix + `…`, with no partial emoji | 10,238 |
| Message only: 10,241 ASCII characters | Chromium's upstream unmarked cut | 10,240 |

The last case is run for all three message dialog kinds. Defaults use the first three cases. The unchanged queue and lifecycle rows also run in the full suite.

## Negative proofs (M1, real App)

| Broken behavior | Expected failure | Evidence |
|---|---|---|
| Old empty extension hook | Eight positive target/group cases and action fail; editable absence remains true | `.re/leftovers/m1/negative-context.json` |
| Editable exclusion removed | Exactly the two editable cases fail; eight other cases and action pass | `.re/leftovers/m1/negative-editable.json` |
| Old 8 KiB / 4 KiB size-refusal guards | Both dialog rows fail; nine message cases report the 8,192-byte refusal and three default cases report the 4,096-byte refusal | `.re/leftovers/m1/negative-dialog.json` |
| Forced failure while native alert is visible | Expected dialog row failure, cleanup PASS, no remaining owned process/window | `.re/leftovers/m1/early-failure.json` |

All negative runs have zero interrupted attempts and successful cleanup. The old-hook binary was built from App-identical source `7845df0b` and exercised by source `7de60312`; the editable mutation is `7eb4e4c3`. Receipt source heads and hashes are preserved in the JSON. No unit tests or computer use were used.

## Full M5 gate and timing rerun

Command: `OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main ~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --with-arc-data`.

The single full run had **24 PASS, one timing-only FAIL, zero SKIP**. It ran at source `8f856ad3`; later pre-merge edits were fixtures/docs/comments only. Main #222 independently passed 25/25. The overlap merge follows TANDEM §4.5a: Debug and both affected suites were rerun after the clean merge; a second full gate is not required. No comparator, baseline, threshold or allowed-missing row changed.

| Check | Result | Seconds |
|---|---|---:|
| build | PASS | 183 |
| commands-demo | PASS | 5 |
| roundtrip | PASS | 1 |
| space-legacy | PASS | 2 |
| space-editor | PASS | 9 |
| space-pad-compare | PASS | 3 |
| suggest-check | PASS | 30 |
| commands-dump | PASS | 0 |
| route | PASS | 15 |
| favicons | PASS | 3 |
| media-demo | PASS | 1 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 0 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 4 |
| settings-preview | PASS | 88 |
| sidebar-render | PASS | 110 |
| sidebar-compare | PASS | 195 |
| commandbar-render | FAIL | 47 |
| features-render | PASS | 89 |
| extensions-render | PASS | 8 |
| sitecontrol-render | PASS | 236 |
| boosts | PASS | 3 |
| import-arc | PASS | 1 |
| verify-secrets-fixture | PASS | 5 |

| commandbar-render attempt | Result | CPU p95 | Inline overhead | Load averages (1/5/15 min) |
|---|---|---:|---:|---|
| Full gate | FAIL (timing only) | 11.10 ms | 0.975 ms | 41.9 / 35.4 / 26.9 |
| Strict quiet rerun on merged head | PASS, 151/151 | 4.75 ms | 0.212 ms | 7.3 / 14.8 / 19.3 |

Quiet rerun: `/usr/bin/lockf -k /tmp/open-m5-quiet.lock ~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --only commandbar-render`. Receipts: `.re/leftovers/verify/summary.txt`, `.re/leftovers/verify-commandbar-quiet/summary.txt` and `.re/leftovers/quiet-commandbar.log`.

Final-head `commands-dump` is missing/extra/different **0/0/0**, with the same eleven allowed-missing rows (enumerated in the JSON receipt). All full-gate display checks passed. No e2e `window` suite was run for this two-suite task.

## Review checklist

| Checklist item | Result | Evidence |
|---|---|---|
| External sizes and decoded bounds | PASS | Display text is at most 10,240 UTF-8 bytes. Truncation follows the explicit lead rule. Queue 8, context nodes 128, depth 8, titles 1 KiB, selection 16 KiB and URLs 64 KiB remain unchanged. Evidence: `App/PageChrome/PageChromeLimits.swift:8; App/PageChrome/PageContextMenuBuilder.swift:12; App/PageChrome/PageDialogPresenter.swift:83`. |
| Worst explicit allocation | PASS | The new UTF-8 prefix buffer is at most 10,237 bytes; the result including `…` is at most 10,240 bytes. Neither approaches allocator ceilings. Evidence: `App/PageChrome/PageChromeLimits.swift:17`. |
| At/over limit cases | PASS | Both dialog limit rows use at-bound, 10,241-byte received text, a split multibyte character, native UI and real page replies. Evidence: `tools/e2e/page_chrome.py:187; pagechrome-leftovers-receipt.json dialogCases`. |
| Trailing/unknown parsed data | N/A | No parser or file format changes. |
| Callback reentrancy | PASS | Menu actions retain the existing DispatchQueue.main.async boundary, finish the engine request once, then run the app command. Owner capture is weak. Evidence: `App/PageChrome/PageContextMenuBuilder.swift:120; App/WebContent/EngineWebContentHostFactory.swift:156`. |
| Free/close exactly once | PASS | Existing completed guards and remove-before-callback ordering remain; new fields are immutable strings owned by the existing queue entry. Real close/quit cases and forced visible-sheet failure exercise cleanup. Evidence: `App/PageChrome/PageDialogPresenter.swift:126; pagechrome-leftovers-receipt.json negativeProofs.intentionalVisibleSheetFailure`. |
| IDs and stale generations | PASS | Existing per-menu hook key and live-owner/completed guards remain; no global or engine IDs are allocated. Evidence: `App/PageChrome/PageContextMenuBuilder.swift:280`. |
| Flush held state | N/A | No new deferred state or disk writes. |
| Real key and focus paths | PASS | No new focus context. Page-chrome retains native Return/Escape/Cmd+W/T/L coverage through the real App. Evidence: `tools/e2e/page_chrome.py:232; tools/e2e/page_chrome.py:240`. |
| Post-merge key ownership | PASS | No shortcut/router changes; existing manage-extensions command is reused. Both affected suites rerun after the overlapping main merge. Evidence: `App/WebContent/EngineWebContentHostFactory.swift:156; finalRuns in the JSON receipt`. |
| Hidden rows cannot run | PASS | Editable targets create no hook item. Removing the guard failed exactly the two editable subcases while the other eight target cases and action still passed. Evidence: `App/PageChrome/PageContextMenuHooks.swift:18; negativeProofs.editableSubcases in the JSON receipt`. |
| New checks fail when broken | PASS | Old-hook App fails cm_manage_extensions; old size guards fail both dialog limit rows with explicit 8192/4096-byte refusals; editable mutation and cleanup negative receipts are retained. Evidence: `negativeProofs in docs/engine-spike/pagechrome-leftovers-receipt.json`. |
| Image comparisons | N/A | No image assertion, comparator or baseline is added or changed. |
| Specific dialog appears | PASS | Each row matches the exact native informativeText/default field, requires visible UI, presses the real button and checks the originating page's reply. Evidence: `tools/e2e/page_chrome.py:212; dialogCases in the JSON receipt`. |
| Timing assertions | N/A | No timing gate added or changed. Existing full-gate timing failures and the strict quiet rerun are both reported with loads. |
| Isolated data/preferences | PASS | Existing harness uses unique data/cache/scratch roots and ports. Both touched suites reset their used defaults and restore them in finally; no new defaults are used. Evidence: `tools/e2e/page_chrome.py:406; tools/e2e/context_menus.py:703`. |
| Dialog/process cleanup on early failure | PASS | Intentional failure with a visible alert reported clean owned-process cleanup and zero interruptions; early-failure.json. Suite finally paths answer dialogs, close servers and quit owned Apps. Evidence: `tools/e2e/page_chrome.py:89; tools/e2e/engine_e2e.py:12232; negativeProofs.intentionalVisibleSheetFailure in the JSON receipt`. |
| Reduce Motion | N/A | No animation path changes. |
| Interrupted animations | N/A | No animation path changes. |
| Width/resize animations | N/A | No geometry or resizing changes. |
| Real-window Arc comparison | N/A | No drawing change; exact menu placement is explicitly GUESS pending the user's S-9 capture, per the lead's spec. |
| Current comments and numbers | PASS | 10,240-byte bound and upstream unmarked character cut are documented; stale refusal text is removed from status/followups. Evidence: `App/PageChrome/PageChromeLimits.swift:8; docs/re/page-chrome.md:245`. |
| Plan/followups/PR agreement | PASS | Both requested leftovers close with the receipt; S-9 capture remains open. Baseline and timing results are reported separately. Evidence: `docs/followups.md:70; docs/followups.md:247; docs/engine-spike/pagechrome-leftovers.md`. |


Remaining external evidence: S-9 for Arc's menu position. No implementation design question remains. The three unchanged-main Little Open event failures remain outside this change.
