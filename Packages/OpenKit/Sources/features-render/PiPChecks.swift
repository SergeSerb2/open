import AppKit
import OpenDesign
import OpenFeatures
import OpenMedia
import OpenWeb

/// Complete native PiP windows; only the engine video host is fake (plan §8.3).
@MainActor enum PiPChecks {
    static func run(_ check: @MainActor (Bool, String) -> Void) async throws {
        let rules = try PiPSiteRules.bundled()
        var fixtures: [PictureInPictureWindowController] = []
        var pasteboards: [ObjectIdentifier: NSPasteboard] = [:]
        defer { fixtures.forEach { $0.dismiss(reason: .sourceGone) }; pasteboards.values.forEach { $0.releaseGlobally() } }
        func make(_ size: CGSize = CGSize(width: 384, height: 216), url: URL? = URL(string: "https://www.example.test/video"), natural: CGSize? = nil) throws -> (PictureInPictureWindowController, FakePiPHost, MediaSettings) {
            let host = FakePiPHost(); host.naturalSize = natural ?? size
            let settings = MediaSettings(defaults: FeatureCLI.defaults()), board = NSPasteboard.withUniqueName()
            guard let controller = PictureInPictureWindowController(host: host, sourceURL: url, settings: settings, rules: rules,
                screenVisibleFrame: PiPScene.screen, pasteboard: board) else { throw CLIError(description: "PiP fixture creation failed") }
            controller.presentWindows = false; controller.resize(to: size); fixtures.append(controller); pasteboards[ObjectIdentifier(controller)] = board
            OffscreenRenderer.settle(controller.contentView, runLoop: 0.01)
            return (controller, host, settings)
        }
        func pump(_ root: NSView, _ seconds: Double = 0.05) { OffscreenRenderer.settle(root, runLoop: seconds / 3) }
        func click(_ view: NSView, window: NSWindow, label: String) {
            let point = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            let down = PiPScene.event(.leftMouseDown, in: view, at: point)
            check(window.contentView?.hitTest(down.locationInWindow) === view, "PP native hit test: \(label)")
            window.sendEvent(down); window.sendEvent(PiPScene.event(.leftMouseUp, in: view, at: point))
        }
        func nativeAction(_ title: String, in menu: NSMenu) {
            guard let index = menu.items.firstIndex(where: { $0.title == title }) else { check(false, "PP menu item exists: \(title)"); return }
            menu.performActionForItem(at: index)
        }
        // Must precede every in-process fixture that resizes PiP: those seed static lastFrame.
        // The six-screen first-open matrix below uses fresh CLI processes for the same reason.
        let firstPortraitHost = FakePiPHost(); firstPortraitHost.naturalSize = CGSize(width: 900, height: 1600)
        guard let firstPortrait = PictureInPictureWindowController(host: firstPortraitHost, sourceURL: nil, settings: MediaSettings(defaults: FeatureCLI.defaults()), rules: rules, screenVisibleFrame: PiPScene.screen) else { throw CLIError(description: "first portrait failed") }
        firstPortrait.presentWindows = false; fixtures.append(firstPortrait)
        let initialPortrait = firstPortrait.window!.frame
        check(abs(initialPortrait.width - 160) <= 1 && abs(initialPortrait.height - 160 * 16 / 9) <= 1,
              "PP6 first-open portrait before any resize uses relaxed fit: \(initialPortrait)")
        let matrixRoot = FileManager.default.temporaryDirectory.appendingPathComponent("open-pip-screens-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: matrixRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: matrixRoot) }
        // Portrait minimum/first size stays about 160x284. Landscape fit grows above
        // its 284x160 minimum at 1440 pt; this includes the observed 2560x1440 case.
        let screens: [(Int, Int, [Double])] = [(1600, 900, [284, 160]), (1796, 1010, [284, 160]),
            (1920, 1080, [284, 160]), (2560, 1440, [320, 180]), (2844, 1600, [355.5, 199.96875]), (3840, 2160, [480, 270])]
        for (width, height, landscapeFirst) in screens {
            for orientation in ["portrait", "landscape"] {
                let reportURL = matrixRoot.appendingPathComponent("\(orientation)-\(height).json")
                let process = Process(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                process.arguments = ["pip", "--out", matrixRoot.appendingPathComponent("\(orientation)-\(height).png").path,
                    "--screen", "\(width)x\(height)", "--natural-size", orientation == "portrait" ? "900x1600" : "1600x900",
                    "--first-open", "--geometry-report", reportURL.path]
                process.standardOutput = output; process.standardError = output
                try process.run()
                let receipt = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw CLIError(description: "PP6 native geometry CLI failed: " + String(decoding: receipt, as: UTF8.self)) }
                let report = try JSONDecoder().decode([String: [Double]].self, from: Data(contentsOf: reportURL))
                let first = report["firstSize"] ?? [], minimum = report["minimumSize"] ?? [], insets = report["insets"] ?? []
                let expectedFirst = orientation == "portrait" ? [160.0, 284.0] : landscapeFirst
                let expectedMinimum = orientation == "portrait" ? [160.0, 284.0] : [284.0, 160.0]
                check(first.count == 2 && zip(first, expectedFirst).allSatisfy { abs($0 - $1) <= 1 },
                      "PP6 first \(orientation) on \(width)x\(height): \(first)")
                check(minimum.count == 2 && zip(minimum, expectedMinimum).allSatisfy { abs($0 - $1) <= 1 },
                      "PP6 \(orientation) minimum on \(width)x\(height): \(minimum)")
                check(insets.count == 2 && insets.allSatisfy { abs($0 - 10) < 0.01 },
                      "PP6 \(orientation) bottom-right insets on \(width)x\(height): \(insets)")
            }
        }
        // Capture session 2 item 13's display: frame 2560x1440, visible frame 2560x1410 (30 pt menu bar, Dock hidden).
        // Arc opened 320x180 there, 10 pt from the visible frame's right and bottom; the /8 box is the whole screen.
        do {
            let reportURL = matrixRoot.appendingPathComponent("capture-display.json")
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["pip", "--out", matrixRoot.appendingPathComponent("capture-display.png").path, "--screen", "2560x1410",
                "--screen-frame", "2560x1440", "--natural-size", "1280x720", "--first-open", "--geometry-report", reportURL.path]
            process.standardOutput = output; process.standardError = output
            try process.run()
            let receipt = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CLIError(description: "PP6 capture-display CLI failed: " + String(decoding: receipt, as: UTF8.self)) }
            let report = try JSONDecoder().decode([String: [Double]].self, from: Data(contentsOf: reportURL))
            let first = report["firstSize"] ?? [], insets = report["insets"] ?? []
            check(first == [320, 180] && insets.count == 2 && insets.allSatisfy { abs($0 - 10) < 0.01 },
                  "PP6 capture display 2560x1440 (visible 2560x1410) opens 320x180 at 10 pt insets: \(first) \(insets)")
        }
        let (regular, host, settings) = try make()
        let (compact, _, _) = try make(CGSize(width: 284, height: 160))
        for (controller, p) in [(regular, CGFloat(10)), (compact, CGFloat(8))] {
            let overlay = controller.overlay, width = controller.contentView.bounds.width
            check(overlay.control(named: "close")?.view.frame == CGRect(x: p, y: p, width: 28, height: 28) &&
                  overlay.control(named: "minimize")?.view.frame == CGRect(x: p + 32, y: p, width: 28, height: 28) &&
                  overlay.control(named: "settings")?.view.frame == CGRect(x: width - p - 28, y: p, width: 28, height: 28), "PP1 corner frames at width \(width)")
        }
        check(compact.overlay.isCompact && compact.overlay.control(named: "play")?.pointSize == 24 && regular.overlay.control(named: "play")?.pointSize == 28,
              "PP1 compact/regular play glyphs use 24/28 pt")
        check(["play", "back", "forward", "previous", "next"].allSatisfy { id in
            guard let view = regular.overlay.control(named: id)?.view, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.01 && c.redComponent < 0.1 && c.greenComponent < 0.1 && c.blueComponent < 0.1 { return true }
            } }
            return false
        }, "PP five center glyphs cache their soft black shadow")
        let (twitch, _, _) = try make(url: URL(string: "https://www.twitch.tv/channel"))
        check(twitch.overlay.control(named: "play")?.view.isHidden == true && twitch.overlay.control(named: "back")?.view.isHidden == true &&
              twitch.overlay.control(named: "forward")?.view.isHidden == true && twitch.overlay.scrubber.isHidden, "PP2 Twitch hides play, skip and scrubber")
        let (meet, _, _) = try make(url: URL(string: "https://meet.google.com/example"))
        check(meet.overlay.control(named: "close")?.view.isHidden == true && meet.overlay.control(named: "minimize")?.view.frame.origin == CGPoint(x: 10, y: 10), "PP2 Meet hides Close and moves Minimize into its slot")
        check(regular.overlay.control(named: "back")?.pointSize == 20 && compact.overlay.control(named: "back")?.pointSize == 16 && Glyph.pipSkipBack.spec.symbol == "gobackward.15" && Glyph.pipSkipForward.spec.symbol == "goforward.15", "PP SF skip glyphs use 20 pt regular and 16 pt compact")
        check(regular.overlay.control(named: "tab")?.view.frame.midY == 176 && regular.overlay.control(named: "mute")?.view.frame.midY == 176, "PP bottom controls share one center line")
        check(twitch.overlay.control(named: "previous")?.view.frame.midX == 192 - 24 && twitch.overlay.control(named: "next")?.view.frame.midX == 192 + 24 && twitch.overlay.control(named: "mute")?.view.frame.midY == 192, "PP Twitch packs tracks and removes the hidden scrubber offset")
        let (narrow, _, _) = try make(CGSize(width: 160, height: 284))
        check(narrow.overlay.control(named: "back")?.view.isHidden == true && narrow.overlay.control(named: "forward")?.view.isHidden == true, "PP skip buttons hide below 168 pt")
        let (boundary, _, _) = try make(CGSize(width: 168, height: 299))
        check(boundary.overlay.control(named: "back")?.view.isHidden == false && boundary.overlay.control(named: "forward")?.view.isHidden == false, "PP skip buttons remain visible at the 168 pt boundary")
        check(regular.overlay.control(named: "settings")?.title == "Options", "PP ellipsis tooltip and AX copy say Options")
        let (meeting, meetingHost, _) = try make(CGSize(width: 284, height: 160))
        meetingHost.mediaState.actions = [.toggleMicrophone, .toggleCamera, .hangUp]; meetingHost.mediaState.microphoneMuted = false; meetingHost.mediaState.cameraOn = true
        meeting.refresh(); pump(meeting.contentView)
        let utility = ["tab", "mute"].compactMap { meeting.overlay.control(named: $0)?.view.frame }
        check(["microphone", "camera", "hangup"].compactMap { meeting.overlay.control(named: $0)?.view.frame }.allSatisfy { frame in !utility.contains { $0.intersects(frame) } },
              "PP compact meeting row does not overlap Back to Tab or Mute")
        guard let panel = regular.window else { throw CLIError(description: "PiP fixture has no window") }
        panel.orderBack(nil); pump(regular.contentView, 0.4)
        check(panel.isVisible && panel.frame.maxX < 0, "PP panel stays offscreen")
        regular.overlay.setControlsVisible(false, animated: false)
        regular.overlay.mouseMoved(with: PiPScene.event(.mouseMoved, in: regular.overlay, at: CGPoint(x: 90, y: 70)))
        pump(regular.contentView, 0.02)
        let controlsLayer = regular.overlay.control(named: "play")?.view.superview?.layer
        check(regular.overlay.controlsVisible && controlsLayer?.opacity == 1 && controlsLayer?.animation(forKey: "pip.controls") != nil,
              "PP3 pointer movement starts the real control fade")
        try await Task.sleep(for: .seconds(2.05)); pump(regular.contentView)
        check(!regular.overlay.controlsVisible && controlsLayer?.opacity == 0, "PP3 actual 2 s work hides controls")
        try await Task.sleep(for: .seconds(0.35)); pump(regular.contentView)
        check(controlsLayer?.animationKeys()?.isEmpty != false, "PP3 fade leaves no animation keys")
        check(!regular.overlay.scrubber.hasDisplayLink && !regular.overlay.hasScheduledHide,
              "PP idle hidden controls have no display link or pending hide work")
        func cpuSeconds() -> Double {
            var time = timespec(); clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time)
            return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
        }
        let cpuStart = cpuSeconds(), wallStart = CACurrentMediaTime()
        try await Task.sleep(for: .seconds(2))
        let idleCPU = 100 * (cpuSeconds() - cpuStart) / (CACurrentMediaTime() - wallStart)
        check(idleCPU <= 0.5, String(format: "PP idle offscreen window CPU %.3f%% (budget 0.5%%)", idleCPU))
        let heldMenu = regular.overlay.makeMenu()
        heldMenu.delegate?.menuWillOpen?(heldMenu)
        regular.overlay.mouseExited(with: PiPScene.event(.mouseMoved, in: regular.overlay, at: .zero)); try await Task.sleep(for: .seconds(2.2)); pump(regular.contentView)
        check(regular.overlay.menuIsTracking && regular.overlay.controlsVisible && !regular.overlay.hasScheduledHide && controlsLayer?.opacity == 1,
              "PP3 real menu delegate tracking keeps controls visible")
        heldMenu.delegate?.menuDidClose?(heldMenu); try await Task.sleep(for: .seconds(0.35)); pump(regular.contentView)
        check(!regular.overlay.menuIsTracking && !regular.overlay.controlsVisible, "PP3 menu close after pointer exit fades controls")
        regular.overlay.setControlsVisible(true, animated: false); host.mediaState.duration = 120; host.currentTime = 12; host.positionUpdatedAt = Date(); regular.refresh(); pump(regular.contentView)
        let scrubber = regular.overlay.scrubber, start = CGPoint(x: scrubber.bounds.width / 4, y: scrubber.bounds.midY)
        panel.sendEvent(PiPScene.event(.leftMouseDown, in: scrubber, at: start))
        check(host.calls.contains(where: { if case .seek(let value) = $0 { return abs(value - 30) < 0.001 }; return false }) && host.mediaState.playback == .playing,
              "PP4 mouse-down jumps without pausing before any drag")
        let drag = CGPoint(x: start.x + scrubber.bounds.width * 0.3, y: start.y - 80)
        host.mediaState.actions.insert(.skipAd); regular.refresh()
        panel.sendEvent(PiPScene.event(.leftMouseDragged, in: scrubber, at: drag)); pump(regular.contentView, 0.02)
        scrubber.mouseExited(with: PiPScene.event(.mouseMoved, in: scrubber, at: drag))
        check(scrubber.barHeight == 6 && host.mediaState.playback == .paused && ["tab", "mute", "ad"].allSatisfy { id in regular.overlay.control(named: id)?.view.layer?.opacity == 0 && regular.overlay.control(named: id)?.view.layer?.animation(forKey: "pip.scrubUtility")?.duration == 0.15 }, "PP4 drag keeps the 6 pt bar and fades all utility controls in 0.15 s")
        if let fadedMute = regular.overlay.control(named: "mute")?.view {
            let beforeFadedClick = host.calls.count
            let location = CGPoint(x: fadedMute.bounds.midX, y: fadedMute.bounds.midY)
            let down = PiPScene.event(.leftMouseDown, in: fadedMute, at: location)
            check(panel.contentView?.hitTest(down.locationInWindow) !== fadedMute, "PP mid-drag faded utility rejects hit testing")
            // A second window-level mouse-down would replace AppKit's active drag capture.
            // Hit testing above proves routing; exercise the guarded input handlers directly.
            fadedMute.mouseDown(with: down); fadedMute.mouseUp(with: PiPScene.event(.leftMouseUp, in: fadedMute, at: location))
            check(host.calls.count == beforeFadedClick && !host.mediaMuted && scrubber.isDragging, "PP click on faded Mute does nothing mid-drag")
        }
        let precisionLabel = descendants(regular.overlay).compactMap { $0 as? NSTextField }.first { $0.stringValue == scrubber.precisionText }
        check(precisionLabel?.layer?.opacity == 1 && precisionLabel?.layer?.animation(forKey: "pip.precision")?.duration == 0.15, "PP precision hint fades in with the utility transition")
        check(precisionLabel?.lineBreakMode == .byTruncatingTail && precisionLabel?.frame.width == regular.overlay.bounds.width - 20, "PP4 precision label truncates within the horizontal padding")
        check(scrubber.precisionText == "Seeking at 3× precision" && host.calls.contains(where: { if case .scrub(let value) = $0 { return abs(value - 42) < 0.001 }; return false }),
              "PP4 click-to-jump then 80 pt up drag scrubs at 3× precision")
        panel.sendEvent(PiPScene.event(.leftMouseUp, in: scrubber, at: drag)); pump(regular.contentView)
        check(host.calls.contains(where: { if case .seek(let value) = $0 { return abs(value - 42) < 0.001 }; return false }) && host.mediaState.playback == .playing,
              "PP4 release seeks and resumes playback")
        let flatStart = CGPoint(x: scrubber.bounds.width / 2, y: scrubber.bounds.midY)
        panel.sendEvent(PiPScene.event(.leftMouseDown, in: scrubber, at: flatStart))
        panel.sendEvent(PiPScene.event(.leftMouseDragged, in: scrubber, at: CGPoint(x: flatStart.x + 20, y: flatStart.y)))
        check(scrubber.precisionText == "Drag upwards to seek precisely", "PP4 flat drag shows the neutral hint")
        panel.sendEvent(PiPScene.event(.leftMouseUp, in: scrubber, at: flatStart))
        let beforeClick = host.calls.count
        panel.sendEvent(PiPScene.event(.leftMouseDown, in: scrubber, at: flatStart))
        panel.sendEvent(PiPScene.event(.leftMouseUp, in: scrubber, at: flatStart))
        check(Array(host.calls.dropFirst(beforeClick)) == [.seek(60)] && host.mediaState.playback == .playing && !scrubber.isDragging, "PP4 a plain click seeks once without pause/resume")
        check(["tab", "mute", "ad"].allSatisfy { regular.overlay.control(named: $0)?.view.layer?.opacity == 1 }, "PP4 mouse-up restores the utility controls")
        if let play = regular.overlay.control(named: "play")?.view {
            play.setAccessibilityFocused(true)
            check(!regular.overlay.hasScheduledHide, "PP accessibility focus holds controls")
            panel.resignKey(); pump(regular.contentView, 0.02)
            check(!panel.isKeyWindow && regular.overlay.hasScheduledHide, "PP resign-key clears keyboard and accessibility focus holds")
        }
        host.endOfMedia = true; regular.refresh()
        check(regular.overlay.control(named: "forward")?.view.isAccessibilityEnabled() == false && regular.overlay.control(named: "forward")?.view.alphaValue == 0.4 && regular.overlay.control(named: "next")?.view.isAccessibilityEnabled() == true, "PP ended disables Skip ahead at 0.4 opacity while offered Next stays enabled")
        if let forward = regular.overlay.control(named: "forward")?.view {
            forward.mouseEntered(with: PiPScene.event(.mouseMoved, in: forward, at: CGPoint(x: forward.bounds.midX, y: forward.bounds.midY)))
            pump(regular.contentView)
            check(forward.layer?.affineTransform() == .identity && forward.layer?.animation(forKey: "pip.hover") == nil, "PP disabled Skip ahead does not grow on hover")
            if let bitmap = forward.bitmapImageRepForCachingDisplay(in: forward.bounds) {
                forward.cacheDisplay(in: forward.bounds, to: bitmap)
                check((bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 2)?.alphaComponent ?? 1) < 0.03, "PP disabled Skip ahead draws no hover plate")
            } else { check(false, "PP disabled hover bitmap exists") }
            check(forward.accessibilityHelp() == "Skip ahead 15 seconds", "PP disabled Skip ahead retains its tooltip copy")
            forward.mouseExited(with: PiPScene.event(.mouseMoved, in: forward, at: .zero))
        }
        host.endOfMedia = false
        host.mediaState.playback = .paused; regular.refresh()
        check(!scrubber.hasDisplayLink, "PP paused playback stops the display link")
        panel.orderOut(nil); pump(regular.contentView)
        check(!scrubber.hasDisplayLink && !regular.overlay.hasScheduledHide, "PP ordered-out window has no display link or hide work")
        let menu = regular.overlay.makeMenu()
        print("NATIVE MENU regular\n" + PiPScene.menuDump(menu) + "END NATIVE MENU")
        check(menu.items.map(\.title) == ["Keep Window on Top", "", "Picture-in-picture on www.example.test:", "Open automatically", "Turn off", "", "Copy URL", "Mute"] &&
              menu.items[1].isSeparatorItem && menu.items[5].isSeparatorItem && !menu.items[2].isEnabled && menu.items.allSatisfy { $0.keyEquivalent.isEmpty }, "PP5 exact native menu order, header, separators and no keys")
        nativeAction("Turn off", in: menu)
        let disabled = regular.overlay.makeMenu()
        print("NATIVE MENU disabled\n" + PiPScene.menuDump(disabled) + "END NATIVE MENU")
        check(disabled.items[4].state == .on && disabled.items[3].state == .off && settings.isAutoDisabled(host: "sub.example.test"), "PP5 native Turn off updates the shared site state")
        nativeAction("Open automatically", in: disabled)
        check(regular.overlay.makeMenu().items[3].state == .on && !settings.isAutoDisabled(host: "example.test"), "PP5 Open automatically restores the radio state")
        nativeAction("Keep Window on Top", in: regular.overlay.makeMenu())
        check(panel.level == .normal && !settings.keepOnTop, "PP5 Keep Window on Top updates the actual panel level")
        nativeAction("Mute", in: regular.overlay.makeMenu())
        check(host.calls.contains(.muted(true)) && regular.overlay.makeMenu().items.last?.title == "Unmute", "PP5 native Mute reaches the host")
        nativeAction("Copy URL", in: regular.overlay.makeMenu())
        check(pasteboards[ObjectIdentifier(regular)]?.string(forType: .string) == "https://www.example.test/video", "PP5 Copy URL uses the panel's real named pasteboard")
        let (hostless, _, _) = try make(url: URL(string: "about:blank"))
        print("NATIVE MENU hostless\n" + PiPScene.menuDump(hostless.overlay.makeMenu()) + "END NATIVE MENU")
        check(hostless.overlay.makeMenu().items.map(\.title) == ["Keep Window on Top", "", "Mute"], "PP5 host-less menu has items 1, 2 and 4 only")
        let privateDefaults = FeatureCLI.defaults(), privateSettings = MediaSettings(defaults: privateDefaults), privateSession = MediaSettings.PrivateHosts()
        let before = privateDefaults.dictionaryRepresentation() as NSDictionary
        let privateHost = FakePiPHost()
        guard let privateController = PictureInPictureWindowController(host: privateHost, sourceURL: URL(string: "https://www.private.example.test/"), settings: privateSettings, rules: rules, privateSession: privateSession, screenVisibleFrame: PiPScene.screen) else { throw CLIError(description: "private PiP fixture creation failed") }
        privateController.presentWindows = false; fixtures.append(privateController)
        nativeAction("Turn off", in: privateController.overlay.makeMenu())
        print("NATIVE MENU private-disabled\n" + PiPScene.menuDump(privateController.overlay.makeMenu()) + "END NATIVE MENU")
        check(privateSession.disabled == ["private.example.test"] && before.isEqual(to: privateDefaults.dictionaryRepresentation()), "PP5 private Turn off writes only its in-memory session")
        regular.resize(to: CGSize(width: 384, height: 216))
        let reusedHost = FakePiPHost(); reusedHost.naturalSize = CGSize(width: 900, height: 1600)
        guard let reused = PictureInPictureWindowController(host: reusedHost, sourceURL: nil, settings: MediaSettings(defaults: FeatureCLI.defaults()), rules: rules, screenVisibleFrame: PiPScene.screen) else { throw CLIError(description: "reused portrait failed") }
        reused.presentWindows = false; fixtures.append(reused)
        check(abs(reused.window!.frame.width - 216) <= 1 && abs(reused.window!.frame.height - 384) <= 1, "PP6 later portrait reuses the landscape long side")
        regular.resize(to: CGSize(width: 10, height: 10)); pump(regular.contentView)
        check(panel.frame.width >= 284 && panel.frame.height >= 160 && abs(panel.frame.width / panel.frame.height - 16 / 9) < 0.01, "PP6 minimum landscape size preserves aspect")
        let (portrait, _, _) = try make(CGSize(width: 900, height: 900), natural: CGSize(width: 900, height: 1600))
        let portraitFrame = portrait.window!.frame
        check(abs(portraitFrame.width - 253.125) <= 1 && abs(portraitFrame.height - 450) <= 1 && portrait.overlay.isCompact &&
              portraitFrame.width <= PiPScene.screen.width / 2 && portraitFrame.height <= PiPScene.screen.height / 2 &&
              portrait.window!.contentAspectRatio == CGSize(width: 900, height: 1600),
              "PP6 9:16 on 900 pt screen caps at about 253x450 with compact controls: frame=\(portraitFrame), overlay=\(portrait.overlay.bounds), max=\(portrait.window!.contentMaxSize)")
        portrait.resize(to: CGSize(width: 1, height: 1)); pump(portrait.contentView)
        check(portrait.window!.frame.width >= 160 && portrait.window!.frame.height <= 450 && abs(portrait.window!.frame.width / portrait.window!.frame.height - 9 / 16) < 0.01,
              "PP6 portrait relaxed short-side minimum stays within maximum")
        let (square, _, _) = try make(CGSize(width: 900, height: 900), natural: CGSize(width: 100, height: 100))
        check(square.window!.frame.size == CGSize(width: 450, height: 450), "PP6 1:1 on 900 pt screen caps at 450x450")
        square.resize(to: CGSize(width: 1, height: 1)); pump(square.contentView)
        check(square.window!.frame.size == CGSize(width: 284, height: 284) && square.overlay.isCompact, "PP6 square preserves aspect at its minimum")
        square.resize(to: CGSize(width: 450, height: 450))
        let squareImage = OffscreenRenderer().render(square.contentView, scale: 2), squarePixels: NSBitmapImageRep
        squarePixels = NSBitmapImageRep(cgImage: squareImage)
        check(stride(from: 40, to: 860, by: 80).allSatisfy { y in stride(from: 40, to: 860, by: 80).allSatisfy { x in (squarePixels.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.99 } }, "PP fake square video stays opaque above the 2x tiling threshold")
        let sourcePanel = NSPanel(contentRect: CGRect(x: -22000, y: -22000, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        sourcePanel.isReleasedWhenClosed = false; defer { sourcePanel.close() }
        func animatedFixture() throws -> (PictureInPictureWindowController, FakePiPHost) {
            let h = FakePiPHost()
            guard let c = PictureInPictureWindowController(host: h, sourceURL: nil, settings: MediaSettings(defaults: FeatureCLI.defaults()), rules: rules, sourceWindow: sourcePanel, screenVisibleFrame: PiPScene.screen) else { throw CLIError(description: "animated fixture failed") }
            c.reduceMotionOverride = false; c.resize(to: CGSize(width: 384, height: 216)); fixtures.append(c)
            return (c, h)
        }
        let (animated, animatedHost) = try animatedFixture()
        let targetFrame = animated.window!.frame
        var closedCount = 0, returnedCount = 0
        animated.onClosed = { _ in closedCount += 1 }; animated.onBackToTab = { returnedCount += 1 }
        animated.present(); try await Task.sleep(for: .seconds(1)); pump(animated.contentView)
        check(animated.window!.frame == targetFrame && animated.window!.alphaValue == 1 && animatedHost.windowVisible && targetFrame.maxX < 0, "PP presentWindows=true finishes its real offscreen spring at target frame and alpha 1")
        animated.dismiss(reason: .backToTab); try await Task.sleep(for: .seconds(0.6)); pump(animated.contentView)
        check(returnedCount == 1 && closedCount == 1 && animatedHost.calls == [.close(false)] && animated.window?.isVisible == false && !animatedHost.windowVisible, "PP Back to Tab animated completion closes exactly once")
        let (interrupted, interruptedHost) = try animatedFixture()
        var interruptedCount = 0; interrupted.onClosed = { _ in interruptedCount += 1 }
        interrupted.present(); try await Task.sleep(for: .milliseconds(20)); interrupted.dismiss(reason: .userClosed)
        try await Task.sleep(for: .seconds(1)); pump(interrupted.contentView)
        check(interruptedCount == 1 && interruptedHost.calls == [.close(true)] && interrupted.window?.isVisible == false && !interruptedHost.windowVisible, "PP close during presentation reaches a clean completed end state")
        for (id, reason, pause) in [("tab", PiPSession.Reason.backToTab, false), ("minimize", .minimized, false), ("close", .userClosed, true)] {
            let (controller, actionHost, _) = try make(); controller.window?.orderBack(nil); pump(controller.contentView)
            var returned = false, closed: PiPSession.Reason?
            controller.onBackToTab = { returned = true }; controller.onClosed = { closed = $0 }
            if let button = controller.overlay.control(named: id)?.view, let window = controller.window { click(button, window: window, label: id) }
            check(actionHost.calls.last == .close(pause) && closed == reason && controller.window?.isVisible == false && (!pause || actionHost.mediaState.playback == .paused) && (id != "tab" || returned),
                  "PP7 \(id) sends exactly the intended close/pause effect")
        }
        let documentHost = FakePiPHost()
        guard let document = DocumentPiPWindowController(host: documentHost, sourceURL: URL(string: "https://meeting.example.test/"), requestedSize: CGSize(width: 400, height: 300), settings: MediaSettings(defaults: FeatureCLI.defaults()), screenVisibleFrame: PiPScene.screen) else { throw CLIError(description: "Document PiP fixture creation failed") }
        defer { document.close() }
        document.presentWindows = false; pump(document.contentView)
        check(document.topBar.frame.height == 28 && document.window?.frame.height == 328 && document.topBar.layer?.backgroundColor == PiPRole.documentTopBar.cgColor(.dark), "PP8 Document PiP has its 28 pt #212123 top bar")
        check(document.topBar.layer?.sublayers?.contains(where: { $0.backgroundColor == PiPRole.documentHairline.cgColor(.dark) && abs($0.frame.height - 1 / (document.window?.backingScaleFactor ?? 1)) < 0.01 }) == true,
              "PP8 Document PiP uses the white 20% one-pixel hairline")
        print("NATIVE MENU document\n" + PiPScene.menuDump(document.makeMenu()) + "END NATIVE MENU")
        check(document.makeMenu().items.map(\.title) == ["Keep Window on Top", "", "Picture-in-picture on meeting.example.test:"], "PP8 native Document PiP menu has Keep on Top and host header")
        document.window?.orderBack(nil); pump(document.contentView)
        if let options = descendants(document.topBar).first(where: { $0.accessibilityIdentifier() == "pip.document.settings" }), let window = document.window {
            options.mouseEntered(with: PiPScene.event(.mouseMoved, in: options, at: CGPoint(x: 10, y: 10)))
            window.sendEvent(PiPScene.event(.leftMouseDown, in: options, at: CGPoint(x: 10, y: 10)))
            if let bitmap = options.bitmapImageRepForCachingDisplay(in: options.bounds) {
                options.cacheDisplay(in: options.bounds, to: bitmap)
                check(abs((bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 2)?.alphaComponent ?? 0) - 0.18) < 0.03, "PP Document Options pressed plate is white 0.18")
            } else { check(false, "PP Document pressed bitmap exists") }
        }
        if let close = descendants(document.topBar).first(where: { $0.accessibilityIdentifier() == "pip.document.close" }), let window = document.window { click(close, window: window, label: "Document close") }
        check(documentHost.calls == [.close(false)], "PP8 Document close returns the child without pausing")
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
