import AppKit
import OpenEngine
import OpenModel
import OpenWeb

/// OpenWeb's phase-2 PiP host over the engine's OEPictureInPicture (media-pip §7.1, EM-4).
/// The PiP window controller in OpenFeatures sees only this protocol.
@MainActor
final class EnginePictureInPictureHost: WebPictureInPictureHost {
  let pip: OEPictureInPicture
  let tabID: ItemID
  /// Mute goes through the tab (§4.4.5: "Mute"/"Unmute" toggles `tab.isMuted`).
  private let setTabMuted: (Bool) -> Void
  private let tabMuted: () -> Bool

  init(pip: OEPictureInPicture, tabID: ItemID, tabMuted: @escaping () -> Bool, setTabMuted: @escaping (Bool) -> Void) {
    self.pip = pip; self.tabID = tabID; self.tabMuted = tabMuted; self.setTabMuted = setTabMuted
  }

  var videoView: NSView { pip.videoView }
  var naturalSize: CGSize { pip.naturalSize }
  var sourceBounds: CGRect { pip.sourceBounds }
  var mediaState: WebMediaState {
    var actions: WebMediaActions = [.play, .pause, .seekTo, .exitPictureInPicture]
    let controls = pip.controls
    if controls.contains(.nextTrack) { actions.insert(.nextTrack) }
    if controls.contains(.previousTrack) { actions.insert(.previousTrack) }
    if controls.contains(.skipAd) { actions.insert(.skipAd) }
    if controls.contains(.toggleMicrophone) { actions.insert(.toggleMicrophone) }
    if controls.contains(.toggleCamera) { actions.insert(.toggleCamera) }
    if controls.contains(.hangUp) { actions.insert(.hangUp) }
    if controls.contains(.nextSlide) { actions.insert(.nextSlide) }
    if controls.contains(.previousSlide) { actions.insert(.previousSlide) }
    let meeting = !controls.isDisjoint(with: [.toggleMicrophone, .toggleCamera, .hangUp])
    return WebMediaState(
      playback: pip.playbackState == .playing ? .playing : .paused, isControllable: true, hasVideo: true,
      largestVideoArea: Double(pip.naturalSize.width * pip.naturalSize.height), actions: actions, isPictureInPicture: true,
      microphoneMuted: meeting ? pip.microphoneMuted : nil, cameraOn: meeting ? pip.cameraOn : nil,
      volume: nil, duration: pip.position?.duration)
  }
  var currentTime: Double { pip.position?.position ?? 0 }
  var playbackRate: Double { pip.playbackState == .playing ? (pip.position?.playbackRate ?? 1) : 0 }
  var positionUpdatedAt: Date { pip.position?.lastUpdated ?? Date() }
  var endOfMedia: Bool { pip.playbackState == .endOfVideo || pip.position?.isEndOfMedia == true }
  var sourceTitle: String { pip.sourceTitle }
  var favicon: NSImage? { pip.favicon }
  var mediaMuted: Bool { tabMuted() || pip.mediaMuted }
  var windowFrame: CGRect {
    get { pip.windowFrame }
    set { pip.windowFrame = newValue }
  }
  var windowVisible: Bool {
    get { pip.isWindowVisible }
    set { pip.isWindowVisible = newValue }
  }
  func togglePlayPause() { pip.togglePlayPause() }
  func nextTrack() { pip.nextTrack() }
  func previousTrack() { pip.previousTrack() }
  func skipAd() { pip.skipAd() }
  func toggleMicrophone() { pip.toggleMicrophone() }
  func toggleCamera() { pip.toggleCamera() }
  func hangUp() { pip.hangUp() }
  func nextSlide() { pip.nextSlide() }
  func previousSlide() { pip.previousSlide() }
  func seekTo(_ time: Double) { pip.seek(to: time) }
  func scrubTo(_ time: Double) { pip.seek(to: time) }
  func setMuted(_ muted: Bool) { setTabMuted(muted) }
  func closePausingVideo(_ pause: Bool) { pip.close(pausingVideo: pause) }
}
