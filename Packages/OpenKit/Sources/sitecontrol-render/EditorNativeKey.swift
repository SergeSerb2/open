import AppKit
import OpenDesign

/// A registered harness app is required for a real activating browser window.
/// The CLI process cannot acquire that state merely by overriding isKeyWindow.
@MainActor enum EditorNativeKey {
    static func run(review: Bool = false) -> [Flows.Check] {
        let competing = NSApp.windows.filter { $0 is EditorParentWindow && $0.isVisible }.count
        guard competing == 0 else {
            return [.init(name:"F25 native key suite has no competing editor parent windows (found \(competing))",pass:false)]
        }
        let fm = FileManager.default,base: URL
        if let path = ProcessInfo.processInfo.environment["OPEN_VERIFY_SUITE_ROOT"] {
            var directory: ObjCBool = false
            guard path.utf8.count <= 4096, path.hasPrefix("/"),
                  fm.fileExists(atPath: path,isDirectory: &directory), directory.boolValue else {
                return [.init(name:"F25 owned native harness root must be an existing absolute directory",pass:false)]
            }
            base = URL(fileURLWithPath: path,isDirectory: true)
        } else { base = fm.temporaryDirectory }
        // Shared-screen holds must stop after the first focus loss. Other
        // callers retain the existing bounded three-attempt policy.
        let configured = ProcessInfo.processInfo.environment["OPEN_VERIFY_FOCUS_ATTEMPTS"]
        guard configured == nil || configured == "1" || configured == "3" else {
            return [.init(name:"native focus attempts must be 1 or 3",pass:false)]
        }
        let maximumAttempts = configured == "1" ? 1 : 3
        var retained: [Flows.Check] = []
        for attempt in 1...maximumAttempts {
            let checks = runAttempt(base: base,attempt: attempt,review: review)
            let interruptions = checks.filter(\.interrupted)
            if configured == "1", !interruptions.isEmpty { CLI.report(retained+checks) }
            if interruptions.isEmpty || checks.contains(where: { !$0.pass && !$0.interrupted && !$0.info }) || attempt == maximumAttempts { return retained+checks }
            // A fresh registered app, model and window per attempt, as in e2e.
            // Historical interruptions stay visible but never count as passes.
            retained += interruptions.map { .init(name:$0.name,pass:false,info:true,interrupted:true) }
        }
        return retained
    }
    private static func runAttempt(base: URL,attempt: Int,review: Bool) -> [Flows.Check] {
        let fm = FileManager.default
        let root = base.appendingPathComponent("open-editor-native-"+UUID().uuidString),app = root.appendingPathComponent("EditorHarness.app")
        let id = "org.open.harness.editor."+UUID().uuidString.lowercased(),result = root.appendingPathComponent("result.json")
        defer {
            for running in NSRunningApplication.runningApplications(withBundleIdentifier: id) { _ = running.forceTerminate() }
            try? fm.removeItem(at: root)
        }
        do {
            let mac = app.appendingPathComponent("Contents/MacOS"),resources = app.appendingPathComponent("Contents/Resources")
            try fm.createDirectory(at: mac,withIntermediateDirectories: true);try fm.createDirectory(at: resources,withIntermediateDirectories: true)
            try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath(),to: mac.appendingPathComponent("sitecontrol-render"))
            let bundleRoot = Bundle.module.bundleURL.deletingLastPathComponent()
            for bundle in try fm.contentsOfDirectory(at: bundleRoot,includingPropertiesForKeys: nil) where bundle.lastPathComponent.hasPrefix("OpenKit_") && bundle.pathExtension == "bundle" { try fm.copyItem(at: bundle,to: resources.appendingPathComponent(bundle.lastPathComponent)) }
            let info: [String: Any] = ["CFBundleExecutable":"sitecontrol-render","CFBundleIdentifier":id,"CFBundleName":"Open Editor Harness","CFBundlePackageType":"APPL","NSHighResolutionCapable":true]
            try PropertyListSerialization.data(fromPropertyList: info,format: .xml,options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            let process = Process();process.executableURL = URL(fileURLWithPath: "/usr/bin/open");process.arguments = ["-W","-n",app.path,"--args","editor-native-key","--out",result.path,"--renderer-pid",String(ProcessInfo.processInfo.processIdentifier),"--focus-attempt",String(attempt)]
            if review { process.arguments?.append("--review");if CommandLine.arguments.contains("--fail-sheet") { process.arguments?.append("--fail-sheet") } }
            process.standardOutput = FileHandle.nullDevice;process.standardError = FileHandle.nullDevice;try process.run()
            let deadline = Date().addingTimeInterval(20)
            while process.isRunning && Date()<deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            if process.isRunning { process.terminate();process.waitUntilExit() }
            guard let data = try? Data(contentsOf: result),data.count <= 65536,let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],!rows.isEmpty,rows.count<=32 else { return [.init(name:"F25 registered native harness produced its result",pass:false)] }
            var checks: [Flows.Check] = rows.compactMap { row in guard let name = row["name"] as? String,let pass = row["pass"] as? Bool else { return nil };return .init(name:name,pass:pass,interrupted: row["interrupted"] as? Bool ?? false) }
            guard checks.count == rows.count else { return [.init(name:"F25 native result schema is complete",pass:false)] }
            let interrupted = checks.contains(where: \.interrupted)
            if review {
                guard rows.count == 2,process.terminationStatus == 0 else { return [.init(name:"R1 registered native app completes both review flows and exits",pass:false)] }
                return checks
            }
            checks.append(.init(name:interrupted ? "F25 native attempt \(attempt) exits after foreground interruption" : "F25 native suite completes all ten checks and exits",pass:(interrupted || rows.count == 10) && process.terminationStatus == 0));return checks
        } catch { return [.init(name:"F25 registered native harness launch: \(error)",pass:false)] }
    }
    private static var focusAttempt = 1
    private static var ownedPIDs: Set<Int32> = [ProcessInfo.processInfo.processIdentifier]
    static func enterAppLoop(out: String,rendererPID: Int32?,attempt: Int,review: Bool) {
        focusAttempt = attempt
        if let rendererPID,rendererPID > 1 { ownedPIDs.insert(rendererPID) }
        let timer = Timer(timeInterval: 0,repeats: false) { _ in MainActor.assumeIsolated {
            do { try runHere(out: out,review: review) } catch { FileHandle.standardError.write(Data("native editor harness: \(error)\n".utf8)) }
            NSApp.stop(nil)
            if let wake = NSEvent.otherEvent(with: .applicationDefined,location: .zero,modifierFlags: [],timestamp: ProcessInfo.processInfo.systemUptime,windowNumber: 0,context: nil,subtype: 0,data1: 0,data2: 0) { NSApp.postEvent(wake,atStart: true) }
        } }
        RunLoop.main.add(timer,forMode: .default)
        NSApp.run()
    }
    static func runHere(out: String,review: Bool) throws {
        if review {
            let checks = CodeFlows.reviewFlows().map { focusCheck($0.name,pass:$0.pass) }
            try write(checks,out:out);return
        }
        NSApp.setActivationPolicy(.regular)
        var checks: [Flows.Check] = []
        func check(_ name: String,_ pass: Bool) { checks.append(focusCheck(name,pass: pass)) }
        var mayContinue: Bool {
            ProcessInfo.processInfo.environment["OPEN_VERIFY_FOCUS_ATTEMPTS"] != "1"
                || !checks.contains(where: \.interrupted)
        }
        autoreleasepool {
            let p = EditorStage(onScreen: true)
            defer { p.controller.close();p.parent.close() }
            guard p.nativeParentReady else {
                check("F25 native browser parent owns activation before presenting its nonactivating panel",false);return
            }
            p.parent.makeKeyAndOrderFront(nil);p.settle()
            let before = p.parent.isKeyWindow && !p.panel.isKeyWindow
            p.drag();p.tap("editor.font.0");p.tap("editor.tool.case")
            check("F25 pointer pad/buttons/font cells keep the native browser window key (parentReady=\(p.nativeParentReady), parentMain=\(p.parent.isMainWindow))",before && p.parent.isKeyWindow && !p.panel.isKeyWindow)
            guard mayContinue else { return }
            p.tap("editor.color.advanced")
            guard let popup = p.view.advancedPopover else { check("F24 advanced popover opens after colors are ready=\(p.session.colorsReady)",false);return }
            let frame = p.panel.convertFromScreen(popup.panel.frame)
            check("F24 advanced window frame is (-34,258,250,232)",abs(frame.minX+34)<0.01 && abs(p.panel.frame.height-frame.maxY-258)<0.01 && frame.size == CGSize(width:250,height:232))
            guard mayContinue else { return }
            check("F25 advanced pointer use keeps browser key",p.parent.isKeyWindow && !popup.panel.isKeyWindow)
            guard mayContinue else { return }
            p.key(53,"\u{1b}",window:popup.panel);p.settle(0.25)
            check("F24 Esc closes only the advanced popover",!p.view.advanced && p.controller.panel != nil)
            guard mayContinue else { return }
            p.tap("editor.color.advanced");p.mouse(.leftMouseDown,point:CGPoint(x:400,y:300),in:p.backdrop);p.mouse(.leftMouseUp,point:CGPoint(x:400,y:300),in:p.backdrop);p.settle(0.25)
            check("F24 native outside click closes the advanced popover",!p.view.advanced)
            guard mayContinue else { return }
            p.menu("Rename this Boost…");p.settle()
            check("F25 rename text sheet becomes key",p.controller.activeAlert?.window.isKeyWindow == true && !p.parent.isKeyWindow)
            guard mayContinue else { return }
            p.alert("Cancel");p.panel.makeKey();p.settle()
            check("F25 native floating-window key entry focuses Done",p.panel.isKeyWindow && p.panel.firstResponder === p.view.control(id:"editor.done"))
            guard mayContinue else { return }
            p.key(48,"\t");check("F25 Tab follows Done with the name menu",p.panel.firstResponder === p.view.control(id:"editor.name"))
            guard mayContinue else { return }
            p.tap("editor.tool.code");p.settle(0.3)
            if let code = p.view.codeView {
                p.parent.makeKeyAndOrderFront(nil)
                let point = code.editor.convert(CGPoint(x:80,y:20),to:nil)
                let up = NSEvent.mouseEvent(with:.leftMouseUp,location:point,modifierFlags:[],timestamp:CACurrentMediaTime(),windowNumber:p.panel.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:0)!
                NSApp.postEvent(up,atStart:false)
                p.mouse(.leftMouseDown,point:CGPoint(x:80,y:20),in:code.editor);p.settle()
                check("F25 click into code makes the native editor key",p.panel.isKeyWindow && !p.parent.isKeyWindow && p.panel.firstResponder === code.editor)
            } else { check("F25 code view exists",false) }
            guard mayContinue else { return }
            p.controller.setCodeMode(false,animated:false);p.panel.makeKey();p.settle()
            checks.append(checkDoneKeyReturn(first: p))
        }
        try write(checks,out:out)
    }
    private static func write(_ checks: [Flows.Check],out: String) throws {
        let rows = checks.map { ["name":$0.name,"pass":$0.pass,"interrupted":$0.interrupted] as [String:Any] }
        try JSONSerialization.data(withJSONObject:rows,options:[.sortedKeys]).write(to:URL(fileURLWithPath:out),options:.atomic)
    }

    private struct Foreground {
        let pid: Int32
        let name: String,bundle: String
        let owned: Bool
        var label: String { "\(name) [\(bundle)] pid=\(pid)" }
    }
    private static func foreground() -> Foreground {
        let app = NSWorkspace.shared.frontmostApplication
        func bounded(_ value: String?) -> String {
            String(decoding:(value ?? "<unknown>").utf8.prefix(256),as:UTF8.self)
                .replacingOccurrences(of:"\n",with:" ").replacingOccurrences(of:"\r",with:" ").replacingOccurrences(of:"|",with:"/")
        }
        let pid = app?.processIdentifier ?? 0
        return Foreground(pid:pid,name:bounded(app?.localizedName),bundle:bounded(app?.bundleIdentifier),owned:ownedPIDs.contains(pid))
    }
    private static func focusCheck(_ name: String,pass: Bool,foreground fg: Foreground? = nil) -> Flows.Check {
        let fg = fg ?? foreground()
        var loads = [Double](repeating: 0,count: 3);_ = getloadavg(&loads,3)
        let interrupted = !fg.owned
        let status = interrupted ? "INTERRUPTED (foreground lost to \(fg.label))" : "foreground=\(fg.label)"
        return .init(name:"\(name) — attempt \(focusAttempt) \(status); load1 \(String(format:"%.2f",loads[0]))",pass:pass && !interrupted,interrupted:interrupted)
    }
    private static var ownsActivation: Bool {
        NSApp.isActive && foreground().pid == ProcessInfo.processInfo.processIdentifier
    }
    private static func checkDoneKeyReturn(first stage: EditorStage) -> Flows.Check {
        let ready = ownsActivation && stage.panel.isKeyWindow
        guard ready else { return focusCheck("F25 Done precondition: editor is key in the foreground app",pass:false) }
        let parentWasMain = stage.parent.isMainWindow
        let closing = stage.panel,start = ProcessInfo.processInfo.systemUptime
        stage.tap("editor.done")
        // Keep the original 3 s deadline. Do not repair activation or key focus
        // after Done; classify the actual foreground owner at the result.
        while (closing.isVisible || stage.controller.panel != nil || !stage.parent.isKeyWindow || !ownsActivation) && ProcessInfo.processInfo.systemUptime<start+3 { stage.settle(0.01) }
        let elapsed = ProcessInfo.processInfo.systemUptime-start,fg = foreground()
        let pass = NSApp.isActive && fg.pid == ProcessInfo.processInfo.processIdentifier && stage.controller.panel == nil && !closing.isVisible && stage.parent.isKeyWindow
        let detail = String(format:"configured close %.3f s, elapsed %.3f s, lateness %+.1f ms",Motion.boostEditorCloseDuration,elapsed,(elapsed-Motion.boostEditorCloseDuration)*1000)
        return focusCheck("F25 Done returns key to the native browser window (closed=\(stage.controller.panel == nil), visible=\(closing.isVisible), parentKey=\(stage.parent.isKeyWindow), active=\(NSApp.isActive), parentMainBefore=\(parentWasMain), parentMainAfter=\(stage.parent.isMainWindow)); \(detail)",pass:pass,foreground:fg)
    }
}
