import AppKit
import OpenDesign
import OpenModel

/// S2 19/0011, 0025. Solid dark colors are the lead's v1 guess; no Space tint or material.
@MainActor
public final class LittleOpenTitleBarView: NSView {
    private let capsule = NSView()
    private let pill = NSView()
    private let divider = NSView()
    public let profileButton: NSButton
    public let hostButton: NSButton
    public let copyButton: NSButton
    public let pillButton: NSButton
    public let chevronButton: NSButton
    private let keycap = NSTextField(labelWithString: "⌘O")
    public var onProfile: (() -> Void)?
    public var onEditURL: (() -> Void)?
    public var onCopy: (() -> Void)?
    public var onOpenInSpace: (() -> Void)?
    public var onMoreSpaces: (() -> Void)?
    public private(set) var spaceTitle = ""
    private var profileWidth: CGFloat = 0

    public override init(frame: NSRect) {
        func button(_ title: String, symbol: String? = nil) -> NSButton {
            let b = NSButton(title: title, target: nil, action: nil)
            b.isBordered = false; b.font = .systemFont(ofSize: LittleOpenMetrics.fontSize)
            b.contentTintColor = LittleOpenMetrics.text.nsColor
            if let symbol {
                b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(.init(paletteColors: [LittleOpenMetrics.text.nsColor]))
                b.imagePosition = .imageOnly; b.imageScaling = .scaleProportionallyDown
            }
            b.setAccessibilityLabel(title); return b
        }
        profileButton = button("Profile", symbol: "person.crop.circle")
        hostButton = button("")
        copyButton = button("Copy Current URL", symbol: "link")
        pillButton = button("Open in Space")
        chevronButton = button("More Spaces", symbol: "chevron.down")
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = LittleOpenMetrics.titleBarFill.cgColor
        for (view, color, radius) in [(capsule, LittleOpenMetrics.capsuleFill, LittleOpenMetrics.capsuleRadius),
                                      (pill, LittleOpenMetrics.pillFill, LittleOpenMetrics.pillRadius)] {
            view.wantsLayer = true; view.layer?.backgroundColor = color.cgColor
            view.layer?.cornerRadius = radius; view.layer?.cornerCurve = .continuous; addSubview(view)
        }
        divider.wantsLayer = true; divider.layer?.backgroundColor = LittleOpenMetrics.text.withAlpha(LittleOpenMetrics.dividerAlpha).cgColor; addSubview(divider)
        for (i, b) in [profileButton, hostButton, copyButton, pillButton, chevronButton].enumerated() {
            b.tag = i; b.target = self; b.action = #selector(press(_:)); addSubview(b)
        }
        chevronButton.toolTip = "More Spaces"
        keycap.font = .systemFont(ofSize: LittleOpenMetrics.fontSize); keycap.textColor = LittleOpenMetrics.text.nsColor
        keycap.alignment = .center; keycap.wantsLayer = true
        keycap.layer?.backgroundColor = LittleOpenMetrics.capsuleFill.cgColor
        keycap.layer?.cornerRadius = LittleOpenMetrics.keycapRadius
        addSubview(keycap)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    @objc private func press(_ button: NSButton) {
        switch button.tag {
        case 0: onProfile?()
        case 1: onEditURL?()
        case 2: onCopy?()
        case 3: onOpenInSpace?()
        case 4: onMoreSpaces?()
        default: break
        }
    }
    public func update(url: URL?, profile: Profile?, showsProfile: Bool, spaceTitle: String?) {
        let m = LittleOpenMetrics.self
        var host = url?.host ?? url?.absoluteString ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        hostButton.title = host; hostButton.setAccessibilityLabel(host)
        hostButton.attributedTitle = NSAttributedString(string: host, attributes: [.font: NSFont.systemFont(ofSize: m.fontSize), .foregroundColor: m.text.nsColor])
        let name = profile?.name ?? "Profile"
        profileButton.title = name; profileButton.imagePosition = .imageLeading
        profileButton.attributedTitle = NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: m.fontSize, weight: .medium), .foregroundColor: m.text.nsColor])
        profileButton.setAccessibilityLabel("Profile: \(name)"); profileButton.isHidden = !showsProfile
        profileWidth = showsProfile ? min(m.maximumProfileWidth, ceil(profileButton.attributedTitle.size().width) + m.profileIcon.width + m.hostGap) : 0
        self.spaceTitle = spaceTitle ?? ""
        let title = "Open in \(self.spaceTitle)"
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: m.fontSize), .foregroundColor: m.text.nsColor])
        text.addAttribute(.font, value: NSFont.systemFont(ofSize: m.fontSize, weight: .bold), range: NSRange(location: 8, length: (self.spaceTitle as NSString).length))
        pillButton.attributedTitle = text; pillButton.setAccessibilityLabel(title + " ⌘O")
        pillButton.isEnabled = spaceTitle != nil; needsLayout = true
    }
    public override func layout() {
        super.layout(); let m = LittleOpenMetrics.self, w = bounds.width
        capsule.frame = m.capsule(width: w); pill.frame = m.pill(width: w); divider.frame = m.divider(width: w)
        copyButton.frame = m.copy(width: w); chevronButton.frame = m.chevron(width: w)
        let label = m.pillButton(width: w)
        pillButton.frame = CGRect(x: label.minX, y: label.minY, width: label.width - m.keycapWidth, height: label.height)
        keycap.frame = CGRect(x: label.maxX - m.keycapWidth, y: label.minY, width: m.keycapWidth, height: label.height)
        let chipX = m.profileIcon.minX
        // On a minimum-size page the chip hides before it can cover the host/copy control (guess).
        let available = max(0, copyButton.frame.minX - m.hostGap - chipX)
        let chipWidth = min(profileWidth, max(0, available - m.minimumHostWidth))
        profileButton.isHidden = profileWidth == 0 || chipWidth == 0
        profileButton.frame = CGRect(x: chipX, y: m.hostY, width: chipWidth, height: m.hostHeight)
        let left = profileButton.isHidden ? capsule.frame.minX + m.hostGap : profileButton.frame.maxX + m.hostGap
        let right = copyButton.frame.minX - m.hostGap
        let width = min(ceil(hostButton.attributedTitle.size().width), max(0, right - left))
        hostButton.frame = CGRect(x: left + max(0, right - left - width) / 2, y: m.hostY, width: width, height: m.hostHeight)
    }
    /// Frames in the measured top-left coordinate system, shared by automation and L4.
    public var elementFrames: [String: CGRect] {
        ["capsule": capsule.frame, "profile": profileButton.frame, "host": hostButton.frame,
         "copy": copyButton.frame, "pill": pill.frame, "open": LittleOpenMetrics.pillButton(width: bounds.width),
         "chevron": chevronButton.frame, "divider": divider.frame]
    }
}
