# Step 4 PiP evidence — review r2

The real AppKit PiP and Document PiP windows use only the plan's fake video host.
All images are Open's synthetic gradient, size label, and SF Symbols. No Arc
frame is copied. Capture session 2 item 13 supplies the lead's sizing/inset
measurement; its hover controls did not appear, so control styles remain guesses.

```sh
swift build --package-path Packages/OpenKit -c release -j 6
Packages/OpenKit/.build/release/features-render check
python3 Packages/OpenKit/MediaRenders/step4/render-scenes.py
```

The native-window check passes **254/254**, including PP1–PP8, real animated
present/dismiss and interrupted-close paths, menu actions, seek-only click,
precision drag, focus resignation, the 168 pt boundary, and faded-utility
hit/handler suppression. The latter keeps the active scrub gesture: a second
window-level mouse-down would replace AppKit's drag capture, so the check asserts
real hit-test exclusion and then the guarded handlers directly.

First-open sizing now fits the natural aspect inside visibleFrame / 8, clamps
to the orientation-aware minimum (284×160 landscape / 160×284 portrait), and
uses 10 pt bottom-right insets. Later opens reuse the last long side and origin,
clamped. Document PiP keeps its provisional 16 pt inset in a separate token.
The /8 factor fits **one** data point: capture session 2 item 13,
`.re/runtime/sessions/20261026-103015-13-auto-pip`, whose lead-provided measurement
is 16:9 at 320×180, screen top-left (2230,1250), on 2560×1440. It is exact there
and a guess elsewhere. These raw frames stay local.

PP6 runs each orientation/screen pair in a fresh real CLI process, so static
lastFrame cannot contaminate the first frame. It reads window.frame before any
explicit resize, probes the minimum, and records both. One-point AppKit native
frame rounding is allowed while the natural contentAspectRatio stays set.
The first portrait fixture in the parent process must also remain ahead of any
fixture that resizes PiP; this ordering requirement is commented in the harness.

| Screen | First landscape | Minimum landscape | First portrait | Minimum portrait | Right / bottom |
|---|---|---|---|---|---|
| 1600×900 | 285×160 | 285×161 | 160×285 | 160×285 | 10 / 10 |
| 1796×1010 | 285×160 | 285×161 | 160×285 | 160×285 | 10 / 10 |
| 1920×1080 | 285×160 | 285×161 | 160×285 | 160×285 | 10 / 10 |
| 2560×1440 | 320×180 | 285×161 | 160×285 | 160×285 | 10 / 10 |
| 2844×1600 | 356×200 | 285×161 | 160×285 | 160×285 | 10 / 10 |
| 3840×2160 | 480×270 | 285×161 | 160×285 | 160×285 | 10 / 10 |

All twelve [native geometry JSON reports](geometry/) are reproduced by the script.
The observed 2560×1440 case is exactly 320×180 at top-left (2230,1250).
The 1920×1080 fit is below the minimum and clamps; native first frame is 285×160
(ideal minimum box 284×160, with aspect preservation and native rounding).
Portrait frames are 160×285 native points on all six heights, within one point
of the 160×284 minimum box.

Review-r2 control changes: Play/Pause 28/24 pt, Skip 20/16 pt; a cached black .35
shadow, radius 2 and zero offset, on the five center glyphs only (guess). A live
cacheDisplay probe finds the shadow on each. Disabled Skip ahead has no plate
or grow and keeps its tooltip. The precision hint fades in/out in .15 s with
the utilities and never intercepts hits. Document buttons press with white .18.
The updated gallery includes disabled hover and Document pressed states.

Idle offscreen process CPU: 0.042% over 2 s (budget 0.5%). Hidden, paused and
ordered-out states have no display link. No polling timer is used.

The large 2× square stays opaque. Invalid size and state exit 1 without a PNG.
Menu files dump the real NSMenu with order, separator/checkmark/enabled states,
keys, modifiers and nesting. No menu preview is drawn. Source-tab and Document
opener teardown remain future App gates in plan Steps 10/11.

| Scene | 1× | 2× |
|---|---|---|
| compact-meeting | [PNG](compact-meeting@1x.png) | [PNG](compact-meeting@2x.png) |
| compact-paused | [PNG](compact-paused@1x.png) | [PNG](compact-paused@2x.png) |
| compact-playing | [PNG](compact-playing@1x.png) | [PNG](compact-playing@2x.png) |
| compact-precision-1 | [PNG](compact-precision-1@1x.png) | [PNG](compact-precision-1@2x.png) |
| compact-precision-3 | [PNG](compact-precision-3@1x.png) | [PNG](compact-precision-3@2x.png) |
| controls-hidden | [PNG](controls-hidden@1x.png) | [PNG](controls-hidden@2x.png) |
| document-hover | [PNG](document-hover@1x.png) | [PNG](document-hover@2x.png) |
| document-pressed | [PNG](document-pressed@1x.png) | [PNG](document-pressed@2x.png) |
| document | [PNG](document@1x.png) | [PNG](document@2x.png) |
| first-open-landscape-clamped | [PNG](first-open-landscape-clamped@1x.png) | [PNG](first-open-landscape-clamped@2x.png) |
| first-open-landscape | [PNG](first-open-landscape@1x.png) | [PNG](first-open-landscape@2x.png) |
| first-open-portrait | [PNG](first-open-portrait@1x.png) | [PNG](first-open-portrait@2x.png) |
| meet | [PNG](meet@1x.png) | [PNG](meet@2x.png) |
| portrait-meeting | [PNG](portrait-meeting@1x.png) | [PNG](portrait-meeting@2x.png) |
| portrait-minimum | [PNG](portrait-minimum@1x.png) | [PNG](portrait-minimum@2x.png) |
| portrait-precision-1 | [PNG](portrait-precision-1@1x.png) | [PNG](portrait-precision-1@2x.png) |
| portrait-precision | [PNG](portrait-precision@1x.png) | [PNG](portrait-precision@2x.png) |
| portrait | [PNG](portrait@1x.png) | [PNG](portrait@2x.png) |
| precision-1 | [PNG](precision-1@1x.png) | [PNG](precision-1@2x.png) |
| precision-3 | [PNG](precision-3@1x.png) | [PNG](precision-3@2x.png) |
| precision-8 | [PNG](precision-8@1x.png) | [PNG](precision-8@2x.png) |
| regular-ended-hover | [PNG](regular-ended-hover@1x.png) | [PNG](regular-ended-hover@2x.png) |
| regular-ended | [PNG](regular-ended@1x.png) | [PNG](regular-ended@2x.png) |
| regular-paused | [PNG](regular-paused@1x.png) | [PNG](regular-paused@2x.png) |
| regular-playing | [PNG](regular-playing@1x.png) | [PNG](regular-playing@2x.png) |
| square | [PNG](square@1x.png) | [PNG](square@2x.png) |
| twitch | [PNG](twitch@1x.png) | [PNG](twitch@2x.png) |
| youtube | [PNG](youtube@1x.png) | [PNG](youtube@2x.png) |

56 PNGs total. Native menus: [regular](menu-regular.txt), [disabled](menu-disabled.txt), [host-less](menu-hostless.txt), [private disabled](menu-private-disabled.txt), [Document](menu-document.txt).

[Runtime receipt](features-check.txt) · [Build receipt](build.txt) · [PNG hashes and sizes](renders.json).
