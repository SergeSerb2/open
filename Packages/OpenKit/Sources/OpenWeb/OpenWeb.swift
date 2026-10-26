import Foundation

// OpenWeb: the Swift view of the web engine for OpenKit libraries.
//
// OpenKit never imports OpenEngine (the ObjC++ CEF layer). Libraries that
// need a page, a profile's scripts and filters, or extension actions take
// these protocols; the App target makes the OpenEngine classes conform
// (App/EngineBridge.swift). That keeps the engine swappable and keeps CEF
// out of every package. See docs/engine-api.md for the engine side.

// MARK: - Web content

/// What changed in a web content. Mirrors the engine's change bits.
public struct WebContentChange: OptionSet, Sendable, Hashable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let url = WebContentChange(rawValue: 1 << 0)
    public static let title = WebContentChange(rawValue: 1 << 1)
    public static let favicon = WebContentChange(rawValue: 1 << 2)
    public static let loading = WebContentChange(rawValue: 1 << 3)
    public static let progress = WebContentChange(rawValue: 1 << 4)
    public static let navigationHistory = WebContentChange(rawValue: 1 << 5)
    public static let audio = WebContentChange(rawValue: 1 << 6)
    public static let fullscreen = WebContentChange(rawValue: 1 << 7)
    public static let crash = WebContentChange(rawValue: 1 << 8)
    public static let zoom = WebContentChange(rawValue: 1 << 9)
    public static let mediaCapture = WebContentChange(rawValue: 1 << 10)
    public static let statusText = WebContentChange(rawValue: 1 << 11)
    public static let live = WebContentChange(rawValue: 1 << 12)
    public static let media = WebContentChange(rawValue: 1 << 13)
    public static let pictureInPicture = WebContentChange(rawValue: 1 << 14)
}

/// One page. Split View, Peek, Little Arc, Boosts, and Zap work through this.
@MainActor
public protocol WebContent: AnyObject {
    var url: URL? { get }
    var title: String { get }
    /// PNG of the current favicon, when the engine has one.
    var faviconPNG: Data? { get }
    var isLoading: Bool { get }
    /// 0...1
    var estimatedProgress: Double { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var isAudible: Bool { get }
    var isMuted: Bool { get set }
    var isCrashed: Bool { get }
    /// 0 = 100%, each step is 20%.
    var zoomLevel: Double { get set }

    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload()
    func stopLoading()

    /// Runs `script` in the page's main world (promises are awaited) and
    /// returns a JSON-compatible value; undefined and null come back as NSNull.
    func evaluateJavaScript(_ script: String) async throws -> Any
    /// PNG of the visible page.
    func snapshotPNG() async throws -> Data

    func find(_ text: String, forward: Bool, caseSensitive: Bool)
    func stopFinding(clearSelection: Bool)
}

// MARK: - Profile (scripts, network filter, permissions)

public enum UserScriptKind: Sendable, Hashable {
    case javaScript
    case styleSheet
}

public enum UserScriptInjectionTime: Sendable, Hashable {
    /// Before any page script runs.
    case documentStart
    /// At DOMContentLoaded.
    case documentEnd
}

/// A Boost or Zap: code or CSS injected into matching pages of a profile.
public struct UserScript: Sendable, Hashable, Identifiable {
    public var id: String
    public var source: String
    public var kind: UserScriptKind
    public var injectionTime: UserScriptInjectionTime
    /// Chrome match patterns ("*://*.example.com/*", "<all_urls>").
    public var matchPatterns: [String]
    public var mainFrameOnly: Bool

    public init(
        id: String, source: String, kind: UserScriptKind = .javaScript,
        injectionTime: UserScriptInjectionTime = .documentStart,
        matchPatterns: [String], mainFrameOnly: Bool = true
    ) {
        self.id = id; self.source = source; self.kind = kind
        self.injectionTime = injectionTime; self.matchPatterns = matchPatterns
        self.mainFrameOnly = mainFrameOnly
    }
}

public enum ResourceType: Sendable, Hashable {
    case mainFrame, subFrame, stylesheet, script, image, font, media
    case xhr, fetch, ping, worker, serviceWorker, favicon, other
}

/// One network request, as the ad blocker sees it.
public struct ResourceRequestInfo: Sendable, Hashable {
    public var url: String
    public var method: String
    /// Top-level site of the page ("" if none).
    public var firstPartyURL: String
    /// Origin that started the request ("" if none).
    public var initiator: String
    public var type: ResourceType
    public var isNavigation: Bool

