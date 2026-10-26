import AppKit
import OpenSiteControl
import OpenModel

@MainActor
enum Flows {
    struct Check { let name: String; let pass: Bool }
    @MainActor final class MenuObservation {
        var opened = 0
        var highlighted: String?
        var timer: Timer?
        weak var menu: NSMenu?
        weak var picker: Stage?
    }
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
        for button in [NSEvent.EventType.rightMouseDown,.otherMouseDown] {
            c.present(anchor: .urlField,tabID: s.tabID,animated: false)
            stage.click(CGPoint(x: 800,y: 600),button: button)
            checks.append(Check(name: "outside \(button) dismisses and forwards to the page",pass: !c.isPresented && (button == .rightMouseDown ? stage.root.rightHits == 1 : stage.root.otherHits == 1)))
        }
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
        let pairs = [("AXPopover", "Site Control Center"),
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
        let recovered = Stage(open: false), geometry = recovered.controller.geometry
        var episodes = 0; recovered.controller.onUnavailable = { _ in episodes += 1 }
        recovered.controller.geometry = nil
        recovered.controller.present(anchor: .urlField,tabID: recovered.source.tabID,animated: false)
        recovered.controller.geometry = geometry
        recovered.controller.present(anchor: .urlField,tabID: recovered.source.tabID,animated: false)
        recovered.controller.geometry = nil; recovered.controller.layout(); recovered.controller.layout()
        checks.append(Check(name: "successful presentation resets once-per-failure-episode reporting",pass: episodes == 2))
        let animated = Stage()
        animated.controller.dismiss(reason: .escape,animated: true)
        checks.append(Check(name: "close fades both layers and disables hit testing immediately",pass: !animated.controller.view.isActive && !animated.controller.view.isHidden && animated.controller.view.presentationLayers.allSatisfy { $0.animation(forKey: "close.opacity")?.duration == 0.12 }))
        animated.controller.present(anchor: .urlField,tabID: animated.source.tabID,animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.22))
        checks.append(Check(name: "old close completion cannot hide a new presentation",pass: animated.controller.isPresented && !animated.controller.view.isHidden))
        checks.append(Check(name: "host is exposed once in native AX",pass: dump.components(separatedBy: "news.example.com").count == 2))
        for scheme in ["https","http","chrome","open","chrome-extension","about","data","file"] {
            let securityStage = Stage()
            securityStage.source.value?.context.url = URL(string: scheme+"://example.test/")!
            securityStage.source.changed()
            let security = securityStage.controller.view.panel.controls.first { $0.controlID == "security" }
            checks.append(Check(name: "security label policy for \(scheme)",pass: (security == nil || security!.isHidden) == !["https","http"].contains(scheme) && (security == nil || security!.title == (scheme == "https" ? "Secure" : "Insecure"))))
        }
        let corner = Stage()
        for closing in [false,true] {
            corner.controller.dismiss(reason: .action,animated: false)
            corner.controller.present(anchor: .urlField,tabID: corner.source.tabID,animated: !closing)
            if closing { corner.controller.dismiss(reason: .escape,animated: true) }
            for _ in 0..<3 {
                OffscreenRenderer.settle(corner.root); RunLoop.main.run(until: Date().addingTimeInterval(0.025))
                let expected = corner.controller.view.panel.frame.origin
                let fixed = corner.controller.view.presentationLayers.allSatisfy { layer in
                    guard let presentation = layer.presentation() else { return false }
                    return layer.anchorPoint == .zero && hypot(presentation.frame.minX-expected.x,presentation.frame.minY-expected.y)<0.1
                }
                checks.append(Check(name: "motion \(closing ? "close" : "open") top-left remains fixed",pass: fixed))
            }
        }
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
        check("internal page has only Share, Copy URL and footer", internalPage.controller.view.panel.controls.map(\.controlID) == ["action.share", "action.copyURL", "more"])
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
        check("extension picker falls back to Add Extension in More", basic.controller.mode == .extensionPicker && basic.controller.preferredMenuItemTitle == "Add Extension…" && basic.focusedID == "more" && !basic.controller.view.panel.extensionsSectionVisible)
        let picker = Stage(state: "scc-no-boosts", open: false)
        let observation = MenuObservation()
        observation.picker = picker
        picker.controller.onMenu = { menu, _ in
            observation.opened += 1; observation.menu = menu
            let timer = Timer(timeInterval: 0.03, repeats: false) { _ in
                MainActor.assumeIsolated {
                    observation.highlighted = observation.menu?.highlightedItem?.title
                    observation.picker?.key(code: 53, characters: "\u{1b}")
                }
            }
            observation.timer = timer
            RunLoop.main.add(timer, forMode: .eventTracking)
        }
        picker.controller.present(anchor: .contentTopLeading, tabID: picker.source.tabID, mode: .extensionPicker, animated: false)
        check("picker fallback focuses More without opening a menu", observation.opened == 0 && picker.focusedID == "more")
        picker.key(code: 36, characters: "\r")
        check("picker Return opens the native menu with Add Extension highlighted", observation.opened == 1 && observation.highlighted == "Add Extension…")
        check("picker Escape closes the panel from the native menu", !picker.controller.isPresented)
        picker.controller.onMenu = nil; observation.timer?.invalidate(); observation.timer = nil
        let ax = accessibilityDump(Stage().controller.view.panel)
        check("F21 all section, tile, row and action labels and roles", ["AXHeading label=Settings", "AXButton label=Settings, More", "AXCheckBox label=Block Ads & Trackers", "AXCheckBox label=Camera", "AXCheckBox label=Notifications", "AXGroup label=Calm news, Enabled", "AXCheckBox label=Enable Calm news", "AXButton label=Edit Calm news", "AXMenuButton label=More"].allSatisfy(ax.contains))
        let live = Stage(); live.source.value?.context.displayHost = "Updated host"; live.source.changed()
        check("live source updates the open panel", live.controller.isPresented && accessibilityDump(live.controller.view.panel).contains("Updated host"))
        live.source.value = nil; live.source.changed()
        check("closed anchor tab dismisses on source notification", !live.controller.isPresented)
        let removal = Stage()
        let removedID = removal.source.value!.boosts[0].id
        removal.window.makeFirstResponder(removal.controller.view.panel.control(id: "boost.\(removedID).switch"))
        removal.source.value?.boosts = []; removal.source.changed()
        check("live Boost removal keeps keyboard input in the panel", removal.window.firstResponder === removal.controller.view)
        removal.key(code: 48, characters: "\t")
        check("Tab works after the focused Boost disappears", removal.focusedID == "action.share")
        let shortcut = Stage(); shortcut.key(code: 8, characters: "c", modifiers: [.command, .shift])
        check("Command shortcut dismisses and returns to normal routing", !shortcut.controller.isPresented && shortcut.source.calls.isEmpty)
        check("picker item focus guard fails when Extensions UI lands", !basic.controller.view.panel.extensionsSectionVisible)
        for code: UInt16 in [36,49] {
            let command = Stage(); let target = command.controller.view.panel.control(id: "contentBlocking")!
            command.window.makeFirstResponder(target); command.key(code: code,characters: code == 36 ? "\r" : " ",modifiers: .command)
            check("Command+\(code) never activates a focused control", command.source.calls.isEmpty && !command.controller.isPresented)
        }
        let unfocused = Stage(); unfocused.key(code: 49,characters: " ")
        check("Space with no focused control is passed to the page", unfocused.root.keys == [49])
        let wrapped = Stage(state: "scc-many")
        check("long tile titles use two full lines", wrapped.controller.view.panel.control(id: "contentBlocking")?.title == "Block Ads &\nTrackers")
        check("private switches have half opacity", privatePage.controller.view.panel.control(id: "boost.\(ids[0]).switch")?.alphaValue == 0.5)
        let axStage = Stage(); let nativeAX = accessibilityDump(axStage.controller.view.panel)
        check("native AX puts actions before sections and host appears once", nativeAX.range(of: "AXButton label=Share").map { a in nativeAX.range(of: "AXScrollArea").map { a.lowerBound < $0.lowerBound } ?? false } == true && nativeAX.components(separatedBy: "news.example.com").count == 2 && nativeAX.contains("Site settings and Boosts"))
        for selecting in [true,false] {
            let native = Stage(); let observed = MenuObservation(); observed.picker = native
            var dismissal: SiteControlDismissReason?; native.controller.onDismiss = { dismissal = $0 }
            native.controller.onMenu = { menu,_ in
                observed.menu = menu
                let timer = Timer(timeInterval: 0.04,repeats: false) { _ in MainActor.assumeIsolated {
                    observed.highlighted = observed.menu?.highlightedItem?.title
                    observed.picker?.key(code: selecting ? 36 : 53,characters: selecting ? "\r" : "\u{1b}")
                } }; observed.timer = timer; RunLoop.main.add(timer,forMode: .eventTracking)
            }
            native.tap("more")
            if selecting { check("native tracked Return chooses Clear Cookies and keeps reload row", observed.highlighted == "Clear Cookies" && native.source.calls == ["clear:1"] && native.controller.isPresented && native.controller.view.panel.showsReload) }
            else { check("native tracked Esc dismisses with menuCancelled", !native.controller.isPresented && dismissal == .menuCancelled) }
            observed.timer?.invalidate(); native.controller.onMenu = nil
        }
        let rowCommand = Stage(); let row = rowCommand.controller.view.panel.control(id: "boost.\(ids[0]).switch")!.superview!
        rowCommand.window.makeFirstResponder(row); rowCommand.key(code: 36,characters: "\r",modifiers: .command)
        check("Command+Return on a Boost row cannot edit after dismissal", rowCommand.source.calls.isEmpty && !rowCommand.controller.isPresented)
        let growth = Stage(); let lastRow = growth.controller.view.panel.control(id: "boost.\(ids[1]).switch")!.superview!
        let oldY = lastRow.frame.minY
        growth.tap("contentBlocking")
        check("mouse activation does not show a keyboard focus ring", growth.controller.view.panel.control(id: "contentBlocking")?.showsKeyboardFocus == false)
        let viewport = growth.controller.view.panel.subviews.compactMap { $0 as? NSScrollView }.first!
        for _ in 0..<3 {
            OffscreenRenderer.settle(growth.root); RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            let y = lastRow.layer?.presentation()?.frame.minY ?? .infinity
            let bottom = lastRow.layer?.presentation()?.frame.maxY ?? .infinity
            let height = viewport.layer?.presentation()?.bounds.height ?? 0
            check("reload growth moves content with its viewport without clipping the last row", y >= oldY && y < oldY+32 && bottom-viewport.contentView.bounds.minY <= height+0.5)
        }
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
