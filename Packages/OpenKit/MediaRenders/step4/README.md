# Step 4 PiP evidence

The real AppKit PiP and Document PiP windows render over the plan's fake video
host. All artwork is Open's own drawing or SF Symbols. The video surface paints
only a synthetic gradient and its size. PiP uses the same colors in both appearances.
No App or engine wiring belongs to this step.

```sh
swift build --package-path Packages/OpenKit -c release -j 6
Packages/OpenKit/.build/release/features-render check
python3 Packages/OpenKit/MediaRenders/step4/render-scenes.py
```

The check command passes 191/191, including PP1–PP8. It creates complete native
panels offscreen, sends mouse events through NSWindow.sendEvent after hit testing,
and invokes actual NSMenu items. PP3 observes a real finite CA fade, lets the
actual 2 s DispatchWorkItem fire, and checks that animation keys disappear.
PP4 verifies click-to-jump, 80 pt upward precision dragging, final seek and resume.
The full verification gate now runs features-render check.

The idle offscreen window measured 0.025% process CPU over 2 s (0.5% budget).
Hidden controls, paused playback and an ordered-out panel have no display link;
ordered-out panels also cancel the pending control-hide item. The display link
requires visible controls, a visible unoccluded window, finite duration and playing
state. On-screen motion, key focus and engine-backed video remain later checks.

PP6 checks exact native contentAspectRatio and the 50% screen cap. AppKit rounds
the requested 253.125×450 portrait frame to 254×450 native points; the check allows
one point of native frame rounding. The portrait PNG uses exact 9:16 at 252×448.
The square check reaches 450×450 and returns to a 284×284 minimum.

The menu files below dump the real NSMenu. Each row includes its title, separator,
checkmark, enabled state, key equivalent, modifier mask and indentation for nesting.
The check captures the host-less, disabled and private states after real actions.
There is no drawn menu preview. Invalid size and state CLI cases both exit 1 and
produce no PNG.

Lead decisions recorded in plan §4.4.2, §4.4.4 and §8.3:

- 2026-10-26 02:38: click jumps before precision dragging; Open design pending S1/S2.
- 2026-10-26 02:47: preserve aspect and the 50% maximum; relax the minimum for portrait.
- 2026-10-26 03:11: native menu text only; PNG renders only the PiP window.

Meeting-row packing is provisional Open geometry pending S1/S11: center it near
the bottom and move it one row above Back to Tab and Mute if their frames overlap.
The compact native-window check verifies that these controls remain separate.

| Scene | 1× | 2× |
|---|---|---|
| compact-meeting | [PNG](compact-meeting@1x.png) | [PNG](compact-meeting@2x.png) |
| compact-paused | [PNG](compact-paused@1x.png) | [PNG](compact-paused@2x.png) |
| compact-playing | [PNG](compact-playing@1x.png) | [PNG](compact-playing@2x.png) |
| controls-hidden | [PNG](controls-hidden@1x.png) | [PNG](controls-hidden@2x.png) |
| document | [PNG](document@1x.png) | [PNG](document@2x.png) |
| meet | [PNG](meet@1x.png) | [PNG](meet@2x.png) |
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

Native menus: [regular](menu-regular.txt), [disabled](menu-disabled.txt), [host-less](menu-hostless.txt), [private disabled](menu-private-disabled.txt), [Document PiP](menu-document.txt).

[Complete check receipt](features-check.txt) · [Build receipt](build.txt).
