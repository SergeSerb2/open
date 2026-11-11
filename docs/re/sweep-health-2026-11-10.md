# Main sweep triage, 2026-11-10

This is Plan A Step 3's finding inventory. Runtime receipts are specific to the
revision and machine shown below. A later passing run does not erase an earlier
failure. All flows use Open's automation socket; no system mouse or keyboard
input, unit tests, or Chromium build was used.

The recorded engine distribution is
`891c23539c5638e89a87195e34780fec2b478bfa242b6775bfd38a334f008e67`.
M1 runs use its built-in 2x panel. The M5 reference is the external AW2726DM,
2560x1440, 1x, 240 Hz, as qualified in PR #305.

## Findings and guards

| Finding | Cause and reachability | Change and real-flow evidence |
|---|---|---|
| Native NTP abort | User-reachable in both embedded styles. Reports `Open-2026-11-10-120428.ips` (PID 59101) and `Open-2026-11-10-162019.ips` (PID 22141) both record SIGABRT and `NewTabPageHandler::OnBrowserWindowInterfaceChanged`, its constructor, and `NewTabPageUI::CreatePageHandler`. The second report belongs to the Chrome NTP probe; Profiles had not launched. The pinned Chromium file `chrome/browser/ui/webui/new_tab_page/new_tab_page_handler.cc:1214-1215` checks for `NewTabFooterController::From(browser)`. Open's embedded hosts do not supply that full BrowserView controller. | OpenEngine maps native NTP aliases to `about:blank` before initial creation and explicit navigation, in both styles. `OEClient::OnBeforeBrowse` also cancels main-frame renderer/redirect NTP navigation, including before popup adoption attaches its page. It preserves the current document. Real `ntp` runs passed 10/10 in each style at `9a8536f2`, with clean shutdown and no new crash/dialog. The old unsafe paths were not replayed. |
| Welcome W06 | Harness placement error. Its old receipt records cards 1 and 3 played while the hardware pointer covered card 3 after window placement was clamped. | The harness checks actual native card rectangles, moves only its own window, and restarts Welcome at the settled position. No safe placement yields INTERRUPTED. Welcome passed 49/49 at `3171de9d`. `tools/e2e/welcome.py` records the placement evidence. |
| Missing-source Import screen | Harness expected the retired Import route. PR #267 routes discovery without a usable source to Favorites. | `import_robust.py` checks Favorites, the completed probe, unchanged model, and absent saved browser snapshot. A deliberately healthy source rejects that expectation. The retained negative receipt has 27 FAIL/6 PASS, so it cannot count as a positive run. |
| Arc container selection | User-reachable importer defect. Selecting `containers[1]` can import a Little Browser instead of the global sidebar. | Import, probe, mapping labels, and Archive filtering now select the unique `{"global":{}}` pair. Real first-run/Settings synthetic cases cover both orders and missing/duplicate refusal. The real CLI passes all four cases; the saved old CLI imports one Little Browser Space and accepts malformed global identities. See [container finding](import-container-identity.md). |
| Tabstrip cleanup | Harness asked per-window `policy` after the tested command closed the last browser window. That replaced the command's receipt with `policy: no window`. | Restore policy only while a browser window exists, while preserving genuine restore errors. Full tabstrip passed 35/35 at `9a8536f2`, with owned cleanup. |
| Three window colour rows | The old sweep ran on a non-reference 1920x1080 1x display. | PR #305 qualified all three on the exact AW display mode. All 12 reference PNGs, hashes, and limits stayed unchanged (old/new DeltaE00=0). Wrong-colour controls still fail. This was a display-key correction, not a product repaint. |
| A3 Favorite hover | Harness-only synthetic exit. The native queued motion already enters the Favorite and arms its preview. The helper then sent an exit to every unrelated tracking owner, including `SpacePageView`, which cleared the shared preview. The later Favorite enter sees unchanged `pointerInside` and does not re-arm. #301 hit testing is separate. | Full `aa9933a7` and `ce670139` runs reproduce A3. A fresh real-App probe fails the same first hover in under ten seconds. A temporary tagged call stack at `ce670139` names `SpacePageView.mouseExited` called by `AutomationController.hover`; event-order tracing places it before the helper's Favorite enter. The helper now exits only prior simulated hover owners, before queued native motion can enter the new target. A click also reconciles its tracking owners. The intermediate ownership-only fix passed a fresh hover but still failed after a row click: the remaining late exit from the previous SpacePageView cleared the newly shown card. The ordered two-phase dispatch removes that duplicate late exit. At `8a8eb7ef`, the unchanged full sidebar suite passed 229/229, including A3 and E11; the small real-App hover/click/leave probe passed 3/3. Both Favorite click guards still reject reversing #301. |
| E11 preview dismissal | Intermittent failure during the full sidebar setup; root cause is unresolved. Minimized valid preview show/leave probes and a later full run pass. | Keep the failing `3666eabd` receipt. The assertion now records the actual window, pointer, tracking owners, and preview state. The full `116f70c3` run passed E11 and every later row. No product fix is claimed. |
| Chrome open-world messages | Harness schema mismatch after the factory added `pickerAccepted`; the transport callback still has four fields. | PR #304 checks both exact schemas and compares the transport projection. Full Features passed 48/48 at `3666eabd`, including `open_world_messages`. |
| Display-link interposer crash | Harness-only mutable registry access from a dispatch worker. The original report's failing frame is `__hookDisplayLinkClass` while adding to its NSHashTable. | Keep registry work on the main thread; attribute the caller before dispatch. Full Little Open passed 41/41 at `9a8536f2`, Split 40/40 at `3666eabd`, and Downloads' native idle observation passed at `116f70c3`. Observer runs remain M1-only. |
| Downloads clone teardown | Harness-only lifetime error: deleting a temporary bundle before late/reparented helpers exited. | Only a uniquely owned disposable clone enables path-wide helper rescans during quit. The `116f70c3` Downloads full, clear, and history receipts all have cleanup PASS, with no new crash or system dialog. |
| Downloads historical Retry | User-reachable engine callback-lifetime defect. A completed 131072-byte transfer loses its terminal update after its originating tab closes. | Keep the raw Retry predicate failing. Only `downloads/history_retry` has the lead-approved exact DEFERRED policy entry; the engine lane owns the repair. No App workaround. The focused `116f70c3` history run passed 24 independent rows, including clear/persistence/Profile retirement, then failed Retry plus its causal suite error. See [callback finding](download-retry-callback-lifetime.md). |
| Downloads clear fixture cancellation | Full sequence intermittently receives an already-cancelled 0-byte `/slow` transfer before the native Cancel button exists. Root cause remains unresolved; it is not covered by the Retry deferral. | Retain the original failures, including the reduced reproduction at `06f5139e`. Full strict Downloads at `aa9933a7` passed all clear-range, native Cancel, history and quit guards: 120 PASS, with only raw historical Retry and its causal suite error failing. The native Cancel predicate stays unchanged. |
| Settings Profile deletion after PR #307 | Harness still requested the removed `Delete Profile` button; deletion now lives in the native row menu. The first post-merge strict Downloads run passed 93 rows and reached the known Retry failure, then stopped before the independent Profile-retirement assertion. | Follow the real `open://settings/profiles/delete` route and enabled `Actions for Profile …` → `Delete…` menu item, as the Settings redesign acceptance flow does. Keep typed-name, data-retirement and persistence predicates unchanged. Shared callers use that same real-control helper. The bulk action uses the new visible title. No direct model deletion or App workaround. |
| Strict launch log | Harness-only: direct-child launches created the per-launch stderr file only for world-audit runs. The newly reachable generic-quit flow read the absent file and stopped the strict full Downloads run after 113 PASS. | Create the same per-launch stderr for every direct child. Keep the aggregate log for post-quit consumers. Generic quit still reads the actual launch, so earlier launches cannot satisfy its alert-count assertions. Focused strict generic-quit passed 7/7 at `68f9b47e`, including alert precedence, Stay/re-quit, harness bypass, and safe cleanup. |
| Import idle CPU | Main-merge bisection identified PR #306 (`b0ebbacf`) as the first bad merge: the visible Welcome playlist kept `CrBrowserMain` active. Chromium local-build stack sampling added separate Release CPU work. | PR #308 (`6da537a8`) fixes the finite Welcome lifecycle and default stack-profiler switch. Its full M5 gate passed 25/25; M1 original import passed 5/5 at 0.594% idle. Step 3 includes that merge and reruns the same guarded import flow. See [attribution, original failures and resolution](import-idle-attribution-2026-11-10.md). |
| Profiles-engine socket startup | Harness constructed a 104-byte AF_UNIX path; the server requires fewer than 104 bytes including its terminator. | Budget the actual home path, PID, style and random suffix against 103 bytes. Full profiles-engine passed 22/22 at `faabeb64`. |
| Profiles migration probe | Harness used a normal pre-engine quit to inspect migration; that quit now legitimately saves browser state. | An automation-only layout probe exits after real migration, before windows/engine/quit saving. Normal quit is unchanged. Full Profiles passed 74/74 at `faabeb64`. |
| AppleScript A18 | Harness inherited `restoreWindowsOnLaunch=false` and did not answer the now-default quit warning. | Save/set/restore the needed restore policy and arm the real Quit button before the event. AppleScript passed 208 rows with the two separately approved consent blocks. No Automation permission was requested. |
| Passwords P-16 | One full run failed popup dismissal; a minimized sequence and the later full run passed. Root cause remains unresolved. | Keep the failed receipt. P-16 now reports each native substep precisely. The full diagnostic rerun passed 78 rows with only approved `PW-KC1` BLOCKED, with no new crash/dialog. |

