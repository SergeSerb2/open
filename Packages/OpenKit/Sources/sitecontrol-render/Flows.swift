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
        checks.append(Check(name: "F2 Escape closes and restores focus", pass: !c.isPresented && reason == .escape))
        c.toggle(anchor: .urlField, tabID: s.tabID, animated: false)
        stage.click(CGPoint(x: 800, y: 600))
        checks.append(Check(name: "F2 outside click closes and reaches page", pass: !c.isPresented && reason == .outside && stage.root.hits == 1))
        c.present(anchor: .urlField, tabID: s.tabID, animated: false)
        let dump = accessibilityDump(c.view.panel)
        checks.append(Check(name: "F21 panel, host, six actions and footer are labelled", pass:
            ["Site Control Center", "news.example.com", "Share", "Copy URL", "New Boost", "Capture a portion of this page", "Capture the full page", "Capture in Portrait Mode", "Connection: Secure", "More"].allSatisfy(dump.contains)))
        c.dismiss(reason: .action, animated: false)
        s.value = nil
        var errors = 0
        c.onUnavailable = { _ in errors += 1 }
        c.present(anchor: .urlField, tabID: s.tabID, animated: false)
        c.present(anchor: .urlField, tabID: s.tabID, animated: false)
        checks.append(Check(name: "F22 missing snapshot stays closed and logs once", pass: !c.isPresented && errors == 1 && s.calls.isEmpty))
        return checks
    }
    static func accessibilityDump(_ view: NSView, indent: String = "") -> String {
        let role = view.accessibilityRole()?.rawValue ?? "view"
        let label = view.accessibilityLabel() ?? (view as? NSTextField)?.stringValue ?? ""
        let help = view.accessibilityHelp() ?? ""
        return indent + role + " " + label + " " + help + "\n" + view.subviews.map { accessibilityDump($0, indent: indent + "  ") }.joined()
    }
}
