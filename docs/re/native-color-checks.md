# Native color checks (2026-11-13)

These checks use the M1 built-in display at 2×, 1512×982 pt / 3024×1964 px,
120 Hz. Its normalized ICC SHA-256 is
`ced527b7482d75a039b583d3a6b856fb4e3f0c26010e4258ba770e17b142e844`,
the existing `icc-header-v1` key in `docs/verification.md`. All samples below
convert the screenshot's embedded profile to sRGB.

## Site Control light fixture

The reference is Arc 1.172.2 capture session 2, `14c-sidebar-url/s2-sidebar-site-control`:
gold sidebar `#B9A35F`, page `#F3F5EE`, 1280×800 pt window, 366 pt sidebar.
The fixture key `#BD9C26` was an Open input fitted to that visible sidebar,
not an observed Arc editor key (private `D3-report-k1.md`, fixture description).

PR #344, merge `10de0d07`, changed light editor themes to the measured sRGB
blend over 0.91 (`ThemeField.Evaluator`, `SidebarThemeRules`). The old fixture
key then produced a brighter sidebar. The material check continued to compare
against the original scene's panel colors.

On unchanged App head `788a277c`, engine `b0cb685a`, restoring the reference
sidebar color through the new law changed the body-left error from 3.64 to
0.35 ΔE00 and the footer-chip error from 3.62 to 0.32. The other material samples,
the closed-panel negative, the no-ghost check and the neutral-theme check passed.
Evidence: private `imc-color-drift/gold-probe/results-sitecontrol-release.json`
and E3's `e3-gate-part2-788a277c` retry receipts.

The synthetic fixture now uses `#9F7C12`. It also checks the visible sidebar
against `#B9A35F` within 1 ΔE00 before accepting the material result. Material
targets and their 3 ΔE00 limits are unchanged.

The retained green `cd048f14` Release executable (SHA-256
`13da425e90ee664de83f9e2c4fa15127bda81b25f9b986eebcf4bfe4ab711afe`)
still passes the old fixture on this display, with exactly the original sample
means. Evidence: private `imc-color-drift/{green-cd048,old-sitecontrol}` receipts.
This control does not support an environment-drift explanation.

## Sidebar glyph coverage

The reference is Arc 1.170.0 `F0001` (`20261024-213009-session-full`,
`0001-213009/win-5245.png`). The real-App comparison converts both images to
sRGB and compares core ink after reducing Open's native 2× screenshot to 1×.

The unchanged retained `cd048f14` binary already misses the toggle (2.38 ΔE00)
and New Tab plus (3.65). At `788a277c`, the toggle stays 2.38 and the plus improves
to 2.48. These are older glyph coverage mismatches, not regressions from engine
#532. Evidence: private `imc-color-drift/old-sidebar` and E3 retry receipts.

The toggle now uses SF `sidebar.left` at 16 pt Medium, and New Tab uses SF `plus`
at 13.5 pt Medium. Role opacities and the drawing path are unchanged. The native
real-App comparison passes all 31 elements at the original limits (position
≤1 pt, color ≤2 ΔE00); its worst color error is 1.22. Evidence: private
`imc-color-drift/glyph-probe` receipt. These are SF configuration changes; no
reference image or extracted asset is included in the product.
