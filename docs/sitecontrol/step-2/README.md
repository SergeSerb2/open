# Site Control Step 2

Capture-session-2 library migration: Extensions → optional Boosts → Settings, the Extensions “+” fallback, native row circles with real glyph cut-outs, section hover actions, reload row, and the captured native menu. The panel's material/chrome and arrow-tip spring come from merged Step 1.

The 104 synthetic Light/Dark 1x/2x renders and 20 native presentation frames have SHA-256 receipts. `sitecontrol-render check` verifies the 104 committed still receipts. `motion/SHA256SUMS` records the presentation captures. All frames here contain Open-only synthetic content; no Arc frame, private backdrop, or personal data is committed.

Latest focused results: 90/90 native flows; 1048/1048 pixel/geometry probes; base comparison 62 PASS; qualified hover comparison 61 PASS plus the one explicitly deferred Share-glyph comparison; Boost comparison 5 PASS. Thresholds are unchanged: maximum ink-box edge error 1 pt, non-text ΔE00 ≤2, material ΔE00 ≤3. See `comparison-base.md`, `comparison-hover.md`, and `comparison-boost.md`.

Flows send clicks and keys through the native window. They cover tracked NSMenu Return/Clear Cookies and Esc cancellation, Command guards, requested picker mode, stale menu generations, nonzero AX heading frames, host exposed once, and newly visible Settings title pixels after scrolling. The native hierarchy keeps every row and focus target. Drawing is lazy only while a row is clipped. Motion checks read configured durations before sampling and check fixed arrow tips/action positions.

The dark separator uses the captured additive +35 RGB rule, not the earlier white 0.22 guess. The global-off note uses the lead-approved 28 pt guessed band, baselines +11/+26; Reload remains +20. Outside/anchor dismissal stays immediate because the available captures do not resolve a fade. The qualified Share comparison remains “hover or press, unconfirmed”.

`performance/README.md` contains five-pair main-thread instruction measurements and numeric profiler attribution. The 8 ms CPU gate remains unchanged; wall time is diagnostic. Instruction counts do not replace that gate.

S11–S13 and the real-app snapshot comparison are deferred to Step 3 per plan §12/§11. This PR adds no app hook. The latest full-gate result is recorded separately in `verify-all.txt`.
