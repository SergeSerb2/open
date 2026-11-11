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
| A3 Favorite hover | The original `kind=none` failure remains unreproduced. Source review and the real comparison do not support #301's click hit-test change as its cause. | Full sidebar-completion passed 229/229 at `116f70c3`. In a fresh real-App comparison at that head, A3 hover passed with current code, with only #301 reversed, and after restoration. Both native Favorite click guards passed/current, failed/reversed, passed/restored. Hover tracking and click hit testing are separate paths in `FavoriteTileView`. Keep the full A3 guard. |
| E11 preview dismissal | Intermittent failure during the full sidebar setup; root cause is unresolved. Minimized valid preview show/leave probes and a later full run pass. | Keep the failing `3666eabd` receipt. The assertion now records the actual window, pointer, tracking owners, and preview state. The full `116f70c3` run passed E11 and every later row. No product fix is claimed. |
| Chrome open-world messages | Harness schema mismatch after the factory added `pickerAccepted`; the transport callback still has four fields. | PR #304 checks both exact schemas and compares the transport projection. Full Features passed 48/48 at `3666eabd`, including `open_world_messages`. |
| Display-link interposer crash | Harness-only mutable registry access from a dispatch worker. The original report's failing frame is `__hookDisplayLinkClass` while adding to its NSHashTable. | Keep registry work on the main thread; attribute the caller before dispatch. Full Little Open passed 41/41 at `9a8536f2`, Split 40/40 at `3666eabd`, and Downloads' native idle observation passed at `116f70c3`. Observer runs remain M1-only. |
| Downloads clone teardown | Harness-only lifetime error: deleting a temporary bundle before late/reparented helpers exited. | Only a uniquely owned disposable clone enables path-wide helper rescans during quit. The `116f70c3` Downloads full, clear, and history receipts all have cleanup PASS, with no new crash or system dialog. |
| Downloads historical Retry | User-reachable engine callback-lifetime defect. A completed 131072-byte transfer loses its terminal update after its originating tab closes. | Keep the raw Retry predicate failing. Only `downloads/history_retry` has the lead-approved exact DEFERRED policy entry; the engine lane owns the repair. No App workaround. The focused `116f70c3` history run passed 24 independent rows, including clear/persistence/Profile retirement, then failed Retry plus its causal suite error. See [callback finding](download-retry-callback-lifetime.md). |
| Downloads clear fixture cancellation | Full sequence intermittently receives an already-cancelled 0-byte `/slow` transfer before the native Cancel button exists. Root cause remains unresolved; it is not covered by the Retry deferral. | Retain the `116f70c3` full failure (62 PASS plus the assertion and causal suite error). Fresh `OPEN_DOWNLOADS_CASE=clear` passed all 11 range/validation rows with the same source. A later strict full run passed those rows and reached 113 PASS before an unrelated missing launch-log harness error. The native Cancel predicate stays unchanged. |
| Strict launch log | Harness-only: direct-child launches created the per-launch stderr file only for world-audit runs. The newly reachable generic-quit flow read the absent file and stopped the strict full Downloads run after 113 PASS. | Create the same per-launch stderr for every direct child. Keep the aggregate log for post-quit consumers. Generic quit still reads the actual launch, so earlier launches cannot satisfy its alert-count assertions. Focused strict generic-quit passed 7/7 at `68f9b47e`, including alert precedence, Stay/re-quit, harness bypass, and safe cleanup. |
| Import idle CPU | Valid quiet M1 runs failed at 3.585% and 3.161%. OS counters identified the browser main thread; native state showed the initial Welcome playlist still active during the ten-second post-import wait. | Finish all four native Welcome completions before starting the large Settings import. Keep the post-import wait, CPU interval, and <1% limit unchanged. The real control passed at 0.395%; final committed-harness rerun pending. See [attribution and controls](import-idle-attribution-2026-11-10.md). |
| Profiles-engine socket startup | Harness constructed a 104-byte AF_UNIX path; the server requires fewer than 104 bytes including its terminator. | Budget the actual home path, PID, style and random suffix against 103 bytes. Full profiles-engine passed 22/22 at `faabeb64`. |
| Profiles migration probe | Harness used a normal pre-engine quit to inspect migration; that quit now legitimately saves browser state. | An automation-only layout probe exits after real migration, before windows/engine/quit saving. Normal quit is unchanged. Full Profiles passed 74/74 at `faabeb64`. |
| AppleScript A18 | Harness inherited `restoreWindowsOnLaunch=false` and did not answer the now-default quit warning. | Save/set/restore the needed restore policy and arm the real Quit button before the event. AppleScript passed 208 rows with the two separately approved consent blocks. No Automation permission was requested. |
| Passwords P-16 | One full run failed popup dismissal; a minimized sequence and the later full run passed. Root cause remains unresolved. | Keep the failed receipt. P-16 now reports each native substep precisely. The full diagnostic rerun passed 78 rows with only approved `PW-KC1` BLOCKED, with no new crash/dialog. |

