import AppKit
import OpenModel
import OpenSuggest
import OpenDesign

@MainActor
final class FeatureRootView: NSView {
    var onLayout: (() -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); onLayout?() }
}

@MainActor
public final class LittleOpenWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    public let session: LittleOpenSession
    public private(set) var container: WebContentContainer
    private weak var coordinator: LittleOpenCoordinator?
    private let factory: any WebContentHostFactory
    private let defaults: UserDefaults
    let root = FeatureRootView(frame: CGRect(x: 0, y: 0, width: 720, height: 540))
    let toolbar = NSView()
    public let urlField = NSTextField()
    private var buttons: [ActionButton] = []
    private let banner = NSView()
    private let bannerLabel = NSTextField(labelWithString: "Open in Space keeps this page in your browser.")
    private var bannerButton: ActionButton!
    var offscreenKey = false
    var isKeyForReuse: Bool { window?.isKeyWindow == true || offscreenKey }
    public var currentURL: URL? { container.host(for: session.tab.id)?.currentURL }
    public init(session: LittleOpenSession, coordinator: LittleOpenCoordinator, factory: any WebContentHostFactory, defaults: UserDefaults) {
        self.session = session; self.coordinator = coordinator; self.factory = factory; self.defaults = defaults
        container = WebContentContainer(factory: factory)
        // Guess defaults: routing plan §9.3 / lead Q7. No App bundle exists yet.
        let window = NSWindow(contentRect: root.bounds, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.minSize = CGSize(width: 360, height: 240)
        super.init(window: window); window.contentView = root; window.delegate = self; window.title = "Little Open"
        // Offscreen harnesses never read/write the user's frame preferences or order a window.
        if coordinator.presentWindows {
            window.setFrameAutosaveName("LittleOpenWindow")
            let point = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
                window.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - window.frame.width / 2, y: screen.visibleFrame.midY - window.frame.height / 2))
            }
        }
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.addSubview(container); root.addSubview(toolbar); toolbar.addSubview(urlField)
        urlField.font = .systemFont(ofSize: 13); urlField.placeholderString = "Search or Enter URL…"; urlField.delegate = self
        urlField.target = self; urlField.action = #selector(submit)
        for (i, spec) in [("arrow.left", "Go back"), ("arrow.right", "Go forward"), ("arrow.clockwise", "Reload"), ("person.crop.circle", "Profile"), ("arrow.down.circle", "Downloads"), ("arrow.up.right.square", "Open in Space")].enumerated() {
            let b = ActionButton(symbol: spec.0, title: spec.1) { [weak self] in self?.press(i) }; toolbar.addSubview(b); buttons.append(b)
        }
        buttons[4].isEnabled = false
        banner.wantsLayer = true; banner.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        banner.addSubview(bannerLabel); bannerButton = ActionButton(symbol: "checkmark", title: "Got it") { [weak self] in
            self?.defaults.set(true, forKey: "open.links.littleOpenNUXSeen"); self?.banner.isHidden = true; self?.root.needsLayout = true
        }; banner.addSubview(bannerButton); root.addSubview(banner)
        banner.isHidden = defaults.bool(forKey: "open.links.littleOpenNUXSeen")
        root.onLayout = { [weak self] in self?.layoutContent() }
        configureContainer(); layoutContent()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    private func configureContainer() {
        container.tabProvider = { [weak session] id in session?.tab.id == id ? session?.tab : nil }
        container.onFocusedMetadata = { [weak self] title in
            guard let self else { return }; self.window?.title = self.session.tab.url.scheme == "about" ? "Little Open" : title
            self.urlField.stringValue = self.session.tab.url.scheme == "about" ? "" : self.session.tab.url.absoluteString
            self.buttons[0].isEnabled = self.container.host(for: self.session.tab.id)?.canGoBack ?? false
            self.buttons[1].isEnabled = self.container.host(for: self.session.tab.id)?.canGoForward ?? false
            self.coordinator?.onChange?()
        }
        container.onTabURLChanged = { [weak self] _, _ in if let self { self.coordinator?.recordActivity(self.session.id) } }
        container.show(tabIDs: [session.tab.id], focusedTabID: session.tab.id, orientation: .horizontal, fractions: [1], spaceID: SpaceID(), profileID: session.profileID)
    }
    private func layoutContent() {
        let w = root.bounds.width, h = root.bounds.height
        toolbar.frame = CGRect(x: 0, y: h - 40, width: w, height: 40)
        for i in 0..<3 { buttons[i].frame = CGRect(x: 6 + CGFloat(i) * 28, y: 6, width: 26, height: 28) }
        urlField.frame = CGRect(x: 96, y: 7, width: max(60, w - 202), height: 26)
        for i in 3..<6 { buttons[i].frame = CGRect(x: w - 100 + CGFloat(i - 3) * 32, y: 6, width: 30, height: 28) }
        let bannerHeight: CGFloat = banner.isHidden ? 0 : 30
        banner.frame = CGRect(x: 10, y: h - 40 - bannerHeight, width: w - 20, height: bannerHeight)
        bannerLabel.frame = CGRect(x: 8, y: 6, width: max(0, banner.bounds.width - 55), height: 18)
        bannerLabel.font = .systemFont(ofSize: 12); bannerButton.frame = CGRect(x: banner.bounds.width - 35, y: 2, width: 30, height: 26)
        container.frame = CGRect(x: 10, y: 10, width: max(0, w - 20), height: max(0, h - 60 - bannerHeight))
    }
    /// A fresh container on profile switch prevents cache reuse across browser profiles.
    func replaceProfile() {
        container.closeAll(); container.removeFromSuperview(); container = WebContentContainer(factory: factory)
        root.addSubview(container, positioned: .below, relativeTo: toolbar); configureContainer(); layoutContent()
    }
    public func focusURL() { window?.makeFirstResponder(urlField); urlField.selectText(nil) }
    @objc private func submit() {
        let input = urlField.stringValue
        let engine = SearchEngines.engine(id: coordinator?.model.profile(id: session.profileID)?.settings.searchEngineID)
        if let url = InputClassifier().classify(input).url ?? engine.searchURL(for: input) { container.host(for: session.tab.id)?.load(url) }
    }
    private func press(_ i: Int) {
        let host = container.host(for: session.tab.id)
        switch i {
        case 0: host?.goBack()
        case 1: host?.goForward()
        case 2: if host?.isLoading == true { host?.stop() } else { host?.reload() }
        case 3: profileMenu().popUp(positioning: nil, at: .zero, in: buttons[3])
        case 5: moveMenu().popUp(positioning: nil, at: .zero, in: buttons[5])
        default: break
        }
    }
    public func moveMenu() -> NSMenu {
        let menu = NSMenu(title: "Open in Space")
        for space in coordinator?.model.spaces ?? [] { menu.addItem(FeatureMenuItem(space.title) { [weak self] in
            guard let self else { return }; self.coordinator?.moveToSpace(sessionID: self.session.id, spaceID: space.id)
        }) }; return menu
    }
    private func profileMenu() -> NSMenu {
        let menu = NSMenu(title: "Profile")
        for profile in coordinator?.model.profiles ?? [] { menu.addItem(FeatureMenuItem(profile.name) { [weak self] in
            guard let self else { return }; self.coordinator?.switchProfile(sessionID: self.session.id, profileID: profile.id)
        }) }; return menu
    }
    public func windowShouldClose(_ sender: NSWindow) -> Bool { coordinator?.close(sessionID: session.id, archiveReason: nil); return false }
    public func windowDidBecomeKey(_ notification: Notification) { session.windowIsVisible = true; coordinator?.recordActivity(session.id) }
    public func windowDidMiniaturize(_ notification: Notification) { session.windowIsVisible = false; coordinator?.onChange?() }
    public func windowDidDeminiaturize(_ notification: Notification) { session.windowIsVisible = true; coordinator?.onChange?() }
    public func windowDidChangeOcclusionState(_ notification: Notification) {
        if let window { session.windowIsVisible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible) }; coordinator?.onChange?()
    }
}
