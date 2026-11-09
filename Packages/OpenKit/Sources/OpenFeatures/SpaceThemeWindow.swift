import AppKit

/// The Space controls only this window's frame. Attached surfaces retain their
/// previous system appearance, unless they choose an explicit appearance.
@MainActor
class SpaceThemeWindow: NSWindow {
    /// Private windows already kept their content and inherited sheets dark.
    var contentAppearanceOverride: NSAppearance?
    @MainActor
    private final class Attachment {
        weak var window: NSWindow?
        var pinnedAppearance: NSAppearance?
        var observation: NSKeyValueObservation?
        var updating = false
        init(_ window: NSWindow) { self.window = window }
    }
    private var attachments: [ObjectIdentifier: Attachment] = [:]
    private var systemAppearanceObservation: NSKeyValueObservation?

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
    override func addChildWindow(_ childWin: NSWindow, ordered place: NSWindow.OrderingMode) {
        preserveAppearance(of: childWin)
        super.addChildWindow(childWin, ordered: place)
    }
    override func removeChildWindow(_ childWin: NSWindow) {
        super.removeChildWindow(childWin)
        releaseAppearance(of: childWin)
    }

    private func preserveAppearance(of window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard attachments[id] == nil else { return }
        let attachment = Attachment(window)
        attachments[id] = attachment
        attachment.observation = window.observe(\.appearance, options: [.new]) { [weak self, weak attachment] _, _ in
            MainActor.assumeIsolated {
                guard let self, let attachment, !attachment.updating, let window = attachment.window else { return }
                // A panel can choose a mode after attachment (the theme editor).
                attachment.pinnedAppearance = nil
                if window.appearance == nil { self.pin(attachment) }
            }
        }
        if window.appearance == nil { pin(attachment) }
        if systemAppearanceObservation == nil {
            systemAppearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for attachment in Array(self.attachments.values) where attachment.pinnedAppearance != nil {
                        self.pin(attachment)
                    }
                }
            }
        }
    }
    private func pin(_ attachment: Attachment) {
        guard let window = attachment.window else { return }
        let appearance = contentAppearanceOverride ?? NSApp.effectiveAppearance
        attachment.updating = true
        defer { attachment.updating = false }
        if window.appearance?.name != appearance.name { window.appearance = appearance }
        attachment.pinnedAppearance = window.appearance
    }
    private func releaseAppearance(of window: NSWindow) {
        guard let attachment = attachments.removeValue(forKey: ObjectIdentifier(window)) else { return }
        attachment.observation = nil
        if let pinned = attachment.pinnedAppearance, window.appearance === pinned { window.appearance = nil }
        if attachments.isEmpty { systemAppearanceObservation = nil }
    }
}
