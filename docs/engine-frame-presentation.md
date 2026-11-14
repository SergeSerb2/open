# Hosted-page presentation receipts

Status: implementation in progress. Compilation, real-App receipts and retained-pixel verification are required before this capability is ready for shell use. The recorded engine distribution has not changed.

`OEWebContent.requestFramePresentation(pixelSize:backingScale:requestID:retainingSurfaceForResize:completion:)` requests one successful screen presentation for the current attached page. The call does not change its geometry. `pixelSize` contains integral device-pixel dimensions, each from 1 through 32768. The scale must be finite, positive and at most 16, and must match the attached window. A pending request uses constant-size state; it does not allocate a bitmap of the requested size.

For a resize, arm the request with `retainingSurfaceForResize: true` before the shell makes its single native geometry write. The renderer waits for the exact viewport and scale. It then requests successful presentation feedback for the next submitted frame and forces a redraw, so a static document can complete. The receipt echoes the caller's UUID, device-pixel size and scale. `presentedAt` uses the host monotonic clock in seconds.

The engine uses `cc::LayerTreeHost::RequestSuccessfulPresentationTimeForNextFrame`, whose contract requires that the frame reach the screen. Load completion, a redraw acknowledgement, renderer activation, DOM animation callbacks, captures and elapsed time do not produce a successful receipt. The renderer also binds the request to its `LocalSurfaceId`. The browser checks the current document, render widget, native view, parent, window, visibility and viewport again in the deferred delivery task.

Only one request can be pending for a page. A newer request supersedes the previous one. Navigation, hide, detach, renderer loss, close, or a geometry/surface change after matching cancels it. An accepted request completes once on the main thread, with `nil` on cancellation. A `nil` return means the request was unavailable and no completion is promised. `cancel()` is idempotent. It never clears the displayed surface.

The macOS retention path opts into an infinite surface resize deadline. Existing `stretch_content_to_fill_bounds: false` remains in effect. Cancelling changes the policy for future resizes; it does not evict the retained surface. This behavior still needs real-window pixel verification.

The shell must keep its existing cover on cancellation or deadline expiry. A deadline can report a timeout; it cannot authorize removal of the cover. The optional OpenWeb adapters remain separate from this engine API.

Implementation sources:

- Chromium patch `0510-open-frame-presentation.patch`: widget request, successful presentation feedback, surface identity and macOS retention policy.
- `Engine/fork/src/open/browser/page/open_frame_presentation.mm`: document and attachment ownership, deferred validation and cancellation.
- `Engine/OpenEngine/src/OEWebContent.mm`: native host lifetime, caller UUID and one-shot token.

The socket-only real-App suite is `tools/e2e/engine_e2e.py --config Release --only engine-presentation`. Its static-page, resize, cancellation and supersession flows use live Chromium pages and native windows. No unit tests or fake presentation providers are used.
