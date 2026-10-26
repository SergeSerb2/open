import AppKit

/// One native destination choice; completion is consumed before calling out.
/// Closing a window/engine answers pending requests before the sheet teardown.
@MainActor
final class DownloadDestinationChoice {
  let panel = NSSavePanel()
  private var completion: (@MainActor (URL?) -> Void)?
  init(completion: @escaping @MainActor (URL?) -> Void) { self.completion = completion }
  func finish(_ url: URL?) {
    guard let completion else { return }; self.completion = nil; completion(url)
  }
  func cancel() {
    finish(nil)
    panel.sheetParent?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil)
  }
}
