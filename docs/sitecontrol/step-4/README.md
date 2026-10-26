# Step 4: native Boost editor, review round 2

The editor keeps the existing Profile BoostStore and matcher. All sites, page pixels, and preferences in these fixtures are synthetic.

The 23 states cover light/dark at 1x/2x (92 PNGs). [SHA256SUMS](SHA256SUMS) binds every PNG. The real harness checks the receipts, native event flows, real AX hierarchy, on-disk commit/delete durability, legacy undo, saved IP/path scope, and performance budgets.

The font strip keeps 56 pt chips and 6 pt gaps. Its 232 pt viewport scrolls, has a trailing fade, and fully reveals the keyboard-focused chip, per the lead's 2026-10-26 10:00 decision.

Menu and sheet contact sheets use AppKit's native view capture, composited beside the editor. The opaque plate replaces the WindowServer material unavailable to offscreen rendering; it is evidence layout only. The editor itself is captured with Core Animation/Metal. Hover fixtures set the native hover state; press and keyboard fixtures use window.sendEvent.

| State | Light 1x | Light 2x | Dark 1x | Dark 2x |
|---|---|---|---|---|
| editor-interstitial | [light 1x](editor-interstitial-light@1x.png) | [light 2x](editor-interstitial-light@2x.png) | [dark 1x](editor-interstitial-dark@1x.png) | [dark 2x](editor-interstitial-dark@2x.png) |
| editor-simple | [light 1x](editor-simple-light@1x.png) | [light 2x](editor-simple-light@2x.png) | [dark 1x](editor-simple-dark@1x.png) | [dark 2x](editor-simple-dark@2x.png) |
| editor-advanced-color | [light 1x](editor-advanced-color-light@1x.png) | [light 2x](editor-advanced-color-light@2x.png) | [dark 1x](editor-advanced-color-dark@1x.png) | [dark 2x](editor-advanced-color-dark@2x.png) |
| editor-neutral-page | [light 1x](editor-neutral-page-light@1x.png) | [light 2x](editor-neutral-page-light@2x.png) | [dark 1x](editor-neutral-page-dark@1x.png) | [dark 2x](editor-neutral-page-dark@2x.png) |
| editor-not-active | [light 1x](editor-not-active-light@1x.png) | [light 2x](editor-not-active-light@2x.png) | [dark 1x](editor-not-active-dark@1x.png) | [dark 2x](editor-not-active-dark@2x.png) |
| editor-global-off | [light 1x](editor-global-off-light@1x.png) | [light 2x](editor-global-off-light@2x.png) | [dark 1x](editor-global-off-dark@1x.png) | [dark 2x](editor-global-off-dark@2x.png) |
| editor-legacy | [light 1x](editor-legacy-light@1x.png) | [light 2x](editor-legacy-light@2x.png) | [dark 1x](editor-legacy-dark@1x.png) | [dark 2x](editor-legacy-dark@2x.png) |
| editor-menu | [light 1x](editor-menu-light@1x.png) | [light 2x](editor-menu-light@2x.png) | [dark 1x](editor-menu-dark@1x.png) | [dark 2x](editor-menu-dark@2x.png) |
| editor-scope-host | [light 1x](editor-scope-host-light@1x.png) | [light 2x](editor-scope-host-light@2x.png) | [dark 1x](editor-scope-host-dark@1x.png) | [dark 2x](editor-scope-host-dark@2x.png) |
| editor-scope-ip | [light 1x](editor-scope-ip-light@1x.png) | [light 2x](editor-scope-ip-light@2x.png) | [dark 1x](editor-scope-ip-dark@1x.png) | [dark 2x](editor-scope-ip-dark@2x.png) |
| editor-rename | [light 1x](editor-rename-light@1x.png) | [light 2x](editor-rename-light@2x.png) | [dark 1x](editor-rename-dark@1x.png) | [dark 2x](editor-rename-dark@2x.png) |
| editor-reset | [light 1x](editor-reset-light@1x.png) | [light 2x](editor-reset-light@2x.png) | [dark 1x](editor-reset-dark@1x.png) | [dark 2x](editor-reset-dark@2x.png) |
| editor-delete | [light 1x](editor-delete-light@1x.png) | [light 2x](editor-delete-light@2x.png) | [dark 1x](editor-delete-dark@1x.png) | [dark 2x](editor-delete-dark@2x.png) |
| editor-double-banner | [light 1x](editor-double-banner-light@1x.png) | [light 2x](editor-double-banner-light@2x.png) | [dark 1x](editor-double-banner-dark@1x.png) | [dark 2x](editor-double-banner-dark@2x.png) |
| editor-hover-side | [light 1x](editor-hover-side-light@1x.png) | [light 2x](editor-hover-side-light@2x.png) | [dark 1x](editor-hover-side-dark@1x.png) | [dark 2x](editor-hover-side-dark@2x.png) |
| editor-pressed-side | [light 1x](editor-pressed-side-light@1x.png) | [light 2x](editor-pressed-side-light@2x.png) | [dark 1x](editor-pressed-side-dark@1x.png) | [dark 2x](editor-pressed-side-dark@2x.png) |
| editor-focus-side | [light 1x](editor-focus-side-light@1x.png) | [light 2x](editor-focus-side-light@2x.png) | [dark 1x](editor-focus-side-dark@1x.png) | [dark 2x](editor-focus-side-dark@2x.png) |
| editor-hover-chip | [light 1x](editor-hover-chip-light@1x.png) | [light 2x](editor-hover-chip-light@2x.png) | [dark 1x](editor-hover-chip-dark@1x.png) | [dark 2x](editor-hover-chip-dark@2x.png) |
| editor-pressed-chip | [light 1x](editor-pressed-chip-light@1x.png) | [light 2x](editor-pressed-chip-light@2x.png) | [dark 1x](editor-pressed-chip-dark@1x.png) | [dark 2x](editor-pressed-chip-dark@2x.png) |
| editor-focus-chip | [light 1x](editor-focus-chip-light@1x.png) | [light 2x](editor-focus-chip-light@2x.png) | [dark 1x](editor-focus-chip-dark@1x.png) | [dark 2x](editor-focus-chip-dark@2x.png) |
| editor-hover-tile | [light 1x](editor-hover-tile-light@1x.png) | [light 2x](editor-hover-tile-light@2x.png) | [dark 1x](editor-hover-tile-dark@1x.png) | [dark 2x](editor-hover-tile-dark@2x.png) |
| editor-pressed-tile | [light 1x](editor-pressed-tile-light@1x.png) | [light 2x](editor-pressed-tile-light@2x.png) | [dark 1x](editor-pressed-tile-dark@1x.png) | [dark 2x](editor-pressed-tile-dark@2x.png) |
| editor-focus-tile | [light 1x](editor-focus-tile-light@1x.png) | [light 2x](editor-focus-tile-light@2x.png) | [dark 1x](editor-focus-tile-dark@1x.png) | [dark 2x](editor-focus-tile-dark@2x.png) |

