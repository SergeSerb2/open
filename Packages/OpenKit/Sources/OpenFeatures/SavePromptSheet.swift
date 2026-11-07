import AppKit
import OpenDesign
import OpenWeb

public struct SavePromptText {
    public let title: String
    public let body: String
    public let buttons: [DialogSheetButton]
    @MainActor public init(kind: SavePromptKind, displayHost: String, offersNeverForSite: Bool) {
        switch kind {
        case .password, .passwordUpdate:
            title = Self.passwordTitle(displayHost)
            body = "That way, it’ll be auto-filled next time"
            buttons = (kind == .password && offersNeverForSite ? [.init("Never on this site", role: .leading)] : [])
                + [.init("No", role: .cancel), .init("Save", role: .primary)]
        case .card:
            title = "Save this card?"; body = "That way, it can be auto-filled next time"
            buttons = [.init("Not Now", role: .cancel), .init("Save", role: .primary)]
        case .address, .addressUpdate:
            title = "Save Address?"; body = "Saved addresses will appear in auto-fill next time you order something."
            buttons = [.init("No Thanks", role: .cancel), .init("Save", role: .primary)]
        }
    }
    @MainActor private static func passwordTitle(_ host: String) -> String {
        guard !host.isEmpty else { return "Save this password?" }
        func title(_ host: String) -> String { "Save password for \(host)?" }
        let maximum = DialogSheetView.textHeight("A\nA", font: Typography.promptTitle.font)
        func fits(_ value: String) -> Bool { DialogSheetView.textHeight(title(value), font: Typography.promptTitle.font) <= maximum }
        if fits(host) { return title(host) }
        let characters = Array(host)
        func shortened(_ count: Int) -> String {
            String(characters.prefix((count + 1) / 2)) + "…" + String(characters.suffix(count / 2))
        }
        var low = 0, high = characters.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(shortened(middle)) { low = middle } else { high = middle - 1 }
        }
        return title(shortened(low))
    }
}

@MainActor public final class SavePromptSheet: DialogSheetPanel {
    public let kind: SavePromptKind
    public private(set) var request: (any SavePromptRequest)?
    public var onFinished: (() -> Void)?
    public static let maximumHostBytes = 4096
    public init?(_ request: any SavePromptRequest) {
        guard !request.isAnswered, request.displayHost.utf8.count <= Self.maximumHostBytes else { return nil }
        self.request = request; kind = request.kind
        // <=4096 host bytes; only the bounded, two-line title is laid out in the
        // sheet. A render backing at 2x is bounded by 840×410×4 = 1,377,600 bytes.
        let text = SavePromptText(kind: request.kind, displayHost: request.displayHost, offersNeverForSite: request.offersNeverForSite)
        super.init(title: text.title, body: text.body, buttons: text.buttons)
        dialogView.onPress = { [weak self] role in self?.answer(role) }
    }
    @available(*, unavailable) required public init?(coder: NSCoder) { fatalError() }
    private func answer(_ role: DialogSheetButton.Role) {
        guard let request else { return }
        self.request = nil // Clear ownership before an engine callback can withdraw/reenter.
        if !request.isAnswered {
            request.answer(role == .primary ? .save : role == .leading ? .neverForSite : .dismiss)
        }
        onFinished?()
    }
    public func releaseUnanswered() { request = nil }
    public override func close() { releaseUnanswered(); onFinished?(); super.close() }
}
