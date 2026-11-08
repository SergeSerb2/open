# Section 3 item 14 (part): row speaker, PiP window and a two-card stack against Arc

Media plan §14.2. Arc frames come from capture session 2
(`.re/runtime/sessions/20261026-*`, local only). This directory holds numbers and
Open-only PNGs with fixture titles. Arc frames, Arc/Open/diff sheets, AX dumps and
snapshots that carry an Arc title stay in `.re/section3/parity/` (local drivers:
`rowwin.py`, `stack2win.py`, `pipwin.py`, `compare-rows.sh`, `compare-stack2.sh`,
`pip/render.sh`, `pip/calibrate`).

## Setup

- App: `build/Debug/Open.app` (`tools/build.sh Debug`, recorded engine distribution).
  Row and stack runs: this branch before the PiP change (sidebar code as on `main`
  `b32a6222`). `--style chrome`, fresh data root, `--pip-site-rules` with the e2e
  `MEDIA_RULES`, `appearance dark`, default theme, `window-frame [200,150,1728,1084]`
  (Arc's frame size in every session-2 frame), sidebar 228 (`window-state`:
  `sidebarWidth` 228, `anchored`), synthetic pointer away at (1200, 600).
- Display: the main display AW2726DM, 2560 × 1440 at 1x, the capture display. Its
  `NSScreen.visibleFrame` is 2560 × 1410 (30 pt menu bar, Dock hidden), read with
  `osascript -l JavaScript` (`NSScreen.screens`).
- Snapshots: `snapshot` (`windowserver+devtools`), 1728 × 1084 at 1x, the same size,
  scale and top-left origin as the Arc frames. No cropping or offset was needed.
