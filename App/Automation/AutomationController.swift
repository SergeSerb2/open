#if OPEN_AUTOMATION
  import AppKit
  import OpenEngine
  import Synchronization

  /// Executes automation commands on the main actor. Every command answers
  /// `{"id":…, "ok":true, "result":…}` or `{"id":…, "ok":false, "error":"…"}`.
  @MainActor
  final class AutomationController {
    struct Failure: Error { let message: String }

    let window: BrowserWindowController
    private let blockCounter = BlockCounter()

    init(window: BrowserWindowController) {
      self.window = window
    }

    func handle(_ data: Data) async -> Data {
      var id: Any = NSNull()
      var response: [String: Any]
      do {
        guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cmd = request["cmd"] as? String
        else { throw Failure(message: "expected {\"cmd\": …}") }
        id = request["id"] ?? NSNull()
        let args = request["args"] as? [String: Any] ?? [:]
        let result = try await run(cmd, args)
        response = ["id": id, "ok": true, "result": result]
      } catch let failure as Failure {
        response = ["id": id, "ok": false, "error": failure.message]
      } catch {
        response = ["id": id, "ok": false, "error": "\(error.localizedDescription)"]
      }
      let safe = JSONSerialization.isValidJSONObject(response) ? response : ["id": id, "ok": false, "error": "unserializable result"]
      return (try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    // MARK: Dispatch

    private func run(_ cmd: String, _ a: [String: Any]) async throws -> Any {
      switch cmd {
      case "ping":
        return [
          "pid": Int(getpid()), "chromium": Engine.shared.chromiumVersion, "cef": Engine.shared.cefVersion,
          "userData": Engine.shared.configuration.userDataDirectory.path,
        ]
      case "tabs":
        return window.allTabs.map(describe)
      case "open":
        let url = try url(a, "url")
        if a["kind"] as? String == "peek" { return describe(window.openPeek(url: url)) }
        var profileTab: Tab
        if let profileID = a["profile"] as? String {
          let profile = Engine.shared.profile(identifier: profileID)
          let webView = window.makeWebView(url: url, style: style(a) ?? window.options.defaultStyle, profile: profile)
          profileTab = window.addTab(webView: webView, background: a["background"] as? Bool ?? false)
        } else {
          profileTab = window.openTab(url: url, style: style(a), background: a["background"] as? Bool ?? false)
        }
        return describe(profileTab)
      case "navigate":
        try tab(a).webView.load(try url(a, "url"))
        return true
      case "back":
        try tab(a).webView.goBack()
        return true
      case "activate":
        window.activate(try tab(a))
        return true
      case "close":
        window.close(try tab(a))
        return true
      case "split":
        let left = try tab(a, key: "left"), right = try tab(a, key: "right")
        window.showSplit(left: left, right: right)
        return true
      case "wait":
        return try await waitForLoad(try tab(a), timeout: a["timeout"] as? Double ?? 20)
      case "eval":
        guard let js = a["js"] as? String else { throw Failure(message: "missing js") }
        let result = try await tab(a).webView.evaluateJavaScript(js)
        return result ?? NSNull()
      case "devtools":
        guard let method = a["method"] as? String else { throw Failure(message: "missing method") }
        return try await tab(a).webView.sendDevToolsMethod(method, parameters: a["params"] as? [String: Any])
      case "mouse":
        // Clicks at (x, y) points from the top-left of one of OUR windows by
        // sending NSEvents to that window. The system cursor does not move.
        let number = a["window"] as? Int ?? 0
        guard let target = NSApp.windows.first(where: { $0.windowNumber == number }) else {
          throw Failure(message: "no window \(number)")
        }
        let p = NSPoint(x: a["x"] as? Double ?? 0, y: target.frame.height - (a["y"] as? Double ?? 0))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
          if let e = NSEvent.mouseEvent(
            with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: number, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
          {
            target.sendEvent(e)
          }
        }
        return true
      case "focus":
        try tab(a).webView.focusPage()
        return true
      case "rightclick":
        let tab = try tab(a)
        let x = a["x"] as? Double ?? 100, y = a["y"] as? Double ?? 100
        for type in ["mousePressed", "mouseReleased"] {
          _ = try await tab.webView.sendDevToolsMethod(
            "Input.dispatchMouseEvent", parameters: ["type": type, "x": x, "y": y, "button": "right", "clickCount": 1])
        }
        return true
      case "click":
        return try await click(try tab(a), selector: a["selector"] as? String, text: a["text"] as? String)
      case "type":
        let webView = try tab(a).webView
        _ = try await webView.sendDevToolsMethod("Input.insertText", parameters: ["text": a["text"] as? String ?? ""])
        return true
      case "events":
        return window.drainEvents()
      case "extensions":
        let profile = (a["profile"] as? String).map { Engine.shared.profile(identifier: $0) } ?? window.profile
        profile.extensions.reload()
        return profile.extensions.installedExtensions.map(describe)
      case "popup":
        guard let id = a["extension"] as? String, let ext = window.profile.extensions.extension(identifier: id)
        else { throw Failure(message: "unknown extension") }
        guard let tab = window.openExtensionPopup(ext) else { throw Failure(message: "extension has no popup") }
        return describe(tab)
      case "windows":
        return NSApp.windows.map(describe)
      case "window-frame":
        guard let w = window.window else { throw Failure(message: "no window") }
        if let f = a["frame"] as? [Double], f.count == 4 {
          w.setFrame(NSRect(x: f[0], y: f[1], width: f[2], height: f[3]), display: true)
        }
        return NSStringFromRect(w.frame)
      case "snapshot":
        return try await snapshot(a)
      case "key":
        return try sendKey(a)
      case "find":
        let tab = try tab(a)
        tab.webView.find(a["text"] as? String ?? "", forward: true, caseSensitive: false)
        try await Task.sleep(for: .milliseconds(500))
        let r = window.lastFindResult
        return ["matches": r?.matchCount ?? 0, "active": r?.activeMatchIndex ?? 0, "final": r?.isFinal ?? false]
      case "zoom":
        let webView = try tab(a).webView
        if let level = a["level"] as? Double { webView.zoomLevel = level }
        return webView.zoomLevel
      case "mute":
        let webView = try tab(a).webView
        webView.isMuted = a["muted"] as? Bool ?? true
        return ["muted": webView.isMuted, "audible": webView.isAudible]
      case "chrome-command":
        guard let command = a["command"] as? Int else { throw Failure(message: "missing command") }
        return try tab(a).webView.executeChromeCommand(command)
      case "devtools-open":
        try tab(a).webView.showDevTools()
        return true
      case "print-pdf":
        let path = (a["path"] as? String) ?? NSTemporaryDirectory() + "open-print.pdf"
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
          (try? tab(a))?.webView.printToPDF(at: URL(fileURLWithPath: path)) { c.resume(returning: $0) }
        }
        return ["ok": ok, "path": path]
      case "print":
        try tab(a).webView.print()
        return true
      case "fullscreen-exit":
        try tab(a).webView.exitFullscreen()
        return true
      case "policy":
        if let v = a["contextMenu"] { window.contextMenuPolicy = v as? String }
        if let v = a["fullscreen"] { window.fullscreenPolicy = v as? String }
        if let v = a["dialogs"] { window.dialogPolicy = v as? String }
        if let v = a["permissions"] { window.permissionPolicy = v as? String }
        if let v = a["prompt"] { window.promptText = v as? String }
        return true
      case "dialog":
        return window.completePendingDialog(accept: a["accept"] as? Bool ?? true, text: a["text"] as? String)
      case "script-add":
        let script = UserScript(
          identifier: a["id"] as? String ?? UUID().uuidString,
          source: a["source"] as? String ?? "",
          kind: a["css"] as? Bool == true ? .styleSheet : .javaScript,
          injectionTime: a["end"] as? Bool == true ? .documentEnd : .documentStart,
          matchPatterns: a["matches"] as? [String] ?? ["<all_urls>"],
          mainFrameOnly: !(a["allFrames"] as? Bool ?? false))
        window.profile.addUserScript(script)
        return window.profile.userScripts.map(\.identifier)
      case "script-remove":
        window.profile.removeUserScript(identifier: a["id"] as? String ?? "")
        return window.profile.userScripts.map(\.identifier)
      case "filter":
        let patterns = a["block"] as? [String] ?? []
        blockCounter.reset()
        if patterns.isEmpty {
          window.profile.requestFilter = nil
        } else {
          let counter = blockCounter
          window.profile.requestFilter = { request in
            for p in patterns where request.urlString.contains(p) {
              counter.add(request.urlString)
              return .block
            }
            return .allow
          }
        }
        return true
      case "filter-stats":
        return blockCounter.snapshot()
      case "permission":
        let origin = try url(a, "origin")
        let kind = PermissionKind(rawValue: UInt32(a["kind"] as? Int ?? 0))
        if let state = a["state"] as? Int, let s = PermissionState(rawValue: state) {
          window.profile.setPermissionState(s, for: kind, origin: origin)
        }
        return window.profile.permissionState(for: kind, origin: origin).rawValue
      case "download-dir":
        window.downloadDirectory = URL(fileURLWithPath: a["path"] as? String ?? NSTemporaryDirectory())
        return true
      case "downloads":
        return window.profile.downloads.map {
          [
            "id": $0.identifier, "state": $0.state.rawValue, "received": $0.receivedBytes, "total": $0.totalBytes,
            "path": $0.destinationURL?.path ?? "", "url": $0.sourceURL.absoluteString,
          ] as [String: Any]
        }
      case "metrics":
        return await metrics(interval: a["interval"] as? Double ?? 1)
      case "timing":
        return await timing()
      case "quit":
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
        return true
      default:
        throw Failure(message: "unknown command \(cmd)")
      }
    }

    // MARK: Arguments

    private func tab(_ a: [String: Any], key: String = "tab") throws -> Tab {
      if let id = a[key] as? Int {
        guard let tab = window.tab(id: id) else { throw Failure(message: "no tab \(id)") }
        return tab
      }
      guard let active = window.activeTab else { throw Failure(message: "no active tab") }
      return active
    }

    private func url(_ a: [String: Any], _ key: String) throws -> URL {
      guard let s = a[key] as? String, let url = URL(string: s) else { throw Failure(message: "missing \(key)") }
      return url
    }

    private func style(_ a: [String: Any]) -> RuntimeStyle? {
      switch a["style"] as? String {
      case "chrome": return .chrome
      case "alloy": return .alloy
      default: return nil
      }
    }

    // MARK: Descriptions

    private func describe(_ tab: Tab) -> [String: Any] {
      let wv = tab.webView
      var d: [String: Any] = [
        "id": tab.id, "kind": tab.kind.rawValue, "browserId": wv.identifier, "live": wv.isLive,
        "url": wv.url?.absoluteString ?? "", "title": wv.title, "loading": wv.isLoading,
        "style": wv.runtimeStyle == .chrome ? "chrome" : "alloy", "audible": wv.isAudible, "muted": wv.isMuted,
        "crash": wv.crashState.rawValue, "fullscreen": wv.isFullscreen, "active": tab === window.activeTab,
        "favicon": wv.favicon != nil, "profile": wv.profile.identifier, "canGoBack": wv.canGoBack,
        "zoom": wv.zoomLevel, "popup": wv.isPopup,
      ]
      if let ext = tab.extensionID { d["extension"] = ext }
      return d
    }

    private func describe(_ e: Extension) -> [String: Any] {
      [
        "id": e.identifier, "name": e.name, "version": e.version, "enabled": e.isEnabled, "unpacked": e.isUnpacked,
        "manifestVersion": e.manifestVersion, "hasAction": e.hasAction, "actionTitle": e.actionTitle ?? "",
        "popup": e.actionPopupURL?.absoluteString ?? "", "options": e.optionsURL?.absoluteString ?? "",
        "icon": e.icon.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "", "badge": e.badgeText ?? NSNull(),
        "permissions": e.permissions, "hostPermissions": e.hostPermissions,
      ]
    }

    private func describe(_ w: NSWindow) -> [String: Any] {
      [
        "number": w.windowNumber, "title": w.title, "class": String(describing: type(of: w)),
        "visible": w.isVisible, "key": w.isKeyWindow, "frame": NSStringFromRect(w.frame),
        "parent": w.parent?.windowNumber ?? 0, "level": w.level.rawValue,
        "sheet": w.isSheet, "attachedSheet": w.attachedSheet?.windowNumber ?? 0,
      ]
    }

    // MARK: Helpers

    private func waitForLoad(_ tab: Tab, timeout: Double) async throws -> [String: Any] {
      let deadline = Date().addingTimeInterval(timeout)
      // Let a just-issued navigation start before polling.
      try await Task.sleep(for: .milliseconds(150))
      while Date() < deadline {
        let wv = tab.webView
        if wv.isLive && !wv.isLoading && wv.url != nil { return describe(tab) }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw Failure(message: "timeout waiting for load")
    }

    /// Clicks the element's center with DevTools Input events (real input
    /// inside the page, so the page sees a user gesture). Never touches the
    /// system mouse.
    private func click(_ tab: Tab, selector: String?, text: String?) async throws -> Any {
      // Find by CSS selector, or by visible text (case-insensitive regex) among
      // buttons and links, searching open shadow roots too.
      let js = """
        (() => {
          const sel = \(jsString(selector ?? "")), re = \(jsString(text ?? ""));
          const all = [];
          const walk = (root) => { for (const el of root.querySelectorAll('*')) { all.push(el); if (el.shadowRoot) walk(el.shadowRoot); } };
          walk(document);
          let e = sel ? document.querySelector(sel) : null;
          if (!e && re) { const rx = new RegExp(re, 'i');
            e = all.find(x => /^(BUTTON|A)$/.test(x.tagName) || x.getAttribute('role') === 'button'
                              ? rx.test((x.innerText || x.getAttribute('aria-label') || '').trim()) : false); }
          if (!e) return null; e.scrollIntoView({block:'center'});
          const r = e.getBoundingClientRect(); return [r.x + r.width/2, r.y + r.height/2]; })()
        """
      guard let point = try await tab.webView.evaluateJavaScript(js) as? [Double], point.count == 2 else {
        throw Failure(message: "no element for \(selector ?? text ?? "")")
      }
      for type in ["mousePressed", "mouseReleased"] {
        _ = try await tab.webView.sendDevToolsMethod(
          "Input.dispatchMouseEvent",
          parameters: ["type": type, "x": point[0], "y": point[1], "button": "left", "clickCount": 1])
      }
      return point
    }

    private func jsString(_ s: String) -> String {
      let data = try? JSONSerialization.data(withJSONObject: [s])
      let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
      return String(arr.dropFirst().dropLast())
    }

    /// Sends a key event to one of OUR windows (for example a Chromium dialog
    /// window). In-process only: it does not touch the system keyboard.
    private func sendKey(_ a: [String: Any]) throws -> Any {
      let number = a["window"] as? Int ?? NSApp.keyWindow?.windowNumber ?? 0
      guard let target = NSApp.windows.first(where: { $0.windowNumber == number }) else {
        throw Failure(message: "no window \(number)")
      }
      let keys: [String: (String, UInt16)] = [
        "return": ("\r", 36), "escape": ("\u{1b}", 53), "tab": ("\t", 48), "space": (" ", 49),
        "t": ("t", 17), "w": ("w", 13), "l": ("l", 37), "f": ("f", 3), "s": ("s", 1), "a": ("a", 0),
        "c": ("c", 8), "1": ("1", 18), "2": ("2", 19),
      ]
      guard let (chars, code) = keys[a["key"] as? String ?? "return"] else { throw Failure(message: "unknown key") }
      var mods: NSEvent.ModifierFlags = []
      for m in a["modifiers"] as? [String] ?? [] {
        switch m {
        case "cmd": mods.insert(.command)
        case "shift": mods.insert(.shift)
        case "opt": mods.insert(.option)
        case "ctrl": mods.insert(.control)
        default: break
        }
      }
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        guard
          let event = NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: number, context: nil, characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: code)
        else { continue }
        // Straight to the window (NSApp would drop it while another app is
        // active): the page's NSView gets it first, so app shortcuts must
        // come back through the engine's OnPreKeyEvent hook.
        target.sendEvent(event)
      }
      return ["firstResponder": target.firstResponder.map { String(describing: type(of: $0)) } ?? "none"]
    }

    private func snapshot(_ a: [String: Any]) async throws -> Any {
      let path = a["path"] as? String ?? NSTemporaryDirectory() + "open-snapshot.png"
      let url = URL(fileURLWithPath: path)
      if a["tab"] != nil {
        let png = try await tab(a).webView.takeSnapshot()
        try png.write(to: url)
        return ["path": path, "method": "devtools"]
      }
      let number = a["window"] as? Int
      guard
        let target = number.flatMap({ n in NSApp.windows.first { $0.windowNumber == n } }) ?? window.window
      else { throw Failure(message: "no window") }
      let method = try await WindowSnapshot.capture(target, controller: window, to: url)
      return ["path": path, "method": method]
    }

    private func metrics(interval: Double) async -> [String: Any] {
      let tasks = await Engine.shared.sampleProcessMetrics(after: interval)
      let footprints = ProcessFootprint.tree(root: getpid())
      return [
        "tasks": tasks.map {
          [
            "kind": $0.kind.rawValue, "title": $0.title, "memory": $0.memoryFootprint, "gpu": $0.gpuMemory,
            "cpu": $0.cpuUsage,
          ] as [String: Any]
        },
        "processes": footprints.map {
          ["pid": Int($0.pid), "name": $0.name, "footprint": $0.footprint, "rss": $0.rss] as [String: Any]
        },
        "totalFootprint": footprints.reduce(UInt64(0)) { $0 + $1.footprint },
        "totalRSS": footprints.reduce(UInt64(0)) { $0 + $1.rss },
        "liveTabs": window.allTabs.filter { $0.webView.isLive }.count,
      ]
    }

    private func timing() async -> [String: Any] {
      var out: [String: Any] = LaunchTiming.shared.report
      if let first = window.tabs.first {
        let js = "(() => { const p = performance.getEntriesByName('first-contentful-paint')[0]; return p ? performance.timeOrigin + p.startTime : null; })()"
        if let fcpEpochMs = try? await first.webView.evaluateJavaScript(js) as? Double {
          let start = LaunchTiming.shared.processStart.timeIntervalSince1970 * 1000
          out["firstContentfulPaint"] = (fcpEpochMs - start).rounded()
        }
      }
      return out
    }
  }

  /// Counts blocked requests. Touched from Chromium's network thread.
  final class BlockCounter: Sendable {
    private let state = Mutex<(count: Int, recent: [String])>((0, []))

    func add(_ url: String) {
      state.withLock {
        $0.count += 1
        $0.recent.append(url)
        if $0.recent.count > 50 { $0.recent.removeFirst() }
      }
    }

    func reset() { state.withLock { $0 = (0, []) } }

    func snapshot() -> [String: Any] {
      state.withLock { ["blocked": $0.count, "recent": $0.recent] }
    }
  }

  /// Physical footprint (what Activity Monitor shows) of a process and its
  /// direct children (Chromium launches every helper from the browser process).
  enum ProcessFootprint {
    struct Sample {
      let pid: pid_t
      let name: String
      let footprint: UInt64
      let rss: UInt64
    }

    static func tree(root: pid_t) -> [Sample] {
      var pids = [root]
      let count = proc_listchildpids(root, nil, 0)
      if count > 0 {
        var children = [pid_t](repeating: 0, count: Int(count) * 2)
        let n = proc_listchildpids(root, &children, Int32(children.count * MemoryLayout<pid_t>.size))
        pids += children.prefix(Int(n))
      }
      return pids.compactMap(sample)
    }

    static func sample(_ pid: pid_t) -> Sample? {
      var info = rusage_info_v4()
      let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
          proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
      }
      guard ok == 0 else { return nil }
      var name = [CChar](repeating: 0, count: 1024)
      proc_name(pid, &name, UInt32(name.count))
      var task = proc_taskinfo()
      proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size))
      return Sample(
        pid: pid, name: String(cString: name), footprint: info.ri_phys_footprint, rss: task.pti_resident_size)
    }
  }
#endif
