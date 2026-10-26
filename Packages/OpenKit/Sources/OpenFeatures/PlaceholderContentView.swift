import AppKit
import OpenModel
import OpenDesign

@MainActor
public final class PlaceholderContentView: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let hostLabel = NSTextField(labelWithString: "")
    let icon = NSImageView()
    init(tab: Tab, style: SpaceThemeStyle) {
        super.init(frame: .zero); wantsLayer = true
        layer?.backgroundColor = style.lightPalette?.background.cgColor ?? RGBA.white(PanelMetrics.emptyFillWhiteAlpha).cgColor
        titleLabel.stringValue = tab.displayTitle; titleLabel.font = .systemFont(ofSize: 14)
        hostLabel.stringValue = tab.url.host() ?? ""; hostLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = style.titleColor(.light).nsColor; hostLabel.textColor = titleLabel.textColor?.withAlphaComponent(0.65)
        titleLabel.alignment = .center; hostLabel.alignment = .center
        icon.image = tab.live.faviconPNG.flatMap(NSImage.init(data:)) ?? NSImage(systemSymbolName: "globe", accessibilityDescription: "Page")
        for v in [titleLabel, hostLabel, icon] { addSubview(v) }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override func layout() {
        super.layout(); let y = bounds.midY
        icon.frame = CGRect(x: bounds.midX - 16, y: y + 18, width: 32, height: 32)
        titleLabel.frame = CGRect(x: 20, y: y - 12, width: max(0, bounds.width - 40), height: 20)
        hostLabel.frame = CGRect(x: 20, y: y - 36, width: max(0, bounds.width - 40), height: 20)
    }
}
