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
        checks += padAndWindowFlows()
        let stage = EditorStage(), store = stage.host.boostStore
        let id = stage.session.boost.id
        let initial = stage.session.boost
        let refreshBefore = stage.host.refreshes
        let wheel = stage.view.pad
        stage.mouse(.leftMouseDown,point: CGPoint(x: 110,y: 73.5),in: wheel)
        for i in 0..<40 { stage.mouse(.leftMouseDragged,point: CGPoint(x: 73.5+Double(i),y: 45),in: wheel) }
        check("F10 drag leaves the real store unchanged before mouse-up", store.boost(id: id) == initial && stage.host.refreshes == refreshBefore)
        stage.settle(0.02)
        check("F10 live preview uses real planner and strips JavaScript", !stage.host.previews.isEmpty && stage.host.previews.count <= 2 && stage.host.previews.allSatisfy { !$0.containsJS && $0.combinedJS.isEmpty && $0.boosts.allSatisfy { $0.js.isEmpty } })
        stage.mouse(.leftMouseUp,point: CGPoint(x: 110,y: 45),in: wheel)
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
        stage.tap("editor.font.0")
        check("F12 System font cell persists the safe CSS family", store.boost(id: id)?.fontFamily == "system-ui, -apple-system, sans-serif")
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
        let welcome = EditorStage(state: "editor-first-run"); welcome.tap("editor.make")
        check("F19 Make your own persists only the dismissed flag", welcome.defaults.bool(forKey: "open.boosts.hasDismissedInterstitial") && !welcome.session.showsInterstitial)
        let untouched = EditorStage(state: "editor-first-run"); untouched.tap("editor.later")
        check("F19 close leaves interstitial flag false", !untouched.defaults.bool(forKey: "open.boosts.hasDismissedInterstitial") && untouched.controller.panel == nil)
        let legacy = EditorStage(state: "editor-legacy"), encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let legacyID = legacy.session.boost.id
        legacy.host.boostStore.saveNow(); let reloaded = legacy.host.boostStore.load().first!
        let bytes = try! encoder.encode(reloaded.colorAdjustment)
        let dumpBefore = Flows.accessibilityDump(legacy.view)
        check("legacy filter is exact and the wheel is editable with a note", legacy.session.boost.colorWheel == nil && legacy.session.boost.colorAdjustment?.brightness == 2 && legacy.session.boost.colorAdjustment?.invert == 0.5 && legacy.view.pad.acceptsFirstResponder && dumpBefore.contains("Custom colors — editing replaces them."))
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
        checks += scopeFlows()
        checks += reviewFlows()
        let axStage = EditorStage(); let ax = Flows.accessibilityDump(axStage.view)
        let labels = ["Done","My Boost","Undo","Color","Hue","Intensity","Invert lightness","Advanced color controls","Reset to original colors","System","Zap","Code","Change text size","Change text case"]
        check("F21 real editor AX hierarchy labels all controls", labels.allSatisfy { ax.contains("label="+$0+"\n") } && ax.contains("AXGroup label=Color\n"))
        let notActive = EditorStage(); notActive.controller.pageDidNavigate(tabID: notActive.host.tabID,url: URL(string: "https://elsewhere.test/")!); notActive.settle()
        check("navigation keeps the editor and shows Not active", notActive.controller.panel != nil && Flows.accessibilityDump(notActive.view).contains("This Boost doesn't apply to elsewhere.test."))
        notActive.controller.boundContextDidChange(tabID: ItemID(),profileID: notActive.host.profileID)
        check("tab switch finalizes and closes the bound editor", notActive.controller.panel == nil)
        let off = EditorStage(state: "editor-global-off"); off.drag(); off.settle(0.03)
        check("global-off permits stored edits and skips every preview", off.session.boost.colorWheel != nil && off.host.previews.isEmpty)
        return checks
    }
    private static func reviewFlows() -> [Flows.Check] {
        var checks: [Flows.Check] = []
        func check(_ name: String,_ pass: Bool) { checks.append(.init(name: name,pass: pass)) }
        let durable = EditorStage(); let id = durable.session.boost.id
        durable.tap("editor.tool.case"); let committed = durable.session.boost
        durable.key(53,"\u{1b}")
        let fresh = BoostStore(root: durable.host.root,profileID: durable.host.profileID)
        let diskValue = fresh.load().first { $0.id == id }
        check("103-1 commit then close flushes to a fresh store without caller saveNow",diskValue?.textTransform == committed.textTransform && diskValue?.textTransform == "capitalize" && diskValue?.siteMatch == committed.siteMatch && diskValue?.name == committed.name)
        let deleted = EditorStage(); let deletedID = deleted.session.boost.id
        deleted.menu("Delete this Boost"); deleted.alert("Delete")
        let afterDelete = BoostStore(root: deleted.host.root,profileID: deleted.host.profileID)
        check("103-1 native Delete is durable immediately",afterDelete.load().allSatisfy { $0.id != deletedID })
        let sliderStage = EditorStage(); sliderStage.tap("editor.color.advanced")
        let slider = sliderStage.slider(0)!
        let sliderWindow = slider.window!
        sliderWindow.makeKey();sliderWindow.makeFirstResponder(slider)
        let original = sliderStage.session.boost, refreshes = sliderStage.host.refreshes
        for _ in 0..<4 { sliderStage.key(124,"\u{f703}",window: sliderWindow) }
        check("103-2 slider repeats keep live state out of store before the group ends",sliderStage.host.refreshes == refreshes && sliderStage.session.boost != original)
        sliderStage.settle(1.1)
        check("103-2 one second slider repeats commit once",sliderStage.host.refreshes == refreshes+1)
        sliderStage.key(6,"z",modifiers: .command)
        check("103-2 one undo restores every repeated slider step",sliderStage.session.boost.colorAdjustment == original.colorAdjustment && !sliderStage.session.undoManager.canUndo)
        let beforeAX = sliderStage.host.refreshes
        for _ in 0..<4 { _ = slider.accessibilityPerformIncrement() }
        slider.setAccessibilityFocused(false)
        check("103-2 AX slider repeats commit once on AX focus loss",sliderStage.host.refreshes == beforeAX+1)
        sliderStage.key(6,"z",modifiers: .command)
        check("103-2 one undo restores all AX increments",sliderStage.session.boost.colorAdjustment == original.colorAdjustment)
        for _ in 0..<2 { sliderStage.key(124,"\u{f703}",window: sliderWindow) }
        sliderStage.key(48,"\t",window: sliderWindow)
        check("103-2 keyboard focus loss commits the slider group",!sliderStage.session.isInteracting)
        let owners = EditorStage();owners.panel.makeKey();owners.view.focus(owners.view.pad)
        owners.key(126,"\u{f700}"); let wheelState = owners.session.boost
        owners.tap("editor.color.advanced");let brightness = owners.slider(0)!
        owners.mouse(.leftMouseDown,point: CGPoint(x: 80,y: 14),in: brightness)
        owners.mouse(.leftMouseUp,point: CGPoint(x: 90,y: 14),in: brightness)
        owners.key(6,"z",modifiers: .command)
        check("103-3 slider drag has its own undo entry after wheel repeat",owners.session.boost.colorWheel == wheelState.colorWheel)
        owners.key(6,"z",modifiers: .command)
        check("103-3 second undo restores the wheel repeat separately",owners.session.boost.colorWheel == nil)
        let rejected = EditorStage(), existingPanel = rejected.panel, existingSession = rejected.session
        let ok = rejected.controller.present(parent: rejected.parent,contentRect: CGRect(x: 228,y: 10,width: 762,height: 740),context: rejected.session.context,boostID: BoostID())
        check("103-5 an invalid request preserves the live editor",!ok && rejected.controller.panel === existingPanel && rejected.controller.session === existingSession && !existingSession.isClosed)
        let tempStage = EditorStage(), file = tempStage.host.boostStore.fileURL
        let directory = file.deletingLastPathComponent(); try! FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let stale = file.appendingPathExtension("tmp-"+UUID().uuidString), unrelated = directory.appendingPathComponent("unrelated.tmp-keep"), tempDirectory = file.appendingPathExtension("tmp-directory")
        try! Data("abandoned".utf8).write(to: stale); try! Data("keep".utf8).write(to: unrelated); try! FileManager.default.createDirectory(at: tempDirectory,withIntermediateDirectories: false)
        let loaded = BoostStore(root: tempStage.host.root,profileID: tempStage.host.profileID); _ = loaded.load()
        check("103-7 load removes only stale atomic-write files",!FileManager.default.fileExists(atPath: stale.path) && FileManager.default.fileExists(atPath: unrelated.path) && FileManager.default.fileExists(atPath: tempDirectory.path))
        let loading = EditorStage(waitForColors: false)
        check("103-8 pending page sampling disables Shuffle and wheel edits",!loading.session.colorsReady && loading.controller.makeMenu().items.first { $0.title == "Shuffle" }?.isEnabled == false && loading.view.control(id: "editor.color.invert")?.isEnabled == false && !loading.view.pad.acceptsFirstResponder)
        loading.settle(0.4)
        check("103-8 sampling enables Shuffle and wheel edits",loading.session.colorsReady && loading.controller.makeMenu().items.first { $0.title == "Shuffle" }?.isEnabled == true && loading.view.control(id: "editor.color.invert")?.isEnabled == true)
        let fonts = EditorStage(); let fourth = fonts.view.control(id: "editor.font.3")!
        for _ in 0..<40 { fonts.key(48,"\t"); if fonts.panel.firstResponder === fourth { break } }
        let visible = fourth.visibleRect
        check("F12 font grid keeps 26 pt cells and keyboard focus",fonts.panel.firstResponder === fourth && fourth.bounds.width == 26 && visible.width >= 25.9 && fourth.showsKeyboardFocus)
        check("design 12 disabled tile copy is user-facing",fonts.view.control(id: "editor.tool.zap")?.tooltipTitle == "Zap isn’t available yet." && fonts.view.control(id: "editor.tool.code")?.tooltipTitle == "Code editing isn’t available yet.")
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
        checks.append(.init(name: "saved IP path scope has one host choice and a checked path item", pass: ipMenu.items.map(\.title) == ["127.0.0.1","Only pages under /news"] && ipMenu.items.map(\.state) == [.off,.on]))
        for path in ["/other/page","/"] {
            let savedIP = EditorStage(url: URL(string: "http://127.0.0.1"+path)!,boost: Boost(name: "Local",siteMatch: SiteMatch(domain: "127.0.0.1",pathPrefix: "/news")))
            let menu = savedIP.view.scopeMenu()
            checks.append(.init(name: "103-4 saved IP /news is checked while page is "+path,pass: menu.items.filter { $0.state == .on }.map(\.title) == ["Only pages under /news"] && menu.items.first?.title == "127.0.0.1"))
        }
        let ipRoot = EditorStage(url: URL(string: "http://127.0.0.1/")!)
        checks.append(.init(name: "root IP scope hides path and registrable-domain items",pass: ipRoot.view.scopeMenu().items.map(\.title) == ["127.0.0.1"]))
        return checks
    }
    private static func padAndWindowFlows() -> [Flows.Check] {
        var checks: [Flows.Check] = []
        func check(_ name: String,_ pass: Bool) { checks.append(.init(name: name,pass: pass)) }
        let s = EditorStage(),pad = s.view.pad
        for i in 0..<12 {
            let angle = Double(i)*30,rad = angle * .pi/180,t = 0.4+Double(i%3)*0.2
            let p = CGPoint(x: 73.5+cos(rad)*66.5*0.99*t,y: 73.5+sin(rad)*66.5*0.99*t)
            // Click away from the primary knob to exercise the absolute pad law.
            s.session.resetColors();
            let deadline = Date().addingTimeInterval(3)
            while !s.session.colorsReady && Date()<deadline { s.settle(0.001) }
            s.settle()
            s.mouse(.leftMouseDown,point: p,in: pad);s.mouse(.leftMouseUp,point: p,in: pad);s.settle()
            guard let w = s.session.boost.colorWheel,let a = pad.primaryKnobCenter,let secondary = pad.secondaryKnobFrames.first else { check("F11 screen point \(i+1) produced an editable color",false);continue }
            let e = CGPoint(x: 73.5+cos(rad+(.pi/4))*66.5*0.99*t,y: 73.5+sin(rad+(.pi/4))*66.5*0.99*t)
            check("F11 screen point \(i+1) and both knob centers",abs(w.hue-angle)<1e-9 && abs(w.intensity-t)<1e-9 && hypot(a.x-p.x,a.y-p.y)<0.01 && hypot(secondary.midX-e.x,secondary.midY-e.y)<0.01)
        }
        let relative = EditorStage(state: "editor-color"),start = relative.view.pad.primaryKnobCenter!
        let offset = CGPoint(x: start.x+4,y: start.y+3),end = CGPoint(x: offset.x+6,y: offset.y+8)
        relative.mouse(.leftMouseDown,point: offset,in: relative.view.pad);relative.mouse(.leftMouseDragged,point: end,in: relative.view.pad);relative.mouse(.leftMouseUp,point: end,in: relative.view.pad)
        let center = relative.view.pad.primaryKnobCenter!
        check("F10 knob drag retains its pointer offset",hypot(center.x-start.x-6,center.y-start.y-8)<0.01)
        s.controller.close();relative.controller.close()
        // Closing a controller restores key to its parent. Those offscreen
        // parents must leave the window server before the activating app runs.
        s.parent.close();relative.parent.close()
        checks += EditorNativeKey.run()
        return checks
    }
    static func renders() -> [Flows.Check] {
        var checks: [Flows.Check] = []
        for state in CLI.editorNames { for scale: CGFloat in [1,2] { autoreleasepool {
            let stage = EditorStage(state: state,scale: scale),image = stage.render(),body = stage.editorImage()
            checks.append(.init(name: "render \(state) \(Int(scale))x light editor and opaque canvas",pass: image.width == Int(1200*scale) && image.height == Int(900*scale) && body.width == Int(183*scale) && CLI.fullyOpaque(image) && stage.panel.appearance?.name == .aqua))
            let m = BoostEditorMetrics.self
            if !["editor-not-active","editor-global-off"].contains(state) {
                checks.append(.init(name: "render \(state) control frames match captured AX",pass: stage.view.pad.frame == m.ringFrame && stage.view.control(id: "editor.done")?.frame == m.done && stage.view.control(id: "editor.tool.size")?.frame == m.size && stage.view.control(id: "editor.tool.code")?.frame == m.code))
            }
            if state == "editor-no-color" {
                let pad = stage.view.pad,center = pad.primaryKnobCenter!,x = center.x+pad.frame.minX,y = center.y+pad.frame.minY
                let top = CLI.pixel(body,x: Int(x*scale),y: Int((y-8)*scale)),mid = CLI.pixel(body,x: Int(x*scale),y: Int(y*scale)),bottom = CLI.pixel(body,x: Int(x*scale),y: Int((y+8)*scale))
                print("knob gradient @\(scale)x top=\(top) mid=\(mid) bottom=\(bottom)")
                checks.append(.init(name: "knob-gradient probe \(Int(scale))x top darker / bottom lighter",pass: Int(top[0])+5<Int(mid[0]) && Int(mid[0])+5<Int(bottom[0])))
            }
            let dump = Flows.accessibilityDump(stage.view)
            checks.append(.init(name: "render \(state) native AX hierarchy",pass: state == "editor-first-run" ? dump.contains("Make a Boost") && dump.contains("Maybe Later") : dump.contains("AXGroup label=Color") && dump.contains("AXSlider label=Hue") && dump.contains("AXSlider label=Intensity")))
        } } }
        return checks
    }
}
