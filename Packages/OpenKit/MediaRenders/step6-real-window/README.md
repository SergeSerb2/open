# Step 6: real-window mini player against Arc (R1–R4)

The media plan §13.8.6 runs, repeated with real-window snapshots of the built App
instead of offscreen `sidebar-render` frames. Arc frames: capture session 2,
E1 = 14b/0012 (no media), E2 = 14b/0014 (rest), E3 = 14b/0024 (expanded, Volume
hovered), E6 = 16/0004 (stack), E7 = 16/0012 (stack expanded, Play hovered).
Arc frames, Arc/Open/diff sheets, and the AX-title snapshots stay local in `.re/`.
This directory holds only Open pixels that use the fixture's own titles.

## Setup

- App: `build/Debug/Open.app` from `s3/media-app-wiring` 237b7d8f (`tools/build.sh Debug`;
  recorded engine distribution, no engine build). `--style chrome`, fresh data root,
  `--pip-site-rules` with the e2e `MEDIA_RULES`.
- Window: `window-frame [200,150,1728,1084]`, `appearance dark`, default theme, sidebar
  228 (fresh default; `window-state` reports `sidebarWidth` 228, `anchored`).
- Sources: three `video.html` tabs (canvas + tone, no previous/next handlers, so the
  track buttons are disabled like E2) from a local `http.server` over
  `tools/e2e/fixtures/media/`. `defaults open.advanced.enablePictureInPictureOnLeave=false`:
  with the default setting, leaving the tab opens auto-PiP and the card does not show
  (Arc's E2/E6 show the card).
- Pointer: synthetic `mouse action=hover` only (the system pointer is not moved). Away
  = (1200, 600). R2 hovers the Volume button center (198, 1018), R4 the front card's
  Play center (114, 1018). Each hover is sent twice, 0.6 s apart (see finding 1).
- Snapshot: `snapshot` (`windowserver+devtools`), 1728 × 1084 at 1x on the 1x main
  display. The window was key and the app active for every snapshot.
- Titles for the compare: each card's tab title was set at runtime
  (`document.title`) to the AX title from the local E3/E7 `ax.json`, card by card
  (E7 has three different titles; the offscreen runs used one string for all three).
  The committed PNGs were re-captured with the fixture title.

Card frames read back from `mini-players` at the snapshots (window points, top-left):
R1 `[8,1001,212,33]`; R2 `[8,968,212,66]`; R3 `[8,1001,212,33]`, `[13,994,202,33]`,
`[18,987,192,33]`; R4 `[8,968,212,66]`, `[8,897,212,66]`, `[8,826,212,66]`.

## Input geometry and color

No cropping or offset was needed. The real-window snapshot has the same size, scale
and top-left origin as the Arc frames and the offscreen render (the window has no
separate title bar strip; the sidebar runs from y 0). Both the Arc PNGs and the
Open snapshots carry the same embedded profile ("Rec. ITU-R BT.2020-1; sRGB Gamma",
per `sips -g profile`), and `compare-media` converts both through it to sRGB. The
profile is wider than P3, so nothing is clipped before the measurement; the 8-bit
wide-gamut encoding explains the 0.12 ΔE00 on fills whose sRGB hex is identical.

## Commands

```sh
~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh Debug
~/Library/Caches/OpenRE/scripts/heavy.sh nice -n 10 swift build --package-path Packages/OpenKit -c release -j 6 --product sidebar-render
# Local driver (not committed): .re/section3/realwindow/realwin.py, harness `engine_e2e.Open`.
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 .re/section3/realwindow/realwin.py ax        .re/section3/realwindow/ax
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 .re/section3/realwindow/realwin.py ax        .re/section3/realwindow/ax2
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 .re/section3/realwindow/realwin.py synthetic .re/section3/realwindow/synthetic
# For each run (D = snapshot dir, O = output under .re/):
sidebar-render compare-media --arc E2 --ours $D/R1-rest.png --out $O/R1 --state rest \
  --arc-reference E1 --ours-reference $D/ref-nomedia.png
sidebar-render compare-media --arc E3 --ours $D/R2-expanded-volume.png --out $O/R2 --state expanded \
  --arc-reference E1 --ours-reference $D/ref-nomedia.png --mask 198,1018,30,66
sidebar-render compare-media --arc E6 --ours $D/R3-stack.png --out $O/R3 --state stack \
  --arc-reference E1 --ours-reference $D/ref-nomedia-after.png
sidebar-render compare-media --arc E7 --ours $D/R4-stack-expanded-play.png --out $O/R4 --state stack-expanded \
  --arc-reference E1 --ours-reference $D/ref-nomedia-after.png
```

The driver takes `ref-nomedia` (all three video tabs open, none playing, home tab
selected) before R1, and `ref-nomedia-after` (all three cards closed through
`media-action close`) after R4. R3/R4 use the second one; see finding 3.

Load averages (`os.getloadavg`, 1/5/15 min): build start 17.8 / 19.7 / 30.4;
run `ax` 29.9 / 29.8 / 31.6 → 28.2 / 29.4 / 31.4; run `synthetic` 16.5 / 21.4 / 25.4
→ 16.3 / 21.1 / 25.2; run `ax2` 16.3 / 20.3 / 24.6 → 18.8 / 20.6 / 24.7.
The `ax` and `ax2` tables are byte-identical.

## Summary

| Run / Arc frame | Worst edge error (pt), target ≤ 1 | Worst ΔE00, target ≤ 2 | Worst shadow error (pp), target ≤ 1.5 | Offscreen Step 3b (edge / ΔE00 / pp) |
|---|---|---|---|---|
| R1 / E2 | 0 | 0.47 | 0.71 | 0 / 0.56 / 0.91 |
| R2 / E3 | 0 | 0.73 | 0.60 | 0 / 0.73 / 0.93 |
| R3 / E6 | 2 (back card 1 strip, known artifact) | 0.62 | 0.81 | 2 / 0.56 / 0.91 |
| R4 / E7 | 0 | 0.97 | 0.96 | 2 / 0.86 / 0.93 |

## R1 rest (E2)

| Element | Position error (pt) | ΔE00 | Arc color | Open color | Arc ink box (px) | Open ink box (px) |
|---|---|---|---|---|---|---|
| Card 0 edges and fill | 0.0 | 0.12 | #050627 | #050627 | 8,1001 212×33 | 8,1001 212×33 |
| Card 0 Previous | 0.0 | 0.47 | #3B3C55 | #3C3D57 | 65,1012 13×11 | 65,1012 13×11 |
| Card 0 Pause | 0.0 | 0.38 | #ABAAB5 | #ABAAB6 | 110,1012 9×12 | 110,1012 9×12 |
| Card 0 Next | 0.0 | 0.42 | #3B3C55 | #3C3D57 | 149,1012 13×11 | 149,1012 13×11 |
| Card 0 Volume | 0.0 | 0.29 | #A9A8B4 | #A9A9B5 | 188,1011 19×14 | 188,1011 19×14 |

| Shadow distance (pt) | Arc darkening (%) | Open darkening (%) | Difference (pp) |
|---|---|---|---|
| 0.5 | 9.91 | 10.11 | 0.20 |
| 2.5 | 5.02 | 5.73 | 0.71 |
| 4.5 | 2.29 | 2.65 | 0.36 |

## R2 expanded, Volume hovered (E3)

| Element | Position error (pt) | ΔE00 | Arc color | Open color | Arc ink box (px) | Open ink box (px) |
|---|---|---|---|---|---|---|
| Card 0 edges and fill | 0.0 | 0.12 | #050627 | #050627 | 8,968 212×66 | 8,968 212×66 |
| Card 0 Previous | 0.0 | 0.47 | #3B3C55 | #3C3D57 | 65,1012 13×11 | 65,1012 13×11 |
| Card 0 Pause | 0.0 | 0.38 | #ABAAB5 | #ABAAB6 | 110,1012 9×12 | 110,1012 9×12 |
| Card 0 Next | 0.0 | 0.42 | #3B3C55 | #3C3D57 | 149,1012 13×11 | 149,1012 13×11 |
| Card 0 Volume | 0.0 | 0.73 | #AEAEB8 | #B0AFBA | 188,1011 19×14 | 188,1011 19×14 |
| Card 0 title | 0.0 | 0.46 | #C8C8D0 | #C9C8D0 | 23,980 127×12 | 23,980 127×12 |
| Card 0 title fill | — | 0.25 | #050627 | #050627 | — | — |
| Card 0 PiP | 0.0 | 0.37 | #A5A5B0 | #A5A5B2 | 166,978 15×13 | 166,978 15×13 |
| Card 0 Close | 0.0 | 0.65 | #AAA9B4 | #A8A8B4 | 192,980 11×11 | 192,980 11×11 |
| Hover plate | 0.0 | 0.38 | #191937 | #1A1A38 | 186,1006 24×24 | 186,1006 24×24 |

| Shadow distance (pt) | Arc darkening (%) | Open darkening (%) | Difference (pp) |
|---|---|---|---|
| 0.5 | 9.91 | 10.17 | 0.26 |
| 2.5 | 5.02 | 5.55 | 0.53 |
| 4.5 | 2.00 | 2.59 | 0.60 |

E3 has one extra trailing capture row (1085 → 1084); `compare-media` drops it
without moving the origin. The tooltip mask `198,1018,30,66` is applied as in §13.8.6.

## R3 stack collapsed (E6)

| Element | Position error (pt) | ΔE00 | Arc color | Open color | Arc ink box (px) | Open ink box (px) |
|---|---|---|---|---|---|---|
| Card 0 edges and fill | 1.0 | 0.00 | #050627 | #050627 | 8,1002 211×32 | 8,1001 212×33 |
| Card 0 Previous | 0.0 | 0.48 | #3B3C55 | #3C3D57 | 65,1012 13×11 | 65,1012 13×11 |
| Card 0 Pause | 0.0 | 0.62 | #ABAAB5 | #AAAAB6 | 110,1012 9×12 | 110,1012 9×12 |
| Card 0 Next | 0.0 | 0.43 | #3B3C55 | #3C3D57 | 149,1012 13×11 | 149,1012 13×11 |
| Card 0 Volume | 0.0 | 0.33 | #A9A8B4 | #A9A9B4 | 188,1011 19×14 | 188,1011 19×14 |
| Back card 1 visible edges (top/left/right; bottom occluded) | 2.0 | — | #090827 | #090827 | 18,994 194×9 | 18,994 192×9 |
| Back strip 1 | — | 0.14 | #090827 | #090827 | — | — |
| Back card 2 visible edges (top/left/right; bottom occluded) | 1.0 | — | #15122D | #14112C | 20,987 188×9 | 21,987 186×9 |
| Back strip 2 | — | 0.29 | #15122D | #14112C | — | — |

| Shadow distance (pt) | Arc darkening (%) | Open darkening (%) | Difference (pp) |
|---|---|---|---|
| 0.5 | 9.91 | 9.94 | 0.03 |
| 2.5 | 5.02 | 5.83 | 0.81 |
| 4.5 | 2.29 | 3.03 | 0.74 |

## R4 stack expanded, front Play hovered (E7)

| Element | Position error (pt) | ΔE00 | Arc color | Open color | Arc ink box (px) | Open ink box (px) |
|---|---|---|---|---|---|---|
| Card 0 edges and fill | 0.0 | 0.00 | #050627 | #050627 | 8,968 212×66 | 8,968 212×66 |
| Card 0 Previous | 0.0 | 0.48 | #3B3C55 | #3C3D57 | 65,1012 13×11 | 65,1012 13×11 |
| Card 0 Pause | 0.0 | 0.61 | #AFB0BA | #B1B1BC | 110,1012 9×12 | 110,1012 9×12 |
| Card 0 Next | 0.0 | 0.43 | #3B3C55 | #3C3D57 | 149,1012 13×11 | 149,1012 13×11 |
| Card 0 Volume | 0.0 | 0.33 | #A9A8B4 | #A9A9B4 | 188,1011 19×14 | 188,1011 19×14 |
| Card 0 title (left/top/bottom) | 0.0 | 0.26 | #C8C8D0 | #C8C8CF | 23,980 127×12 | 23,980 127×12 |
| Card 0 title fill | — | 0.00 | #050627 | #050627 | — | — |
| Card 0 PiP | 0.0 | 0.46 | #A5A5B0 | #A4A5B1 | 166,978 15×13 | 166,978 15×13 |
| Card 0 Close | 0.0 | 0.76 | #AAA9B4 | #A8A8B4 | 192,980 11×11 | 192,980 11×11 |
| Card 1 edges and fill | 0.0 | 0.00 | #050627 | #050627 | 8,897 212×66 | 8,897 212×66 |
| Card 1 Previous | 0.0 | 0.47 | #3B3C55 | #3C3D57 | 65,941 13×11 | 65,941 13×11 |
| Card 1 Pause | 0.0 | 0.60 | #ABAAB5 | #AAAAB6 | 110,941 9×12 | 110,941 9×12 |
| Card 1 Next | 0.0 | 0.39 | #3B3C55 | #3C3D57 | 149,941 13×11 | 149,941 13×11 |
| Card 1 Volume | 0.0 | 0.32 | #A9A8B4 | #A9A9B4 | 188,940 19×14 | 188,940 19×14 |
| Card 1 title (left/top/bottom) | 0.0 | 0.24 | #C7C7CE | #C7C7CE | 22,909 124×10 | 22,909 124×10 |
| Card 1 title fill | — | 0.00 | #050627 | #050627 | — | — |
| Card 1 PiP | 0.0 | 0.37 | #A6A5B1 | #A5A6B1 | 166,907 15×13 | 166,907 15×13 |
| Card 1 Close | 0.0 | 0.58 | #AAA9B4 | #A8A8B4 | 192,909 11×11 | 192,909 11×11 |
| Expanded gap 1 | — | 0.71 | #272132 | #282031 | — | — |
| Card 2 edges and fill | 0.0 | 0.00 | #050627 | #050627 | 8,826 212×66 | 8,826 212×66 |
| Card 2 Previous | 0.0 | 0.47 | #3B3C55 | #3C3D57 | 65,870 13×11 | 65,870 13×11 |
| Card 2 Pause | 0.0 | 0.64 | #ABAAB5 | #AAAAB6 | 110,870 9×12 | 110,870 9×12 |
| Card 2 Next | 0.0 | 0.41 | #3B3C55 | #3C3D57 | 149,870 13×11 | 149,870 13×11 |
| Card 2 Volume | 0.0 | 0.39 | #A9A8B4 | #A9A9B4 | 188,869 19×14 | 188,869 19×14 |
| Card 2 title (left/top/bottom) | 0.0 | 0.28 | #C7C7CF | #C8C7CF | 23,838 128×12 | 23,838 128×12 |
| Card 2 title fill | — | 0.00 | #050627 | #050627 | — | — |
| Card 2 PiP | 0.0 | 0.44 | #A5A5B0 | #A3A3AF | 166,836 15×13 | 166,836 15×13 |
| Card 2 Close | 0.0 | 0.73 | #AAA9B4 | #A8A8B4 | 192,838 11×11 | 192,838 11×11 |
| Expanded gap 2 | — | 0.85 | #272131 | #272031 | — | — |
| Hover plate | 0.0 | 0.97 | #191938 | #1A1B38 | 102,1006 24×24 | 102,1006 24×24 |

| Shadow distance (pt) | Arc darkening (%) | Open darkening (%) | Difference (pp) |
|---|---|---|---|
| 0.5 | 9.91 | 9.93 | 0.02 |
| 2.5 | 5.02 | 5.59 | 0.58 |
| 4.5 | 2.00 | 2.95 | 0.96 |

## Misses and causes

- **R3 back card 1 visible edges, 2.0 pt** (Arc box x 18…212, Open x 18…210). The
  same number as the offscreen Step 3b run, which design review r1 accepted as a
  measurement artifact. Re-checked on the real-window pixels: per-row crossings of
  the strip (rows 994–1000, left x 11…21 and right x 206…217) agree within 1 px
  between Arc and Open on every row, on both sides, and are mirror-symmetric; the 1 px ring plane fit for the 7 pt
  rounded strip moves the 50 % threshold by 2 px on the right only. Not an App bug.
- No other element misses a target. R3 card 0 (1.0 pt, Arc 211 × 32 vs 212 × 33) is
  within target and equals the offscreen value. With per-card AX titles, the R4 middle
  title (2 pt in the offscreen run, different strings) now matches exactly (0.0 pt,
  same 124 × 10 ink box).

## Findings outside the table

1. **Title row stuck on "Back to Tab" after a single hover (App bug, low severity).**
   One `mouse action=hover` on the collapsed card's Volume button expands the card,
   and the title row then reads "Back to Tab" while the pointer is on Volume, for at
   least 3 s (2 of 2 probe runs; `.re/section3/realwindow/tooltip.py`). Arc's E3 shows
   the media title in this state. A second event at the same point clears it (R2 sends
   two). Cause: `MediaControlsView.mouseEntered` (`MediaControlsView.swift:164-167`)
   sets `isExpanded` and runs `measure`, which sets the card's `isExpanded` at once;
   the card's own enter/move for the same event then runs
   `MiniPlayerCardView.hover(_:inside:)` (`MiniPlayerCardView.swift:264-267`), which
   converts the location against the card frame from before layout (collapsed, top at
   y 1001, so local y = 17 < 33) and sets `pointerOnTitle`. With a real pointer the
   next `mouseMoved` corrects it; a pointer that stops on the control right at entry
   keeps the wrong title. Whether AppKit delivers the two enters in this order for a
   real pointer is not verified (the harness delivers them in dictionary order).
   Possible fix: in `hover(_:inside:)`, lay out first when the card's frame height
   differs from `cardHeight` (for example `superview?.layoutSubtreeIfNeeded()`), so
   the hit test uses the expanded frame. Another option is to lay out in
   `MediaControlsView.mouseEntered` after `measure(.stack)`. Do not just clear
   `pointerOnTitle` on expansion: entering a collapsed stack over a back strip
   (y 987…1000) correctly lands on card 0's title row after expansion.
2. **No tooltip on screen after the synthetic Volume hover.** Arc's E3 shows "Adjust
   Tab Volume". In Open, `CGWindowListCopyWindowInfo` showed no level-25 (status bar)
   panel within 3 s, and the snapshot shows none. A new layer-0 0 × 0 child window
   appeared instead; it was not identified. The cause is not determined: either the
   synthetic hover path or a real defect. The compare masks this region either way.
   It needs a real-pointer check or a tooltip readback command.
3. **Sidebar background shift after setting three tab titles.** In both AX-title runs,
   after the three titles were set and the cards were closed again, the sidebar
   gradient was darker by up to 1 count (G −0.9 on average) over the whole sidebar,
   including y 1040…1084. The synthetic run (no title change) shows no shift: its
   two references are byte-identical. This is not in the mini-player. With the first
   reference, R3/R4 shadow differences are 0.62 / 1.18 / 1.17 and
   0.60 / 0.95 / 1.39 pp (still within 1.5); with the matching after-reference they
   are as tabled. The cause is not determined.
4. Open's stack shadow is consistently darker than Arc's at 2.5 and 4.5 pt
   (+0.5…+1.0 pp), within target. In the synthetic run the stack values equal the
   single card's values (10.11 / 5.73 / 2.65 %), so the back cards add no shadow below
   the front card, as in Arc (E6 equals E2).

## Committed PNGs (Open only, fixture titles, 1x, 1728 × 1084)

| File | State |
|---|---|
| [R1-rest-dark-228-1x.png](R1-rest-dark-228-1x.png) | one playing video, pointer away |
| [R2-expanded-volume-hover-dark-228-1x.png](R2-expanded-volume-hover-dark-228-1x.png) | expanded, Volume hovered |
| [R3-stack-dark-228-1x.png](R3-stack-dark-228-1x.png) | three playing videos, collapsed |
| [R4-stack-expanded-play-hover-dark-228-1x.png](R4-stack-expanded-play-hover-dark-228-1x.png) | expanded stack, front Play hovered |
| [ref-no-media-dark-228-1x.png](ref-no-media-dark-228-1x.png) | the same window with no card (shadow reference) |

SHA-256: R1 `932b03aa…`, R2 `ebccd78c…`, R3 `6254fabb…`, R4 `70c6f986…`,
ref `619b4995…` (identical to the synthetic run's after-reference).
Binaries: `Open` `99fab3ddfa6d96c8…`, `sidebar-render` `43a14aaa0ae28137…`.
