# Deferred Little Open Browser

Section 9 decision: deferred Little Open Browser.

The bar is a command bar. Its first frame needs neither an engine Browser nor a page. A stable AppKit view occupies the container slot while those objects are absent. This also keeps the page path compatible with the pane-slot reuse merged in main `5916425d`.

The existing coordinator `onChange` feed runs after the window is ordered front. It draws and commits that window's first `CATransaction`. The commit completion queues Browser creation on the next main run-loop turn. There is no production display link, timer, fixed delay, or pre-warmed Browser pool. Profile replacement uses the same path.

The window owns one hidden Chrome `OEBrowser` and one tab after creation. A URL submitted before creation stays in one pending navigation slot. A later navigation replaces an earlier pending navigation, as it does in a live page. The factory seeds that URL before Chrome tab insertion, so creation can start the target directly. Native Return on the first event uses this path. External-link and Opt+Cmd-click entries also keep their URL until creation.

Before creation, `surfacePage` is nil, visibility is false, history has no page to record, and automation `browserID` is null. The committed-frame read records the absent Browser and page before construction. The independent timing probe keeps the original native display-link endpoint. Creation registers the engine host and fires coordinator `onChange` again for Section 6 discovery. Closing clears the URL and prevents the weak commit/queued callback from creating a Browser. Live close still flushes history and closes the Browser once.

Section 11 must still consume `StandalonePageSurface` for dialogs and permission anchors. Section 6 owns extension delegates, popup anchors, and its real extension acceptance. Move to Space keeps the existing reload and factory ownership boundary.

## Timing method

Use `tools/e2e/littleopen_bench.py` under quiet then on-screen `lockf -k`, or `tools/e2e/littleopen_bench_series.py` under the outer quiet lock, with fresh App/profile/cache per sample, alternating pair order, automation Release, and the same engine and display. Every measured load1 must be at most 12. First frame uses the existing native display-link probe. Page load keeps PR #185's native-field submit to loading=false, document complete, and FCP endpoint. The series runner releases the screen lock after each complete interleaved pair. It waits for low load holding only the quiet lock; an entire incomplete pair is discarded solely if load1 exceeds 12. Every attempt is retained. `--pair-index` outputs are explicitly partial and cannot serve as aggregate acceptance. The series requires 10–100 samples per build and applies the same strict median/p95 gates. No warm-up delay is added before submit. Browser creation to page ready starts immediately before Browser construction and ends at that same page-ready observation; it can include the time before native submit.

The old synchronous receipt on engine `3f45b07b` compared main `ffcf4649` with branch `621c537f` (10 pairs, load1 8.57–9.80):

| Metric, median / p95 | Main | Synchronous branch | Gate |
|---|---:|---:|---|
| First native frame, ms | 73.73 / 82.52 | 78.80 / 110.37 | FAIL |
| Page load, ms | 99.47 / 416.51 | 88.30 / 175.68 | PASS |

The old per-window median RSS cost was 5.48 MiB. Memory uses App `totalRSS` (App and owned helpers), one loaded window minus baseline, after the existing 0.5 s fixture settle. This is not a long-duration soak.

Intermediate deferred receipts remain in `.re/surface-hook/`: attempt 1 passed first frame (58.60 / 62.45 ms versus 75.79 / 91.56 ms) but failed page load (102.43 / 140.23 ms versus 97.55 / 125.07 ms). Attempt 2 seeded the early URL before insertion; 20 pairs passed first frame and page-load p95 but missed page-load median by 2.23 ms (109.93 versus 107.69 ms). The final version uses the lead-approved transaction-commit callback instead of waiting for a second display-link observation.

Display-link attempt 3 stopped at the declared load limit after 17 valid samples; transaction attempt 4 stopped after four. Neither is an acceptance receipt. A planned attempt 5 was canceled before sampling when main advanced. Final current-main acceptance, the memory table, and the final-head verification table are maintained in [PR #185](https://github.com/SergeSerb2/open/pull/185). The final comparison includes main `4ac8566a` (Find and Section 11 docs) and engine `3f45b07b`.

## Real-app race checks and negative proofs

The `littleopen` suite has 39 rows. Its new rows are `littleopen_browser_deferred`, `littleopen_submit_before_browser`, and `littleopen_close_before_browser`. They use the real window, command bar, native `OEApplication.sendEvent` path, engine, and automation socket. The deferred row also checks an external-link window. The close row checks Browser count after later turns and checks the automation text bound at 8,192/8,193 UTF-8 bytes.

Native typing can pump nested AppKit work, and Return can wait for the real suggestion stream. An automation-only creation hook delivers typing/Return on the committed-frame creation turn, then lets that test's creation resume only after the real navigation intent reaches `load`. `submittedBeforeBrowser` excludes the internal `about:blank` placeholder. The check therefore proves an actual URL submission before Browser creation. This uses no fake page, mock engine, timer, or fixed delay. Normal creation takes no such hook.

Removing just `pendingURL = url` from the pre-Browser `load` branch makes `littleopen_submit_before_browser` FAIL: the recorded submission has `browserID=null`, `content=0`, and `submittedBeforeBrowser=true`, but the target never loads. The owned apps quit cleanly with zero focus interruptions. Exact source bytes are restored after the negative build. Earlier draft race probes did not distinguish pending command-bar Return from actual URL delivery; their apparent submit passes are not negative-proof evidence.

Restoring the three original App adapters from `621c537f` on main `5916425d` removes deferred creation. All 19 complete interleaved pairs stay at load1 6.22–10.56. Planned pair 20 exceeded the declared load limit and is excluded; no complete pair is selected by its timing outcome. The no-slower gate FAILs on page load:

| Metric, median / p95 | Main | Original synchronous adapter | Gate |
|---|---:|---:|---|
| First native frame, ms | 74.87 / 105.55 | 67.00 / 86.31 | PASS |
| Page load, ms | 97.58 / 163.63 | 156.60 / 501.51 | FAIL |

This control proves rejection by the combined timing gate; it does not prove a first-frame slowdown in that session. The old original receipt above separately records the first-frame failure. An earlier synchronous-init-only probe kept the new stable view and passed timing; it is diagnostic and is not used as the timing negative proof. Raw receipts remain in `.re/surface-hook/`.

