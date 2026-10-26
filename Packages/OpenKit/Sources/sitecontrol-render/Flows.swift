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
        let savedResponder = stage.window.firstResponder
        c.toggle(anchor: .urlField, tabID: s.tabID, animated: false)
        var reason: SiteControlDismissReason?
        c.onDismiss = { reason = $0 }
        stage.key(code: 53, characters: "\u{1b}")
        checks.append(Check(name: "F2 Escape closes and restores focus", pass: !c.isPresented && reason == .escape && savedResponder != nil && stage.window.firstResponder === savedResponder))
        c.toggle(anchor: .urlField, tabID: s.tabID, animated: false)
        stage.click(CGPoint(x: 800, y: 600))
        checks.append(Check(name: "F2 outside click closes and reaches page", pass: !c.isPresented && reason == .outside && stage.root.hits == 1))
        let target = SiteControlButton(id: "harness.page-target", label: "Page action", symbol: "link", pointSize: 18)
        target.frame = CGRect(x: 780, y: 580, width: 44, height: 36)
        var forwardedActions = 0; target.invoke = { forwardedActions += 1 }
        stage.root.addSubview(target, positioned: .below, relativeTo: c.view)
        c.present(anchor: .urlField, tabID: s.tabID, animated: false)
        stage.click(CGPoint(x: 800, y: 600))
        checks.append(Check(name: "outside click reaches a real native target/action exactly once", pass: !c.isPresented && forwardedActions == 1))
        target.removeFromSuperview()
        c.present(anchor: .urlField, tabID: s.tabID, animated: false)
        let dump = accessibilityDump(c.view.panel)
        let pairs = [("AXPopover", "Site Control Center"), ("AXStaticText", "news.example.com"),
                     ("AXButton", "Share"), ("AXButton", "Copy URL"), ("AXButton", "New Boost"),
                     ("AXButton", "Capture a portion of this page"), ("AXButton", "Capture the full page"),
                     ("AXButton", "Capture in Portrait Mode"), ("AXStaticText", "Connection: Secure"), ("AXMenuButton", "More")]
        checks.append(Check(name: "F21 native AX role and label pairs, host description, favicon hidden", pass:
            pairs.allSatisfy { dump.contains($0.0 + " label=" + $0.1 + "\n") } &&
            c.view.panel.accessibilityLabel() == "news.example.com" && c.view.panel.accessibilityHelp() == nil && !dump.contains("AXImage")))
        checks.append(Check(name: "Step 2 More is enabled", pass: c.view.panel.controls.last?.isEnabled == true))
        s.value?.commandsEnabled = [:]; s.changed()
        checks.append(Check(name: "missing capture capability disables all three actions", pass:
            c.view.panel.controls.filter { $0.controlID.hasPrefix("action.capture") }.allSatisfy { !$0.isEnabled }))
        let second = Stage(source: s)
        s.value?.context.displayHost = "updated.example.com"; s.changed()
        checks.append(Check(name: "two windows observe a shared source independently", pass:
            s.observers.count == 2 && c.view.panel.snapshot?.context.displayHost == "updated.example.com" && second.controller.view.panel.snapshot?.context.displayHost == "updated.example.com"))
        var transient: Stage? = Stage(source: s)
        checks.append(Check(name: "third window registers its own observer", pass: transient?.controller.isPresented == true && s.observers.count == 3))
        transient = nil
        checks.append(Check(name: "window teardown removes only its own observer", pass: s.observers.count == 2))
        let missingGeometry = Stage(open: false)
        missingGeometry.controller.geometry = nil
        var geometryErrors = 0
        missingGeometry.controller.onUnavailable = { _ in geometryErrors += 1 }
        missingGeometry.controller.present(anchor: .urlField, tabID: missingGeometry.source.tabID, animated: false)
        missingGeometry.controller.present(anchor: .urlField, tabID: missingGeometry.source.tabID, animated: false)
        checks.append(Check(name: "F22 missing geometry stays closed and logs once", pass: !missingGeometry.controller.isPresented && geometryErrors == 1))
        let lostGeometry = Stage()
        var lostErrors = 0
        lostGeometry.controller.onUnavailable = { _ in lostErrors += 1 }
        lostGeometry.controller.geometry = nil; lostGeometry.controller.layout(); lostGeometry.controller.layout()
        checks.append(Check(name: "F22 geometry lost while open closes and logs once", pass: !lostGeometry.controller.isPresented && lostErrors == 1))
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
        check("F5 unavailable blocker opens Settings without mutation", unavailable.source.calls == ["settings:advanced:adblock"] && !unavailable.controller.view.panel.showsReload)

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
        noBoosts.source.value?.capabilities.insert(.clearCache); noBoosts.source.changed()
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
        check("F21 all section, tile, row and action labels and roles", ["AXHeading label=Settings", "AXButton label=Settings, More", "AXCheckBox label=Block Ads & Trackers", "AXCheckBox label=Camera", "AXCheckBox label=Notifications", "AXGroup label=Calm news, Enabled", "AXCheckBox label=Enable Calm news", "AXButton label=Edit Calm news", "AXMenuButton label=More"].allSatisfy(ax.contains))
        let live = Stage(); live.source.value?.context.displayHost = "Updated host"; live.source.changed()
        check("live source updates the open panel", live.controller.isPresented && accessibilityDump(live.controller.view.panel).contains("Updated host"))
        live.source.value = nil; live.source.changed()
        check("closed anchor tab dismisses on source notification", !live.controller.isPresented)
        let shortcut = Stage(); shortcut.key(code: 8, characters: "c", modifiers: [.command, .shift])
        check("Command shortcut dismisses and returns to normal routing", !shortcut.controller.isPresented && shortcut.source.calls.isEmpty)
        return result
    }
    /// Traverse the actual AppKit AX children (including cells), not NSView.subviews.
    static func accessibilityDump(_ node: any NSAccessibilityProtocol, indent: String = "") -> String {
        let role = node.accessibilityRole()?.rawValue ?? "AXUnknown"
        let candidates = role == "AXPopover" ? [node.accessibilityTitle(), node.accessibilityLabel()] : [node.accessibilityLabel(), node.accessibilityTitle(), node.accessibilityValue() as? String]
        let label = candidates.compactMap { $0 }.first { !$0.isEmpty } ?? ""
        var line = indent + role + " label=" + label + "\n"
        if let title = node.accessibilityTitle(), !title.isEmpty, let description = node.accessibilityLabel() {
            line += indent + "  description=" + description + "\n"
        }
        return line + (node.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
            .map { accessibilityDump($0, indent: indent + "  ") }.joined()
    }
}
