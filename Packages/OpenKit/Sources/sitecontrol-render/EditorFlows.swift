import AppKit
import OpenSiteControl
import OpenBoosts
import OpenModel
import OpenDesign

@MainActor
enum EditorFlows {
    static func run() -> [Flows.Check] {
        var checks: [Flows.Check] = []
        func check(_ name: String,_ pass: Bool) { checks.append(.init(name: name,pass: pass)) }
        let stage = EditorStage(), store = stage.host.boostStore
        let id = stage.session.boost.id
        let initial = stage.session.boost
        let refreshBefore = stage.host.refreshes
        let wheel = stage.view.wheel
        stage.mouse(.leftMouseDown,point: CGPoint(x: 64,y: 30),in: wheel)
        for i in 0..<40 { stage.mouse(.leftMouseDragged,point: CGPoint(x: 64+Double(i),y: 40),in: wheel) }
        check("F10 drag leaves the real store unchanged before mouse-up", store.boost(id: id) == initial && stage.host.refreshes == refreshBefore)
        stage.settle(0.02)
        check("F10 live preview uses real planner and strips JavaScript", !stage.host.previews.isEmpty && stage.host.previews.count <= 2 && stage.host.previews.allSatisfy { !$0.containsJS && $0.combinedJS.isEmpty && $0.boosts.allSatisfy { $0.js.isEmpty } })
        stage.mouse(.leftMouseUp,point: CGPoint(x: 100,y: 40),in: wheel)
        let afterDrag = store.boost(id: id)!
        check("F10 mouse-up commits once and derives the wheel adjustment", stage.host.refreshes == refreshBefore+1 && afterDrag.colorWheel != nil && afterDrag.colorAdjustment == afterDrag.colorWheel?.adjustment)
        stage.key(6,"z",modifiers: .command)
        check("F14 one Cmd+Z restores the complete pre-drag value", stage.session.boost.colorAdjustment == initial.colorAdjustment && stage.session.boost.colorWheel == initial.colorWheel && !stage.session.undoManager.canUndo)
        stage.key(6,"z",modifiers: [.command,.shift])
        check("F14 Cmd+Shift+Z restores the drag", stage.session.boost.colorWheel == afterDrag.colorWheel)
        // Twelve fixed edits go through the public editor session -> real store -> planner.
        let inputs: [(Double,Double,Double?,Bool,Double,Double,Double,Double,Double)] = [
            (0,0,nil,false,1,1,1,0,1), (90,1,0,false,1,1,1,90,1.5), (270,1,0,false,1,1,1,270,1.5),
            (10,0.5,350,false,1,1,1,10,1.25), (350,0.5,10,false,1,1,1,350,1.25),
            (180,1,0,false,1,1,1,180,1.5), (120,0.5,120,false,1,1,1,0,1.25),
            (0,0,nil,true,1,1,1,180,1), (90,1,0,true,1,1,1,270,1.5),
            (20,0.25,100,false,0.5,1.5,2,340,2.25), (100,1,100,false,1.5,0.5,0,0,0), (720,1,0,false,1,1,2,0,3)]
        for (i,v) in inputs.enumerated() {
            stage.session.editWheel { $0 = BoostColorWheel(hue: v.0,intensity: v.1,baseHue: v.2,invertLightness: v.3,brightness: v.4,contrast: v.5,originalSaturation: v.6) }
            let saved = store.boost(id: id)!, c = saved.colorAdjustment
            let identity = i == 0
            let pass = identity ? saved.colorWheel == nil && c == nil : c.map { abs($0.hueRotateDegrees-v.7)<1e-9 && abs($0.saturation-v.8)<1e-9 && $0.brightness == v.4 && $0.contrast == v.5 && $0.invert == (v.3 ? 1 : 0) } ?? false
            let plan = BoostInjectionPlanner.plan(url: stage.host.url,profileID: stage.host.profileID,matcher: BoostMatcher(boosts: store.allBoosts()),boostsGloballyEnabled: true)
            check("F11 wheel input \(i+1) through store and injection planner", pass && plan.colorAdjustment == c)
        }
        stage.tap("editor.font.1")
        check("F12 System font chip persists the safe CSS family", store.boost(id: id)?.fontFamily == "system-ui, -apple-system, sans-serif")
        stage.key(6,"z",modifiers: .command)
        check("F14 font undo restores Original", store.boost(id: id)?.fontFamily == nil)
        stage.key(6,"z",modifiers: [.command,.shift])
        check("F14 font redo restores System", store.boost(id: id)?.fontFamily == "system-ui, -apple-system, sans-serif")
        for i in [2,3,4,0,1] { stage.tap("editor.tool.size"); check("F12 text size cycle \(i)", store.boost(id: id)?.textZoom == BoostEditorSession.textSizes[i]) }
        stage.tap("editor.tool.size",modifiers: .shift)
        check("F12 Shift-click cycles size backwards", store.boost(id: id)?.textZoom == 0.9)
        for i in [1,2,3,0] { stage.tap("editor.tool.case"); check("F12 text case cycle \(i)", store.boost(id: id)?.textTransform == BoostEditorSession.textCases[i]) }
        stage.key(6,"z",modifiers: .command)
        check("F14 case undo restores lowercase", store.boost(id: id)?.textTransform == "lowercase")
        stage.key(6,"z",modifiers: [.command,.shift])
        check("F14 case redo restores default", store.boost(id: id)?.textTransform == nil)
        stage.menu("All Boosts…"); check("F15 All Boosts delegates and keeps editor open", stage.host.libraries == 1 && stage.controller.panel != nil)
        let beforeShuffle = stage.session.boost
        stage.menu("Shuffle"); let shuffled = stage.session.boost
        check("F15 Shuffle sets wheel and font, preserving text options", shuffled.colorWheel.map { (0.6...1).contains($0.intensity) } == true && shuffled.fontFamily != nil && shuffled.textZoom == beforeShuffle.textZoom && shuffled.textTransform == beforeShuffle.textTransform)
        stage.key(6,"z",modifiers: .command)
        check("F14 Shuffle is one complete undo step", stage.session.boost.colorWheel == beforeShuffle.colorWheel && stage.session.boost.fontFamily == beforeShuffle.fontFamily)
        for text in ["Evening colors", ""] {
            stage.menu("Rename this Boost…")
            if let alert = stage.controller.activeAlert {
                stage.key(0,"a",modifiers: .command,window: alert.window)
                if text.isEmpty { stage.key(51,"\u{7f}",window: alert.window) }
                else { for character in text { stage.key(0,String(character),window: alert.window) } }
            }
            stage.alert("Done")
            check("F15 native rename Done permits '\(text)'", stage.session.boost.name == text)
        }
        let beforeCancel = stage.session.boost.name
        stage.menu("Rename this Boost…"); stage.alert("Cancel")
        check("F15 rename Cancel preserves name", stage.session.boost.name == beforeCancel)
        let beforeReset = stage.session.boost
        stage.menu("Reset all Edits"); stage.alert("Cancel")
        check("F15 reset Cancel preserves edits", stage.session.boost == beforeReset)
        stage.menu("Reset all Edits"); stage.alert("Reset")
        check("F15 Reset clears all edit fields and preserves scope/name", stage.session.boost.isEmpty && stage.session.boost.name == beforeReset.name && stage.session.boost.siteMatch == beforeReset.siteMatch)
        stage.key(6,"z",modifiers: .command)
        check("F14 Reset is one undo step", stage.session.boost.colorAdjustment == beforeReset.colorAdjustment && stage.session.boost.textZoom == beforeReset.textZoom && stage.session.boost.fontFamily == beforeReset.fontFamily)
        stage.menu("Delete this Boost"); stage.alert("Cancel")
        check("F15 delete Cancel keeps editor and stored Boost", stage.controller.panel != nil && store.boost(id: id) != nil)
        stage.menu("Delete this Boost"); stage.alert("Delete")
        check("F15 Delete closes editor and deletes from the real store", stage.controller.panel == nil && store.boost(id: id) == nil)
        for changed in [false,true] {
            let s = EditorStage(isNew: true); let newID = s.session.boost.id
            if changed { s.tap("editor.tool.case") }; s.key(53,"\u{1b}")
            check("F16 close new Boost changed=\(changed)", (s.host.boostStore.boost(id: newID) != nil) == changed && s.host.exits == 1)
        }
        let welcome = EditorStage(state: "editor-interstitial"); welcome.tap("editor.make")
        check("F19 Make your own persists only the dismissed flag", welcome.defaults.bool(forKey: "open.boosts.hasDismissedInterstitial") && !welcome.session.showsInterstitial)
        let untouched = EditorStage(state: "editor-interstitial"); untouched.tap("editor.close")
        check("F19 close leaves interstitial flag false", !untouched.defaults.bool(forKey: "open.boosts.hasDismissedInterstitial") && untouched.controller.panel == nil)
        let legacy = EditorStage(state: "editor-legacy"), encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let legacyID = legacy.session.boost.id
        legacy.host.boostStore.saveNow(); let reloaded = legacy.host.boostStore.load().first!
        let bytes = try! encoder.encode(reloaded.colorAdjustment)
        let dumpBefore = Flows.accessibilityDump(legacy.view)
        check("legacy filter is exact and the wheel is editable with a note", legacy.session.boost.colorWheel == nil && legacy.session.boost.colorAdjustment?.brightness == 2 && legacy.session.boost.colorAdjustment?.invert == 0.5 && legacy.view.wheel.acceptsFirstResponder && dumpBefore.contains("Custom colors — editing replaces them."))
        legacy.tap("editor.tool.case")
        check("non-color edit retains exact legacy filter", (try! encoder.encode(legacy.host.boostStore.boost(id: legacyID)!.colorAdjustment)) == bytes)
        legacy.tap("editor.color.invert")
        let converted = legacy.host.boostStore.boost(id: legacyID)!
        check("first color edit replaces legacy values with normalized wheel values", converted.colorWheel != nil && converted.colorAdjustment == converted.colorWheel?.adjustment)
        legacy.key(6,"z",modifiers: .command); legacy.host.boostStore.saveNow(); let undone = legacy.host.boostStore.load().first!
        check("legacy first-edit undo restores byte-identical colorAdjustment and nil wheel", undone.colorWheel == nil && (try! encoder.encode(undone.colorAdjustment)) == bytes)
        let rich = EditorStage(boost: Boost(name: "Rich",siteMatch: SiteMatch(domain: "news.example.com"),css: "body { color: red; }",js: "window.__boost = 1;",zaps: [ZappedElement(selector: ".ad")]))
        let richBefore = rich.session.boost
        rich.menu("Reset all Edits"); rich.alert("Reset")
        check("F15 Reset also clears stored CSS, JS and Zaps", rich.session.boost.isEmpty)
        rich.key(6,"z",modifiers: .command)
        check("F14 Reset restores CSS, JS and Zaps together", rich.session.boost.css == richBefore.css && rich.session.boost.js == richBefore.js && rich.session.boost.zaps == richBefore.zaps)
        let inline = EditorStage(); let field = inline.view.nameField
        let center = CGPoint(x: field.bounds.midX,y: field.bounds.midY)
        inline.mouse(.leftMouseDown,point: center,in: field,clicks: 2); inline.mouse(.leftMouseUp,point: center,in: field,clicks: 2)
        inline.key(0,"R"); inline.key(36,"\r")
        check("F15 header double-click and Return commit inline rename", inline.session.boost.name == "R" && inline.controller.panel != nil)
        inline.controller.beginInlineRename(); inline.key(0,"X"); inline.key(53,"\u{1b}")
        check("F15 first Esc cancels inline rename and keeps panel", inline.session.boost.name == "R" && inline.controller.panel != nil)
        inline.key(53,"\u{1b}")
        check("F15 second Esc closes the editor", inline.controller.panel == nil)
        checks += scopeFlows()
        let axStage = EditorStage(); let ax = Flows.accessibilityDump(axStage.view)
        let labels = ["Boost scope","More","Close","Colors","Invert lightness","Advanced color controls","Reset to original colors","Original","System","Zap","Code","Normal","Aa"]
        check("F21 real editor AX hierarchy labels all controls", labels.allSatisfy { ax.contains("label="+$0+"\n") } && ax.contains("AXSlider label=Colors\n"))
        let notActive = EditorStage(); notActive.controller.pageDidNavigate(tabID: notActive.host.tabID,url: URL(string: "https://elsewhere.test/")!); notActive.settle()
        check("navigation keeps the editor and shows Not active", notActive.controller.panel != nil && Flows.accessibilityDump(notActive.view).contains("This Boost doesn't apply to elsewhere.test."))
        notActive.controller.boundContextDidChange(tabID: ItemID(),profileID: notActive.host.profileID)
        check("tab switch finalizes and closes the bound editor", notActive.controller.panel == nil)
        let off = EditorStage(state: "editor-global-off"); off.drag(); off.settle(0.03)
        check("global-off permits stored edits and skips every preview", off.session.boost.colorWheel != nil && off.host.previews.isEmpty)
        return checks
    }
    private static func scopeFlows() -> [Flows.Check] {
        var checks: [Flows.Check] = []
        let stage = EditorStage(), menu = stage.view.scopeMenu()
        checks.append(.init(name: "scope menu labels host and subdomains without changing stored meaning", pass: menu.items.map(\.title) == ["All of example.com","news.example.com and subdomains","Only pages under /news"]))
        menu.performActionForItem(at: 1)
        let saved = stage.host.boostStore.boost(id: stage.session.boost.id)!
        let childPlan = BoostInjectionPlanner.plan(url: URL(string: "https://child.news.example.com/")!,profileID: stage.host.profileID,matcher: BoostMatcher(boosts: [saved]),boostsGloballyEnabled: true)
        let parentPlan = BoostInjectionPlanner.plan(url: URL(string: "https://example.com/")!,profileID: stage.host.profileID,matcher: BoostMatcher(boosts: [saved]),boostsGloballyEnabled: true)
        checks.append(.init(name: "news.example.com scope applies to child.news.example.com",pass: childPlan.boosts.map(\.boostID) == [saved.id]))
        checks.append(.init(name: "news.example.com scope does not apply to example.com",pass: parentPlan.isEmpty))
        let ip = EditorStage(url: URL(string: "http://127.0.0.1/news/story")!,boost: Boost(name: "Local",siteMatch: SiteMatch(domain: "127.0.0.1",pathPrefix: "/news")))
        let ipMenu = ip.view.scopeMenu()
        checks.append(.init(name: "saved IP path scope has one host choice and a checked path item", pass: ipMenu.items.map(\.title) == ["127.0.0.1","Only pages under /news"] && ipMenu.items.map(\.state) == [.off,.on] && ip.view.control(id: "editor.scope")?.title == "127.0.0.1/news ▾"))
        let ipRoot = EditorStage(url: URL(string: "http://127.0.0.1/")!)
        checks.append(.init(name: "root IP scope hides path and registrable-domain items",pass: ipRoot.view.scopeMenu().items.map(\.title) == ["127.0.0.1"]))
        return checks
    }
    static func renders() -> [Flows.Check] {
        var checks: [Flows.Check] = []
        for state in CLI.editorNames { for appearance in [ContentAppearance.light,.dark] { for scale: CGFloat in [1,2] {
            autoreleasepool {
                let stage = EditorStage(state: state,scale: scale,appearance: appearance), image = stage.render()
                let frame = stage.parent.convertFromScreen(stage.panel.frame)
                let fill = CLI.pixel(image,x: Int((frame.minX+40)*scale),y: Int((760-frame.maxY+75)*scale)), backdrop = CLI.pixel(image,x: Int(5*scale),y: Int(5*scale))
                checks.append(.init(name: "render \(state) \(appearance.rawValue) \(Int(scale))x body and opaque backdrop",pass: image.width == Int(1000*scale) && image.height == Int(760*scale) && fill != backdrop && CLI.fullyOpaque(image)))
                let color = Core.popoverBackground.resolved(appearance).nsColor.usingColorSpace(.sRGB)!
                let expected = [color.redComponent,color.greenComponent,color.blueComponent].map { Int(($0*255).rounded()) }
                let stableFill = zip(fill.prefix(3),expected).allSatisfy { abs(Int($0)-$1) <= 2 }
                checks.append(.init(name: "render \(state) exact opaque editor surface after resize",pass: stableFill))
                let dump = Flows.accessibilityDump(stage.view)
                checks.append(.init(name: "render \(state) real controls present",pass: dump.contains("AXButton label=Close\n") && (state == "editor-interstitial" ? dump.contains("Make your own!") : dump.contains("AXSlider label=Colors"))))
            }
        } } }
        return checks
    }
}
