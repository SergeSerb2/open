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
        let pairs = [("AXPopover", "Site Control Center"), ("AXStaticText", "news.example.com"),
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