## Previously unrun suites

These are the latest complete positive sweep receipts, not a claim that all
were rerun at the final PR head. The final merge gate is a separate requirement.
Older raw paths below are relative to the initial Plan A worktree's
`.re/gate-health/step3/`. New `step3-aa9933a7-r1/` receipts are under
`.re/gate-health/` in the Step 3 worktree and its owned M1 checkout.

| Suite | Machine | PASS / other | Receipt revision and result |
|---|---|---|---|
| littleopen | M1 | 41 / 0 | `9a8536f2`, `m1-resume-1730` |
| extensions-p3 | M1 | 19 / 0 | `7128cfc9`, `m1-baseline-final` |
| extensions-ui | M1 | 69 / 3 DEFERRED | `7128cfc9`; its three M5 pixel/timing rows are not accepted by this M1 receipt |
| extensions-e2 | M1 | 26 / 0 | `7128cfc9`, `m1-baseline-final` |
| profiles-engine | M1 | 22 / 0 | `faabeb64`, `m1-resume-1657` |
| media | M1 | 31 / 1 BLOCKED | `7128cfc9`; recording requires user consent |
| routing | M1 | 13 / 0 | `7128cfc9`, `m1-baseline-final` |
| history | M1 | 31 / 0 | `7128cfc9`, `m1-baseline-final` |
| applescript | M1 | 208 / 2 BLOCKED | `faabeb64`, `m1-resume-1657`; predates the later ban on external AppleScript over SSH. Future gate runs this suite on M5. |
| downloads | M1 | 120 / 1 exact DEFERRED | `aa9933a7`, `step3-aa9933a7-r1/downloads`: strict full completed every independent flow. Raw Retry FAIL and its causal suite error remain; only `downloads/history_retry` is deferred. Cleanup PASS; no new crash/dialog. |
| incognito | M1 | 31 / 0 | `faabeb64`, `m1-resume-1657` |
| sitedata | M1 | 10 / 0 | `9d121516`, `m1-baseline-final` |
| passwords | M1 | 78 / 1 BLOCKED | `3666eabd`, `m1-probes-1935`; Keychain manual row only |
| passwords-probe | M1 | 7 / 3 NOT_REQUESTED | `9d121516`; superseded observation suite is opt-in, not a default acceptance receipt |
| secrets-import | M1 | 14 / 0 | `9d121516`, `m1-baseline-final` |
| owner-watch | M1 | 4 / 0 | `3666eabd`, `m1-resume-1830`; real owned-process death flows |
| find | M1 | 58 / 0 | `9d121516`, `m1-baseline-final` |
| split | M1 | 40 / 0 | `3666eabd`, `m1-resume-1915` |
| profiles | M1 | 74 / 0 | `faabeb64`, `m1-resume-1657` |

