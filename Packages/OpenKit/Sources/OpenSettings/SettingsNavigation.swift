import AppKit
import SwiftUI
import OpenDesign

struct SettingsNavigation: NSViewRepresentable {
    let viewModel: SettingsViewModel
    let section: SettingsSection
    let query: String
    let results: [SettingsSearchEntry]
    let updateState: String?
    let focusRequest: Int
    func makeNSView(context: Context) -> SettingsNavigationView { SettingsNavigationView(model: viewModel) }
    func updateNSView(_ view: SettingsNavigationView, context: Context) { view.update(section: section, query: query, results: results, focusRequest: focusRequest) }
}

@MainActor final class SettingsNavigationView: NSView, NSTextFieldDelegate {
    let model: SettingsViewModel
    let search = NSTextField()
    private let clear = NSButton(title: "×", target: nil, action: nil)
    private let hint = NSTextField(labelWithString: "⌘F")
    private let glass = NSTextField(labelWithString: "⌕")
    private let scroll = NSScrollView()
    private let items = FlippedSettingsView()
    private let footer = NSTextField(labelWithString: "")
    private let check = NSButton(title: "Check", target: nil, action: nil)
    private var buttons: [SettingsNavigationButton] = []
    private var groups: [(NSTextField, SettingsSection)] = []
    private var lastFocus = 0
    private var currentQuery = ""
    override var isFlipped: Bool { true }
    init(model: SettingsViewModel) {
        self.model = model; super.init(frame: .zero)
        search.isBordered = false; search.drawsBackground = false
        search.font = .systemFont(ofSize: 12); search.placeholderString = "Search settings"
        search.delegate = self; search.focusRingType = .none
        search.setAccessibilityLabel("Search settings"); search.identifier = .init("settings-search")
        search.setAccessibilityRole(.textField)
        addSubview(search); glass.font = .systemFont(ofSize: 17); addSubview(glass)
        hint.font = .systemFont(ofSize: 11, weight: .medium); addSubview(hint)
        clear.isBordered = false; clear.target = self; clear.action = #selector(clearSearch)
        clear.setAccessibilityLabel("Clear settings search"); addSubview(clear)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = items; addSubview(scroll)
        for section in SettingsSection.allCases {
            if let title = section.group {
                let label = NSTextField(labelWithString: title); label.font = SettingsTokens.Redesign.group.font
                label.attributedStringValue = NSAttributedString(string: title, attributes: [.font: label.font!, .kern: 0.735])
                items.addSubview(label); groups.append((label, section))
            }
            let button = SettingsNavigationButton(section: section)
            button.target = self; button.action = #selector(selectSection(_:))
            items.addSubview(button); buttons.append(button)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        footer.stringValue = "Open \(version)"; footer.font = .systemFont(ofSize: 11.5)
        addSubview(footer); check.isBordered = false; check.font = .systemFont(ofSize: 11.5, weight: .medium)
        check.target = self; check.action = #selector(checkUpdates); addSubview(check)
        check.setAccessibilityLabel("Check for Updates")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(section: SettingsSection, query: String, results: [SettingsSearchEntry], focusRequest: Int) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        footer.stringValue = "Open \(version)" + (model.updateState.map { " · " + $0 } ?? "")
        currentQuery = query
        if search.stringValue != query { search.stringValue = query }
        let counts = Dictionary(grouping: results, by: \.section).mapValues(\.count)
        for button in buttons {
            button.selected = query.isEmpty && button.section == section
            button.resultCount = query.isEmpty ? nil : counts[button.section, default: 0]
            button.profileCount = button.section == .profiles ? model.model.profiles.count : 0
            button.attention = button.section == .shortcuts && !model.shortcuts.unexpected.isEmpty
            button.setAccessibilitySelected(button.selected)
            button.accent = SettingsTokens.Redesign.accessibleAccent(model.settingsAccentSource, dark: contentAppearance == .dark)
            button.needsDisplay = true
        }
        hint.isHidden = !query.isEmpty; clear.isHidden = query.isEmpty
        if lastFocus != focusRequest { lastFocus = focusRequest; window?.makeFirstResponder(search) }
        window?.title = section.title
        needsDisplay = true
    }
    override func layout() {
        super.layout()
        search.frame = .init(x: 34, y: 51, width: 146, height: 19)
        glass.frame = .init(x: 19, y: 48, width: 16, height: 24)
        hint.frame = .init(x: 183, y: 52, width: 28, height: 16)
        clear.frame = .init(x: 187, y: 48, width: 26, height: 24)
        scroll.frame = .init(x: 10, y: 84, width: bounds.width - 20, height: max(100, bounds.height - 126))
        var y: CGFloat = 0
        for button in buttons {
            if let group = groups.first(where: { $0.1 == button.section })?.0 {
                group.frame = .init(x: 8, y: y + 10, width: 185, height: 13); y += 28
            }
            button.frame = .init(x: 0, y: y, width: bounds.width - 20, height: 30); y += 30
        }
        items.frame = .init(x: 0, y: 0, width: scroll.bounds.width, height: y)
        footer.frame = .init(x: 18, y: bounds.height - 27, width: 165, height: 18)
        check.frame = .init(x: bounds.width - 51, y: bounds.height - 31, width: 41, height: 24)
    }
    override func draw(_ rect: NSRect) {
        let dark = contentAppearance == .dark
        let t = SettingsTokens.Redesign.self
        let accent = t.accessibleAccent(model.settingsAccentSource, dark: dark)
        let background = t.navigationBase.resolved(dark ? .dark : .light).nsColor
        (background.blended(withFraction: dark ? 0.06 : 0.08, of: accent) ?? background).setFill(); bounds.fill()
        t.control.nsColor.setFill(); NSBezierPath(roundedRect: .init(x: 10, y: 44, width: bounds.width - 20, height: 30), xRadius: 8, yRadius: 8).fill()
        let focused = (window?.firstResponder as? NSTextView)?.delegate === search
        (focused ? accent : t.controlLine.nsColor).setStroke()
        let ring = NSBezierPath(roundedRect: .init(x: 10.5, y: 44.5, width: bounds.width - 21, height: 29), xRadius: 8, yRadius: 8)
        ring.lineWidth = 1; ring.stroke()
        if focused { accent.withAlphaComponent(0.35).setStroke(); let path = NSBezierPath(roundedRect: .init(x: 8.5, y: 42.5, width: bounds.width - 17, height: 33), xRadius: 9, yRadius: 9); path.lineWidth = 3; path.stroke() }
        search.placeholderAttributedString = NSAttributedString(string: "Search settings", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: t.secondary.nsColor])
        search.textColor = t.text.nsColor; glass.textColor = t.secondary.nsColor; hint.textColor = t.secondary.nsColor
        clear.contentTintColor = t.secondary.nsColor; footer.textColor = t.secondary.nsColor; check.contentTintColor = accent
        groups.forEach { $0.0.textColor = t.secondary.nsColor }
        t.hairline.nsColor.setFill(); NSRect(x: 18, y: bounds.height - 40, width: bounds.width - 36, height: 1).fill()
    }
    func controlTextDidChange(_ notification: Notification) { model.searchQuery = search.stringValue; needsDisplay = true }
    func controlTextDidBeginEditing(_ notification: Notification) { needsDisplay = true }
    func controlTextDidEndEditing(_ notification: Notification) { needsDisplay = true }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): model.searchSelection = min(max(0, model.searchResults.count - 1), model.searchSelection + 1); return true
        case #selector(NSResponder.moveUp(_:)): model.searchSelection = max(0, model.searchSelection - 1); return true
        case #selector(NSResponder.insertNewline(_:)): model.openSearchSelection(); return true
        case #selector(NSResponder.cancelOperation(_:)): clearSearch(); return true
        default: return false
        }
    }
    @objc private func clearSearch() { model.searchQuery = ""; window?.makeFirstResponder(search) }
    @objc private func checkUpdates() { model.general.checkForUpdates() }
    @objc private func selectSection(_ sender: SettingsNavigationButton) { model.navigate(to: sender.section) }
    func beginSearch(with text: String) {
        model.searchQuery += text; search.stringValue = model.searchQuery
        window?.makeFirstResponder(search)
        search.currentEditor()?.selectedRange = NSRange(location: (model.searchQuery as NSString).length, length: 0)
    }
}

