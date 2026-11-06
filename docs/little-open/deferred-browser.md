# Deferred Little Open Browser

Section 9 decision: deferred Little Open Browser.

The bar is a command bar. Its first frame needs neither an engine Browser nor a page. A stable AppKit view occupies the container slot while those objects are absent. This also keeps the page path compatible with the pane-slot reuse merged in main `5916425d`.

The existing coordinator `onChange` feed runs after the window is ordered front. It draws and flushes that window's first transaction, then confirms its committed native refresh with the same one-shot display-link boundary as the App's first-window observer. `RunLoop.main.perform` queues Browser creation on the following main run-loop turn. The display link stops after that frame or on close; there is no timer, fixed delay, idle observer, or pre-warmed Browser pool. Profile replacement uses the same path. A transaction completion alone proved too early: in-process traces show Chrome tab creation can block the native first-frame callback before it runs.

The window owns one hidden Chrome `OEBrowser` and one tab after creation. A URL submitted before creation stays in one pending navigation slot. A later navigation replaces an earlier pending navigation, as it does in a live page. The factory seeds that URL before Chrome tab insertion, so creation can start the target directly. Native Return on the first event uses this path. External-link and Opt+Cmd-click entries also keep their URL until creation.

Before creation, `surfacePage` is nil, visibility is false, history has no page to record, and automation `browserID` is null. The committed-frame read records the absent Browser and page before construction. The independent timing probe keeps the original native display-link endpoint. Creation registers the engine host, starts its attached tab through `prepareForDisplay`, and fires coordinator `onChange` again for Section 6 discovery. The wrapper method uses the existing creation path directly after attachment; it avoids another automatic queue turn during the first URL input. It is idempotent and refuses pending popups, closed pages, and detached views. Closing clears the URL and prevents the weak commit/queued callback from creating a Browser. Live close still flushes history and closes the Browser once.

Section 11 must still consume `StandalonePageSurface` for dialogs and permission anchors. Section 6 owns extension delegates and popup anchors. Its merged #189 attachment runs from the same `onChange` feed once the host exists. Visibility updates retain the same native Browser window instead of repeatedly entering `SetHostView` for an unchanged window. Move to Space keeps the existing reload and factory ownership boundary.

## Timing method

Use `tools/e2e/littleopen_bench.py` under quiet then on-screen `lockf -k`, or `tools/e2e/littleopen_bench_series.py` under the outer quiet lock, with fresh App/profile/cache per sample, alternating pair order, automation Release, and the same engine and display. Every measured load1 must be at most 12. First frame uses the existing native display-link probe. Page load keeps PR #185's native-field submit to loading=false, document complete, and FCP endpoint. The series runner releases the screen lock after each complete interleaved pair. It waits for low load holding only the quiet lock; an entire incomplete pair is discarded solely if load1 exceeds 12. Every attempt is retained. `--pair-index` outputs are explicitly partial and cannot serve as aggregate acceptance. The series requires 10–100 samples per build and applies the same strict median/p95 gates. No warm-up delay is added before submit. Browser creation to page ready starts immediately before Browser construction and ends at that same page-ready observation; it can include the time before native submit.

The old synchronous receipt on engine `3f45b07b` compared main `ffcf4649` with branch `621c537f` (10 pairs, load1 8.57–9.80):

| Metric, median / p95 | Main | Synchronous branch | Gate |
|---|---:|---:|---|
| First native frame, ms | 73.73 / 82.52 | 78.80 / 110.37 | FAIL |
| Page load, ms | 99.47 / 416.51 | 88.30 / 175.68 | PASS |

The old per-window median RSS cost was 5.48 MiB. Memory uses App `totalRSS` (App and owned helpers), one loaded window minus baseline, after the existing 0.5 s fixture settle. This is not a long-duration soak.

Intermediate deferred receipts remain in `.re/surface-hook/`: attempt 1 passed first frame (58.60 / 62.45 ms versus 75.79 / 91.56 ms) but failed page load (102.43 / 140.23 ms versus 97.55 / 125.07 ms). Attempt 2 seeded the early URL before insertion; 20 pairs passed first frame and page-load p95 but missed page-load median by 2.23 ms (109.93 versus 107.69 ms). These earlier scheduling attempts are diagnostic. The final path confirms the native frame after flushing the window transaction before it queues Browser creation.

