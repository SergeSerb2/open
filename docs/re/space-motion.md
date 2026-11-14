# Space motion endpoint

The Space strip uses live backing layers and native pages inside the viewport.
The current shipping selection path has no page bitmap or presentation fence. Native geometry changes
only when the viewport changes; the scheduled slide uses a layer translation.

The M1 measurement on a4a53e77 records a critical spring with response 0.20 s,
duration and settlingDuration 0.30 s, and travel 228 pt. Its physical response at
0.30 s is 0.9991587254, leaving 0.19181 pt before the model endpoint. Key/click
trials retain a late text change at roughly 280–325 ms, with up to four captured
unchanged frames before that change. Evidence: the private NT handoff receipt
`NT-frames/animation-space-layer-visibility-23/`, the `window-motion` spring
fields and the unchanged detector's native sample ledger. Earlier pixel pairs
in `NT-frames/animation-controls-and-spaces-21/` locate the same tail in sidebar
text. Layer-only hiding did not remove it.

The slide normalizes the animation's travel by its physical progress at the
finite duration. This makes its last presentation equal the native endpoint
when the animation retires. Response, damping, initial velocity and lifetime
stay unchanged. The maximum display cadence is requested for this finite
animation. A separate M1 run must establish the effect; this calculation is
not a pacing receipt or a replacement fit to Arc.

The captured C14-3 recording has no accepted replacement curve. The existing
session-2 response and damping tokens therefore remain. Reduce Motion does
not install a slide. Reversal starts from the current presentation value.


## Page continuity: engine dependency

LEAD 18:40 requires a destination viewport snapshot over the outgoing pixels,
then a live-view handoff only after an engine frame-presented callback. The
source audit on `1eb035c4e` finds no such public API:

- `WebContentContainer.show` hides/removes the old host before configuring the
  new one. `PaneSlotView.configure` unhides and attaches the new host. These
  are native visibility changes, without a new-frame receipt.
- `OEWebContentView.viewDidUnhide` calls `oe_showPageIfVisible`, which forwards
  `WasHidden(false)`. Neither that method nor `OEWebContentDelegate` reports
  presentation of the resulting view.
- `CefOpenPageHandler` reports selection, security and history swipes, with no
  presentation hook. `OpenWeb.WebContent` and `WebContentHost` have no such hook.
- `PeekOverlayView.afterSnapshotCommit` explicitly describes its one-refresh
  hold as **not a physical-presentation receipt**. It cannot satisfy this rule.

Private native evidence from `NT-frames/animation-space-finite-35/` shows white
between 13.77 and 38.77 ms in key-next, with page pixels returning at 47.11 ms.
The same issue on main is retained as a finding. It is not waived for #575.

`SpacePageSnapshotTransition` is now connected through
`SpaceContentTransitionController` to Space selection. The live handoff is not
accepted until the engine presentation adapter lands. It provides bounded memory-only images, a stationary
outgoing plate, an incoming snapshot/theme plate, a render-server spring and
Reduce Motion, plus separate motion-complete and engine-presented receipts.
A failed or stale presentation cannot retire the cover. Snapshot keys include
Space, profile, pane selection, host/document revisions, viewport and scale.
The cache is bounded to eight entries and 64 MiB; each image is limited to
8192 per dimension, 16M pixels and 64 MiB decoded. Two active plates can retain
at most two additional images (128 MiB). It performs no per-frame capture,
layout, text work, timer driving or native view resize. The controller folds an interrupted presentation into a bounded transparent
image above the unchanged native source. It invalidates cache keys on
navigation, host close, profile teardown and geometry changes. Viewport
capture combines native chrome with bounded engine page images; PNG decode
runs on a worker. Only one source capture can be in flight per window.
The source remains attached during motion; native selection changes once
after the incoming plate covers it. Missing captures refuse cache insertion.

The required shared engine contract is:

1. Request a one-shot presentation **after** the destination view is attached,
   visible and has its final viewport. Include a caller generation/request ID.
2. Success identifies this WebContents, document/renderer generation,
   view-attachment generation, viewport in device pixels and scale. It must
   follow a successful compositor presentation for that target, newer than the
   attachment/request. A pre-attachment or previous-viewport presentation is stale.
3. A retained/saved surface may qualify if it matches the current document,
   attached view, viewport and scale and is successfully presented after the
   request. Space switching does not require new renderer pixels in that case.
   Load, DOM rAF, capture completion, render-view readiness, a display tick and
   animation completion are not presentation receipts.
4. Close, navigation replacement, renderer loss, hide, detach and superseding
   requests cancel the request. Cancellation/error cannot report success or
   reveal a blank native surface. No completion deadline reveals live content.
5. Deliver once on the main actor without retaining a closed page. The shell
   validates its own selection generation before retiring a retained image.

The controller leaves outgoing content unchanged during preparation and
motion. Once the incoming plate fully covers it, it applies native
selection/layout once behind the plate and requests presentation. Only a
matching successful callback removes the plate. With no destination snapshot,
the incoming plate contains the destination Space field. Empty Spaces complete
against their explicitly rendered themed surface, rather than a nonexistent
engine frame. The small `WebContentFramePresentation` protocol accepts a per-view device-pixel
viewport and request UUID; cancellation returns no success. Its receipt echoes
the UUID and viewport. The shell also validates host identity, document revision,
selection and request generations. The default host provider is nil until E3
implements the App adapter, so the snapshot/theme stays on top without a timer.
Click/key/swipe, reversal, resize, close, cold-cache and renderer failure flows
require real-App proof; successful live reveal waits for SEAM READY. M1 pacing and strips
must then be rerun unchanged. No result from the earlier sidebar-only candidate
qualifies this new handoff.

E3 confirmed on 2026-11-13 at 18:39 that no implementation/head is available.
Its read-only source audit at 18:48 identifies
`ui::Compositor::RequestSuccessfulPresentationTimeForNextFrame`
(`ui/compositor/compositor.h:363-384`), used for tab-show in
`delegated_frame_host.cc:120-134`. The Mac tab-show path permits a saved frame
(`render_widget_host_view_mac.mm:563-615`). Surface metadata exposes size, scale
and LocalSurfaceId (`render_widget_host_view_mac.mm:1221-1226`), but a shell
API binding those to the requested view/presentation is not implemented. A saved
surface is acceptable for Space switching when those identities match; D3
new-width resize has its separate stronger requirement.
Its existing A/B engine pair remains pinned. Chromium ownership stays with E3;
#575 remains draft pending the engine adapter and runtime proof.
