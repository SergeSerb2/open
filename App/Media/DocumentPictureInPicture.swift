import AppKit
import OpenEngine
import OpenFeatures
import OpenMedia
import OpenModel
import OpenWeb

/// One Document PiP (media-pip §4.6, EM-7): the page's child web content in Open's panel.
/// The child's delegate is this object; the opener tab's lifetime bounds it (Step 10/11 gate).
@MainActor
final class DocumentPictureInPicture: NSObject, OEWebContentDelegate {
  let child: OEWebContent
  let openerTabID: ItemID
  weak var opener: OEWebContent?
  private(set) var window: DocumentPiPWindowController?
  private var host: DocumentPictureInPictureHost?
  var onClosed: (() -> Void)?
  /// Links clicked inside the PiP open as tabs of the opener's window.
  var openURL: ((URL) -> Void)?

  init(child: OEWebContent, opener: OEWebContent, openerTabID: ItemID) {
    self.child = child; self.opener = opener; self.openerTabID = openerTabID
    super.init()
    child.delegate = self
  }

  func present(settings: MediaSettings, screen: CGRect?) -> Bool {
    let host = DocumentPictureInPictureHost(child: child, opener: opener)
    // The requested size is not known before the child exists (EM-7); start at the page's
    // usual request and resize when it arrives.
    guard let window = DocumentPiPWindowController(host: host, sourceURL: opener?.url, requestedSize: CGSize(width: 400, height: 300),
                                                   settings: settings, screenVisibleFrame: screen) else { return false }
    self.host = host; self.window = window
    window.onClosed = { [weak self] in self?.finish() }
    window.showWindow(nil)
    return true
  }

  func close() { window?.close() }

  private func finish() {
    guard window != nil else { return }
    window = nil; host = nil
    child.delegate = nil
    onClosed?()
  }

  // MARK: OEWebContentDelegate (the child page)

  func webContent(_ webContent: OEWebContent, didChange changes: OEWebContentChange) {
    if changes.contains(.pictureInPicture) {
      let size = webContent.requestedPictureInPictureSize
      if size.width > 0, size.height > 0 { window?.resize(requestedSize: size) }
    }
    if changes.contains(.crash), webContent.crashState != .none { close() }
  }
  func webContentDidRequestClose(_ webContent: OEWebContent) {
    // window.close() in the PiP page, or Chromium closing it (opener navigated, a new PiP).
    DispatchQueue.main.async { [weak self] in self?.close() }
  }
  func webContent(_ webContent: OEWebContent, createWebContentFor request: OEOpenRequest) -> OEWebContent? {
    if let url = request.url { openURL?(url) }
    return nil
  }
}

/// OpenWeb's PiP host over a Document PiP child: its "video" is the child page's view.
@MainActor
final class DocumentPictureInPictureHost: WebPictureInPictureHost {
  let child: OEWebContent
  weak var opener: OEWebContent?
  init(child: OEWebContent, opener: OEWebContent?) { self.child = child; self.opener = opener }
  var videoView: NSView { child.view }
  var naturalSize: CGSize { child.requestedPictureInPictureSize }
  var sourceBounds: CGRect { .zero }
  var mediaState: WebMediaState { WebMediaState(playback: .none, isControllable: false) }
  var currentTime: Double { 0 }
  var playbackRate: Double { 0 }
  var positionUpdatedAt: Date { Date() }
  var endOfMedia: Bool { false }
  var sourceTitle: String { opener?.title ?? "" }
  var favicon: NSImage? { opener?.favicon }
  var mediaMuted: Bool { opener?.isMuted ?? false }
  var windowFrame: CGRect = .zero
  var windowVisible = false
  func togglePlayPause() {}
  func nextTrack() {}
  func previousTrack() {}
  func skipAd() {}
  func toggleMicrophone() {}
  func toggleCamera() {}
  func hangUp() {}
  func nextSlide() {}
  func previousSlide() {}
  func seekTo(_ time: Double) {}
  func scrubTo(_ time: Double) {}
  func setMuted(_ muted: Bool) {}
  /// Closing the panel closes the child; Chromium returns the elements to the opener.
  func closePausingVideo(_ pause: Bool) { child.close() }
}