## Previously unrun suites

These are the latest complete positive sweep receipts, not a claim that all
were rerun at the final PR head. The final merge gate is a separate requirement.
Raw paths below are relative to the Plan A worktree's `.re/gate-health/step3/`.

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
| downloads | M1 | 113 / 2 FAIL | `116f70c3` strict full: raw Retry FAIL and an unrelated missing launch-log error. Earlier full sequence stopped at clear cancellation. Independent clear 11/11 PASS; history 24 PASS plus unchanged Retry and causal error FAIL. |
| incognito | M1 | 31 / 0 | `faabeb64`, `m1-resume-1657` |
| sitedata | M1 | 10 / 0 | `9d121516`, `m1-baseline-final` |
| passwords | M1 | 78 / 1 BLOCKED | `3666eabd`, `m1-probes-1935`; Keychain manual row only |
| passwords-probe | M1 | 7 / 3 NOT_REQUESTED | `9d121516`; superseded observation suite is opt-in, not a default acceptance receipt |
| secrets-import | M1 | 14 / 0 | `9d121516`, `m1-baseline-final` |
| owner-watch | M1 | 4 / 0 | `3666eabd`, `m1-resume-1830`; real owned-process death flows |
| find | M1 | 58 / 0 | `9d121516`, `m1-baseline-final` |
| split | M1 | 40 / 0 | `3666eabd`, `m1-resume-1915` |
| profiles | M1 | 74 / 0 | `faabeb64`, `m1-resume-1657` |

## Qualification still open

The both-slot M1 Release timing run at `116f70c3` measured History at
999.3 ms against the unchanged 1400 ms limit, main-thread lag 26.7 ms against
50 ms, and total import 1112.7 ms. Its idle CPU sample was 1.19% against <1%,
so the run failed. Start load was 4.65; it is not a quiet-machine qualification.
The earlier 1675 ms history failure at load 13.49 remains unqualified.

Quiet Release controls at `06f5139e` meet LEAD20:35: R2 History989.9/1400ms,
main lag29.4/50ms PASS, idle3.585% FAIL. R3 repeats idle3.161% FAIL;
`CrBrowserMain` used1.904% of a core. The active Welcome playlist explains
much of that work. A completed-Welcome control before import passes idle
at0.395%; its original post-import assertion is unchanged. Committed harness
qualification remains separate from this private control. The [written
finding](import-idle-attribution-2026-11-10.md) retains all raw misses and
states the exact quiet boundaries.

The strict `68f9b47e` Downloads run stopped at clear cancellation after66PASS;
Retry was not reached. A separate strict generic-quit run passed7/7 and
qualifies the per-launch stderr fix. At `06f5139e`, a reduced sequence also
reproduced the cancelled0-byte clear fixture while its source page was live.
Temporary destination/cancel tracing passed that sequence once and did not
establish a cause. No Downloads predicate or exception changed.

The intermittent E11, P-16, and clear-sequence failures remain recorded with
their guards. No exception covers them. Final-head full-gate qualification and
the M1 observer lane are still pending.