- Row sources: `audio.html` (an `<audio>` tone) with `volume = 0.001` (the probe
  counts volume > 0 as audible, so the row shows the speaker without a loud tone).
  Muted: `media-action toggle-mute`. Unselected: the home tab selected
  (`enablePictureInPictureOnLeave` off, so the card shows instead of Chromium's PiP).
- Row titles for the compare: the audio tab's `document.title` was set at runtime to
  the Arc row's AX title (in memory). The committed PNGs were captured again with the
  fixture title. Title start is the only title measure (left, top, bottom of the ink).
- Open's frames: Open's own AX tree, read with a local read-only reader
  (`AXVisibleRows` of the outline; the row and `sidebarTabCellMuteButton`), so the
  button frame is AX against AX, as in Arc's dump.
- Color: both PNGs embed "Rec. ITU-R BT.2020-1; sRGB Gamma" (`sips -g profile`).
  `compare-media --state row-audible|row-muted` converts through the embedded profile
  into extended linear sRGB Float32 (no clipping; its P3 self-test prints
  (−0.225, 1.042, −0.079)); the stack compare uses the Step 6 path, whose profile is
  wider than P3. Measured pixels outside sRGB: Arc 0, Open 0 in every row run.

## 1. Row speaker in the real window (RI5 compare)

Row-relative points. Arc frames: S2 12/0022 (audible, selected), 12/0027 (muted,
selected), 13/0002 (audible, not selected, PiP open), 14b/0014 (audible, not
selected, mini player shown). Open rows: AX row y 187 (Arc 379).

| Element | 12/0022 audible selected: Arc / Open / error | 12/0027 muted selected: Arc / Open / error |
|---|---|---|
| Speaker button frame (AX) | `[41, 7, 26, 26]` / same / 0.0 pt | same / same / 0.0 pt |
| Glyph ink box | `[44, 15, 19, 11]` / `[45, 14, 18, 12]` / 1.0 pt | `[47, 13, 14, 14]` / same / 0.0 pt |
| Glyph core color (≥ 85 % of peak) | `#B3B3BA` / `#B0B0B7` / ΔE00 0.93 | `#B5B5BC` / `#B1B1B8` / ΔE00 1.14 |
| Glyph peak pixel | `#B8B8BF` / `#B8B8BE` / ΔE00 0.56 | `#B8B8BE` / `#B5B6BD` / ΔE00 0.75 |
| Title start (ink left, top, bottom) | x 71, y 14…28 / same / 0.0 pt | same / same / 0.0 pt |
| Selected-row plate (context) | `#515060` / `#515060` / ΔE00 0.22 | same / ΔE00 0.22 |
| Title core color (context) | `#D9DAFB` / `#D9DAFA` / ΔE00 0.11 | same / ΔE00 0.11 |

| Element | 13/0002 audible, not selected: Arc / Open / error | 14b/0014 audible, not selected: Arc / Open / error |
|---|---|---|
| Speaker button frame (AX) | `[41, 7, 26, 26]` / same / 0.0 pt | same / same / 0.0 pt |
| Glyph ink box | `[44, 15, 19, 11]` / `[45, 14, 18, 12]` / 1.0 pt | `[45, 14, 18, 12]` / same / 0.0 pt |
| Glyph core color | `#A2A0A9` / `#9E9DA5` / ΔE00 1.15 | `#A09FA8` / `#9E9DA5` / ΔE00 0.82 |
| Glyph peak pixel | `#A7A6AE` / `#A5A6AD` / ΔE00 1.21 | same / same / ΔE00 1.21 |
| Title start | x 71, y 14…28 / same / 0.0 pt | same / same / 0.0 pt |
| Row background (context) | `#272538` / `#272538` / ΔE00 0.18 | same / ΔE00 0.18 |
| Title core color (context) | `#D8D9F9` / `#D8D8F9` / ΔE00 0.10 | `#D1D3F3` / `#D8D8F9` / ΔE00 1.33 |

Every gate passes: worst edge 1.0 pt, worst ΔE00 1.21 (Step 2b offscreen: 0–1 pt,
ΔE00 ≤ 1.91, plate 2.23). A repeat run gave byte-identical PNGs and tables.

- The 1.0 pt audible ink edge is Arc's own variation: Arc's audible glyph box is
  `[44, 15, 19, 11]` in 12/0022 and 13/0002 but `[45, 14, 18, 12]` in 14b/0014
  (Arc draws animated waves of its own, PP-23); Open equals the 14b box.
- The real window's selected-row plate matches Arc (ΔE00 0.22); the offscreen
  harness showed 2.23. The difference is the harness, not the theme.
- "Title frame x (AX)" is not measurable in Open: Open's tab row is one AX button
  whose label is the title; it has no text child with a frame (Arc: an AXStaticText at
  x 69). The pixel title start above is the gated measure. Not a media item.
- Open's AX image `media.speakerGlyph` reports the symbol image's rect
  (`[40, y + 9, 28, 22]` audible, `[40, y + 10, 27, 20]` muted), not the 26 × 26
  image-view frame: AppKit's image-view AX frame. The ink boxes above are the check.

## 2. PiP window against capture session 2 item 13

Arc: the auto-PiP window (window 74845, layer 3) of a 16:9 YouTube video at rest. It
is in 430 frames of sessions 07–14 (the earlier capture loops still ran), all with
the frame `[2230, 1250, 320, 180]` (top-left origin) and a byte-identical alpha
channel. The captures are `screencapture -l` window images without shadow. Controls
never appeared for the synthetic pointer (notes 10:31:10), so these frames show the
video only; there is no Arc target for controls, scrims, menu, or hover.

Open phase 2 (`features-render pip --scale 1 --natural-size 1280x720 --first-open
--geometry-report`, controls hidden and visible), before and after this branch:

| Element | Arc (item 13) | Open `main` b32a6222 | Open this branch | Result |
|---|---|---|---|---|
| Size, harness screen 2560 × 1440 | 320 × 180 | 320 × 180 | 320 × 180 | exact |
| Position, harness screen 2560 × 1440 (top-left origin) | (2230, 1250); right 10, bottom 10 | (2230, 1250); 10 / 10 | (2230, 1250); 10 / 10 | exact |
| Size on the capture display (visible frame 2560 × 1410) | 320 × 180 | 314 × 177 (313.3 × 176.25, AppKit-rounded) | 320 × 180 (`--screen 2560x1410 --screen-frame 2560x1440`) | fixed (was 6 / 3 pt) |
| Position on the capture display | (2230, 1250) | (2236, 1253); 10 / 10 | (2230, 1250); 10 / 10 | fixed (was 6 / 3 pt) |
| Corner (window alpha) | continuous, r 6 | circular, r 12 | continuous, r 6 | fixed |
| Inner edge | 1 pt white hairline, alpha 0.121 | none | 1 pt white, alpha 0.12 | fixed |
| Shadow | not in the capture | `hasShadow` | unchanged | not comparable |
| At rest | video only | video only (controls hidden) | same | same |

Corner. Arc's corner alpha is the same in all four corners (max difference 0) and
transposes onto itself. It was fitted against on-screen calibration windows: a
borderless, non-activating 320 × 180 panel at the bottom-right with a layer corner
radius of 5–9 pt, circular and continuous, captured with the same
`screencapture -l <n> -o -x` (`.re/section3/parity/pip/calib.swift`; Open pixels only).
Continuous r 6 matches within 1/255 (rms 0.10/255); the next best, circular r 6, is
off by 21/255 (rms 3.50). Area outside the curve: Arc 8.44 px², continuous 6 8.44,
circular 6 7.83, Open's former circular 12 about 27. CG path fills (SwiftUI
`RoundedRectangle`) give r 6.0–6.25 for both curves but fit worse (max ≥ 39/255):
use the on-screen window as the reference. Harness limit: `features-render`
rasterizes a 6 pt continuous corner tighter than the window server (6.24 px²), so the
offscreen PNG is not the corner proof; the calibration window with the same layer
settings is.

