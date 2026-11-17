import AppKit
import OpenEngine
import OpenFeatures

#if OPEN_ENGINE_FRAME_PRESENTATION
/// Space-specific bridge until the lead integrates a shared OpenWeb adapter.
/// Older public headers compile the host's nil default instead. A new header
/// with an older engine still refuses through supportsFramePresentation.
@MainActor
final class SpaceFramePresentationAdapter: WebContentFramePresentation {
  private weak var content: OEWebContent?
  init(content: OEWebContent) { self.content = content }

  func firstFramePresented(at viewport: WebContentFrameViewport, requestID: UUID,
                           retainingSurfaceForResize: Bool,
                           completion: @escaping @MainActor (WebContentFrameReceipt?) -> Void)
      -> (any WebContentFrameRequest)? {
    guard let content, content.supportsFramePresentation,
          viewport.width > 0, viewport.height > 0,
          viewport.width <= 8192, viewport.height <= 8192,
          viewport.width * viewport.height <= 16 * 1024 * 1024,
          viewport.scale.isFinite, viewport.scale > 0 else { return nil }
    let request = SpaceFramePresentationRequest(completion: completion)
    let pixelSize = NSSize(width: CGFloat(viewport.width), height: CGFloat(viewport.height))
    request.engineRequest = content.requestFramePresentation(pixelSize: pixelSize,
      backingScale: viewport.scale, requestID: requestID,
      retainingSurfaceForResize: retainingSurfaceForResize) { [weak request] frame in
        guard let request else { return }
        guard let frame, frame.requestID == requestID, frame.pixelSize == pixelSize,
              frame.backingScale == viewport.scale,
              frame.presentedAt.isFinite, frame.presentedAt > 0 else {
          request.finish(nil); return
        }
        request.finish(WebContentFrameReceipt(requestID: requestID, viewport: viewport,
                                             presentedAt: frame.presentedAt))
      }
    return request.engineRequest == nil ? nil : request
  }
}

@MainActor
private final class SpaceFramePresentationRequest: WebContentFrameRequest {
  var engineRequest: OEWebContentFrameRequest?
  private var completion: (@MainActor (WebContentFrameReceipt?) -> Void)?
  init(completion: @escaping @MainActor (WebContentFrameReceipt?) -> Void) {
    self.completion = completion
  }
  isolated deinit { engineRequest?.cancel() }

  func finish(_ frame: WebContentFrameReceipt?) {
    let callback = completion; completion = nil; engineRequest = nil
    // Clear ownership before calling shell code, which may close the page.
    callback?(frame)
  }
  func cancel() {
    let token = engineRequest; engineRequest = nil
    finish(nil); token?.cancel()
  }
}
#endif