    public init(url: String, method: String, firstPartyURL: String, initiator: String, type: ResourceType, isNavigation: Bool) {
        self.url = url; self.method = method; self.firstPartyURL = firstPartyURL
        self.initiator = initiator; self.type = type; self.isNavigation = isNavigation
    }
}

/// Returns true to block. Runs on the engine's network thread for every
/// request of the profile, so it must be fast and thread-safe.
public typealias RequestFilter = @Sendable (ResourceRequestInfo) -> Bool

public enum SitePermission: Sendable, Hashable, CaseIterable {
    case camera, microphone, geolocation, notifications, clipboard, midi
    case screenCapture, automaticDownloads, storageAccess, windowManagement
    case localFonts, idleDetection
}

public enum SitePermissionState: Sendable, Hashable {
    case ask, allow, block
}

/// The engine side of one Open profile.
@MainActor
public protocol WebProfile: AnyObject {
    var identifier: String { get }
    var userScripts: [UserScript] { get }
    func addUserScript(_ script: UserScript)
    func removeUserScript(id: String)
    /// nil allows everything.
    func setRequestFilter(_ filter: RequestFilter?)
    func permission(_ permission: SitePermission, origin: URL) -> SitePermissionState
    func setPermission(_ state: SitePermissionState, for permission: SitePermission, origin: URL)
}

// MARK: - Extensions

/// One toolbar action, ready to draw.
public struct ExtensionActionInfo: Sendable, Hashable, Identifiable {
    public var id: String { extensionID }
    public var extensionID: String
    public var title: String
    public var iconPNG: Data?
    public var badgeText: String?
    public var isEnabled: Bool
    public var hasPopup: Bool

    public init(extensionID: String, title: String, iconPNG: Data?, badgeText: String?, isEnabled: Bool, hasPopup: Bool) {
        self.extensionID = extensionID; self.title = title; self.iconPNG = iconPNG
        self.badgeText = badgeText; self.isEnabled = isEnabled; self.hasPopup = hasPopup
    }
}

/// Extension actions of one window (the engine's tab strip).
@MainActor
public protocol ExtensionHost: AnyObject {
    var extensionActions: [ExtensionActionInfo] { get }
    /// Like a click on the action's button. Returns false when it cannot run.
    @discardableResult
    func executeAction(extensionID: String) -> Bool
}

// MARK: - Media (engine-free values; media/PiP plan §7.1)

public struct WebMediaActions: OptionSet, Sendable, Hashable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let play = Self(rawValue: 1 << 0)
    public static let pause = Self(rawValue: 1 << 1)
    public static let previousTrack = Self(rawValue: 1 << 2)
    public static let nextTrack = Self(rawValue: 1 << 3)
    public static let seekBackward = Self(rawValue: 1 << 4)
    public static let seekForward = Self(rawValue: 1 << 5)
    public static let seekTo = Self(rawValue: 1 << 6)
    public static let skipAd = Self(rawValue: 1 << 7)
    public static let stop = Self(rawValue: 1 << 8)
    public static let enterPictureInPicture = Self(rawValue: 1 << 9)
    public static let exitPictureInPicture = Self(rawValue: 1 << 10)
    public static let enterAutoPictureInPicture = Self(rawValue: 1 << 11)
    public static let toggleMicrophone = Self(rawValue: 1 << 12)
    public static let toggleCamera = Self(rawValue: 1 << 13)
    public static let hangUp = Self(rawValue: 1 << 14)
    public static let previousSlide = Self(rawValue: 1 << 15)
    public static let nextSlide = Self(rawValue: 1 << 16)
}

public struct WebMediaState: Sendable, Equatable {
    public enum Playback: Sendable { case none, paused, playing }
    public var playback: Playback
    public var isControllable: Bool
    public var hasVideo: Bool
    public var largestVideoArea: Double
    public var actions: WebMediaActions
    public var isPictureInPicture: Bool
    public var microphoneMuted: Bool?
    public var cameraOn: Bool?
    public var volume: Double?
    public var duration: Double?
    public init(playback: Playback = .none, isControllable: Bool = false, hasVideo: Bool = false,
                largestVideoArea: Double = 0, actions: WebMediaActions = [], isPictureInPicture: Bool = false,
                microphoneMuted: Bool? = nil, cameraOn: Bool? = nil, volume: Double? = nil, duration: Double? = nil) {
        self.playback = playback; self.isControllable = isControllable; self.hasVideo = hasVideo
        self.largestVideoArea = largestVideoArea; self.actions = actions; self.isPictureInPicture = isPictureInPicture
        self.microphoneMuted = microphoneMuted; self.cameraOn = cameraOn; self.volume = volume; self.duration = duration
    }
}

public enum WebMediaAction: Sendable, Equatable {
    case play, pause, previousTrack, nextTrack, seek(to: Double), skipAd, toggleMicrophone, toggleCamera, hangUp
}

@MainActor public protocol WebMediaHost: AnyObject {
    var mediaState: WebMediaState { get }
    func perform(_ action: WebMediaAction)
    func setVolume(_ volume: Double)
    func requestPictureInPicture() async -> Bool
    func exitPictureInPicture(pausing: Bool)
}