Edge. Ring 0 (the outermost pixel row/column, outside 12 px corners) is brighter than
ring 1 by +13.9 luminance on average over the 58 frames of session 13 (sd 3.4;
+7.8…+21.4 per frame over all 430 frames), while ring 1 − ring 2 is −0.02. A white
overlay fits it in encoded values: alpha 0.121 median (IQR 0.107–0.135, 44 154
pixels), the same on all four sides (per-side line fits 0.125–0.136 on every channel, so gray).
Neither Arc's main window nor Open's main window has such a ring (ring 0 = ring 1
within 0.3), so it is the PiP window's own drawing, not the window server. Open now
draws a 1 pt layer border, white 0.12: harness render 0.120 (IQR 0.118–0.122),
on-screen calibration window 0.119.

Size. Arc's 180 pt height is not `visibleFrame.height / 8` on this display
(1410 / 8 = 176.25). The display's visible frame is 2560 × 1410 now; at capture time a
30 pt menu bar is likely (Little Arc opened at y 50 with a 20 pt right inset, notes
10:34:17), but it is not proven. The
whole-screen fit gives 320 × 180 in both cases, so it is the smaller claim: the
`/8` box now uses the screen's `frame`, and placement and the 50 % / minimum limits
keep the visible frame. Whole-screen vs width-only is not decided by this one data
point (both give 320); for portrait videos they differ, and the lead's both-axes rule
is kept. Guess elsewhere, as before.

Phase 2 in the real App (Section 3 Step 11, 2026-11-07, head b6c75921, distribution
`e171318e…`): auto-PiP of `video-file.html` on a tab leave, 1x AW2726DM main display
(screen 2560 × 1440, visible frame 2560 × 1410). Open's window, from the App's own
automation (`pip` `openWindow`, no screen capture): frame top-left `[2230, 1250, 320, 180]`,
right inset 10, bottom inset 10, level 3. Arc item 13: `[2230, 1250, 320, 180]`. Error
0 / 0 / 0 / 0 pt (probe `.re/section3/tools/parity-pip-real.py`). Corner and edge are
the layer settings proven above (continuous r 6, 1 pt white 0.12).

