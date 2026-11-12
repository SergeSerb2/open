import AppKit
import OpenEngine
import OpenFeatures
import OpenMedia
import OpenModel
import OpenWeb

/// One Document PiP (media-pip §4.6, EM-7): the engine's session of kind `.document` in Open's
/// panel. Chromium's controller owns the PiP page and its rules (one PiP app-wide, close when the
/// opener navigates or goes); the opener tab's lifetime bounds it (Step 10/11 gate).
@MainActor
final class DocumentPictureInPicture {
  let pip: OEPictureInPicture
  let openerTabID: ItemID
  private(set) var window: DocumentPiPWindowController?
  private let host: DocumentPictureInPictureHost
  var onClosed: (() -> Void)?

  // Swift 6.4 can inline this initializer and hoist a resilient field offset
  // before this class's metadata is initialized. Keep allocation and field
  // initialization together; otherwise the first PiP can overwrite its header.
  @inline(never) init(pip: OEPictureInPicture, openerTabID: ItemID) {
    self.pip = pip; self.openerTabID = openerTabID
    host = DocumentPictureInPictureHost(pip: pip)
  }

  /// Synchronous, inside the engine's open: the panel and its frame exist before it returns.
  func present(settings: MediaSettings, screen: CGRect?) -> Bool {
    guard let window = DocumentPiPWindowController(host: host, sourceURL: pip.webContent?.url, requestedSize: requestedSize,
                                                   settings: settings, screenVisibleFrame: screen) else { return false }
    self.window = window
    window.onClosed = { [weak self] in self?.finish() }
    window.showWindow(nil)
    return true
  }

  /// The page asked for a new size (window.resizeTo).
  func refresh() { window?.resize(requestedSize: requestedSize) }

  func close() { window?.close() }

  /// The page's request; Chromium's usual default when it asked for none.
  private var requestedSize: CGSize {
    let size = pip.naturalSize
    return size.width > 0 && size.height > 0 ? size : CGSize(width: 400, height: 300)
  }

  private func finish() {
    guard window != nil else { return }
    window = nil
    onClosed?()
  }
}

/// OpenWeb's PiP host over a Document PiP session: its "video" is the PiP page's view.
@MainActor
final class DocumentPictureInPictureHost: WebPictureInPictureHost {
  let pip: OEPictureInPicture
  init(pip: OEPictureInPicture) { self.pip = pip }
  var videoView: NSView { pip.videoView }
  var naturalSize: CGSize { pip.naturalSize }
  var sourceBounds: CGRect { .zero }
  var mediaState: WebMediaState { WebMediaState(playback: .none, isControllable: false) }
  var currentTime: Double { 0 }
  var playbackRate: Double { 0 }
  var positionUpdatedAt: Date { Date() }
  var endOfMedia: Bool { false }
  var sourceTitle: String { pip.sourceTitle }
  var favicon: NSImage? { pip.favicon }
  var mediaMuted: Bool { pip.webContent?.isMuted ?? false }
  var windowFrame: CGRect {
    get { pip.windowFrame }
    set { pip.windowFrame = newValue }
  }
  var windowVisible: Bool {
    get { pip.isWindowVisible }
    set { pip.isWindowVisible = newValue }
  }
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
  /// Closing the panel ends the session; the page's pagehide takes its elements back. The
  /// engine posts the close, so this is safe from inside the panel's own close.
  func closePausingVideo(_ pause: Bool) { pip.close(pausingVideo: pause) }
}
