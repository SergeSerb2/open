import AppKit
import OpenDesign

/// The Space controls only this window's frame. Attached surfaces retain their
/// previous system appearance, unless they choose an explicit appearance.
@MainActor
class SpaceThemeWindow: NSWindow, WindowContentAppearanceHost {
    /// Private windows already kept their content and inherited sheets dark.
    var contentAppearanceOverride: NSAppearance?
    @MainActor
    private final class Attachment {
        weak var window: NSWindow?
        var pinnedAppearance: NSAppearance?
        init(_ window: NSWindow) { self.window = window }
    }
    private var attachments: [ObjectIdentifier: Attachment] = [:]
    private var systemAppearanceObservation: NSKeyValueObservation?
    private static let contentWindowModules: Set<String> = [
        "Open", "OpenDesign", "OpenFeatures", "OpenSpaceEditor", "OpenSiteControl", "OpenExtensionsUI"
    ]

    override func beginSheet(_ sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        preserveAppearance(of: sheetWindow)
        super.beginSheet(sheetWindow) { [weak self, weak sheetWindow] response in
            if let sheetWindow { self?.releaseAppearance(of: sheetWindow) }
            handler?(response)
        }
    }
    override func beginCriticalSheet(_ sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        preserveAppearance(of: sheetWindow)
        super.beginCriticalSheet(sheetWindow) { [weak self, weak sheetWindow] response in
            if let sheetWindow { self?.releaseAppearance(of: sheetWindow) }
            handler?(response)
        }
    }
    override func addChildWindow(_ childWin: NSWindow?, ordered place: NSWindow.OrderingMode) {
        // Guard native nil callbacks despite AppKit's nonnull annotation.
        guard let childWin else { return }
        // Remote/ViewBridge and Safari AutoFill windows belong to macOS. Only
        // our own window subclasses opt into this policy through this path.
        let module = String(reflecting: type(of: childWin)).split(separator: ".", maxSplits: 1).first
        if let module, Self.contentWindowModules.contains(String(module)) {
            preserveAppearance(of: childWin)
        }
        super.addChildWindow(childWin, ordered: place)
    }
    override func removeChildWindow(_ childWin: NSWindow?) {
        guard let childWin else { return }
        super.removeChildWindow(childWin)
        releaseAppearance(of: childWin)
    }

    func contentAppearanceDidChange(for window: NSWindow, inheritsAppearance: Bool) {
        // Our presenter calls this after choosing nil (inherit) or an explicit
        // mode. Do not infer that choice by observing nullable native KVO.
        attachments.removeValue(forKey: ObjectIdentifier(window))
        if inheritsAppearance { trackAppearance(of: window) }
        if attachments.isEmpty { systemAppearanceObservation = nil }
    }

    private func preserveAppearance(of window: NSWindow?) {
        guard let window, window.appearance == nil else { return }
        trackAppearance(of: window)
    }
    private func trackAppearance(of window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard attachments[id] == nil else { return }
        let attachment = Attachment(window)
        attachments[id] = attachment
        pin(attachment)
        if systemAppearanceObservation == nil {
            systemAppearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for (id, attachment) in self.attachments {
                        guard let window = attachment.window,
                              let pinned = attachment.pinnedAppearance,
                              window.appearance === pinned else {
                            self.attachments.removeValue(forKey: id)
                            continue
                        }
                        self.pin(attachment)
                    }
                    if self.attachments.isEmpty { self.systemAppearanceObservation = nil }
                }
            }
        }
    }
    private func pin(_ attachment: Attachment) {
        guard let window = attachment.window else { return }
        let appearance = contentAppearanceOverride ?? NSApp.effectiveAppearance
        if window.appearance?.name != appearance.name { window.appearance = appearance }
        attachment.pinnedAppearance = window.appearance
    }
    private func releaseAppearance(of window: NSWindow) {
        guard let attachment = attachments.removeValue(forKey: ObjectIdentifier(window)) else { return }
        if let pinned = attachment.pinnedAppearance, window.appearance === pinned { window.appearance = nil }
        if attachments.isEmpty { systemAppearanceObservation = nil }
    }
}