## Final Step 3 qualification

At `aa9933a7`, Debug and automation Release App builds passed on the M1.
Full strict Downloads completed 120 passing rows. The unchanged historical
Retry assertion failed, followed by its causal `suite` error naming
`failedRow=history_retry`; this is one predicate, covered only by the exact
lead-approved `downloads/history_retry` deferral. All clear ranges, active
Cancel controls, independent history persistence, corrupt/oversized history
refusal, and both quit-warning variants passed. Owned cleanup passed, with
no new crash report or system dialog.

The original Release import flow passed all five rows on the same head:
History 987.3/1400 ms, maximum main lag 29.1/50 ms, settled idle 0.597%/1%,
and Welcome settled after 19.122 seconds under the separate 30-second cap.
Store files and save counters stayed unchanged; the watchdog was stopped.
The sample held both slots, with preflight load1 2.9399 and 2.9551 ten seconds
apart, foreign CPU 47.5% before and 51.6% immediately after the idle row.
It meets LEAD22:45's <=200% foreign-CPU rule. Cleanup passed, with no new
crash or system dialog. Raw receipts are under
`.re/gate-health/step3-aa9933a7-r1/{downloads,timing}/` on the owned M1
checkout; local copies are under that run's `receipts/` directory.

Passwords passed 78 rows plus the approved manual Keychain block. Full
sidebar completion passed 135 rows, including E11, before reproducing the
original A3 Favorite hover failure (`kind=none`, no preview shows). This
failure remains unexcepted. The diagnostic rerun records native tracking owners, requested point,
scheduled preview work, target, window and preferences without changing the
predicate. The minimized probe and tagged caller trace attribute the failure
to the helper's unrelated synthetic exits, as described above. Temporary
trace code is removed. At `8a8eb7ef`, the complete sidebar suite passed
229/229, including E11 and A3. The fresh hover, hover after a native row
click, and leave/re-enter probe passed 3/3. All owned cleanup checks passed,
with no new crash or system dialog. Receipts are under
`.re/gate-health/step3-hover-fix-r3/` on the M1; copies are retained locally.
A subsequent main merge includes Settings PR #307 (`b96b8534`); focused
post-merge qualification and the final full M5 gate remain separate.

An extra M1 window/chrome diagnostic at `8a8eb7ef` passed 23 functional
and motion rows. The comparison row was SKIP because the private S2 capture
frames are absent on that checkout; `chrome_card_material` then failed its
required reference-presence predicate. Its white, dark and band material
subpredicates all passed. This is an incomplete visual receipt, not window
acceptance. The final M5 gate and Step 4 public gate use their real capture
inputs; no missing-capture exception or fallback was added.

The earlier idle failures and invalid high-load timing samples remain in
[the attribution history](import-idle-attribution-2026-11-10.md). The reduced
cancelled-clear reproduction at `06f5139e` and intermittent E11/P-16 failures
also remain recorded with their guards. A later pass does not establish
an intermittent failure's root cause. Final full M5 qualification is pending.
