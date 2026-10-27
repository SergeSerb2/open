# Site Control Step 1: capture-session-2 migration

These are Open's synthetic offscreen renders. No reference frames, crops, private backdrop images, or personal data are committed.

The body reserves the measured 297 pt no-Boosts stack. Step 2 adds its section views. Each of the four states is rendered in Light/Dark at 1x/2x. The probe backdrop stays #252538 beside a white page in both modes, per plan §8.1; Light material values remain guesses.

- `SHA256SUMS`: receipts for all 16 synthetic renders, verified by `sitecontrol-render check`.
- `motion/`: actual presentation-layer open/close frames, with separate SHA-256 receipts.
- `accessibility.txt`: native AX hierarchy; the host occurs once.
- `checks.txt`: native event flows, render probes, receipts, and the open benchmark.
- `comparison-base.md`: numeric sRGB element results against S2 09/0010.
- `comparison-hover.md`: numeric results against S2 09/0016; the Share-glyph comparison is deferred per the lead ruling of 2026-10-26 because the recorder saved no pointer coordinates or mouse-button state. Its raw ΔE remains in the table; the fixed glyph is unchanged.

The comparison excludes Step 2 sections. Arrow rows use only the outside left/right ring strips to avoid neighboring arrow ink. Wells spanning the sidebar/page boundary use column-local affine ring backgrounds, so the boundary does not count as well ink. Ring color averages the straight portions of all four edges. The classification and acceptance thresholds remain 50% contrast, 85% core, 1 pt position, and ΔE00 2 for non-text elements.

The fitted glow exists only in `sitecontrol-render/MaterialFallback.swift`. Interior weights 0.28/0.28/0.21, tint #49475A, sigma 5, and the live white 0.20 rim remain unchanged. Plan §3.2 records the fitted constants and fit/held-out edge results. Synthetic fallback bitmaps are cached as fixture resources (32 entries maximum); capture comparisons always generate fresh surfaces. The benchmark still constructs, lays out, and displays every native panel, including its NSVisualEffectView.

S11–S13 and the real-app snapshot compare are deferred to Step 3 per plan §12/§11. No App hook is part of this PR.
