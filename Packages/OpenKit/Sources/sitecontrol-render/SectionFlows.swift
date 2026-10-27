import AppKit
import OpenSiteControl
import OpenDesign

@MainActor
enum SectionFlows {
    @MainActor final class MenuObservation {
        var highlighted: String?
        var timer: Timer?
        weak var menu: NSMenu?
        weak var stage: Stage?
    }
    static func run() -> [Flows.Check] {
        var result: [Flows.Check] = []
        func check(_ name: String,_ pass: Bool) { result.append(.init(name: name,pass: pass)) }
        let stage = Stage(state: "scc-boost"),c = stage.controller,s = stage.source
        let id = s.value!.boosts[0].id.description
        let expected = ["action.share","action.newBoost","action.capture","action.captureFull","section.extensions","extension.add","section.boosts","boost.\(id).circle","boost.\(id).row","section.settings","contentBlocking","content.automaticPictureInPicture","more"]
        var visited: [String] = []
        for _ in expected { stage.key(code: 48,characters: "\t"); visited.append(stage.focusedID ?? "missing") }
        check("F3 complete captured section/row Tab order",visited == expected && c.view.panel.focusOrder == expected)
        stage.key(code: 48,characters: "\t"); check("F3 Tab wraps",stage.focusedID == expected.first)
        stage.key(code: 48,characters: "\t",modifiers: .shift); check("F3 Shift+Tab reverses",stage.focusedID == "more")
        c.view.panel.focus(c.view.panel.control(id: "action.share")!)
        stage.key(code: 124,characters: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        check("F3 Right arrow stays inside actions",stage.focusedID == "action.newBoost")
        c.view.panel.focus(c.view.panel.control(id: "contentBlocking")!)
        stage.key(code: 125,characters: String(UnicodeScalar(NSDownArrowFunctionKey)!)); stage.key(code: 49,characters: " ")
        check("F3 Down moves to the next row and Space toggles",s.calls == ["toggle:content.automaticPictureInPicture"] && s.value!.tiles[1].subtitle == "Blocked")
        s.calls = []; stage.tap("contentBlocking"); stage.tap("contentBlocking")
        check("F4 ad blocker On/Off/On with exactly one Reload row",s.calls == ["toggle:contentBlocking","toggle:contentBlocking"] && s.value!.tiles[0].subtitle == "On" && c.view.panel.controls.filter { $0.controlID == "reload" }.count == 1)
        stage.tap("reload"); check("reload closes and calls host once",!c.isPresented && s.calls.last == "reload")
        let unavailable = Stage(state: "scc-adblock-unavailable"); unavailable.tap("contentBlocking")
        check("F5 unavailable blocker opens Settings without writing",unavailable.source.calls == ["settings:advanced:adblock"] && !unavailable.controller.view.panel.showsReload)
        let permission = Stage(); permission.source.value!.tiles[1].kind = .permission(.camera); permission.source.changed(); permission.tap("content.automaticPictureInPicture")
        check("F6 permission Allowed to Blocked updates checkbox",permission.source.value!.tiles[1].subtitle == "Blocked" && permission.controller.view.panel.control(id: "content.automaticPictureInPicture")?.accessibilityValue() as? Int == 0)
        let boost = Stage(state: "scc-boost"); boost.tap("boost.\(id).circle")
        check("F7 circle toggles without opening editor",boost.source.calls == ["boost:\(id):false"] && boost.controller.isPresented)
        for method in 0..<3 {
            boost.controller.present(anchor: .urlField,tabID: boost.source.tabID,animated: false)
            if method == 0 { boost.tap("boost.\(id).row",offset: CGPoint(x: 100,y: 16)) }
            else if method == 1 { boost.tap("boost.\(id).row",offset: CGPoint(x: 220,y: 16)) }
            else { boost.controller.view.panel.focus(boost.controller.view.panel.control(id: "boost.\(id).row")!); boost.key(code: 36,characters: "\r") }
        }
        check("F7 row, chevron and Return each open the same editor",boost.source.calls.filter { $0 == "editor:\(id)" }.count == 3 && !boost.controller.isPresented)
        for state in ["scc-no-boosts","scc-boost"] {
            let new = Stage(state: state); new.tap("action.newBoost")
            let menu = Stage(state: state); menu.menu("New Boost…")
            check("F8 New Boost action and menu with \(state)",new.source.calls == ["editor:new"] && menu.source.calls == ["editor:new"] && !new.controller.isPresented && !menu.controller.isPresented)
        }
        func titles(_ stage: Stage) -> [String] { stage.controller.makeMenu().items.map { $0.isSeparatorItem ? "—" : $0.title } }
        let basic = Stage(state: "scc-boost")
        let menuTitles = ["Clear Cookies","—","Manage Boosts…","New Boost…","—","Manage Extensions…","Add Extension…","—","All Site Settings…"]
        check("F9 exact captured menu always includes both Boost commands",titles(basic) == menuTitles)
        basic.source.value?.capabilities.insert(.clearCache); basic.source.changed()
        check("F9 E2 capability adds Clear Cache",titles(basic) == ["Clear Cache"]+menuTitles)
        basic.menu("Clear Cache"); basic.menu("Clear Cookies")
        check("F9 clear data kinds are distinct and keep reload row",basic.source.calls == ["clear:2","clear:1"] && basic.controller.isPresented && basic.controller.view.panel.showsReload)
        for (title,command) in [("Manage Boosts…","view-boosts"),("Manage Extensions…","manage-extensions"),("Add Extension…","add-extension")] {
            let scene = Stage(); scene.menu(title); check("F9 \(title) routes and closes",scene.source.calls == [command] && !scene.controller.isPresented)
        }
        let settings = Stage(); settings.menu("All Site Settings…")
        check("F9 All Site Settings encodes only the origin",settings.source.calls == ["url:chrome://settings/content/siteDetails?site=https://news.example.com"])
        let internalPage = Stage(state: "scc-internal-page")
        check("internal page keeps four actions, Extensions and More; no security",internalPage.controller.view.panel.controls.prefix(4).count == 4 && internalPage.controller.view.panel.control(id: "extension.add") != nil && internalPage.controller.view.panel.control(id: "security")?.isHidden == true && titles(internalPage) == ["Manage Boosts…","New Boost…","—","Manage Extensions…","Add Extension…"])
        let privatePage = Stage(state: "scc-incognito")
        privatePage.tap("action.newBoost"); privatePage.tap("boost.\(id).circle"); privatePage.tap("boost.\(id).row")
        check("F20 private window disables creation, toggle, and edit",privatePage.source.calls.isEmpty && privatePage.controller.makeMenu().items.first { $0.title == "New Boost…" }?.isEnabled == false)
        let disabled = Stage(state: "scc-boosts-off")
        check("global-off note and disabled circle",disabled.controller.view.panel.control(id: "boost.\(id).circle")?.isEnabled == false && Flows.accessibilityDump(disabled.controller.view.panel).contains("Boosts are off. Turn them on in Settings."))
        let many = Stage(state: "scc-many")
        for _ in many.controller.view.panel.focusOrder { many.key(code: 48,characters: "\t") }
        check("long body scrolls focused rows and clamps at 640",many.controller.view.panel.scroll.contentView.bounds.minY > 0 && many.controller.view.panelFrame.height == 640)
        let lastSetting = many.source.value!.tiles.last!
        let lastControl = many.controller.view.panel.control(id: lastSetting.id)!
        many.controller.view.panel.focus(lastControl)
        let scrolledImage = many.render(scale: 1)
        let textOrigin = lastControl.convert(CGPoint(x: 50,y: 0),to: many.root)
        let blank = CLI.pixel(scrolledImage,x: Int(textOrigin.x-4),y: Int(textOrigin.y+5))
        check("scroll exposes freshly drawn last Settings title",CLI.hasInk(scrolledImage,rect: CGRect(x: textOrigin.x,y: textOrigin.y,width: 155,height: 15),scale: 1,fill: blank))
        let picker = Stage(open: false); var menuOpens = 0; picker.controller.onMenu = { _,_ in menuOpens += 1 }
        picker.controller.present(anchor: .urlField,tabID: picker.source.tabID,mode: .extensionPicker,animated: false)
        check("picker focuses + without opening a menu",picker.controller.mode == .extensionPicker && picker.focusedID == "extension.add" && menuOpens == 0)
        var package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while package.path != "/" && !FileManager.default.fileExists(atPath: package.appendingPathComponent("Package.swift").path) { package.deleteLastPathComponent() }
        let extensionHostLanded = FileManager.default.fileExists(atPath: package.appendingPathComponent("Sources/OpenExtensionsUI").path)
        // Blocked on OpenExtensionsUI: replace this guard with its real first
        // pinned-item flow when that target lands; do not silently pass fallback.
        check("picker host guard requires the first real item when extensions land",!extensionHostLanded && !picker.controller.view.panel.hasExtensionItems && picker.controller.view.panel.extensionPickerFocusResolved)
        picker.key(code: 36,characters: "\r")
        check("picker Return runs Add Extension",picker.source.calls == ["add-extension"] && !picker.controller.isPresented && menuOpens == 0)
        let ax = Flows.accessibilityDump(Stage(state: "scc-boost").controller.view.panel)
        let headingStage = Stage()
        let section = headingStage.controller.view.panel.control(id: "section.extensions")!
        let heading = section.accessibilityChildren()?.first as? NSView
        check("F21 heading child has a real window and nonzero frame",heading?.window === headingStage.window && (heading?.accessibilityFrame().width ?? 0)>70 && (heading?.accessibilityFrame().height ?? 0)==24)
        check("F21 native section, checkbox, and Boost edit roles",["AXHeading label=Extensions","AXButton label=Extensions, Manage","AXButton label=Add Extension","AXHeading label=Boosts","AXCheckBox label=Enable My Boost","AXButton label=Edit My Boost","AXCheckBox label=Block Ads & Trackers"].allSatisfy(ax.contains))
        check("F21 action AX precedes sections; host exposed once",ax.range(of: "AXButton label=Share")!.lowerBound < ax.range(of: "AXScrollArea")!.lowerBound && ax.components(separatedBy: "news.example.com").count == 2)
        let removal = Stage(state: "scc-boost"); removal.controller.view.panel.focus(removal.controller.view.panel.control(id: "boost.\(id).circle")!); removal.source.value?.boosts = []; removal.source.changed()
        check("live removal restores focus to panel",removal.window.firstResponder === removal.controller.view)
        removal.key(code: 48,characters: "\t"); check("Tab works after focused row removal",removal.focusedID == "action.share")
        for target in ["contentBlocking","boost.\(id).row"] { for code: UInt16 in [36,49] {
            let command = Stage(state: "scc-boost"); command.controller.view.panel.focus(command.controller.view.panel.control(id: target)!); command.key(code: code,characters: code == 36 ? "\r" : " ",modifiers: .command)
            check("Command+\(code) never activates \(target)",command.source.calls.isEmpty && !command.controller.isPresented)
        }
        }
        let stale = Stage(),retainedMenu = stale.controller.makeMenu()
        stale.controller.dismiss(reason: .escape,animated: false)
        stale.controller.present(anchor: .urlField,tabID: stale.source.tabID,animated: false)
        retainedMenu.performActionForItem(at: 0)
        check("retained native menu cannot act on a later presentation generation",stale.source.calls.isEmpty && !stale.controller.view.panel.showsReload)
        for selecting in [true,false] {
            let native = Stage(); let observed = MenuObservation(); observed.stage = native
            var reason: SiteControlDismissReason?; native.controller.onDismiss = { reason = $0 }
            native.controller.onMenu = { menu,_ in
                observed.menu = menu
                let timer = Timer(timeInterval: 0.04,repeats: false) { _ in MainActor.assumeIsolated {
                    observed.highlighted = observed.menu?.highlightedItem?.title
                    observed.stage?.key(code: selecting ? 36 : 53,characters: selecting ? "\r" : "\u{1b}")
                } }; observed.timer = timer; RunLoop.main.add(timer,forMode: .eventTracking)
            }
            if selecting {
                for _ in native.controller.view.panel.focusOrder { native.key(code: 48,characters: "\t") }
                native.key(code: 36,characters: "\r")
            } else { native.tap("more") }
            check(selecting ? "native menu Return selects Clear Cookies and keeps Reload" : "native menu Esc dismisses with menuCancelled",selecting ? observed.highlighted == "Clear Cookies" && native.source.calls == ["clear:1"] && native.controller.isPresented && native.controller.view.panel.showsReload : !native.controller.isPresented && reason == .menuCancelled)
            observed.timer?.invalidate(); native.controller.onMenu = nil
        }
        let resize = Stage()
        resize.tap("contentBlocking")
        resize.window.setContentSize(CGSize(width: 800,height: 360)); resize.controller.view.frame = resize.root.bounds
        resize.controller.layout(); OffscreenRenderer.settle(resize.root)
        let noStructureAnimation = resize.controller.view.presentationLayers.allSatisfy { layer in !(layer.animationKeys() ?? []).contains { $0.hasPrefix("rows.") } }
        check("window resize cancels structure motion and applies the current clamp",noStructureAnimation && resize.controller.view.panelFrame.maxY <= resize.root.bounds.maxY-8)
        return result
    }
}
