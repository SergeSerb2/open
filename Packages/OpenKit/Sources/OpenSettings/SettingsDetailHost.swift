import AppKit
import SwiftUI
import Observation
import QuartzCore
import OpenDesign

@MainActor @Observable final class SettingsPageState {
    var target: String?
    var revision = 0
}
private struct SettingsPageKey: EnvironmentKey {
    static let defaultValue: SettingsPageState? = nil
}
extension EnvironmentValues {
    var settingsPage: SettingsPageState? {
        get { self[SettingsPageKey.self] }
        set { self[SettingsPageKey.self] = newValue }
    }
}

/// AppKit owns only presentation lifetime. All values/actions remain in the
/// existing observable models. Only three measured cold pages are prepared once
/// during idle time; retained pages otherwise lay out only when shown.
struct SettingsDetailHost: NSViewRepresentable {
    let root: SettingsViewModel
    let section: SettingsSection
    let searching: Bool
    func makeNSView(context: Context) -> SettingsSectionHost { SettingsSectionHost(root: root) }
    func updateNSView(_ view: SettingsSectionHost, context: Context) {
        view.show(section, searching: searching)
    }
}

@MainActor final class SettingsSectionHost: NSView {
    private let root: SettingsViewModel
    private var pages: [SettingsSection: (NSView, SettingsPageState)] = [:]
    private var search: NSView?
    private var active: NSView?
    private var lastArrival = -1
    private var idleWork: DispatchWorkItem?
    private var idleSections: [SettingsSection] = [.links, .adBlocking, .shortcuts]
    override var isFlipped: Bool { true }
    init(root: SettingsViewModel) {
        self.root = root
        super.init(frame: .zero)
        wantsLayer = true
        root.onNavigation = { [weak self] in
            guard let self else { return }
            cancelIdlePreparation()
            show(self.root.selectedSection, searching: !self.root.searchQuery.isEmpty)
        }
        root.onUserInput = { [weak self] in self?.cancelIdlePreparation() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func page(for section: SettingsSection) -> (NSView, SettingsPageState) {
        if let page = pages[section] { return page }
        let state = SettingsPageState()
        let view = NSHostingView(rootView: SettingsDetail(root: root, sectionID: section, page: state))
        view.sizingOptions = []; view.safeAreaRegions = []
        let page: (NSView, SettingsPageState) = (view, state)
        pages[section] = page
        return page
    }
    private func cancelIdlePreparation() {
        idleWork?.cancel(); idleWork = nil; idleSections.removeAll()
        stopWaitingForSheet()
    }
    private var sheetEndObserver: NSObjectProtocol?
    private func stopWaitingForSheet() {
        if let sheetEndObserver { NotificationCenter.default.removeObserver(sheetEndObserver) }
        sheetEndObserver = nil
    }
    /// A sheet (the import wizard) owns the window: a cold page layout (about 20 ms, more on
    /// slower Macs) must not land inside its work. Resume once, when the sheet ends. No polling.
    private func resumeIdlePreparationAfterSheet(in window: NSWindow) {
        guard sheetEndObserver == nil else { return }
        sheetEndObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification,
                                                                  object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stopWaitingForSheet(); self.scheduleIdlePreparation()
            }
        }
    }
    private func scheduleIdlePreparation() {
        guard !idleSections.isEmpty, idleWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.idleWork?.isCancelled == false else { return }
                self.idleWork = nil
                guard let window = self.window, window.isVisible else { self.cancelIdlePreparation(); return }
                if window.attachedSheet != nil { self.resumeIdlePreparationAfterSheet(in: window); return }
                let section = self.idleSections.removeFirst()
                if self.pages[section] == nil {
                    let view = self.page(for: section).0
                    view.frame = self.bounds; view.isHidden = true
                    self.addSubview(view)
                    view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                }
                self.scheduleIdlePreparation()
            }
        }
        idleWork = work
        // One page per idle slice, after the first Settings frame. Input and
        // navigation cancel the remaining work; no idle source repeats.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    func show(_ section: SettingsSection, searching: Bool) {
        #if DEBUG || OPEN_AUTOMATION
        let start = CACurrentMediaTime()
        let wasCached = searching ? search != nil : pages[section] != nil
        #endif
        let next: NSView
        var page: SettingsPageState?
        if searching {
            if search == nil {
                let view = NSHostingView(rootView: ScrollView {
                    VStack(alignment: .leading, spacing: 24) { SettingsSearchResults(root: root) }
                        .frame(maxWidth: SettingsStyle.columnWidth, alignment: .leading)
                        .padding(.top, SettingsStyle.topInset).padding(.bottom, 28)
                        .frame(maxWidth: .infinity, alignment: .top).padding(.horizontal, 24)
                }.buttonStyle(OpenSettingsButtonStyle()))
                view.sizingOptions = []; view.safeAreaRegions = []; search = view
            }
            next = search!
        } else {
            (next, page) = self.page(for: section)
        }
        if let page, lastArrival != root.arrivalRevision {
            lastArrival = root.arrivalRevision
            if root.arrivalID != nil { page.target = root.arrivalID; page.revision &+= 1 }
            else if let scroll = outerScroll(in: next) {
                scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        guard active !== next else { return }
        #if DEBUG || OPEN_AUTOMATION
        let constructed = CACurrentMediaTime()
        #endif
        let hadContent = active != nil
        // Retaining a hidden graph must not retain its field editor or key
        // recorder as the window's input owner.
        if let active, let responder = window?.firstResponder {
            let view = (responder as? NSTextView)?.delegate as? NSView ?? responder as? NSView
            if let view, view === active || view.isDescendant(of: active) { window?.makeFirstResponder(nil) }
        }
        root.focusedSettingID = nil
        if searching || section != .shortcuts { root.endShortcutCapture() }
        active?.isHidden = true
        if next.frame != bounds { next.frame = bounds }
        if next.superview == nil { addSubview(next) }
        next.wantsLayer = true
        next.isHidden = false; active = next
        #if DEBUG || OPEN_AUTOMATION
        let attached = CACurrentMediaTime()
        #endif
        next.layoutSubtreeIfNeeded()
        #if DEBUG || OPEN_AUTOMATION
        let laidOut = CACurrentMediaTime()
        #endif
        next.displayIfNeeded()
        #if DEBUG || OPEN_AUTOMATION
        let displayed = CACurrentMediaTime()
        #endif
        // A cached page can reuse its backing layer without another draw. This
        // callback measures completed content layout/display submission, never
        // WindowServer scanout. The same scope applies to cold and warm pages.
        #if DEBUG || OPEN_AUTOMATION
        root.lastSectionPresentation = ["cached": wasCached ? 1 : 0, "constructMs": (constructed - start) * 1000, "showMs": (attached - constructed) * 1000, "layoutMs": (laidOut - attached) * 1000, "displayMs": (displayed - laidOut) * 1000]
        root.onSectionDraw?(section, displayed)
        #endif
        if !hadContent { scheduleIdlePreparation() }
        if hadContent {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = next.layer?.animation(forKey: "settings-section-fade") == nil ? 0 : next.layer?.presentation()?.opacity ?? 0; fade.toValue = 1; fade.duration = SettingsStyle.sectionDuration
            next.layer?.add(fade, forKey: "settings-section-fade")
            if !(Motion.reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
                let rise = CABasicAnimation(keyPath: "transform.translation.y")
                rise.fromValue = next.layer?.animation(forKey: "settings-section-rise") == nil ? -6 : next.layer?.presentation()?.value(forKeyPath: "transform.translation.y") ?? -6; rise.toValue = 0; rise.duration = SettingsStyle.sectionDuration
                next.layer?.add(rise, forKey: "settings-section-rise")
            }
        }
    }
    private func outerScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.outerScroll(in: $0) }.first
    }
    override func layout() {
        super.layout()
        active?.frame = bounds
    }
}
