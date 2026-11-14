import Foundation
import CoreGraphics
import Security

// OpenWeb: the Swift view of the web engine for OpenKit libraries.
//
// OpenKit never imports OpenEngine (the ObjC++ CEF layer). Libraries that
// need a page, a profile's scripts and filters, or extension actions take
// these protocols; the App target makes the OpenEngine classes conform
// (App/EngineBridge.swift). That keeps the engine swappable and keeps CEF
// out of every package. See docs/engine-api.md for the engine side.

// MARK: - Web content

public enum SavePromptKind: Sendable { case password, passwordUpdate, card, address, addressUpdate }
public enum SavePromptAnswer: Sendable { case save, neverForSite, dismiss }

/// Releasing an unanswered request means ignored, rather than a user dismissal.
@MainActor public protocol SavePromptRequest: AnyObject {
    var kind: SavePromptKind { get }
    var displayHost: String { get }
    var offersNeverForSite: Bool { get }
    var isAnswered: Bool { get }
    func answer(_ answer: SavePromptAnswer)
}

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

/// A full-page capture (EP-8).
public struct FullPagePNG: Sendable {
    public var data: Data
    /// The page was taller than the cap and was cut there.
    public var truncated: Bool
    public init(data: Data, truncated: Bool) { self.data = data; self.truncated = truncated }
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
    var securityLevel: WebSecurityLevel { get }
    /// Leaf first; empty for non-TLS or refused oversized chains.
    var certificateChain: [SecCertificate] { get }

    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload()
    func stopLoading()

    /// Runs `script` in the page's main world (promises are awaited) and
    /// returns a JSON-compatible value; undefined and null come back as NSNull.
    func evaluateJavaScript(_ script: String) async throws -> Any
    func evaluateJavaScript(_ script: String, in world: ScriptWorld) async throws -> Any
    /// Main-thread Open-world transport. documentID is Chromium's document token.
    var onOpenWorldMessage: ((String, String, String) -> Void)? { get set }
    /// PNG of the visible page.
    func snapshotPNG() async throws -> Data
    /// A visible-viewport capture for a transition, without emulating another
    /// viewport or asking the renderer to capture beyond its current view.
    func motionSnapshotPNG() async throws -> Data
    /// PNG of the whole page at device scale, at most `maxDevicePixels` tall (page-platform
    /// EP-8; `OEWebContent.captureFullPage`). `truncated` says the page was cut at the cap.
    func fullPagePNG(maxDevicePixels: Int) async throws -> FullPagePNG

    func find(_ text: String, forward: Bool, caseSensitive: Bool)
    func stopFinding(clearSelection: Bool)
}

// MARK: - Profile (scripts, network filter, permissions)

public enum ScriptWorld: Sendable, Hashable { case page, open }
public enum ScriptWorldError: Error { case unsupported }

extension WebContent {
    public func motionSnapshotPNG() async throws -> Data { try await snapshotPNG() }
    /// Alternate backends must opt in to Open's isolated world.
    public func evaluateJavaScript(_ script: String, in world: ScriptWorld) async throws -> Any {
        guard world == .page else { throw ScriptWorldError.unsupported }
        return try await evaluateJavaScript(script)
    }
    public var onOpenWorldMessage: ((String, String, String) -> Void)? {
        get { nil }
        set {}
    }
}

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
    public var world: ScriptWorld

    public init(
        id: String, source: String, kind: UserScriptKind = .javaScript,
        injectionTime: UserScriptInjectionTime = .documentStart,
        matchPatterns: [String], mainFrameOnly: Bool = true, world: ScriptWorld = .page
    ) {
        self.id = id; self.source = source; self.kind = kind
        self.injectionTime = injectionTime; self.matchPatterns = matchPatterns
        self.mainFrameOnly = mainFrameOnly; self.world = world
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
    func changedSiteSettings(origin: URL) -> [WebSiteSetting]
    @discardableResult
    func setSiteSetting(_ state: WebSiteSettingState, kind: String, origin: URL) -> Bool
    func clearSiteData(origin: URL, kinds: WebSiteDataKinds) async throws
    func setPermission(_ state: SitePermissionState, for permission: SitePermission, origin: URL)
}

// MARK: - Extensions

