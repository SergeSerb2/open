# Step 3 mini-player evidence

Own synthetic renders from the real sidebar, store, and fake WebMediaHost objects.
No Arc frames or assets and no personal data are included. Layout/fill/motion guesses
remain in OpenDesign tokens pending S3–S8.

```sh
swift build --package-path Packages/OpenKit -c release -j 6
Packages/OpenKit/.build/release/sidebar-render check
Packages/OpenKit/.build/release/sidebar-render bench --rows 1000 --media-card
python3 Packages/OpenKit/MediaRenders/step3/render-scenes.py
python3 Packages/OpenKit/MediaRenders/step3/compare-bench.py --baseline-ref e44b40d4b1b1beda37673e7209bed958c79cbc11 --out /tmp/open-mini-comparison
```

The check command passes 208/208, including MC1–MC8 and MC10. MC9 runs through
the real 1,000-row benchmark: six interleaved pairs, with alternate pair order,
main without a card and head with one real paused card. Main median/mean p95
are 2.130/1.982 ms; head median/mean are 1.975/1.875 ms. Deltas -0.155/-0.107 ms
meet the 0.3 ms limit. The receipt records all runs and binary hashes.

The paused-card process measured 0.116% CPU over a 2 s idle sample; the complete
window had no CA animations, the stack had no collapse item, and the store held
one actual paused-dismiss work item. The media views create no Timer or display link.

Native event hit testing covers playback, tracks, volume, PiP, title, Close,
and recording actions. Visibility checks cover title fit/hover, pause, Reduce
Motion, hidden sidebar and ordered-out window. Window isVisible observation
handles ordering out an already-occluded window without polling. Source replacement
within one event turn verifies cleanup of the retiring view.

The renderer now supplies one Metal command queue to CARenderer and the read-back
fence (the installed SDK's CARenderer.h documents kCARendererMetalCommandQueue).
It also clones CATextLayer text/font properties. Twenty independent drawer renders
of the same snapshot produce one identical PNG SHA-256, recorded in evidence.
An invalid media spec returns exit 1. A paused-min=61 fixture renders only the
bottom bar, with no card.

CLI scenes use the static glyph path (Reduce Motion), preserving symbol tint
through the layer renderer. The runtime checks separately exercise animated behavior.
The fitting-title check asserts one visible text copy. The repeating copy appears
only while the marquee can run.

## Matrix

| Scene | Light 228 | Dark 228 | Light 500 | Dark 500 |
|---|---|---|---|---|
| audio-playing | [PNG](audio-playing-light-228.png) | [PNG](audio-playing-dark-228.png) | [PNG](audio-playing-light-500.png) | [PNG](audio-playing-dark-500.png) |
| paused | [PNG](paused-light-228.png) | [PNG](paused-dark-228.png) | [PNG](paused-light-500.png) | [PNG](paused-dark-500.png) |
| muted | [PNG](muted-light-228.png) | [PNG](muted-dark-228.png) | [PNG](muted-light-500.png) | [PNG](muted-dark-500.png) |
| video | [PNG](video-light-228.png) | [PNG](video-dark-228.png) | [PNG](video-light-500.png) | [PNG](video-dark-500.png) |
| recording | [PNG](recording-light-228.png) | [PNG](recording-dark-228.png) | [PNG](recording-light-500.png) | [PNG](recording-dark-500.png) |
| drawer | [PNG](drawer-light-228.png) | [PNG](drawer-dark-228.png) | [PNG](drawer-light-500.png) | [PNG](drawer-dark-500.png) |
| stack-collapsed | [PNG](stack-collapsed-light-228.png) | [PNG](stack-collapsed-dark-228.png) | [PNG](stack-collapsed-light-500.png) | [PNG](stack-collapsed-dark-500.png) |
| stack-expanded | [PNG](stack-expanded-light-228.png) | [PNG](stack-expanded-dark-228.png) | [PNG](stack-expanded-light-500.png) | [PNG](stack-expanded-dark-500.png) |
| title-hover | [PNG](title-hover-light-228.png) | [PNG](title-hover-dark-228.png) | [PNG](title-hover-light-500.png) | [PNG](title-hover-dark-500.png) |
| card-hover | [PNG](card-hover-light-228.png) | [PNG](card-hover-dark-228.png) | [PNG](card-hover-light-500.png) | [PNG](card-hover-dark-500.png) |

[Full light sidebar](full-sidebar-light-228.png), [full dark sidebar](full-sidebar-dark-228.png), [expired paused source](expired-dark-228.png).

## Review r1 additions

Drawer state is pruned when the source leaves, including identity replacement.
The native flow closes the tab with its drawer open, restores it, and gets a
fresh 68 pt card. Retiring cards retain their fade but reject hit tests; a click
through the fading old card reaches the replacement host. The long-title check
uses cacheDisplay on the live view and finds text ink, independent of the clone.

The drawer knob stays inside the track with a 6 pt center inset. Back cards have
an opacity-inherited .5 pt top separator edge (guess, pending S6). Copy uses 100%.
The new tooltip capture moves the actual TooltipView from the shown offscreen
child panel into the snapshot; it uses the real delayed tooltip and button hover.
Increase Contrast uses a diagnostics override of the normal accessibility path.

| Additional state | Light | Dark |
|---|---|---|
| themed | [PNG](themed-light-228.png) | [PNG](themed-dark-228.png) |
| narrow-hover | [PNG](narrow-hover-light-180.png) | [PNG](narrow-hover-dark-180.png) |
| narrow-drawer | [PNG](narrow-drawer-light-180.png) | [PNG](narrow-drawer-dark-180.png) |
| button-hover | [PNG](button-hover-light-228.png) | [PNG](button-hover-dark-228.png) |
| button-pressed | [PNG](button-pressed-light-228.png) | [PNG](button-pressed-dark-228.png) |
| tooltip | [PNG](tooltip-light-228.png) | [PNG](tooltip-dark-228.png) |
| increase-contrast | [PNG](increase-contrast-light-228.png) | [PNG](increase-contrast-dark-228.png) |

57 PNGs total. [Review-r1 runtime receipt](evidence/review-r1-check.txt).
