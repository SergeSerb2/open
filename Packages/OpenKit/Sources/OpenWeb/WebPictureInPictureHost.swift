import AppKit

/// Phase 2 boundary (PP-10). AppKit is isolated here; general page protocols stay Foundation-only.
@MainActor public protocol WebPictureInPictureHost: AnyObject {
    var videoView: NSView { get }
    var naturalSize: CGSize { get }
    var sourceBounds: CGRect { get }
    var mediaState: WebMediaState { get }
    var currentTime: Double { get }
    var playbackRate: Double { get }
    var positionUpdatedAt: Date { get }
    var endOfMedia: Bool { get }
    var sourceTitle: String { get }
    var favicon: NSImage? { get }
    var mediaMuted: Bool { get }
    var windowFrame: CGRect { get set }
    var windowVisible: Bool { get set }
    func togglePlayPause()
    func nextTrack()
    func previousTrack()
    func skipAd()
    func toggleMicrophone()
    func toggleCamera()
    func hangUp()
    func nextSlide()
    func previousSlide()
    func seekTo(_ time: Double)
    func scrubTo(_ time: Double)
    func setMuted(_ muted: Bool)
    func closePausingVideo(_ pause: Bool)
}