private final class FlippedSettingsView: NSView { override var isFlipped: Bool { true } }

@MainActor final class SettingsNavigationButton: NSButton {
    let section: SettingsSection
    var selected = false
    var resultCount: Int?
    var profileCount = 0
    var attention = false
    var accent = SettingsTokens.Redesign.accent.nsColor
    private var hover = false
    override var isFlipped: Bool { true }
    init(section: SettingsSection) {
        self.section = section; super.init(frame: .zero)
        title = section.title; isBordered = false; setButtonType(.momentaryChange)
        setAccessibilityRole(.button)
        setAccessibilityLabel(section.title); identifier = .init("settings-nav-" + section.rawValue)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let text = event.characters, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            var ancestor = superview
            while let view = ancestor { if let nav = view as? SettingsNavigationView { nav.beginSearch(with: text); return }; ancestor = view.superview }
        }
        super.keyDown(with: event)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let t = SettingsTokens.Redesign.self
        if selected || hover { accent.withAlphaComponent(selected ? (contentAppearance == .dark ? 0.24 : 0.14) : 0.07).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill() }
        let opacity: CGFloat = resultCount == 0 ? 0.45 : 1
        let color = resultCount == 0 ? t.secondary.nsColor : t.text.nsColor
        (title as NSString).draw(at: .init(x: 33, y: 7), withAttributes: [.font: t.navigation.font, .foregroundColor: color])
        let iconColor = (selected ? accent : t.secondary.nsColor).withAlphaComponent(opacity)
        SettingsNavigationGlyph.draw(section, in: .init(x: 8, y: 7, width: 16, height: 16), color: iconColor)
        let count = resultCount ?? (profileCount > 1 ? profileCount : 0)
        if count > 0 { let value = String(count) as NSString; value.draw(at: .init(x: bounds.width - value.size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width - 8, y: 8), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: t.secondary.nsColor]) }
        else if attention { t.sunEnd.nsColor.setFill(); NSBezierPath(ovalIn: .init(x: bounds.width - 14, y: 12, width: 6, height: 6)).fill() }
        if window?.firstResponder === self { accent.withAlphaComponent(0.35).setStroke(); let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 7, yRadius: 7); path.lineWidth = 3; path.stroke() }
    }
}