Display-link attempt 3 stopped at the declared load limit after 17 valid samples; transaction attempt 4 stopped after four. Neither is an acceptance receipt. A planned attempt 5 was canceled before sampling when main advanced. Final current-main acceptance, the memory table, and the final-head verification table are maintained in [PR #185](https://github.com/SergeSerb2/open/pull/185). The current control is main `8920190f` (including Find and Extensions UI #189), with engine `3f45b07b`. Both sides are rebuilt after that merge. The final branch also merges main `e83dc38f` (#190); that merge adds extension-shortcut acceptance and does not change the timing control's Little Open or key paths.

The complete current-main receipt before the run-loop and host-window corrections used 10 pairs at load1 8.11–9.83: first frame main 89.84/109.12 ms versus branch 91.75/157.76 ms, page load 131.63/193.65 ms versus 158.82/232.72 ms (FAIL). With `RunLoop.main.perform`, a separate 20-pair receipt at load1 9.70–11.91 passed first frame (main 77.55/91.60 ms, branch 71.63/79.18 ms), but page-load median still failed (main 104.46/136.41 ms, branch 112.05/131.19 ms). Neither failing receipt is replaced or counted as final acceptance. The host-window correction follows an in-process trace of 29–37 identical `setWindow:` calls per load, totaling 2–3 ms. A further 20-pair run against main `8920190f` with native-frame confirmation passes first frame (main 65.37/85.59 ms, branch 58.21/66.53 ms) but fails page load (main 100.39/119.43 ms, branch 148.82/178.57 ms), at load1 4.53–9.02. Browser creation to ready is 149.07/178.85 ms and added RSS is 5.38 MiB. A private in-process trace then locates the extra wrapper queue turn: tab creation begins 28.09 ms after submit and takes 14.17 ms; target load begins 51.65 ms after submit. The direct attached-tab creation correction removes that queue turn. Final acceptance remains the fresh uninstrumented gate in the PR.

The direct-creation run has 20 pairs at load1 5.59–9.09. First frame passes (main 76.09/91.61 ms; branch 58.83/73.26 ms), and page-load p95 passes (158.24 versus 139.72 ms). Page-load median still fails (107.45 versus 110.10 ms). Creation to ready is 124.95/156.03 ms; added RSS is 5.98 MiB. A separate experiment used the existing no-renderer option for the hidden blank tab. It worsens page load to 155.79/173.64 ms versus main 96.57/121.66 ms (20 pairs, load1 5.52–10.51), so that experiment and its configuration option are removed. No Chromium patch was changed. Skipping the pre-document background query was also tested separately and removed: 20 pairs at load1 5.63–8.17 gave main 66.89/88.44 ms versus branch 58.30/66.74 ms for first frame, but main 98.57/122.83 ms versus branch 125.94/152.90 ms for page load.

## Real-app race checks and negative proofs

The `littleopen` suite has 39 rows. Its new rows are `littleopen_browser_deferred`, `littleopen_submit_before_browser`, and `littleopen_close_before_browser`. They use the real window, command bar, native `OEApplication.sendEvent` path, engine, and automation socket. The deferred row also checks an external-link window. The close row lets the real creation callback continue after close, checks both Browser count and the cumulative Little Open creation count after later turns and checks the automation text bound at 8,192/8,193 UTF-8 bytes.

Native typing can pump nested AppKit work, and Return can wait for the real suggestion stream. An automation-only creation hook delivers typing/Return on the committed-frame creation turn, then lets that test's creation resume only after the real navigation intent reaches `load`. `submittedBeforeBrowser` excludes the internal `about:blank` placeholder. The check therefore proves an actual URL submission before Browser creation. This uses no fake page, mock engine, timer, or fixed delay. Normal creation takes no such hook.

Removing just `pendingURL = url` from the pre-Browser `load` branch makes `littleopen_submit_before_browser` FAIL: the recorded submission has `browserID=null`, `content=0`, and `submittedBeforeBrowser=true`, but the target never loads. The owned apps quit cleanly with zero focus interruptions. The fresh proof on the direct-creation code records the same failure, with zero focus interruptions and cleanup PASS (`deferred-final-negative-queue`). Exact source bytes are restored after each negative build. Removing only the first `!closed` guard in `createBrowser()` makes `littleopen_close_before_browser` FAIL even though final Browser count returns to baseline 1: cumulative Little Open Browser creations increase from 1 to 3. This proves the counter catches transient creation after close (`deferred-final-negative-close`, zero interruptions, cleanup PASS). Good Debug and automation Release builds pass after exact restoration. Earlier draft race probes did not distinguish pending command-bar Return from actual URL delivery; their apparent submit passes are not negative-proof evidence.

Restoring the three original App adapters from `621c537f` on main `5916425d` removes deferred creation. All 19 complete interleaved pairs stay at load1 6.22–10.56. Planned pair 20 exceeded the declared load limit and is excluded; no complete pair is selected by its timing outcome. The no-slower gate FAILs on page load:

| Metric, median / p95 | Main | Original synchronous adapter | Gate |
|---|---:|---:|---|
| First native frame, ms | 74.87 / 105.55 | 67.00 / 86.31 | PASS |
| Page load, ms | 97.58 / 163.63 | 156.60 / 501.51 | FAIL |

This control proves rejection by the combined timing gate; it does not prove a first-frame slowdown in that session. The old original receipt above separately records the first-frame failure. An earlier synchronous-init-only probe kept the new stable view and passed timing; it is diagnostic and is not used as the timing negative proof. Raw receipts remain in `.re/surface-hook/`.


A final transaction-completion/direct-creation experiment stops with only three complete pairs after sustained load1 above 12. Its two load-invalid incomplete pairs and all logs remain recorded. It has no acceptance verdict. The native-frame/direct-creation source is restored exactly before final builds and regressions.

## Final functional verification

After merging main `e83dc38f`, Debug and automation Release builds pass on engine `3f45b07b`. On the real AW2726DM (2560×1440, 1×), Little Open passes 39/39 three times, page-chrome 41/41, and Peek 42/42. These runs cover the reused container slot, late page installation, Profile replacement, native first-event Return, external intake, history, and close. All owned-process cleanup passes, with zero focus interruptions.

The merged Extensions UI suite has 47 PASS and one existing BLOCKED row, X13 (the App has no Site Control presenter). All three Little Open rows pass, including a real extension popup and `activeTab` execution. Invoke the runner with `python3` as documented; its isolated-Python shebang alone cannot import `extensions_ui` and stops before any App launch.

The `window` suite has 76 PASS and two known-main launch failures under CHILD-RULES 4h: cold/warm sidebar medians 360/362 ms, first paint 586/577 ms. All pixel rows pass. Cleanup passes with zero interruptions. The final full-verifier table and final timing receipt remain in PR #185; passing functional checks do not replace the strict timing gate.

## Final timing acceptance: FAIL

The final 30-pair receipt uses the retained native-frame/direct-creation path after merging main `e83dc38f`, compared with unchanged main `8920190f`. Engine is `3f45b07b`; every measured load1 is 8.32–11.98. Both timing endpoints and the memory method remain unchanged. All 30 complete pairs are included; load-invalid incomplete pairs remain in the attempt log.

| Metric, median / p95, ms | Main | Deferred branch | Gate |
|---|---:|---:|---|
| First native frame | 80.10 / 123.01 | 66.86 / 93.76 | PASS |
| Page load | 113.23 / 186.48 | 130.11 / 209.34 | FAIL |
| Browser creation to page ready | — | 146.63 / 229.81 | Diagnostic |

Added memory is **5.26 MiB/window**, compared with the original 5.48 MiB. Raw receipt: `.re/surface-hook/deferred-190-final-series-30.json`. The independent frame probe confirms creation follows the first native frame. The page-load acceptance is not met, so PR #185 remains draft even though the functional checks pass. No Chromium tree or patch was changed. Further performance work remains for the Section 9 lead; no new engine cause is claimed from these timings alone.
