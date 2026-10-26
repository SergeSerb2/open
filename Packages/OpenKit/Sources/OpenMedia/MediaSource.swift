import Foundation
import Observation
import OpenModel
import OpenWeb

/// Runtime only. The mini player reads its title/favicon from the tab, never session metadata (PP-15).
@MainActor @Observable public final class MediaSource {
    public enum Kind: Sendable { case audioVideo, recording }
    public enum PiP: Sendable, Equatable { case none, active(auto: Bool), minimized }
    public let tabID: ItemID
    public internal(set) var windowID: WindowID
    public internal(set) var kind: Kind = .audioVideo
    public internal(set) var playback: WebMediaState.Playback = .none
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
    internal var dismissed = false
    internal var order: UInt64 = 0
    internal init(tabID: ItemID, windowID: WindowID) { self.tabID = tabID; self.windowID = windowID }
}
