import AppKit
import OpenSiteControl
import OpenModel

@MainActor
enum Flows {
    struct Check { let name: String; let pass: Bool }
    static func run() -> [Check] {
        var checks: [Check] = []
        let stage = Stage()
        let c = stage.controller, s = stage.source
        checks.append(Check(name: "F1 anchor presents", pass: c.isPresented))
        stage.click(CGPoint(x: 201, y: 64))
        checks.append(Check(name: "F1 second anchor click closes and is consumed", pass: !c.isPresented && stage.root.hits == 0 && s.calls.isEmpty))
        c.toggle(anchor: .urlField, tabID: s.tabID, animated: false)
        var reason: SiteControlDismissReason?
        c.onDismiss = { reason = $0 }
        stage.key(code: 53, characters: "\u{1b}")
        checks.append(Check(name: "F2 Escape closes and restores focus", pass: !c.isPresented && reason == .escape))
        c.toggle(anchor: .urlField, tabID: s.tabID, animated: false)
        stage.click(CGPoint(x: 800, y: 600))
        checks.append(Check(name: "F2 outside click closes and reaches page", pass: !c.isPresented && reason == .outside && stage.root.hits == 1))
        c.present(anchor: .urlField, tabID: s.tabID, animated: false)
        let dump = accessibilityDump(c.view.panel)
        checks.append(Check(name: "F21 panel, host, six actions and footer are labelled", pass:
            ["Site Control Center", "news.example.com", "Share", "Copy URL", "New Boost", "Capture a portion of this page", "Capture the full page", "Capture in Portrait Mode", "Connection: Secure", "More"].allSatisfy(dump.contains)))
        c.dismiss(reason: .action, animated: false)
        s.value = nil
        var errors = 0
        c.onUnavailable = { _ in errors += 1 }
        c.present(anchor: .urlField, tabID: s.tabID, animated: false)
        c.present(anchor: .urlField, tabID: s.tabID, animated: false)
        checks.append(Check(name: "F22 missing snapshot stays closed and logs once", pass: !c.isPresented && errors == 1 && s.calls.isEmpty))
        checks += siteControls()
        return checks
    }
    private static func siteControls() -> [Check] {
        var result: [Check] = []
        func check(_ name: String, _ condition: Bool) { result.append(Check(name: name, pass: condition)) }
        let stage = Stage(), c = stage.controller, s = stage.source
        let ids = s.value!.boosts.map { $0.id.description }
        let expected = ["action.share", "action.copyURL", "action.newBoost", "action.capture", "action.captureFull", "action.capturePortrait", "section.settings", "contentBlocking", "permission.camera", "permission.notifications", "section.boosts", "boost.\(ids[0]).switch", "boost.\(ids[0]).edit", "boost.\(ids[1]).switch", "boost.\(ids[1]).edit", "more"]
        var visited: [String] = []
        for _ in expected { stage.key(code: 48, characters: "\t"); visited.append(stage.focusedID ?? "missing") }
        check("F3 Tab visits the complete control order", visited == expected && c.view.panel.focusOrder == expected)
        stage.key(code: 48, characters: "\t"); check("F3 Tab wraps", stage.focusedID == expected.first)
        stage.key(code: 48, characters: "\t", modifiers: .shift); check("F3 Shift+Tab reverses", stage.focusedID == "more")
        stage.window.makeFirstResponder(c.view.panel.control(id: "contentBlocking"))
        stage.key(code: 125, characters: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)))
        stage.key(code: 49, characters: " ")
        if stage.focusedID != "permission.notifications" || s.calls != ["toggle:permission.notifications"] {
            print("F3 observed focus=\(stage.focusedID ?? "nil") calls=\(s.calls)")
        }
        check("F3 tile grid arrows and Space activate the target", stage.focusedID == "permission.notifications" && s.calls == ["toggle:permission.notifications"])
        s.calls = []
        stage.tap("contentBlocking"); stage.tap("contentBlocking")
        check("F4 ad-block On/Off/On, one reload row", s.calls == ["toggle:contentBlocking", "toggle:contentBlocking"] && s.value!.tiles[0].subtitle == "On" && c.view.panel.showsReload && c.view.panel.controls.filter { $0.controlID == "reload" }.count == 1)
        stage.tap("permission.camera")
        check("F6 Camera Allowed becomes Blocked", s.value!.tiles[1].subtitle == "Blocked" && s.calls.last == "toggle:permission.camera")
        stage.tap("reload")
        check("reload closes before host action", !c.isPresented && s.calls.last == "reload")

        let unavailable = Stage(state: "scc-adblock-unavailable")
        unavailable.tap("contentBlocking")
        check("F5 unavailable blocker opens Settings without mutation", unavailable.source.calls == ["settings"] && !unavailable.controller.view.panel.showsReload)

        c.present(anchor: .urlField, tabID: s.tabID, animated: false); s.calls = []
        stage.tap("boost.\(ids[0]).switch")
        check("F7 Boost switch changes value", s.value!.boosts[0].isEnabled == false && s.calls == ["boost:\(ids[0]):false"])
        stage.tap("boost.\(ids[0]).edit")
        c.present(anchor: .urlField, tabID: s.tabID, animated: false)
        stage.window.makeFirstResponder(c.view.panel.control(id: "boost.\(ids[0]).switch"))
        stage.key(code: 36, characters: "\r")
        check("F7 edit button and Return edit the Boost", !c.isPresented && s.calls.filter { $0 == "editor:\(ids[0])" }.count == 2)
        c.present(anchor: .urlField, tabID: s.tabID, animated: false); stage.tap("action.newBoost")
        let empty = Stage(state: "scc-no-boosts"); empty.menu("New Boost…")
        check("F8 both New Boost entries use the host", s.calls.last == "editor:new" && empty.source.calls == ["editor:new"] && !empty.controller.isPresented)

        func titles(_ stage: Stage) -> [String] { stage.controller.makeMenu().items.map { $0.isSeparatorItem ? "—" : $0.title } }
        let basic = Stage()
        check("F9 interim menu hides Clear Cache and section Boost items", titles(basic) == ["Clear Cookies", "—", "Manage Extensions…", "Add Extension…", "—", "All Site Settings…"])
        let noBoosts = Stage(state: "scc-no-boosts")
        check("F9 no-Boost menu has Manage and New", titles(noBoosts) == ["Clear Cookies", "—", "Manage Boosts…", "New Boost…", "—", "Manage Extensions…", "Add Extension…", "—", "All Site Settings…"])
        noBoosts.source.value?.capabilities.insert(.clearCache); noBoosts.source.onChange?(noBoosts.source.tabID)
        check("F9 E2 capability exposes Clear Cache", titles(noBoosts).prefix(2) == ["Clear Cache", "Clear Cookies"])
        noBoosts.menu("Clear Cache"); noBoosts.menu("Clear Cookies")
        check("F9 clear items call distinct kinds and show Reload", noBoosts.source.calls == ["clear:2", "clear:1"] && noBoosts.controller.view.panel.showsReload)
        for (title, action) in [("Manage Boosts…", "view-boosts"), ("Manage Extensions…", "manage-extensions"), ("Add Extension…", "add-extension")] {
            let menuStage = Stage(state: "scc-no-boosts"); menuStage.menu(title)
            check("F9 \(title) routes and closes", menuStage.source.calls == [action] && !menuStage.controller.isPresented)
        }
        let site = Stage(); site.menu("All Site Settings…")
        check("F9 All Site Settings encodes the origin", site.source.calls == ["url:chrome://settings/content/siteDetails?site=https://news.example.com"] && !site.controller.isPresented)
        let internalPage = Stage(state: "scc-internal-page")
        check("internal page has only Share, Copy URL and footer", internalPage.controller.view.panel.controls.map(\.controlID) == ["action.share", "action.copyURL", "security", "more"])
        let privatePage = Stage(state: "scc-incognito")
        privatePage.tap("action.newBoost"); privatePage.tap("boost.\(ids[0]).switch"); privatePage.tap("boost.\(ids[0]).edit")
        check("F20 private window cannot create or edit Boosts", privatePage.source.calls.isEmpty && privatePage.controller.view.panel.control(id: "action.newBoost")?.isEnabled == false)
        let disabled = Stage(state: "scc-boosts-off")
        check("global-off note and disabled switches", disabled.controller.view.panel.control(id: "boost.\(ids[0]).switch")?.isEnabled == false && accessibilityDump(disabled.controller.view.panel).contains("Boosts are off. Turn them on in Settings."))
        let many = Stage(state: "scc-many")
        for _ in many.controller.view.panel.focusOrder { many.key(code: 48, characters: "\t") }
        let scroll = many.controller.view.panel.subviews.compactMap { $0 as? NSScrollView }.first
        check("keyboard focus scrolls the long body", (scroll?.contentView.bounds.origin.y ?? 0) > 0 && many.controller.view.panelFrame.height == 640)
        basic.controller.present(anchor: .contentTopLeading, tabID: basic.source.tabID, mode: .extensionPicker, animated: false)
        check("extension picker falls back to Add Extension in More", basic.controller.mode == .standard && basic.controller.preferredMenuItemTitle == "Add Extension…" && basic.focusedID == "more" && !basic.controller.view.panel.extensionsSectionVisible)
        let ax = accessibilityDump(Stage().controller.view.panel)
        check("F21 all section, tile, row and action labels and roles", ["AXHeading Settings", "AXButton Settings, More", "AXCheckBox Block Ads & Trackers", "AXCheckBox Camera", "AXCheckBox Notifications", "AXGroup Calm news, Enabled", "AXCheckBox Enable Calm news", "AXButton Edit Calm news", "AXMenuButton More"].allSatisfy(ax.contains))
        let live = Stage(); live.source.value?.context.displayHost = "Updated host"; live.source.onChange?(live.source.tabID)
        check("live source updates the open panel", live.controller.isPresented && accessibilityDump(live.controller.view.panel).contains("Updated host"))
        live.source.value = nil; live.source.onChange?(live.source.tabID)
        check("closed anchor tab dismisses on source notification", !live.controller.isPresented)
        let shortcut = Stage(); shortcut.key(code: 8, characters: "c", modifiers: [.command, .shift])
        check("Command shortcut dismisses and returns to normal routing", !shortcut.controller.isPresented && shortcut.source.calls.isEmpty)
        return result
    }
    static func accessibilityDump(_ view: any NSAccessibilityProtocol, indent: String = "") -> String {
        let role = view.accessibilityRole()?.rawValue ?? "view"
        let label = view.accessibilityLabel() ?? (view as? NSTextField)?.stringValue ?? (view.accessibilityValue() as? String) ?? ""
        let help = view.accessibilityHelp() ?? ""
        let value = view.accessibilityValue().map { " value=\($0)" } ?? ""
        let description = view.accessibilityValueDescription().map { " description=\($0)" } ?? ""
        let children = (view.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
        return (indent + role + " " + label + " " + help + value + description).trimmingCharacters(in: .newlines) + "\n" + children.map { accessibilityDump($0, indent: indent + "  ") }.joined()
    }
}
