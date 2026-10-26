import Foundation
import Observation
import OpenModel
import OpenWeb

/// Runtime only. The mini player reads its title/favicon from the tab, never session metadata (PP-15).
@MainActor @Observable public final class MediaSource {
    public enum Origin: Sendable { case tab, auxiliaryPage }
    public enum Kind: Sendable { case audioVideo, recording }
    public enum PiP: Sendable, Equatable { case none, active(auto: Bool), minimized }
    public let origin: Origin
    /// Auxiliary content such as a Peek has its own page identity and no sidebar tab (PK-9).
    public let tabID: ItemID?
    public let pageID: UUID?
    public internal(set) var windowID: WindowID
    public internal(set) var kind: Kind = .audioVideo
    public internal(set) var playback: WebMediaState.Playback = .none
    public internal(set) var isControllable = false
    public internal(set) var hasVideo = false
    public internal(set) var largestVideoArea: Double = 0
    public internal(set) var actions: WebMediaActions = []
    public internal(set) var isMuted = false
    public internal(set) var volume: Double?
    public internal(set) var microphoneOn: Bool?
    public internal(set) var cameraOn: Bool?
    public internal(set) var pip: PiP = .none
    public internal(set) var lastStartedAt: Date?
    public internal(set) var lastInteractionAt: Date?
    public internal(set) var pausedAt: Date?
    internal var userDismissed = false
    internal var enginePictureInPicture = false
    internal var lastState = WebMediaState()
    internal var isCapturing = false
    internal var order: UInt64 = 0
    internal init(tabID: ItemID, windowID: WindowID) {
        origin = .tab; self.tabID = tabID; pageID = nil; self.windowID = windowID
    }
    internal init(pageID: UUID, windowID: WindowID) {
        origin = .auxiliaryPage; tabID = nil; self.pageID = pageID; self.windowID = windowID
    }
}
