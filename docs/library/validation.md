# Library validation

Status: not qualified for a PR. Five valid Release pairs are complete. One
Archive cold-switch sample exceeds its ceiling. The 10,000-row scroll also fails its zero-miss requirement. No final M5 gate or PR has been opened.

The native source is `28dbcfa4`. The Release executable SHA-256 is
`3d7784aea05a4137fa6193706cb39d3e1123ba1c1ba9c4a255dab08cd287fbe5`.
Runner `93a01341` used collector `b07ef7f2`; `9d813028` corrects raw idle
attribution under the lead's later ruling. No product code changed during
qualification. The first two complete pairs survived a collector interruption;
the receipt links the retained prefix and three new pairs. No performance
sample was discarded.

Every pair held all configured M1 heavy slots and the on-screen lock. Two
load1 readings ten seconds apart were at or below 3.5. Other process CPU and
later load are recorded without a rejection threshold. The fixture contains
1,000 downloads, 5,000 history entries and 2,000 archived tabs. All accepted
baseline and candidate launches quit normally with no owned process left.

Budget clocks end at the App commit that contains the complete first screen
or filtered result. They do not wait for the open animation to end.

| Metric | Median ms | Maximum ms | Median limit / sample ceiling ms | Result |
|---|---:|---:|---:|---|
| Prebuilt first commit | 6.621 | 8.944 | 8 / 12 | PASS |
| Complete first screen | 6.621 | 8.944 | 100 / 150 | PASS |
| Cold section | 33.013 | 138.038 | 50 / 75 | FAIL |
| Warm section | 4.424 | 6.342 | 8.3 / 12.45 | PASS |
| One-key search | 10.625 | 12.744 | 16 / 24 | PASS |
| Early cold open | 32.110 | 32.110 | 50 / 75 | PASS |

The failed Archive sample includes 108.597 ms in the awaited provider phase,
0.287 ms in background preparation and 7.818 ms in screen apply. Its final
layout/display/flush cost 0.050/0.006/0.023 ms. Provider elapsed time includes
store waits and actor resumption; this is not identified CPU work. The sample
had valid prerequisite loads 3.311/3.029. Its candidate-before load 4.388 and
end load 6.521 remain information. The sample stays in the result.

Configure p95 median 0.423 ms, maximum configure 1.081 ms and cold-apply median
8.116 ms are diagnostic INFO. They are not budget failures. All fifteen warm
switches configured and reloaded zero rows. Settled Library tasks, timers,
display links and animations were zero in all five pairs.

## Idle attribution

The five idle deltas were +1.353410, +0.005059, +1.629472, −0.004653 and
−0.032389 percentage points. The median, +0.005059, is below 0.05. The high
samples have main-thread deltas +0.249827/+0.240125. They need an explanation
regardless of the larger worker deltas. Their raw main-excess FAILs remain
in the corrected attribution table.

One extra fresh-fixture run swaps the order to open → closed → open at the
same elapsed intervals. It uses the same executable, row/search warm work,
30-second windows and 5.3-second transition settles. Its valid loads were
3.117/2.710. The burst moves to the closed window:

| App process/thread | Open 30.125–60.271 s | Closed 65.770–95.899 s | Open 101.389–131.543 s |
|---|---:|---:|---:|
| App CPU % | 0.251543 | 3.755798 | 0.157033 |
| Foreground worker % | 0.057845 | 2.682919 | 0.008646 |
| CrBrowserMain % | 0.098700 | 0.339888 | 0.082204 |
| Background worker % | 0.053855 | 0.182128 | 0.042836 |
| Chrome_IOThread % | 0.006037 | 0.071281 | 0.003051 |
| NetworkService utility % | 0.064641 | 0.276169 | 0.021666 |

This supports launch-time overlap for the observed burst pattern. The exact
internal Chromium job is not identified. No idle-specific product change was
made. All Library activity deltas and live gauges stayed zero. The static
about:blank page, first responder, window occlusion and animation lists were
stable within each window. Page-card widths stayed at 853 pt open and 1042 pt
closed. The layout-pass difference was one per window, from the explicit
boundary state read. There was no polling inside a CPU window.

Full top-ten thread tables, each process, utility subtypes and renderer client
IDs are retained privately. The socket does not expose renderer PID-to-page
mapping; the record shows one live about:blank page and two renderer PIDs,
without inventing a one-to-one mapping. Final attribution uses read-only
libproc and socket counters. An earlier use of sample, before the diagnostic
tool ruling arrived, is disclosed in the private L3 report; cell construction
counters independently re-confirm the reuse fix.

## Other evidence

Real-app Debug content checks pass 95/95. Application-route key checks pass
17/17 unique assertions. Native source drag start and file/URL pasteboards
pass; dropping into Finder or a web upload field remains a manual check.
The real 60-second release fired at 60.011958 seconds; short-delay release and
reopen checks also pass with the final editor. L3 frames use synthetic Open
data with the browser window key. Shared contrast findings remain in
[contrast.md](contrast.md), with the lead owning the theme-token follow-up.

Physical first/final pixel clocks are information. Their socket-dispatch
origin differs from the native operation clock, so subtracting the elapsed
times does not establish commit-to-compositor delay. Returning sidebar draw
had candidate median 288 ms and baseline median 327 ms; the paired deltas
were +9/+5/−20/−74/−267 ms. This is a five-pair observation, not proof of a
negative launch cost.

## 10,000-row scroll

One supported fixture contains ten profiles with 1,000 downloads each. The
short-root retry used valid loads 3.188/3.098. It completed 120 native display
callbacks and quit normally. Its App main-thread cost was 5.890 ms p95 and
17.168 ms maximum. Fourteen reusable cells handled 1,679 configurations.

The capture recorded 120 content changes and six missed 120 Hz intervals
(gaps of 16.667, 41.667 and 16.667 ms). Three initial Library callbacks cost
17.168, 10.476 and 8.564 ms, above an 8.333 ms frame. The later 39.880 ms
native callback interval occurred with a 4.695 ms measured callback; the
source of that late gap is not identified. The result does not prove zero
Library-attributable misses. Raw scroll verdict: FAIL.

| Callback index | Total ms | Formatting delta ms | Layout ms | Display ms | Flush ms | Unattributed remainder ms |
|---|---:|---:|---:|---:|---:|---:|
| 1 | 17.168 | 2.654 | 0.156 | 1.271 | 4.360 | 8.728 |
| 2 | 10.476 | 1.441 | 0.234 | 0.958 | 3.823 | 4.019 |
| 3 | 8.564 | 1.040 | 0.080 | 0.594 | 3.753 | 3.096 |
| 94 | 4.695 | 0.632 | 0.059 | 0.399 | 1.601 | 2.004 |

The remainder is elapsed work not covered by the existing phases, not a
measured function or an inferred cause. Index 1 configured fourteen rows and
constructed one cell. Other listed callbacks constructed none. The only
individually measured phase above 4 ms was the 4.360 ms flush.

The first independent scroll attempt stopped before measurement because its
nested macOS temporary path exceeded the Unix socket limit. It left no owned
app. The retry changed only that path to a short /tmp data root. The single
order-swapped idle diagnostic was not repeated.

Final audit: no owned App processes, timing jobs, capture helpers or D1 heavy
tickets. The branch is current with origin/main. The full M5 gate and PR wait
for the lead's ruling on the cold outlier and scroll. No budget was relaxed,
no measured sample was discarded and no product optimisation followed these
new failures.