/// Original 16 pt line drawings, based on the lead's vector construction.
enum SettingsNavigationGlyph {
    static func draw(_ section: SettingsSection, in rect: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform(); transform.translateX(by: rect.minX, yBy: rect.minY); transform.concat()
        color.setStroke()
        let path = NSBezierPath(); path.lineWidth = 1.5; path.lineCapStyle = .round; path.lineJoinStyle = .round
        func line(_ points: [(Double, Double)]) { for (i, point) in points.enumerated() { let p = NSPoint(x: point.0, y: point.1); if i == 0 { path.move(to: p) } else { path.line(to: p) } } }
        func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) { path.appendRoundedRect(.init(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r) }
        func circle(_ x: Double, _ y: Double, _ r: Double) { path.appendOval(in: .init(x: x-r, y: y-r, width: r*2, height: r*2)) }
        switch section {
        case .general:
            circle(8,8,2.2); for a in 0..<8 { let angle = Double(a) * .pi / 4; line([(8+cos(angle)*4.6,8+sin(angle)*4.6),(8+cos(angle)*6.2,8+sin(angle)*6.2)]) }
        case .appearance: box(2,3,12,10,2.5); line([(6,3),(6,13)])
        case .tabsArchive: box(2,4,12,3.2,1.2); box(2,9,12,3.2,1.2)
        case .search: circle(7,7,4); line([(10,10),(13.5,13.5)])
        case .links: box(2,7,8,5,2.5); box(6,3,8,5,2.5); line([(6,10),(10,6)])
        case .downloads: line([(8,2.5),(8,10),(5,7.5)]); line([(8,10),(11,7.5)]); line([(3,13.5),(13,13.5)])
        case .previews: box(2,2.5,12,11,2.5); box(5,5.5,6,5,1)
        case .adBlocking: line([(8,1.8),(13,3.6),(13,7.6),(11,11.5),(8,14.2),(5,11.5),(3,7.6),(3,3.6),(8,1.8)])
        case .sitePermissions: circle(8,8,6); line([(5.5,8),(10.5,8)])
        case .passwordsCards: circle(5.5,10.5,2.5); line([(7.3,8.7),(13,3)]); line([(11,5),(12.5,6.5)])
        case .browsingData: circle(8,8,6); line([(8,4.5),(8,8),(10.3,9.5)])
        case .profiles: circle(8,6,2.6); path.move(to: .init(x:3,y:13.5)); path.curve(to: .init(x:13,y:13.5), controlPoint1:.init(x:4,y:8.5),controlPoint2:.init(x:12,y:8.5))
        case .shortcuts: box(1.5,4,13,8,2); for x in [4.5,7,9.5,12] { line([(x,7),(x+0.05,7)]) }; line([(5,9.7),(11,9.7)])
        case .extensions: line([(3,3),(6,3),(6,5),(9,5),(9,3),(13,3),(13,7),(11,7),(11,10),(13,10),(13,13),(3,13),(3,3)])
        case .advanced: for (y,x) in [(4.5,10.0),(8,6),(11.5,11)] { line([(2.5,y),(x-2,y)]); line([(x+2,y),(13.5,y)]); circle(x,y,1.4) }
        }
        path.stroke()
    }
}
