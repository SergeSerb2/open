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
        checks += reviewFlows()
        let axStage = EditorStage(); let ax = Flows.accessibilityDump(axStage.view)
        let labels = ["Boost scope","More","Close","Colors","Invert lightness","Advanced color controls","Reset to original colors","Original","System","Zap","Code","Change text size","Change text case"]
        check("F21 real editor AX hierarchy labels all controls", labels.allSatisfy { ax.contains("label="+$0+"\n") } && ax.contains("AXSlider label=Colors\n"))
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
        let slider = sliderStage.view.subviews.first { $0.identifier?.rawValue == "editor.slider.0" } as! NSControl
        for _ in 0..<30 { sliderStage.key(48,"\t"); if sliderStage.panel.firstResponder === slider { break } }
        let original = sliderStage.session.boost, refreshes = sliderStage.host.refreshes
        for _ in 0..<4 { sliderStage.key(124,"\u{f703}") }
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
        for _ in 0..<2 { sliderStage.key(124,"\u{f703}") }
        sliderStage.key(48,"\t")
        check("103-2 keyboard focus loss commits the slider group",!sliderStage.session.isInteracting)
        let owners = EditorStage(); owners.tap("editor.color.advanced")
        for _ in 0..<20 { owners.key(48,"\t"); if owners.panel.firstResponder === owners.view.wheel { break } }
        owners.key(126,"\u{f700}"); let wheelState = owners.session.boost
        let brightness = owners.view.subviews.first { $0.identifier?.rawValue == "editor.slider.0" }!
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
        check("103-8 pending page sampling disables Shuffle and wheel edits",!loading.session.colorsReady && loading.controller.makeMenu().items.first { $0.title == "Shuffle" }?.isEnabled == false && loading.view.control(id: "editor.color.invert")?.isEnabled == false && !loading.view.wheel.acceptsFirstResponder)
        loading.settle(0.4)
        check("103-8 sampling enables Shuffle and wheel edits",loading.session.colorsReady && loading.controller.makeMenu().items.first { $0.title == "Shuffle" }?.isEnabled == true && loading.view.control(id: "editor.color.invert")?.isEnabled == true)
        let fonts = EditorStage(); let fourth = fonts.view.control(id: "editor.font.3")!
        for _ in 0..<40 { fonts.key(48,"\t"); if fonts.panel.firstResponder === fourth { break } }
        let visible = fourth.visibleRect
        check("design 10 keyboard focus fully reveals a 56 pt font chip",fonts.panel.firstResponder === fourth && fourth.bounds.width == 56 && visible.width >= 55.9 && fourth.showsKeyboardFocus)
        check("design 12 disabled tile copy is user-facing",fonts.view.control(id: "editor.tool.zap")?.toolTip == "Zap isn’t available yet." && fonts.view.control(id: "editor.tool.code")?.toolTip == "Code editing isn’t available yet.")
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
        for path in ["/other/page","/"] {
            let savedIP = EditorStage(url: URL(string: "http://127.0.0.1"+path)!,boost: Boost(name: "Local",siteMatch: SiteMatch(domain: "127.0.0.1",pathPrefix: "/news")))
            let menu = savedIP.view.scopeMenu()
            checks.append(.init(name: "103-4 saved IP /news is checked while page is "+path,pass: menu.items.filter { $0.state == .on }.map(\.title) == ["Only pages under /news"] && menu.items.first?.title == "127.0.0.1" && savedIP.view.control(id: "editor.scope")?.title == "127.0.0.1/news ▾"))
        }
        let ipRoot = EditorStage(url: URL(string: "http://127.0.0.1/")!)
        checks.append(.init(name: "root IP scope hides path and registrable-domain items",pass: ipRoot.view.scopeMenu().items.map(\.title) == ["127.0.0.1"]))
        return checks
    }
    private static func inkContrast(_ image: CGImage,rect: CGRect,scale: CGFloat,background: [UInt8]) -> Double {
        func luminance(_ rgb: [UInt8]) -> Double {
            let linear = rgb.prefix(3).map { value -> Double in let s = Double(value)/255; return s <= 0.04045 ? s/12.92 : pow((s+0.055)/1.055,2.4) }
            return linear[0]*0.2126+linear[1]*0.7152+linear[2]*0.0722
        }
        let base = luminance(background)
        guard let data = image.dataProvider?.data,let bytes = CFDataGetBytePtr(data) else { return 0 }
        var best = 1.0
        for y in Int(rect.minY*scale)..<Int(rect.maxY*scale) { for x in Int(rect.minX*scale)..<Int(rect.maxX*scale) {
            let i = y*image.bytesPerRow+x*4, ink = luminance([bytes[i],bytes[i+1],bytes[i+2]])
            best = max(best,(max(base,ink)+0.05)/(min(base,ink)+0.05))
        } }
        return best
    }
    static func renders() -> [Flows.Check] {
        var checks: [Flows.Check] = []
        for state in CLI.editorNames { for appearance in [ContentAppearance.light,.dark] { for scale: CGFloat in [1,2] {
            autoreleasepool {
                let stage = EditorStage(state: state,scale: scale,appearance: appearance), image = stage.render()
                let frame = stage.parent.convertFromScreen(stage.panel.frame)
                let fill = CLI.pixel(image,x: Int((frame.minX+BoostEditorMetrics.shadowSide+10)*scale),y: Int((760-frame.maxY+BoostEditorMetrics.shadowTop+50)*scale)), backdrop = CLI.pixel(image,x: Int(5*scale),y: Int(5*scale))
                checks.append(.init(name: "render \(state) \(appearance.rawValue) \(Int(scale))x body and opaque backdrop",pass: image.width == Int(1000*scale) && image.height == Int(760*scale) && fill != backdrop && CLI.fullyOpaque(image)))
                let color = Core.popoverBackground.resolved(appearance).nsColor.usingColorSpace(.sRGB)!
                let expected = [color.redComponent,color.greenComponent,color.blueComponent].map { Int(($0*255).rounded()) }
                let stableFill = zip(fill.prefix(3),expected).allSatisfy { abs(Int($0)-$1) <= 2 }
                checks.append(.init(name: "render \(state) exact opaque editor surface after resize",pass: stableFill))
                if state == "editor-interstitial" {
                    let origin = CGPoint(x: frame.minX+BoostEditorMetrics.shadowSide,y: 760-frame.maxY+BoostEditorMetrics.shadowTop)
                    let title = inkContrast(image,rect: CGRect(x: origin.x+22,y: origin.y+140,width: 224,height: 18),scale: scale,background: fill)
                    let body = inkContrast(image,rect: CGRect(x: origin.x+26,y: origin.y+178,width: 216,height: 64),scale: scale,background: fill)
                    let footer = CLI.pixel(image,x: Int((origin.x+20)*scale),y: Int((origin.y+280)*scale))
                    let button = inkContrast(image,rect: CGRect(x: origin.x+14,y: origin.y+282,width: 240,height: 30),scale: scale,background: footer)
                    checks.append(.init(name: String(format: "interstitial %@ %dx rendered contrast title %.2f body %.2f button %.2f",appearance.rawValue,Int(scale),title,body,button),pass: title >= 4.5 && body >= 4.5 && button >= 3))
                }
                let dump = Flows.accessibilityDump(stage.view)
                checks.append(.init(name: "render \(state) real controls present",pass: dump.contains("AXButton label=Close\n") && (state == "editor-interstitial" ? dump.contains("Make your own!") : dump.contains("AXSlider label=Colors"))))
            }
        } } }
        return checks
    }
}
