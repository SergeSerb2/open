# S5b counted gate on the M5 (2026-10-27)

Branch head after merging `origin/main` 41aef97: `2257a687`. Machine: Apple M5 Pro, macOS 27.2 (26B5112a).
The M5's main display was the built-in 2x panel during this run (`system_profiler SPDisplaysDataType`: only "Color LCD"); the
1x AW2726DM that recorded the pixel fixtures was not connected.

| Name | Result | Seconds |
|---|---|---:|
| build | PASS | 86 |
| commands-demo | PASS | 2 |
| roundtrip | PASS | 0 |
| space-legacy | FAIL | 1 |
| space-editor | FAIL | 3 |
| space-pad-compare | PASS | 2 |
| suggest-check | PASS | 13 |
| commands-dump | PASS | 1 |
| route | PASS | 2 |
| favicons | PASS | 2 |
| media-demo | PASS | 1 |
| sleep-demo | PASS | 0 |
| adblock-perf | PASS | 1 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 3 |
| settings-preview | PASS | 80 |
| sidebar-render | PASS | 105 |
| sidebar-compare | FAIL | 93 |
| commandbar-render | PASS | 15 |
| features-render | PASS | 24 |
| sitecontrol-render | FAIL | 50 |
| boosts | PASS | 3 |

The four FAIL rows are environment rows, not S5b rows:

- `space-legacy`, `space-editor` (P1 byte-identical legacy PNGs) and `sidebar-compare` (absolute color gates of
  static-inactive, selected-pinned, yellow; position/ink identical, 0 ΔE00 drift between paired runs) fail the same way on
  untouched `main` 41aef97 in a clean worktree on this machine. The branch and main render `legacy-space-0.png`
  byte-identical (SHA-256 `cdcfe791…87e1b`); it differs from the committed fixture in 575 of 630,000 pixels, all in
  text and glyph ink. These are the display-portability gates owned by section 16 (`docs/followups.md`,
  "Verification (portability)").
- `sitecontrol-render`: only "simple editor build/layout/first draw p95 < 12 ms" fails. The same check on main and
  on this branch swings between 11.6 and 19.6 ms in alternating runs at load1 4.5–6.6 (branch 11.9 / 13.6 / 14.7 / 19.6 ms;
  main 11.6 / 12.1 / 16.9 ms). S5b changes no Site Control code. Filed in `docs/followups.md`.

Real App (Debug, engine framework SHA-256 `61c9ab17…b98a8`, `tools/e2e/settings_previews.py`):
normal flow PASS ("General → Previews, three switches, disabled source, persisted choices, Done; stored delay retained"),
cleanup PASS; forced failure exits 1 with `FORCED: early failure while the real Previews sheet is open`, cleanup PASS,
no remaining windows or processes, roots removed.
