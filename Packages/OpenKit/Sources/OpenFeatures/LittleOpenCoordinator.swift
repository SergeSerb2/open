import AppKit
import Observation
import OpenModel
import OpenRouting
import OpenDesign

/// AppKit coordinates. Injection makes the window placement independent of the desktop.
public struct LittleOpenScreen: Sendable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    public init(frame: CGRect, visibleFrame: CGRect) { self.frame = frame; self.visibleFrame = visibleFrame }
    @MainActor public static func pointerScreen() -> LittleOpenScreen {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        // Guess only when no display exists (offscreen callers inject their screen).
        return LittleOpenScreen(frame: screen?.frame ?? LittleOpenMetrics.fallbackScreenFrame,
                                visibleFrame: screen?.visibleFrame ?? LittleOpenMetrics.fallbackScreenFrame)
    }
}

public enum LittleOpenWindowState: String, Sendable { case bar, page }

@MainActor
public struct LittleOpenAutomationState {
    public let id: WindowID
    public let window: NSWindow
    public let state: LittleOpenWindowState
    public let currentURL: URL
    public let profileID: ProfileID
    public let pillSpaceID: SpaceID?
    public let lastActiveAt: Date
}

@MainActor
@Observable
public final class LittleOpenCoordinator {
    public private(set) var sessions: [LittleOpenSession] = []
    @ObservationIgnored public private(set) var controllers: [WindowID: LittleOpenWindowController] = [:]
    @ObservationIgnored public let model: BrowserModel
    @ObservationIgnored private let archiveSink: (any ArchiveSink)?
    @ObservationIgnored let makeWebContent: (ProfileID) -> any LittleOpenWebContentProviding
    @ObservationIgnored let screenProvider: () -> LittleOpenScreen
    @ObservationIgnored private var lastKeyDownTimestamp: TimeInterval?
    @ObservationIgnored private var introClaimed = false
    @ObservationIgnored public var onSwitchToTab: ((ItemID, SpaceID?) -> Void)?
    @ObservationIgnored public var performCommand: ((String, SpaceID?) -> Void)?
    @ObservationIgnored public var isActionEnabled: ((String, SpaceID?) -> Bool)?
    @ObservationIgnored public var presentWindows = true
    @ObservationIgnored public var onChange: (() -> Void)?
    /// Return true while the App's page-close preflight owns the request.
    @ObservationIgnored public var requestPageClose: ((WindowID, @escaping (Bool) -> Void) -> Bool)?
    @ObservationIgnored public var onOpenInMain: ((WindowID, ItemID, (any WebContentHost)?) -> Void)?
    @ObservationIgnored public var confirmProfileSwitch: ((ProfileID, @escaping (Bool) -> Void) -> Void)?
    @ObservationIgnored public var defaults = UserDefaults.standard
    public init(model: BrowserModel, archiveSink: (any ArchiveSink)?,
                screenProvider: @escaping () -> LittleOpenScreen = { LittleOpenScreen.pointerScreen() },
                makeWebContent: @escaping (ProfileID) -> any LittleOpenWebContentProviding) {
        self.model = model; self.archiveSink = archiveSink; self.makeWebContent = makeWebContent
        self.screenProvider = screenProvider
    }
    isolated deinit { for c in controllers.values { c.container.closeAll(); c.window?.orderOut(nil) } }
    /// Read-only live state for the App's automation adapter.
    public var stateForAutomation: [LittleOpenAutomationState] {
        sessions.compactMap { session in
            guard let controller = controllers[session.id], let window = controller.window else { return nil }
            return LittleOpenAutomationState(id: session.id, window: window, state: controller.state,
                currentURL: controller.currentURL ?? session.tab.url, profileID: session.profileID,
                pillSpaceID: controller.pillSpaceID, lastActiveAt: session.lastActiveAt)
        }
    }
    func claimIntro() -> Bool {
        guard !introClaimed, !defaults.bool(forKey: "open.links.littleOpenNUXSeen") else { return false }
        introClaimed = true
        defaults.set(true, forKey: "open.links.littleOpenNUXSeen")
        return true
    }
    private var defaultProfile: ProfileID? {
        model.windows.compactMap { model.space(id: $0.focusedSpaceID)?.profileID }.first ?? model.profiles.first?.id
    }
    public func open(url: URL, profileHint: ProfileID?) {
        guard let profile = profileHint.flatMap({ model.profile(id: $0)?.id }) ?? defaultProfile else { return }
        let canonical = HostNormalizer.canonicalURLString(url)
        if let session = sessions.first(where: { $0.profileID == profile && HostNormalizer.canonicalURLString(controllers[$0.id]?.currentURL ?? $0.tab.url) == canonical }) {
            resurface(session.id); return
        }
        create(url: url, profile: profile, focus: false)
    }
    /// Every press creates a window; only duplicate delivery of the same key-down coalesces.
    public func openBlank(focusURLField: Bool, keyDownTimestamp: TimeInterval? = nil) {
        if let timestamp = keyDownTimestamp, timestamp.isFinite {
            if let previous = lastKeyDownTimestamp, abs(timestamp - previous) < LittleOpenMetrics.samePressTolerance { return }
            lastKeyDownTimestamp = timestamp
        }
        guard let profile = defaultProfile else { return }
        create(url: URL(string: "about:blank")!, profile: profile, focus: focusURLField)
    }
    /// Explicit Profile pages (Settings and extension management) always create
    /// a window; external-link URL reuse remains owned by open(url:profileHint:).
    @discardableResult
    public func create(url: URL, profile: ProfileID? = nil, focus: Bool) -> ItemID? {
        guard let profile = profile ?? defaultProfile, model.profile(id:profile) != nil else { return nil }
        let tab = Tab(url: url); tab.live.sleepPhase = .live
        let session = LittleOpenSession(tab: tab, profileID: profile)
        let controller = LittleOpenWindowController(session: session, coordinator: self, factory: LittleHostFactory(makeWebContent), defaults: defaults)
        sessions.insert(session, at: 0); controllers[session.id] = controller
        resurface(session.id); if focus { controller.focusURL() }; onChange?()
        return tab.id
    }
    public func resurface(_ id: WindowID) {
        guard let session = sessions.first(where: { $0.id == id }), let controller = controllers[id] else { return }
        session.lastActiveAt = Date()
        if presentWindows { controller.presentWindow() }
        controller.updateVisibility()
        sessions.sort { $0.lastActiveAt > $1.lastActiveAt }; onChange?()
    }
    public func recordActivity(_ id: WindowID) {
        sessions.first { $0.id == id }?.lastActiveAt = Date()
        sessions.sort { $0.lastActiveAt > $1.lastActiveAt }; onChange?()
    }
    public func moveToSpace(sessionID: WindowID, spaceID: SpaceID) {
        guard let session = sessions.first(where: { $0.id == sessionID }), let space = model.space(id: spaceID), let controller = controllers[sessionID] else { return }
        let url = controller.currentURL ?? session.tab.url
        func tabs(_ nodes: [SidebarNode]) -> [Tab] {
            nodes.flatMap { node in switch node { case .tab(let t): [t]; case .folder(let f): tabs(f.children); case .split(let s): s.panes } }
        }
        let canonical = HostNormalizer.canonicalURLString(url)
        let existing = tabs(space.pinned + space.today).first { HostNormalizer.canonicalURLString($0.url) == canonical }
        let tab = existing ?? model.newTab(in: spaceID, url: url, title: session.tab.title, at: 0)
        tab.live.sleepPhase = .live
        let main: BrowserWindowState
        if let current = model.windows.first(where: { $0.style == .standard }) { main = current; model.focusSpace(windowID: main.id, spaceID: spaceID) }
        else { main = BrowserWindowState(focusedSpaceID: spaceID); model.windows.append(main) }
        if case .splitPane(let splitID)? = model.parent(of: tab.id) {
            model.selectNode(windowID: main.id, spaceID: spaceID, nodeID: splitID); model.focusSplitPane(splitID: splitID, tabID: tab.id)
        } else { model.selectNode(windowID: main.id, spaceID: spaceID, nodeID: tab.id) }
        // Reparent only within the same profile; profile data cannot cross contexts.
        let host = existing == nil && session.profileID == space.profileID ? controller.container.takeHost(for: session.tab.id) : nil
        onOpenInMain?(main.id, tab.id, host)
        // With no App target, no recipient exists; release the detached host explicitly.
        if onOpenInMain == nil { host?.close() }
        close(sessionID: sessionID, archiveReason: nil)
    }
    public func close(sessionID: WindowID, archiveReason: ArchiveReason?) {
        close(sessionID: sessionID, archiveReason: archiveReason, now: Date())
    }
    private func close(sessionID: WindowID, archiveReason: ArchiveReason?, now: Date, preflight: Bool = true) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        if preflight, archiveReason == nil, requestPageClose?(sessionID, { [weak self] allowed in
            if allowed { self?.close(sessionID: sessionID, archiveReason: archiveReason, now: now, preflight: false) }
        }) == true { return }
        if let reason = archiveReason { archiveSink?.archive([ArchiveEntry(tab: session.tab, reason: reason, originalLocation: "littleOpen:\(session.id)", spaceID: nil, profileID: session.profileID, archivedAt: now)]) }
        session.windowIsVisible = false
        sessions.removeAll { $0.id == sessionID }
        if let controller = controllers.removeValue(forKey: sessionID) { controller.prepareToClose(); controller.closeWindow() }
        onChange?()
    }
    public func showAll() { for session in Array(sessions.reversed()) { resurface(session.id) } }
    public func closeAll() { for session in Array(sessions) { close(sessionID: session.id, archiveReason: nil) } }
    /// No polling timer: the App's ExpirySweeper schedules this deadline and observes onChange.
    public func nextExpiry(now: Date) -> Date? {
        sessions.compactMap { session in
            model.profile(id: session.profileID)?.settings.littleOpenAutoArchiveAfter.seconds.map {
                session.lastActiveAt.addingTimeInterval($0)
            }
        }.min()
    }
    @discardableResult public func archiveExpired(now: Date) -> Int {
        let expired = sessions.filter { session in
            guard let interval = model.profile(id: session.profileID)?.settings.littleOpenAutoArchiveAfter.seconds else { return false }
            return now >= session.lastActiveAt.addingTimeInterval(interval)
        }.sorted { $0.lastActiveAt < $1.lastActiveAt }
        for session in expired { close(sessionID: session.id, archiveReason: .autoArchived, now: now) }; return expired.count
    }
    public func switchProfile(sessionID: WindowID, profileID: ProfileID) {
        guard let session = sessions.first(where: { $0.id == sessionID }), session.profileID != profileID, model.profile(id: profileID) != nil else { return }
        let apply: (Bool) -> Void = { [weak self, weak session] confirmed in
            guard confirmed, let self, let session, self.sessions.contains(where: { $0 === session }) else { return }
            session.profileID = profileID; self.controllers[sessionID]?.replaceProfile(); self.onChange?()
        }
        if defaults.bool(forKey: "open.links.littleOpenProfileSwitchConfirmed") { apply(true) }
        else if let confirmProfileSwitch { confirmProfileSwitch(profileID, apply) }
        else if let window = controllers[sessionID]?.window, presentWindows {
            let alert = NSAlert(); alert.messageText = "Switch Profile?"
            alert.informativeText = "Each Profile has different browser data, so this webpage might look a little different."
            alert.addButton(withTitle: "Switch Profile"); alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { apply(response == .alertFirstButtonReturn) } }
        }
    }
    public func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Little Open Windows")
        for s in sessions { menu.addItem(FeatureMenuItem(s.tab.title.isEmpty || s.tab.url.absoluteString == "about:blank" ? "Little Open" : s.tab.title) { [weak self] in self?.resurface(s.id) }) }
        menu.addItem(.separator()); menu.addItem(FeatureMenuItem("Show Little Open Windows") { [weak self] in self?.showAll() })
        menu.addItem(FeatureMenuItem("Close Little Open Windows") { [weak self] in self?.closeAll() }); return menu
    }
}
