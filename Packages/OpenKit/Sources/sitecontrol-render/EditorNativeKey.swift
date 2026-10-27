import AppKit

/// A registered harness app is required for a real activating browser window.
/// The CLI process cannot acquire that state merely by overriding isKeyWindow.
@MainActor enum EditorNativeKey {
    static func run() -> [Flows.Check] {
        let fm = FileManager.default,root = fm.temporaryDirectory.appendingPathComponent("open-editor-native-"+UUID().uuidString),app = root.appendingPathComponent("EditorHarness.app")
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
            let process = Process();process.executableURL = URL(fileURLWithPath: "/usr/bin/open");process.arguments = ["-W","-n",app.path,"--args","editor-native-key","--out",result.path]
            process.standardOutput = FileHandle.nullDevice;process.standardError = FileHandle.nullDevice;try process.run()
            let deadline = Date().addingTimeInterval(20)
            while process.isRunning && Date()<deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            if process.isRunning { process.terminate();process.waitUntilExit() }
            guard let data = try? Data(contentsOf: result),data.count <= 65536,let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],!rows.isEmpty,rows.count<=32 else { return [.init(name:"F25 registered native harness produced its result",pass:false)] }
            return rows.compactMap { row in guard let name = row["name"] as? String,let pass = row["pass"] as? Bool else { return nil };return .init(name:name,pass:pass) }
        } catch { return [.init(name:"F25 registered native harness launch: \(error)",pass:false)] }
    }
    static func runHere(out: String) throws {
        NSApp.setActivationPolicy(.regular);NSApp.activate()
        var checks: [Flows.Check] = []
        func check(_ name: String,_ pass: Bool) { checks.append(.init(name:name,pass:pass)) }
        autoreleasepool {
            let p = EditorStage(onScreen: true)
            defer { p.controller.close();p.parent.close() }
            let deadline = Date().addingTimeInterval(3)
            while !NSApp.isActive && Date()<deadline { p.settle(0.01) }
            p.parent.makeKeyAndOrderFront(nil);p.settle()
            let before = p.parent.isKeyWindow && !p.panel.isKeyWindow
            p.drag();p.tap("editor.font.0");p.tap("editor.tool.case")
            check("F25 pointer pad/buttons/font cells keep the native browser window key",before && p.parent.isKeyWindow && !p.panel.isKeyWindow)
            p.tap("editor.color.advanced");let popup = p.view.advancedPopover!,frame = p.panel.convertFromScreen(popup.panel.frame)
            check("F24 advanced window frame is (-34,258,250,232)",abs(frame.minX+34)<0.01 && abs(p.panel.frame.height-frame.maxY-258)<0.01 && frame.size == CGSize(width:250,height:232))
            check("F25 advanced pointer use keeps browser key",p.parent.isKeyWindow && !popup.panel.isKeyWindow)
            p.key(53,"\u{1b}",window:popup.panel);p.settle(0.25)
            check("F24 Esc closes only the advanced popover",!p.view.advanced && p.controller.panel != nil)
            p.tap("editor.color.advanced");p.mouse(.leftMouseDown,point:CGPoint(x:400,y:300),in:p.backdrop);p.mouse(.leftMouseUp,point:CGPoint(x:400,y:300),in:p.backdrop);p.settle(0.25)
            check("F24 native outside click closes the advanced popover",!p.view.advanced)
            p.menu("Rename this Boost…");p.settle()
            check("F25 rename text sheet becomes key",p.controller.activeAlert?.window.isKeyWindow == true && !p.parent.isKeyWindow)
            p.alert("Cancel");p.panel.makeKey();p.settle()
            check("F25 native floating-window key entry focuses Done",p.panel.isKeyWindow && p.panel.firstResponder === p.view.control(id:"editor.done"))
            p.key(48,"\t");check("F25 Tab follows Done with the name menu",p.panel.firstResponder === p.view.control(id:"editor.name"))
            p.tap("editor.done");p.settle(0.2)
            check("F25 Done returns key to the native browser window",p.controller.panel == nil && p.parent.isKeyWindow)
        }
        let rows = checks.map { ["name":$0.name,"pass":$0.pass] as [String:Any] }
        try JSONSerialization.data(withJSONObject:rows,options:[.sortedKeys]).write(to:URL(fileURLWithPath:out),options:.atomic)
    }
}
