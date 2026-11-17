import AppKit
import OpenEngine
import OpenWeb

/// Keep the engine capability at the App boundary. Baseline headers compile
/// this adapter too, but refuse requests; the shell then slides the live page.
extension OEWebContent {
  func retainSurfaceForResize(
    to viewportSize: CGSize, backingScale: CGFloat, generation: Int,
    isCurrent: @escaping @MainActor () -> Bool,
    completion: @escaping @MainActor (Result<WebContentPresentedFrame, WebContentPresentationFailure>) -> Void
  ) -> (any WebContentSurfaceRetention)? {
    #if OPEN_ENGINE_FRAME_PRESENTATION
    guard supportsFramePresentation, let window = view.window,
          !view.isHiddenOrHasHiddenAncestor,
          backingScale.isFinite, backingScale > 0, backingScale <= 16,
          backingScale == window.backingScaleFactor,
          viewportSize.width.isFinite, viewportSize.height.isFinite,
          viewportSize.width > 0, viewportSize.height > 0 else { return nil }
    // Match OpenEngine's native viewport rounding and public request limit.
    // This requests no buffer or readback; the engine owns retained surfaces.
    let pixels = CGSize(width: (viewportSize.width * backingScale).rounded(),
                        height: (viewportSize.height * backingScale).rounded())
    guard pixels.width > 0, pixels.height > 0,
          pixels.width <= 32768, pixels.height <= 32768 else { return nil }
    let requestID = UUID()
    let armedAt = CACurrentMediaTime()
    let retention = EngineSurfaceRetention(isCurrent: { [weak self, weak window] in
      guard let self, let window else { return false }
      return isCurrent() && self.view.window === window && !self.view.isHiddenOrHasHiddenAncestor
        && window.backingScaleFactor == backingScale
        && (self.view.bounds.width * backingScale).rounded() == pixels.width
        && (self.view.bounds.height * backingScale).rounded() == pixels.height
    }, completion: completion)
    guard let request = requestFramePresentation(
      pixelSize: pixels, backingScale: Double(backingScale), requestID: requestID,
      retainingSurfaceForResize: true,
      completion: { [weak retention] receipt in
        // The public receipt binds the actual compositor presentation to this
        // request. No renderer-ready, display tick or timer can satisfy it.
        guard let receipt,
              receipt.requestID == requestID, receipt.pixelSize == pixels,
              receipt.backingScale == Double(backingScale),
              receipt.presentedAt.isFinite, receipt.presentedAt >= armedAt,
              receipt.presentedAt <= CACurrentMediaTime() else {
          retention?.deliver(.failure(.invalidated)); return
        }
        retention?.deliver(.success(.init(generation: generation, viewportSize: viewportSize,
          backingScale: backingScale, presentedAt: receipt.presentedAt)))
      }
    ) else { retention.cancel(); return nil }
    retention.request = request
    return retention
    #else
    return nil
    #endif
  }
}

#if OPEN_ENGINE_FRAME_PRESENTATION
@MainActor
private final class EngineSurfaceRetention: WebContentSurfaceRetention {
  var request: OEWebContentFrameRequest?
  private let isCurrent: @MainActor () -> Bool
  private var completion: (@MainActor (Result<WebContentPresentedFrame, WebContentPresentationFailure>) -> Void)?

  init(isCurrent: @escaping @MainActor () -> Bool,
       completion: @escaping @MainActor (Result<WebContentPresentedFrame, WebContentPresentationFailure>) -> Void) {
    self.isCurrent = isCurrent
    self.completion = completion
  }

  isolated deinit { request?.cancel() }

  func cancel() {
    // Clear before entering the engine. A cancelled or superseded delivery
    // cannot re-enter the shell or clear the currently displayed pixels.
    completion = nil
    let pending = request; request = nil
    pending?.cancel()
  }

  func deliver(_ result: Result<WebContentPresentedFrame, WebContentPresentationFailure>) {
    // Always unwind the engine callback before shell code may close a page.
    // Re-check cancellation on that turn, including after a success was queued.
    DispatchQueue.main.async { [weak self] in
      guard let self, let completion = self.completion else { return }
      self.completion = nil; self.request = nil
      completion(self.isCurrent() ? result : .failure(.invalidated))
    }
  }
}
#endif
