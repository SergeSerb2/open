import AppKit
import OpenDesign
import OpenFeatures
import OpenWeb

@MainActor private final class SaveSheetFixture: SavePromptRequest {
    let kind: SavePromptKind
    let displayHost: String
    var offersNeverForSite: Bool { kind == .password }
    private(set) var isAnswered = false
    init(_ kind: SavePromptKind, host: String) { self.kind = kind; displayHost = host }
    func answer(_ answer: SavePromptAnswer) { isAnswered = true }
}

/// Render the production sheet with synthetic host metadata, without a page or
/// credentials. Request lifetimes and user input are verified in the real App.
@MainActor enum SaveSheetScenes {
    static func render(_ args: [String]) throws {
        let kinds: [String: SavePromptKind] = ["password": .password, "update": .passwordUpdate, "card": .card, "address": .address]
        guard let raw = RenderCLI.value(args, "--kind"), let kind = kinds[raw],
              let out = RenderCLI.value(args, "--out"),
              let scale = Double(RenderCLI.value(args, "--scale") ?? "1"), [1, 2].contains(scale),
              let appearance = ["light": NSAppearance.Name.aqua, "dark": .darkAqua][RenderCLI.value(args, "--appearance") ?? "light"]
        else { throw CLIError(description: "save-sheet requires --kind password|update|card|address --out FILE [--scale 1|2] [--appearance light|dark]") }
        NSApp.appearance = NSAppearance(named: appearance)
        guard let sheet = SavePromptSheet(SaveSheetFixture(kind, host: "login.example.com")) else { throw CLIError(description: "save sheet fixture refused") }
        let view = sheet.dialogView; sheet.contentView = nil
        OffscreenRenderer.writePNG(OffscreenRenderer().render(view, scale: scale), to: URL(fileURLWithPath: out))
        sheet.close()
        print("rendered \(out) \(view.frame.width)×\(view.frame.height) pt")
    }
    static func check(_ check: (Bool, String) -> Void) {
        let oldAppearance = NSApp.appearance
        defer { NSApp.appearance = oldAppearance }
        let rows: [(SavePromptKind, String, String, [String])] = [
            (.password, "password", "Save password for login.example.com?", ["Never on this site", "No", "Save"]),
            (.passwordUpdate, "update", "Save password for login.example.com?", ["No", "Save"]),
            (.card, "card", "Save this card?", ["Not Now", "Save"]),
            (.address, "address", "Save Address?", ["No Thanks", "Save"]),
            (.addressUpdate, "addressUpdate", "Save Address?", ["No Thanks", "Save"])
        ]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            for (kind, name, title, labels) in rows {
                guard let sheet = SavePromptSheet(SaveSheetFixture(kind, host: "login.example.com")) else { check(false, "save sheet \(name) created"); continue }
                defer { sheet.close() }
                let v = sheet.dialogView, t = v.titleLabel.frame, b = v.bodyLabel.frame
                let prefix = "save sheet \(name) \(appearance.rawValue)"
                check(v.frame.width == 420 && sheet.frame.width == 420, "\(prefix) width 420")
                check(sheet.title == title && v.titleLabel.maximumNumberOfLines == 2 && t.minX == 24 && t.minY == 24 && t.width == 372,
                    "\(prefix) title and frame")
                check(b.minX == 24 && b.width == 372 && b.minY == t.maxY + 8 && v.bodyLabel.maximumNumberOfLines == 3,
                    "\(prefix) body frame")
                let expectedBody = kind == .card ? "That way, it can be auto-filled next time" : kind == .address || kind == .addressUpdate
                    ? "Saved addresses will appear in auto-fill next time you order something." : "That way, it’ll be auto-filled next time"
                check(v.bodyLabel.stringValue == expectedBody, "\(prefix) exact body")
                check(v.buttonModels.map(\.label) == labels && v.buttons.map { $0.accessibilityLabel() ?? "" } == labels,
                    "\(prefix) button order and labels")
                check(v.buttons.allSatisfy { $0.frame.height == 28 && $0.frame.width >= 88 && $0.frame.minY == b.maxY + 20 && v.frame.maxY - $0.frame.maxY == 24 },
                    "\(prefix) button row frames")
                check(v.buttons.last?.frame.maxX == 396 && v.buttons[v.buttons.count - 2].frame.maxX == v.buttons.last!.frame.minX - 8
                    && (kind != .password || v.buttons.first?.frame.minX == 24), "\(prefix) button alignment and gap")
                check(zip(v.buttons, v.buttonModels).allSatisfy { button, model in
                    let textWidth = ceil(button.attributedTitle.size().width)
                    return button.frame.width == max(88, textWidth + 24) && button.layer?.cornerRadius == 8
                        && button.keyEquivalent == (model.role == .primary ? "\r" : model.role == .cancel ? "\u{1b}" : "")
                }, "\(prefix) label widths, radii and hints")
                check(sheet.defaultButtonCell === v.primaryButton?.cell && sheet.accessibilityDefaultButton() as? NSButton === v.primaryButton
                    && sheet.accessibilityCancelButton() as? NSButton === v.cancelButton, "\(prefix) default/cancel roles")
                check(v.buttons.indices.allSatisfy { v.buttons[$0].nextKeyView === v.buttons[($0 + 1) % v.buttons.count] },
                    "\(prefix) native button key view loop")
                check(sheet.accessibilityRole() == .sheet && sheet.accessibilityLabel() == title && v.titleLabel.accessibilityRole()?.rawValue == "AXHeading",
                    "\(prefix) accessible sheet and heading")
                if kind == .password { check((132...146).contains(v.frame.height), "\(prefix) one-line height about 140 (\(v.frame.height))") }
                sheet.contentView = nil
                let image = OffscreenRenderer().render(v, scale: 2)
                check(image.width == 840 && image.height == Int(v.frame.height * 2), "\(prefix) production view renders at 2x")
            }
        }
        let longHost = String(repeating: "long-subdomain-", count: 40) + "example.com"
        if let sheet = SavePromptSheet(SaveSheetFixture(.password, host: longHost)) {
            let v = sheet.dialogView
            check(sheet.title.contains("…") && DialogSheetView.textHeight(sheet.title, font: Typography.promptTitle.font) <= DialogSheetView.textHeight("A\nA", font: Typography.promptTitle.font),
                "save sheet long host middle-truncates to at most two lines")
            sheet.contentView = nil
            let image = OffscreenRenderer().render(v, scale: 2)
            check(image.width == 840 && image.height <= 410, "save sheet long host renders within bounded backing")
            sheet.close()
        } else { check(false, "save sheet long host created") }
        if let sheet = SavePromptSheet(SaveSheetFixture(.password, host: "")) {
            check(sheet.title == "Save this password?", "save sheet empty host fallback"); sheet.close()
        }
    }
}
