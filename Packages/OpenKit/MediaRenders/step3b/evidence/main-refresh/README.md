# Main merge verification

Merged main `9e3473c` with a merge commit. The three conflicts were
`MediaControlsView.swift`, `Checks.swift` and `MediaChecks.swift`. Keep the
33/66/99 pt redesign, motion/lifecycle fixes, single-card hover and drawer prune;
retain main’s scheduled-collapse delay receipt, condition-based waits and UUID
preferences suite. `cancelCollapse()` clears both the work item and its delay.
No engine source or key routing was changed by the resolution.

`tools/verify-all.sh`: **20/20 PASS**, no skips or retries, through `heavy.sh`
in a detached session. `sidebar-render check`: **559 PASS, 0 FAIL**.
Focused motion: **49/49**; lifecycle: **30/30**. Two concurrent full sidebar
runs with separate temporary directories and UUID preferences suites each pass
**559/559**. Invalid state/hover CLI cases each exit 1 without writing a PNG.
MC8 idle CPU: **0.023%**, collapsed 33 pt, no idle animation keys or collapse work.

MC9: **PASS**, 12 interleaved pairs against pinned main `9e3473c`, with
`/tmp/open-onscreen-e2e.lock` held across the whole series, after all builds and
focused checks finished. Paired median delta **-0.705 ms**;
20%-trimmed mean **-0.520 ms** (limit +0.3 ms).
Baseline/head median p95: 4.035/3.465 ms.
Three-card report-only p95: 4.11 ms.

All 62 synthetic PNGs were regenerated (62/62 byte-identical to the
previous receipt). R1–R4 numeric comparisons remain unchanged. R3/R4 are the
previously accepted measurement artifacts. No Arc pixels or real-title PNGs
were committed. The renderer hash matches MC9, the render manifest and full
verification.

C5’s real-pointer check and Step 6 real-window snapshots remain pending;
§8.5, `docs/followups.md` and the PR checklist state that scope explicitly.
Historical negative-control receipts describe their original frozen harnesses;
this refresh retains their defect gates and adapts the delay assertions to main.

[Full verification table](../verify-summary.md), [full sidebar flow](../sidebar-check.log),
[focused motion](motion.log), [focused lifecycle](lifecycle.log),
[concurrent runs](concurrent.json), [CLI failures](parser-smoke.json),
[self-review checklist](review-checklist.md), [receipt](receipt.json), [MC9](../mc9.json).
