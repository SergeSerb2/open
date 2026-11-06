import AppKit
import OpenSiteControl
import OpenDesign
import OpenBoosts

@MainActor enum CodeFlows {
    static func run() -> [Flows.Check] {
        let checks = autoreleasepool { editingFlows()+pickerFlow() }
        // Complete deferred native teardown before another process takes focus.
        RunLoop.main.run(until:Date().addingTimeInterval(0.01))
        return checks+EditorNativeKey.run(review:true)+renders()
    }
    private static func editingFlows() -> [Flows.Check] {
        var checks: [Flows.Check] = []
        func check(_ name: String,_ pass: Bool) { checks.append(.init(name: name,pass: pass)) }
        let stage = EditorStage(),store = stage.host.boostStore,id = stage.session.boost.id
        let simple = stage.panel.frame
        stage.tap("editor.tool.code");stage.settle(0.3)
        guard let code = stage.view.codeView else { check("F17 Code opens the native code view",false);return checks }
        let text = code.editor
        func type(_ value: String) { for c in value { stage.key(0,String(c)) } }
        func focus() { stage.panel.makeKey();stage.panel.makeFirstResponder(text) }
        func replace(_ value: String) { focus();text.setSelectedRange(NSRange(location: 0,length: (text.string as NSString).length));type(value) }
        check("F17 mode widens left to 480x588 and hides simple header",stage.panel.frame.size == CGSize(width:480,height:588) && stage.panel.frame.maxX == simple.maxX && stage.view.control(id: "editor.done")?.isHidden == true && !code.isHidden)
        focus();let refreshes = stage.host.refreshes
        type("body {");stage.key(36,"\r");stage.key(48,"\t");type("color: red;")
        let draft = "body {\n    color: red;"
        check("F17 Return keeps brace indent and Tab adds two spaces; no immediate store write",text.string == draft && store.boost(id: id)?.css == "" && stage.host.refreshes == refreshes)
        let cssDelay = stage.session.pendingCodeSaveDelays[.css]
        stage.settle(0.22)
        check("F17 150ms CSS debounce upserts once and refreshes matching page plans",cssDelay == 0.150 && store.boost(id: id)?.css == draft && stage.host.refreshes == refreshes+1 && stage.host.refreshedPlans.count == 10 && stage.host.refreshedPlans.allSatisfy { $0.boosts.contains { $0.css.contains("color: red;") } })
        text.setSelectedRange((text.string as NSString).range(of: "    color: red;"))
        stage.key(44,"/",modifiers:.command)
        let commented = text.string == "body {\n    /* color: red; */"
        stage.key(44,"/",modifiers:.command)
        stage.key(30,"]",modifiers:.command);let indented = text.string == "body {\n      color: red;"
        stage.key(33,"[",modifiers:.command);stage.key(48,"\t",modifiers:.shift)
        let outdented = text.string == "body {\n  color: red;"
        check("F17 CSS Cmd+/ toggles comments; Cmd+]/Cmd+[ and Shift+Tab indent selected lines",commented && indented && outdented)
        replace("  ");type("}")
        check("F17 closing brace on a whitespace-only line outdents",text.string == "}")
        replace("a { color: red; }");stage.settle(0.22)
        let undoBefore = text.string;text.breakUndoCoalescing();type("x");stage.key(6,"z",modifiers:.command)
        check("F17 code owns native undo while Boost-level undo stays empty",text.string == undoBefore && !stage.session.undoManager.canUndo)
        replace("/* comment\ncontinued */\n@media screen {\nbody:hover { color: \"red\"; width: 16px; }\n}")
        func color(_ needle: String,_ value: NSColor) -> Bool {
            let range = (text.string as NSString).range(of: needle)
            return range.location != NSNotFound && (text.textStorage?.attribute(.foregroundColor,at: range.location,effectiveRange:nil) as? NSColor) == value
        }
        check("F17 native highlighter colors comments, strings, units, at-rules and properties",color("comment",BoostEditorColors.codeComment.nsColor) && color("continued",BoostEditorColors.codeComment.nsColor) && color("body",BoostEditorColors.title.nsColor) && color("\"red\"",BoostEditorColors.codeString.nsColor) && color("16px",BoostEditorColors.codeNumber.nsColor) && color("@media",BoostEditorColors.codeKeyword.nsColor) && color("color:",BoostEditorColors.codeProperty.nsColor))
        stage.key(3,"f",modifiers:.command);stage.settle()
        let findVisible = text.enclosingScrollView?.isFindBarVisible == true && stage.session.undoManager.canUndo && stage.session.undoManager.undoActionName == "Edit CSS"
        let hideFind = NSMenuItem();hideFind.tag = NSTextFinder.Action.hideFindInterface.rawValue;text.performTextFinderAction(hideFind);focus()
        check("F17 plain text disables substitutions and enables native Find and undo",!text.isRichText && !text.isAutomaticQuoteSubstitutionEnabled && !text.isAutomaticDashSubstitutionEnabled && !text.isAutomaticTextReplacementEnabled && !text.isAutomaticSpellingCorrectionEnabled && !text.isContinuousSpellCheckingEnabled && !text.isAutomaticDataDetectionEnabled && text.usesFindBar && findVisible && text.allowsUndo && text.enclosingScrollView?.verticalRulerView?.ruleThickness == 36)
        stage.key(19,"2",modifiers:.command)
        let js = code.editor;stage.panel.makeFirstResponder(js)
        let jsRefreshes = stage.host.refreshes
        typeJS(stage,"const answer = 42;\n")
        let unsaved = stage.session.pendingCodeSaveDelays[.js] == 0.500 && store.boost(id:id)?.js == "" && !code.showsRefreshToRun
        stage.settle(0.58)
        check("F18 JS 500ms save never refreshes live; Refresh to Run appears for stored JS",unsaved && store.boost(id:id)?.js == "const answer = 42;\n" && stage.host.refreshes == jsRefreshes && code.showsRefreshToRun)
        let notice = code.subviews.compactMap { $0 as? NSTextField }.first
        let dismiss = code.control("editor.code.dismissNotice")
        let noticeColor = notice?.textColor?.usingColorSpace(.sRGB)
        let noticeStyle = notice?.font == NSFont.systemFont(ofSize:11,weight:.regular) && noticeColor?.redComponent == 0 && noticeColor?.greenComponent == 0 && noticeColor?.blueComponent == 0 && noticeColor?.alphaComponent == 0.60 && notice?.maximumNumberOfLines == 1 && notice?.lineBreakMode == .byTruncatingTail && notice?.frame.minX == 12 && dismiss?.frame == CGRect(x:454,y:494,width:20,height:20) && dismiss?.accessibilityLabel() == "Dismiss"
        check("F18 JavaScript notice follows lead geometry/type, dismisses durably and keeps text",noticeStyle && !stage.defaults.bool(forKey:"open.boosts.hasDismissedJSNotice") && stage.session.showsJSNotice && { stage.tap("editor.code.dismissNotice");return stage.defaults.bool(forKey:"open.boosts.hasDismissedJSNotice") && !stage.session.showsJSNotice && js.string == "const answer = 42;\n" }())
        stage.tap("editor.code.run")
        let stillDirty = code.showsRefreshToRun
        stage.host.loadedScripts[id] = stage.host.boostStore.boost(id:id)?.js
        stage.controller.boundPageDidCommit(tabID:stage.host.tabID)
        check("F18 reload occurs once; commit with equal loaded JS hides Refresh to Run",stage.host.calls.last == "reload" && stage.host.reloads == 1 && stillDirty && !code.showsRefreshToRun)
        stage.panel.makeFirstResponder(js);js.setSelectedRange(NSRange(location:(js.string as NSString).length,length:0));typeJS(stage,"// pending")
        stage.key(15,"r",modifiers:.command)
        let commandReload = stage.host.reloads == 2 && stage.host.reloadScripts[id] == "const answer = 42;\n// pending" && store.boost(id:id)?.js == stage.host.reloadScripts[id]
        js.setSelectedRange(NSRange(location:0,length:(js.string as NSString).length));stage.key(44,"/",modifiers:.command)
        let jsComment = js.string.hasPrefix("// const")
        stage.key(44,"/",modifiers:.command)
        check("F18 Cmd+/ toggles JavaScript line comments and preserves CSS independently",commandReload && jsComment && js.string == "const answer = 42;\n// pending" && code.language == .js && !text.string.isEmpty)
        stage.tap("editor.code.devtools");stage.tap("editor.code.devtools")
        check("F18 Developer Tools toggles the host; Pick Selector remains disabled",stage.host.devTools == [true,false] && code.control("editor.code.pick")?.isEnabled == false)
        stage.key(18,"1",modifiers:.command)
        check("F17 Cmd+1 restores CSS; Cmd+2 selects JS without losing undo state",code.language == .css && code.editor === text && text.undoManager?.canUndo == true)
        func resizeWithMouse(_ point: CGPoint,_ delta: CGPoint) {
            guard let strip = code.hitTest(point) else { return }
            let start = code.convert(point,to:nil)
            let up = NSEvent.mouseEvent(with:.leftMouseUp,location:CGPoint(x:start.x+delta.x,y:start.y+delta.y),modifierFlags:[],timestamp:CACurrentMediaTime(),windowNumber:stage.panel.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:0)!
            NSApp.postEvent(up,atStart:false)
            stage.mouse(.leftMouseDown,point:strip.convert(point,from:code),in:strip);stage.settle()
        }
        let beforeMouse = stage.panel.frame.size
        resizeWithMouse(CGPoint(x:2,y:100),CGPoint(x:-30,y:0))
        resizeWithMouse(CGPoint(x:100,y:code.bounds.height-2),CGPoint(x:0,y:-20))
        let nativeResize = stage.panel.frame.width == beforeMouse.width+30 && stage.panel.frame.height == beforeMouse.height+20 && stage.defaults.string(forKey:"open.boosts.codeEditorSize") == "510x608"
        stage.controller.resizeCode(to:CGSize(width:620,height:700),persist:true)
        let resized = stage.panel.frame
        stage.controller.setCodeMode(false,animated:false);stage.controller.setCodeMode(true,animated:false);stage.settle()
        check("F17 resize persists 620x700, keeps right/top fixed and restores on Code entry",nativeResize && stage.defaults.string(forKey:"open.boosts.codeEditorSize") == "620x700" && stage.panel.frame.size == CGSize(width:620,height:700) && resized.maxX == simple.maxX && resized.maxY == simple.maxY)
        stage.controller.resizeCode(to:CGSize(width:1,height:1),persist:true)
        let minimumSize = stage.panel.frame.size == CGSize(width:360,height:420)
        func restoredSize(_ raw: String) -> CGSize {
            stage.controller.setCodeMode(false,animated:false)
            stage.defaults.set(raw,forKey:"open.boosts.codeEditorSize")
            stage.controller.setCodeMode(true,animated:false)
            return stage.panel.frame.size
        }
        let atLimit = String(repeating:"0",count:57)+"620x700" // exactly 64 UTF-8 bytes
        let accepted = restoredSize(atLimit) == CGSize(width:620,height:700)
        let refused = ["0"+atLimit,"620x700xextra","nanx700","620xinf"].allSatisfy { restoredSize($0) == CGSize(width:480,height:588) }
        check("F17 resize minimum and saved-size 64/65-byte boundary; malformed values fall back",minimumSize && accepted && refused)
        stage.panel.makeFirstResponder(text);stage.key(53,"\u{1b}")
        let ended = stage.view.isCodeMode && !(stage.panel.firstResponder is NSTextView)
        stage.key(53,"\u{1b}");stage.settle(0.3)
        check("F17 first Esc ends text editing; second Esc returns to simple mode",ended && !stage.view.isCodeMode && stage.controller.panel != nil)
        stage.controller.close();stage.parent.close()
        return checks
    }
    private static func pickerFlow() -> [Flows.Check] {
        let stage = EditorStage(state:"editor-code-css")
        defer { stage.controller.close();stage.parent.close() }
        let code = stage.view.codeView!,css = code.editor
        let before = css.string
        css.setSelectedRange(NSRange(location:5,length:0))
        let unavailable = code.control("editor.code.pick")?.isEnabled == false
        stage.host.zapEnabled = true;stage.session.onChange?()
        let enabled = code.control("editor.code.pick")?.isEnabled == true
        stage.tap("editor.code.pick")
        let entered = stage.session.isSelecting && stage.host.pickerCalls.last == "select"
        stage.host.deliver("picker:selected",selector:".picked")
        let expected = (before as NSString).replacingCharacters(in:NSRange(location:5,length:0),with:".picked")
        let inserted = css.string == expected && !stage.session.isSelecting && stage.host.pickerCalls.last == "exit"
        stage.panel.makeKey();stage.panel.makeFirstResponder(css)
        stage.key(6,"z",modifiers:.command)
        let undone = css.string == before
        // A late result while JS owns the view must never edit either language.
        stage.tap("editor.code.pick");code.select(.js)
        let js = code.editor,jsBefore = js.string
        let jsDisabled = code.control("editor.code.pick")?.isEnabled == false
        stage.host.deliver("picker:selected",selector:".late")
        let isolated = css.string == before && js.string == jsBefore && !stage.session.isSelecting
        return [.init(name:"Pick Selector real CSS view: unavailable disabled (\(unavailable)), enabled (\(enabled)), entered (\(entered)), caret insertion (\(inserted)), one Cmd+Z (\(undone)); JS disabled and late result ignored (\(jsDisabled && isolated))",pass:unavailable && enabled && entered && inserted && undone && jsDisabled && isolated)]
    }
    /// Real native field editing and window key dispatch, including hidden siblings.
    static func reviewFlows() -> [Flows.Check] {
        var checks: [Flows.Check] = []
        autoreleasepool {
            let stage = EditorStage(state:"editor-code-css",onScreen:true)
            defer { stage.controller.close();stage.parent.close() }
            guard stage.nativeParentReady else { checks.append(.init(name:"R1-1 native app owns activation before review flow",pass:false));return }
            let code = stage.view.codeView!,css = code.editor
            stage.panel.makeKey();stage.panel.makeFirstResponder(css)
            typeJS(stage,"/* keep CSS */")
            let cssBefore = css.string
            stage.controller.setCodeMode(false,animated:false)
            // A real Edit menu lets the native rename field own Undo through the
            // responder chain. Restore it even if the rename sheet fails.
            let previousMenu = NSApp.mainMenu
            let menu = NSMenu(),edit = NSMenu(title:"Edit"),item = NSMenuItem(title:"Edit",action:nil,keyEquivalent:"")
            item.submenu = edit;menu.addItem(item)
            edit.addItem(withTitle:"Undo",action:Selector(("undo:")),keyEquivalent:"z")
            NSApp.mainMenu = menu
            defer { NSApp.mainMenu = previousMenu }
            stage.menu("Rename this Boost…")
            if CommandLine.arguments.contains("--fail-sheet") {
                let shown = stage.controller.activeAlert?.messageText == "Rename this Boost" && stage.controller.activeAlert?.window.isVisible == true
                checks.append(.init(name:"R1 forced early failure after real rename sheet (visible=\(shown))",pass:false));return
            }
            // NSApp dispatch below proves the real keys. Also exercise AppKit's
            // view-tree callback contract explicitly: this OS may send the key
            // to the focused target before visiting unfocused sibling views.
            @MainActor func refused(_ chars: String,_ key: UInt16) -> Bool {
                let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:CACurrentMediaTime(),windowNumber:stage.panel.windowNumber,context:nil,characters:chars,charactersIgnoringModifiers:chars,isARepeat:false,keyCode:key)!
                return !css.performKeyEquivalent(with:event)
            }
            var renameUndo = false
            if let alert = stage.controller.activeAlert,let field = alert.accessoryView as? NSTextField,let input = field.currentEditor() as? NSTextView {
                let original = input.string
                input.setSelectedRange(NSRange(location:(original as NSString).length,length:0));input.breakUndoCoalescing()
                stage.key(0,"x",window:alert.window);input.breakUndoCoalescing()
                let typed = input.string == original+"x"
                let unfocusedRefused = refused("z",6)
                stage.key(6,"z",modifiers:.command,window:alert.window)
                renameUndo = typed && unfocusedRefused && input.string == original && css.string == cssBefore
            }
            stage.alert("Cancel")
            stage.controller.setCodeMode(true,animated:false);code.select(.js)
            let js = code.editor
            stage.panel.makeKey();stage.panel.makeFirstResponder(js);typeJS(stage,"const kept = 1;")
            js.setSelectedRange(NSRange(location:0,length:(js.string as NSString).length))
            stage.key(44,"/",modifiers:.command)
            let hiddenRefused = refused("/",44)
            let onlyJS = hiddenRefused && js.string == "// const kept = 1;" && css.string == cssBefore && css.enclosingScrollView?.isHidden == true
            print("R1-1 native rename Undo=\(renameUndo), hidden CSS unchanged and only JS commented=\(onlyJS)")
            checks.append(.init(name:"R1-1 unfocused callback refused; rename field owns Cmd+Z (\(renameUndo)); hidden callback refused and CSS cannot steal JS Cmd+/ (\(onlyJS))",pass:renameUndo && onlyJS))
        }
        var emptyDeleted = true,nonemptySaved = true
        for language in [BoostCodeLanguage.css,.js] {
            for finalText in [""," ","kept"] {
                autoreleasepool {
                    let stage = EditorStage(isNew:true,onScreen:true)
                    defer { stage.controller.close();stage.parent.close() }
                    guard stage.nativeParentReady else { emptyDeleted = false;nonemptySaved = false;return }
                    stage.controller.setCodeMode(true,animated:false)
                    let code = stage.view.codeView!;code.select(language)
                    let input = code.editor
                    stage.panel.makeKey();stage.panel.makeFirstResponder(input)
                    typeJS(stage,"temporary code")
                    input.setSelectedRange(NSRange(location:0,length:(input.string as NSString).length))
                    stage.key(51,"\u{7f}")
                    typeJS(stage,finalText)
                    stage.controller.close()
                    let loaded = BoostStore(root:stage.host.root,profileID:stage.host.profileID).load()
                    if finalText.trimmingCharacters(in:.whitespaces).isEmpty { emptyDeleted = emptyDeleted && loaded.isEmpty }
                    else { nonemptySaved = nonemptySaved && loaded.count == 1 && (language == .css ? loaded[0].css : loaded[0].js) == finalText }
                }
            }
        }
        print("R1-2 CSS/JS erased or whitespace-only new Boost deleted=\(emptyDeleted); pending nonempty code saved=\(nonemptySaved)")
        checks.append(.init(name:"F16 erased CSS/JS and whitespace-only new Boosts delete on close (\(emptyDeleted)); nonempty code flushes (\(nonemptySaved))",pass:emptyDeleted && nonemptySaved))
        return checks
    }
    private static func typeJS(_ stage: EditorStage,_ value: String) { for c in value { stage.key(c == "\n" ? 36 : 0,c == "\n" ? "\r" : String(c)) } }
    static func renders() -> [Flows.Check] {
        var checks: [Flows.Check] = []
        for state in ["editor-code-css","editor-code-js-dirty"] { for scale: CGFloat in [1,2] {
            autoreleasepool {
                let stage = EditorStage(state:state,scale:scale),image = stage.editorImage()
                let code = stage.view.codeView!
                let header = CLI.pixel(image,x:Int(100*scale),y:Int(10*scale)),bar = CLI.pixel(image,x:Int(110*scale),y:Int(540*scale))
                let ax = Flows.accessibilityDump(stage.view)
                let codeAX = ax.contains("AXTextArea label="+(state == "editor-code-css" ? "CSS code" : "JavaScript code")) && ax.contains("AXButton label=Back") && ax.contains("AXButton label=CSS") && ax.contains("AXButton label=JS") && !ax.contains("AXGroup label=Color")
                let noticeFill = CLI.pixel(image,x:Int(110*scale),y:Int(490*scale)+1)
                let noticeLine = CLI.pixel(image,x:Int(110*scale),y:Int(490*scale))
                let noticePixels = state != "editor-code-js-dirty" || noticeFill.prefix(3) == [242,242,244] && zip(noticeLine.prefix(3),[223,223,225]).allSatisfy { pair in abs(Int(pair.0)-pair.1)<=1 } && ax.contains("AXButton label=Dismiss")
                var ink = 0
                for y in Int(44*scale)..<Int(110*scale) { for x in Int(45*scale)..<Int(330*scale) { let pixel = CLI.pixel(image,x:x,y:y);if pixel[0]<220 || pixel[1]<220 || pixel[2]<220 { ink += 1 } } }
                checks.append(.init(name:"render \(state) @\(Int(scale))x native header/body/bar geometry and nonempty pixels",pass:codeAX && noticePixels && header[0] == 245 && header[1] == 245 && header[2] == 247 && bar[0] == 255 && bar[1] == 255 && bar[2] == 255 && ink>100 && image.width == Int(480*scale) && image.height == Int(588*scale) && code.control("editor.code.back")?.frame == BoostEditorMetrics.back && code.editor.enclosingScrollView?.frame.minY == 40 && code.control("editor.code.devtools")?.frame == CGRect(x:63,y:535,width:38,height:38) && code.language == (state == "editor-code-css" ? .css : .js) && code.showsRefreshToRun == (state == "editor-code-js-dirty") && !code.editor.string.isEmpty))
            }
        } }
        return checks
    }
    static func bench() -> [Flows.Check] {
        let stage = EditorStage(scale:2);stage.controller.setCodeMode(true,animated:false);stage.settle()
        let editor = stage.view.codeView!.editor
        let css = (0..<2000).map { ".row-\($0) { color: red; padding: 16px; }" }.joined(separator:"\n")
        editor.load(css,language:.css);stage.panel.makeKey();stage.panel.makeFirstResponder(editor);stage.settle()
        var samples: [Double] = [],highlighted: [Int] = []
        for i in 0..<110 {
            autoreleasepool {
                editor.setSelectedRange(NSRange(location:(editor.string as NSString).length-2,length:0))
                let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:CACurrentMediaTime(),windowNumber:stage.panel.windowNumber,context:nil,characters:"x",charactersIgnoringModifiers:"x",isARepeat:false,keyCode:7)!
                NSApp.sendEvent(event)
                let ms = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)-start)/1e6
                if i>=10 { samples.append(ms);highlighted.append(editor.lastHighlightedCharacters) }
            }
        }
        let p95 = samples.sorted()[94]
        var loads = [Double](repeating:0,count:3);_ = getloadavg(&loads,3)
        print(String(format:"Code keystroke: 2x 2000-line CSS; 10 warmups, 100 real native keys; main-thread CPU p95 %.3f ms; lateness vs 2 ms %+.3f ms; load %.2f %.2f %.2f; highlighted max %d / %d chars",p95,p95-2,loads[0],loads[1],loads[2],highlighted.max() ?? 0,(editor.string as NSString).length))
        return [.init(name:"code keystroke to highlight p95 < 2 ms on 2000-line CSS",pass:p95<2 && samples.count == 100 && editor.string.contains(String(repeating:"x",count:110)) && (highlighted.max() ?? .max)<2000)]
    }
}