Phase 1 (what the App showed before Steps 9–10: Chromium's own window, `pipwin.py`, real App,
1.5 s after the leave, pointer away): `NativeWidgetMacFramelessNSWindow` 501 × 282 at
bottom-left (2027, 32), i.e. top-left (2027, 1126), 32 pt from the right and bottom;
square corners (alpha 255 at the corner pixel); no hairline on the left, right or
bottom; the page origin text shows at the top left. Every row misses Arc. Cause:
Chromium's own window and its size rule (`visibleFrame / 5` = 282 high), not Open's
code; phase 2 (EM-4) replaces it (§4.4.1). `phase1-chromium-pip-1x.png` is that window.

## 3. Two-card collapsed stack (R5) against 16/0001

Not compared before: 16/0001–0002 show two cards (one back strip) before the third
video started. `compare-media --state stack --cards 2` (the new option only sets the
card count; the 3-card default and every measure are unchanged), Arc 16/0001,
shadow reference E1 = 14b/0012 and Open's no-media window with the same two video
tabs. Two `video.html` tabs, no track handlers, so previous/next are disabled as in Arc.

| Element | Position error (pt) | ΔE00 | Arc color | Open color | Arc ink box (px) | Open ink box (px) |
|---|---|---|---|---|---|---|
| Card 0 edges and fill | 1.0 | 0.12 | #050627 | #050627 | 8,1001 211×33 | 8,1001 212×33 |
| Card 0 Previous | 0.0 | 0.47 | #3B3C55 | #3C3D57 | 65,1012 13×11 | 65,1012 13×11 |
| Card 0 Pause | 0.0 | 0.38 | #ABAAB5 | #ABAAB6 | 110,1012 9×12 | 110,1012 9×12 |
| Card 0 Next | 0.0 | 0.42 | #3B3C55 | #3C3D57 | 149,1012 13×11 | 149,1012 13×11 |
| Card 0 Volume | 0.0 | 0.29 | #A9A8B4 | #A9A9B5 | 188,1011 19×14 | 188,1011 19×14 |
| Back card 1 visible edges (top/left/right; bottom occluded) | 1.0 | — | #0C0C29 | #0C0C29 | 15,994 198×8 | 16,994 196×8 |
| Back strip 1 | — | 0.12 | #0C0C29 | #0C0C29 | — | — |

| Shadow distance (pt) | Arc darkening (%) | Open darkening (%) | Difference (pp) |
|---|---|---|---|
| 0.5 | 9.91 | 10.11 | 0.20 |
| 2.5 | 5.02 | 5.73 | 0.71 |
| 4.5 | 2.29 | 2.65 | 0.36 |

All within target (≤ 1 pt, ΔE00 ≤ 2, ≤ 1.5 pp). The lone back strip is lighter than
the first strip of a three-card stack (`#0C0C29` vs `#090827` in E6) in both Arc and
Open.

## Other capture frames with a PiP window or a mini player

| Frames | Shows | Status |
|---|---|---|
| 07/…, 08/…, 09/…, 10/…, 11/…, 12/0037–0095, 13/0002–0058, 14/0001–0022 | the item 13 PiP window (430 frames) | compared above (frame from `windows.tsv`, alpha identical, edge step per frame) |
| 8 frames in sessions 07–14 (for example 13/0021, 14/0001) | window 74992, 10 × 10 at (0, 1430), layer 3 | fully transparent (alpha 0); nothing to compare |
| 13/0002–0058 | the video row, audible and not selected, while PiP is open; no card (MS1) | row compared above (13/0002) |
| 14b/0013, 0015–0022, 0025–0026 | one card at rest | pixel-identical to E2 (14b/0014) in x 0…228, y 800…1034: covered by Step 6 R1 |
| 14b/0023 | the card mid-expansion (title fading in, card growing) | not compared: a transition frame with no known time |
| 14b/0024–0025 | tooltip window 75576 ("Adjust Tab Volume", layer 25, 193 × 93) | not compared: Open shows no tooltip for a synthetic hover (Step 6 finding 2) |
| 16/0001–0002 | two-card stack | compared above (R5) |
| 16/0003, 0005–0010, 0013–0023 | three-card stack at rest | pixel-identical to E6 (16/0004): covered by Step 6 R3 |
| 16/0011 | expanded stack | pixel-identical to E7 (16/0012): covered by Step 6 R4 |
| 14b/0004–0011, 0044–0046 | Arc Settings window (`play.square` section icon) | not media UI |