/// Immutable engine image. Identity changes only when engine pixels change.
/// At most 2048² RGBA pixels per rep (16 MiB single allocation).
public final class ExtensionImage: @unchecked Sendable, Hashable {
    public let cgImage: CGImage
    public let pointSize: CGSize
    public let image1x: CGImage?
    public init?(cgImage: CGImage, pointSize: CGSize, image1x: CGImage? = nil) {
        guard pointSize.width.isFinite, pointSize.height.isFinite,
              pointSize.width > 0, pointSize.height > 0, pointSize.width <= 512, pointSize.height <= 512,
              [cgImage, image1x].compactMap({ $0 }).allSatisfy({ $0.width <= 2048 && $0.height <= 2048 }) else { return nil }
        self.cgImage = cgImage; self.pointSize = pointSize; self.image1x = image1x
    }
    public func representation(scale: CGFloat) -> CGImage { scale <= 1 ? image1x ?? cgImage : cgImage }
    public static func == (lhs: ExtensionImage, rhs: ExtensionImage) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

public struct ExtensionActionInfo: Sendable, Hashable, Identifiable {
    public var id: String { extensionID }
    public var extensionID: String
    public var name: String
    public var accessibleName: String
    public var tooltip: String
    public var toolbarImage: ExtensionImage?
    public var menuIcon: ExtensionImage?
    public var badgeText: String?
    public var isEnabled: Bool
    public var hasPopup: Bool
    public var isPinned: Bool
    public var pinnedIndex: Int?
    public var wantsToRun: Bool
    public var isShowingPopup: Bool
    public var shortcutKeys: [String]
    /// Compatibility with the current App bridge; removed by the App wiring step.
    public var title: String { get { tooltip } set { tooltip = newValue } }
    public var iconPNG: Data?
    public init(extensionID: String, name: String, accessibleName: String? = nil, tooltip: String? = nil,
                toolbarImage: ExtensionImage? = nil, menuIcon: ExtensionImage? = nil, badgeText: String? = nil,
                isEnabled: Bool = true, hasPopup: Bool = true, isPinned: Bool = false, pinnedIndex: Int? = nil,
                wantsToRun: Bool = false, isShowingPopup: Bool = false, shortcutKeys: [String] = []) {
        self.extensionID = extensionID; self.name = name; self.accessibleName = accessibleName ?? name
        self.tooltip = tooltip ?? name; self.toolbarImage = toolbarImage; self.menuIcon = menuIcon
        self.badgeText = badgeText; self.isEnabled = isEnabled; self.hasPopup = hasPopup
        self.isPinned = isPinned; self.pinnedIndex = pinnedIndex; self.wantsToRun = wantsToRun
        self.isShowingPopup = isShowingPopup; self.shortcutKeys = shortcutKeys
    }
    public init(extensionID: String, title: String, iconPNG: Data?, badgeText: String?, isEnabled: Bool, hasPopup: Bool) {
        self.init(extensionID: extensionID, name: title, badgeText: badgeText, isEnabled: isEnabled, hasPopup: hasPopup)
        self.iconPNG = iconPNG
    }
}
public typealias ExtensionItem = ExtensionActionInfo
public enum ExtensionRunSource: Sendable { case toolbarButton, menuEntry, command }

@MainActor public protocol ExtensionHost: AnyObject {
    var extensionActions: [ExtensionActionInfo] { get }
    var actionsReady: Bool { get }
    @discardableResult func executeAction(extensionID: String) -> Bool
    @discardableResult func executeAction(extensionID: String, source: ExtensionRunSource) -> Bool
    func setPinned(_ pinned: Bool, extensionID: String)
    func movePinned(extensionID: String, to index: Int)
    func contextMenu(extensionID: String, fromMenuItem: Bool) -> (any ExtensionMenu)?
    func closePopup()
    var onActionsChanged: (@MainActor () -> Void)? { get set }
    var onActionChanged: (@MainActor (ExtensionActionInfo) -> Void)? { get set }
}
/// Compatibility defaults permit the old App bridge to compile unchanged.
/// New adapters implement the source-aware call; the old call is its wrapper.
extension ExtensionHost {
    public var actionsReady: Bool { false }
    public func executeAction(extensionID: String) -> Bool { executeAction(extensionID: extensionID, source: .toolbarButton) }
    public func executeAction(extensionID: String, source: ExtensionRunSource) -> Bool { false }
    public func setPinned(_ pinned: Bool, extensionID: String) {}
    public func movePinned(extensionID: String, to index: Int) {}
    public func contextMenu(extensionID: String, fromMenuItem: Bool) -> (any ExtensionMenu)? { nil }
    public func closePopup() {}
    public var onActionsChanged: (@MainActor () -> Void)? { get { nil } set {} }
    public var onActionChanged: (@MainActor (ExtensionActionInfo) -> Void)? { get { nil } set {} }
}
@MainActor public protocol ExtensionMenu: AnyObject {
    var items: [ExtensionMenuItem] { get }
    func select(command: Int)
    func cancel()
}
public struct ExtensionMenuItem: Sendable, Codable, Equatable {
    public var command: Int
    public var title: String
    public var isEnabled: Bool
    public var isSeparator: Bool
    public var isChecked: Bool
    public var submenu: [ExtensionMenuItem]
    public init(command: Int = 0, title: String = "", isEnabled: Bool = true, isSeparator: Bool = false,
                isChecked: Bool = false, submenu: [ExtensionMenuItem] = []) {
        self.command = command; self.title = title; self.isEnabled = isEnabled
        self.isSeparator = isSeparator; self.isChecked = isChecked; self.submenu = submenu
    }
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