Verification receipts: [focused checks](checks.txt), [full gate](verify-all.txt), [AX hierarchy](accessibility.txt). The PR body maps each review item to its change. All geometry remains a plan guess pending capture session 2.

## Final verification, 2026-10-26

Tested code: e5ba994bbe7cf9aa6790e74b8ebed63283e889fd. The stack contains origin/main
15e261e4fe06fb77149ddda446b9e4f0522490b8, #69 and #96 through merge commits.
The full gate passes 16/17 rows. Site Control passes 1149/1152 checks; only timing checks fail.
All native flows, real rendered contrast/hollow-marker checks, AX, render receipts and the
Boosts browser harness pass. The first full gate is retained in review-r2-initial-*;
its first-popup capture race was fixed in #96 and is clear in the final run.

| Failed timing | Measured | Budget |
|---|---|---|
| SCC first draw CPU p95 | 11.872 ms | <8 ms |
| SCC first draw wall p95 | 13.240 ms | <8 ms |
| Simple editor open p95 | 16.799 ms | <12 ms |

Timing budgets failed under heavy machine load (lead exception, 2026-10-26). Rerun before merge.

Full drag frame (native event + display) p95 1.486 ms, max 3.258 ms (100 frames;
diagnostic, no separate plan budget). Wheel event p95 0.078 ms against <2 ms;
59 previews during a one-second 120 Hz drag; idle main-thread CPU 1.585 ms in two seconds;
ten-page refresh max 0.123 ms; off-main hue sampling 6.897 ms. Dark first-run rendered contrast:
title 11.19:1, body 5.16:1, footer label 10.24:1.
