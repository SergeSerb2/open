# Step 4 PiP evidence — review r1

The real AppKit PiP and Document PiP windows use the plan's fake video host.
All artwork is Open's own drawing or SF Symbols. The synthetic video is a
bitmap-backed gradient and size label; it cannot lose its tiled backing store
when the offscreen renderer clones a large 2× view. No Arc capture yet shows
these surfaces. Guesses stay guesses until capture session 2.

```sh
swift build --package-path Packages/OpenKit -c release -j 6
Packages/OpenKit/.build/release/features-render check
python3 Packages/OpenKit/MediaRenders/step4/render-scenes.py
```

The native-window checks pass **209/209**, including PP1–PP8 and the review
additions. They send native mouse events after hit testing, run real menu items,
and use actual finite animation and delayed-work completion. A plain click seeks
once without pause/resume; dragging pauses, fades the utility controls, keeps the
bar at 6 pt and resumes on release. Narrow labels truncate within the padding.

The first portrait frame is checked before any resize (160×285 native points;
AppKit rounds the ideal 160×284.444). Later opens reuse the last long side.
The maximum-size 9:16 case still respects the 50% cap with native one-point
rounding. A real presentWindows=true offscreen panel runs its source-rect spring,
reaches the target and alpha 1, completes Back to Tab exactly once, and closes
cleanly when interrupted during presentation. The focus check resigns the actual
key panel and verifies that both focus holds clear.

Idle offscreen process CPU: 0.020% over 2 s (budget 0.5%). Hidden, paused and
ordered-out states have no display link. No polling timer is used.

The square 2× snapshot check samples opacity across the video, including the
region that was transparent before. The rendered gallery covers the 160×284
minimum and scrubbing at 284 and 160 pt, plus the Document PiP Options hover.
Invalid size and state exit 1 without a PNG.

Native menus below dump the real NSMenu: order, separators, checkmarks, enabled
state, keys, modifiers and nesting. No menu preview is drawn. App source-tab and
Document PiP opener teardown remain required Step 10/11 lifecycle gates in the
plan. These fake-host checks prove effects after calls, not future App wiring.

Lead decisions: 02:38 click jump, refined at 09:23 to seek-only on a plain click;
02:47 preserve aspect and cap; 09:23 first-open fit and later long-side reuse;
03:11 native menu text only. All times are 2026-10-26 America/Vancouver.
The .25 full-window dim, unplated center cluster, and provisional meeting-row
packing remain Open design guesses pending S1/S11.

| Scene | 1× | 2× |
|---|---|---|
| compact-meeting | [PNG](compact-meeting@1x.png) | [PNG](compact-meeting@2x.png) |
| compact-paused | [PNG](compact-paused@1x.png) | [PNG](compact-paused@2x.png) |
| compact-playing | [PNG](compact-playing@1x.png) | [PNG](compact-playing@2x.png) |
| compact-precision-1 | [PNG](compact-precision-1@1x.png) | [PNG](compact-precision-1@2x.png) |
| compact-precision-3 | [PNG](compact-precision-3@1x.png) | [PNG](compact-precision-3@2x.png) |
| controls-hidden | [PNG](controls-hidden@1x.png) | [PNG](controls-hidden@2x.png) |
| document-hover | [PNG](document-hover@1x.png) | [PNG](document-hover@2x.png) |
| document | [PNG](document@1x.png) | [PNG](document@2x.png) |
| meet | [PNG](meet@1x.png) | [PNG](meet@2x.png) |
| portrait-meeting | [PNG](portrait-meeting@1x.png) | [PNG](portrait-meeting@2x.png) |
| portrait-minimum | [PNG](portrait-minimum@1x.png) | [PNG](portrait-minimum@2x.png) |
| portrait-precision-1 | [PNG](portrait-precision-1@1x.png) | [PNG](portrait-precision-1@2x.png) |
| portrait-precision | [PNG](portrait-precision@1x.png) | [PNG](portrait-precision@2x.png) |
| portrait | [PNG](portrait@1x.png) | [PNG](portrait@2x.png) |
| precision-1 | [PNG](precision-1@1x.png) | [PNG](precision-1@2x.png) |
| precision-3 | [PNG](precision-3@1x.png) | [PNG](precision-3@2x.png) |
| precision-8 | [PNG](precision-8@1x.png) | [PNG](precision-8@2x.png) |
| regular-ended | [PNG](regular-ended@1x.png) | [PNG](regular-ended@2x.png) |
| regular-paused | [PNG](regular-paused@1x.png) | [PNG](regular-paused@2x.png) |
| regular-playing | [PNG](regular-playing@1x.png) | [PNG](regular-playing@2x.png) |
| square | [PNG](square@1x.png) | [PNG](square@2x.png) |
| twitch | [PNG](twitch@1x.png) | [PNG](twitch@2x.png) |
| youtube | [PNG](youtube@1x.png) | [PNG](youtube@2x.png) |

46 PNGs total. Native menus: [regular](menu-regular.txt), [disabled](menu-disabled.txt), [host-less](menu-hostless.txt), [private disabled](menu-private-disabled.txt), [Document](menu-document.txt).

[Runtime receipt](features-check.txt) · [Build receipt](build.txt) · [PNG hashes and sizes](renders.json).
