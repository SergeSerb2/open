import AppKit
import OpenMedia
import OpenModel
import OpenWeb

/// Exact PP-8 order, backed by the same settings/site matching as AutoPiPPolicy.
@MainActor public final class PiPMenuBuilder {
    private let host: any WebPictureInPictureHost
    private let sourceURL: URL?
    private let settings: MediaSettings
    private let privateSession: MediaSettings.PrivateHosts?
    private let pasteboard: NSPasteboard
    public var onTopChanged: ((Bool) -> Void)?
    public var onMuteChanged: (() -> Void)?
    public init(host: any WebPictureInPictureHost, sourceURL: URL?, settings: MediaSettings,
                privateSession: MediaSettings.PrivateHosts? = nil, pasteboard: NSPasteboard = .general) {
        self.host = host; self.sourceURL = sourceURL; self.settings = settings
        self.privateSession = privateSession; self.pasteboard = pasteboard
    }
    public func build(document: Bool = false) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for entry in PiPMenuEntry.entries(url: sourceURL, muted: host.mediaMuted, keepOnTop: settings.keepOnTop,
                                          disabledHosts: settings.disabledHosts(privateSession: privateSession), document: document) {
            if entry.isSeparator { menu.addItem(.separator()); continue }
            guard let action = entry.action else {
                let header = NSMenuItem(title: entry.title, action: nil, keyEquivalent: ""); header.isEnabled = false; menu.addItem(header); continue
            }
            let item = PiPMenuItem(entry.title) { [self] in
                switch action {
                case .keepOnTop: settings.keepOnTop.toggle(); onTopChanged?(settings.keepOnTop)
                case .openAutomatically, .turnOff:
                    if let name = sourceURL?.host { settings.setAutomatic(action == .openAutomatically, host: name, privateSession: privateSession) }
                case .copyURL:
                    if let sourceURL {
                        let clean = URLCleaner.clean(sourceURL).url.absoluteString
                        pasteboard.clearContents(); pasteboard.setString(clean, forType: .string); pasteboard.setString(clean, forType: .URL)
                    }
                case .toggleMute: host.setMuted(!host.mediaMuted); onMuteChanged?()
                }
            }
            item.state = entry.checked ? .on : .off; menu.addItem(item)
        }
        return menu
    }
}

@MainActor private final class PiPMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: ""); target = self
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}
