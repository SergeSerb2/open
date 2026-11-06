import AppKit
import OpenCommandBar
import OpenSuggest

@MainActor final class SyntheticExtensionSource: ExtensionCommandBarSource {
    var actions: [ExtensionCommandBarAction] = [.init(id: "probe", name: "Action Probe", shortcutKeys: ["⇧", "⌘", "Y"])]
    var keywords: [ExtensionKeyword] = [.init(id: "probe", name: "Action Probe", keyword: "probe"), .init(id: "conflict", name: "Conflict", keyword: "yt"), .init(id: "partial", name: "Partial Site", keyword: "you")]
    var starts = 0, cancels = 0
    var deleted: [String] = []
    func startSession(extensionID: String) { starts += 1 }
    func cancelSession(extensionID: String) { cancels += 1 }
    func deleteSuggestion(_ content: String, extensionID: String) { deleted.append(content) }
    func defaultRow(extensionID: String, text: String) -> ExtensionOmniboxRow { .init(content: text, title: "Probe: %s") }
    func inputChanged(_ text: String, extensionID: String) async -> [ExtensionOmniboxRow]? {
        ["alpha", "alpine", "also"].filter { !deleted.contains($0) }.map { .init(content: $0, title: $0, boldRanges: [0..<min(2, $0.utf16.count)], deletable: true) }
    }
    init() { _ = Self.image }
    // Prebuilt before any view draws, as required of the App's engine icon source.
    private static let image = Synthetic.icon("•", color: 0xBF5AF2)
    static func icon(_ id: String) -> NSImage? { image }

}

@MainActor enum ExtensionFlows {
    static func run(_ env: Scenes.Env) -> [Flows.Check] {
        let source = SyntheticExtensionSource()
        env.engine.extensionSource = source
        defer { env.engine.extensionSource = nil }
        var checks: [Flows.Check] = []
        func check(_ name: String, _ pass: Bool, _ detail: String) {
            checks.append(.init(name: name, pass: pass, detail: detail))
            print("\(pass ? "PASS" : "FAIL")  \(name)  —  \(detail)")
        }
        func fresh(_ mode: CommandBarMode = .newTab) -> Stage {
            let s = Stage(size: CGSize(width: 1100, height: 760), scale: 2, engine: env.engine, backdrop: .darkPage)
            s.controller.extensionIcon = SyntheticExtensionSource.icon
            s.controller.present(Scenes.request(env, mode: mode)); s.settle()
            return s
        }
        do {
            let s = fresh(); s.type("action pro"); s.settle()
            let row = s.controller.rows.first
            s.key(.returnKey); s.settle()
            check("extension action Return closes and sends id", row?.kind == .extensionAction && row?.accessory == .keys(["⇧", "⌘", "Y"]) && !s.controller.isPresented && s.recorder.intents.last == .runExtensionAction(extensionID: "probe"), "\(s.recorder.intents)")
        }
        for entryKey in [Stage.Key.tab, .space] {
            let s = fresh(); s.type("probe"); s.settle()
            let hint = s.controller.view.debugTrailing
            let before = source.cancels
            s.key(entryKey); s.settle()
            let chip = s.controller.view.debugInput.chip
            let entered = s.controller.extensionScope?.id == "probe" && chip?.name == "Action Probe" && chip?.extensionID == "probe"
            s.type("al"); s.settle()
            let rows = s.controller.rows
            s.key(.escape); s.controller.dismiss(reason: .programmatic)
            check("extension keyword \(entryKey) → chip, ordered rows, Esc cancels once", hint.contains("Action Probe") && hint.contains("hint+space") && entered && rows.map(\.title) == ["Probe: al", "alpha", "alpine", "also"] && rows[1].boldRanges == [0..<2] && source.cancels == before + 1, "entered \(entered), rows \(rows.map(\.title)), cancels \(source.cancels - before)")
        }
        do {
            let s = fresh(); s.type("probe"); s.settle(); s.key(.tab); s.settle()
            let before = source.cancels
            s.key(.backspace); s.settle(); s.controller.dismiss(reason: .programmatic)
            check("extension Backspace on empty exits once", s.controller.extensionScope == nil && s.controller.text == "probe" && source.cancels == before + 1, "restored \(s.controller.text); cancels \(source.cancels - before)")
        }
        do {
            let s = fresh(); s.type("probe"); s.settle(); s.key(.tab); s.settle(); s.type("al"); s.settle()
            s.key(.down); s.key(.forwardDelete, flags: .shift); s.settle()
            check("extension Shift+Delete deletes the selected deletable row", source.deleted == ["alpha"] && !s.controller.rows.contains { $0.title == "alpha" } && s.controller.isPresented, "deleted \(source.deleted)")
            s.controller.dismiss(reason: .programmatic)
        }
        for (mode, flags, destination) in [(CommandBarMode.newTab, NSEvent.ModifierFlags(), CommandBarDestination.newTab), (.editCurrentURL, [], .currentTab), (.editCurrentURL, .command, .currentTab)] {
            let s = fresh(mode)
            s.fieldEditor?.selectAll(nil); s.type("probe"); s.settle(); s.key(.tab); s.settle(); s.type("beta"); s.settle()
            let before = source.cancels
            s.key(.returnKey, flags: flags); s.settle()
            let modifiers: CommandBarModifiers = flags.contains(.command) ? .command : []
            check("extension accept \(mode) \(flags.rawValue) reports content and disposition", s.recorder.intents.last == .extensionOmnibox(extensionID: "probe", content: "beta", destination: destination, modifiers: modifiers) && source.cancels == before && !s.controller.isPresented, "\(s.recorder.intents)")
        }
        do {
            let s = fresh(); s.type("probe"); s.settle(); s.key(.tab); s.settle()
            let before = source.cancels
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: s.window)
            s.controller.dismiss(reason: .programmatic)
            check("extension window change cancels once", !s.controller.isPresented && source.cancels == before + 1, "cancels \(source.cancels - before)")
        }
        do {
            let s = fresh(); s.type("yt"); s.settle(); s.key(.tab); s.settle()
            check("extension keyword conflict enters Site Search", s.controller.siteScope?.name == "YouTube" && s.controller.extensionScope == nil, "scope \(s.controller.scope?.title ?? "-")")
            s.controller.dismiss(reason: .programmatic)
        }
        do {
            let s = fresh(); s.type("you"); s.settle(); s.key(.tab); s.settle()
            check("extension exact keyword beats a partial site name", s.controller.extensionScope?.id == "partial", "scope \(s.controller.scope?.title ?? "-")")
            s.controller.dismiss(reason: .programmatic)
        }
        return checks
    }
}