## Commands

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh Debug
~/Library/Caches/OpenRE/scripts/heavy.sh nice -n 10 swift build --package-path Packages/OpenKit -c release -j 6 --product sidebar-render
~/Library/Caches/OpenRE/scripts/heavy.sh nice -n 10 swift build --package-path Packages/OpenKit -c release -j 6 --product features-render
# Local drivers in .re/section3/parity/ (not committed), one per lock:
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 rowwin.py ax ax          # AX titles (local only)
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 rowwin.py synthetic synthetic
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 rowwin.py ax ax2         # repeat
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 stack2win.py stack2
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 pipwin.py phase1
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock pip/calibrate pip/calib          # corner calibration windows
./compare-rows.sh ax cmp-ax; ./compare-stack2.sh; pip/render.sh final
features-render pip --out F.png --scale 1 --screen 2560x1410 --screen-frame 2560x1440 \
  --natural-size 1280x720 --first-open --geometry-report F.json --controls hidden|visible --site youtube
```

Load averages (1 / 5 / 15 min): row runs 12.5 / 15.5 / 18.5 → 12.5 / 14.9 / 18.1;
phase-1 run 9.1 / 13.3 / 17.1; builds 16.8 / 18.8 / 20.4 → 23.0 / 21.8 / 21.2.

## Committed PNGs (Open only, fixture titles, 1x)

| File | State |
|---|---|
| [row-audible-selected-dark-228-1x.png](row-audible-selected-dark-228-1x.png) | audible tab selected (1728 × 1084) |
| [row-muted-selected-dark-228-1x.png](row-muted-selected-dark-228-1x.png) | the same tab muted |
| [row-audible-unselected-dark-228-1x.png](row-audible-unselected-dark-228-1x.png) | audible tab not selected (card shown) |
| [R5-stack2-dark-228-1x.png](R5-stack2-dark-228-1x.png) | two playing videos, collapsed stack |
| [ref-no-media-stack2-dark-228-1x.png](ref-no-media-stack2-dark-228-1x.png) | the same window without cards (shadow reference) |
| [pip-main-screen2560x1440-1x.png](pip-main-screen2560x1440-1x.png) | phase-2 window on `main`, harness screen 2560 × 1440 |
| [pip-main-visible2560x1410-1x.png](pip-main-visible2560x1410-1x.png) | phase-2 window on `main`, capture display's visible frame (314 × 177) |
| [pip-fixed-capture-display-hidden-1x.png](pip-fixed-capture-display-hidden-1x.png) | this branch, capture display, controls hidden |
| [pip-fixed-capture-display-visible-1x.png](pip-fixed-capture-display-visible-1x.png) | this branch, capture display, controls visible (no Arc target) |
| [phase1-chromium-pip-1x.png](phase1-chromium-pip-1x.png) | the App's phase-1 Chromium PiP window, on-screen pixels |

SHA-256 (first 16 hex): row-audible-selected `d309157266e771aa`, row-muted-selected
`7de9ef0a5733a57c`, row-audible-unselected `e983f01aa896c6ba`, R5 `24159f60c42acd5c`,
ref `64708ce8eafa9527`, pip-main-screen `6af94773f2bfce4d`, pip-main-visible
`8be7fa5eadc2bb73`, pip-fixed-hidden `74bb94be60346d4d`, pip-fixed-visible
`a287c5746ea7a859`, phase1 `4bdf9d94b74f39b2`. The Step 4 PiP PNGs
(`../step4/`) predate the corner and edge change.
