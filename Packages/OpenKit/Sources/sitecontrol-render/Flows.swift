import AppKit
import OpenSiteControl

@MainActor
enum Flows {
    struct Check { let name: String; let pass: Bool }
    static func run() -> [Check] {
        var checks: [Check] = []
        let stage = Stage()
        let c = stage.controller, s = stage.source
        checks.append(Check(name: "F1 anchor presents", pass: c.isPresented))
        stage.click(CGPoint(x: 201, y: 64))
        checks.append(Check(name: "F1 second anchor click closes and is consumed", pass: !c.isPresented && stage.root.hits == 0 && s.calls.isEmpty))
        c.toggle(anchor: .urlField, tabID: s.tabID, animated: false)
        var reason: SiteControlDismissReason?
        c.onDismiss = { reason = $0 }
        stage.key(code: 53, characters: "\u{1b}")
        checks.append(Check(name: "F2 Escape closes and restores focus", pass: !c.isPresented && reason == .escape && stage.window.firstResponder === stage.root))
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
        checks.append(Check(name: "Step 1 More is disabled", pass: c.view.panel.controls.last?.isEnabled == false))
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
            let security = securityStage.controller.view.panel.controls.first { $0.controlID == "security" }!
            checks.append(Check(name: "security label policy for \(scheme)",pass: security.isHidden == !["https","http"].contains(scheme) && (security.isHidden || security.title == (scheme == "https" ? "Secure" : "Insecure"))))
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
        return checks
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
