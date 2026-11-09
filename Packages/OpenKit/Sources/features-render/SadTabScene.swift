import AppKit
import OpenDesign
import OpenFeatures

/// Render the production placeholder without a renderer, window ordering, or crash probe.
@MainActor enum SadTabScene {
    static func render(_ args: [String]) throws {
        let allowed = ["--scene", "--out", "--scale", "--appearance", "--width"]
        guard (5...11).contains(args.count), args.count % 2 == 1 else { throw CLIError(description: "invalid sad-tab options") }
        let keys = stride(from: 1, to: args.count, by: 2).map { args[$0] }
        guard keys.allSatisfy({ allowed.contains($0) }), Set(keys).count == keys.count,
              let out = RenderCLI.value(args, "--out"),
              let scale = Double(RenderCLI.value(args, "--scale") ?? "1"), [1, 2].contains(scale),
              let width = Double(RenderCLI.value(args, "--width") ?? "800"), width.isFinite, (200...1600).contains(width),
              let appearance = ["light": NSAppearance.Name.aqua, "dark": .darkAqua][RenderCLI.value(args, "--appearance") ?? "light"]
        else { throw CLIError(description: "sad-tab requires --out FILE [--scale 1|2] [--appearance light|dark] [--width 200...1600]") }
        NSApp.appearance = NSAppearance(named: appearance)
        let view = SadTabView(style: .defaultTheme(system: appearance == .darkAqua ? .dark : .light))
        view.frame = CGRect(x: 0, y: 0, width: width, height: 540)
        OffscreenRenderer.writePNG(OffscreenRenderer().render(view, scale: scale), to: URL(fileURLWithPath: out))
        print("rendered \(out) \(width)×540 pt; AX buttons: \(view.reloadButton.accessibilityLabel() ?? ""), \(view.closeButton.accessibilityLabel() ?? ""); default: Reload")
    }

    /// Render the real scene at normal and minimum pane widths, in both appearances.
    static func check(_ check: (Bool, String) -> Void) {
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            for width in [CGFloat(800), CGFloat(200)] {
                let style = SpaceThemeStyle.defaultTheme(system: appearance == .darkAqua ? .dark : .light)
                let view = SadTabView(style: style)
                view.frame = CGRect(x: 0, y: 0, width: width, height: 540)
                let image = OffscreenRenderer().render(view, scale: 2)
                let prefix = "Sad Tab \(appearance.rawValue) \(Int(width))pt"
                let children = view.accessibilityChildren()?.compactMap { $0 as? NSView } ?? []
                let labels = children.compactMap { $0 as? NSTextField }
                check(view.accessibilityLabel() == "This page crashed. Something went wrong while showing this page."
                    && children.count == 4 && labels.map(\.stringValue) == ["This page crashed", "Something went wrong while showing this page."]
                    && children[2] === view.reloadButton && children[3] === view.closeButton,
                    "\(prefix) AX group, copy and reading order")
                if let title = labels.first, let body = labels.last, labels.count == 2,
                   let icon = view.subviews.first(where: { $0 is NSImageView }) {
                    check([icon, title, body, view.reloadButton, view.closeButton].allSatisfy { view.bounds.contains($0.frame) }
                        && title.font?.pointSize == (width < 240 ? 17 : 20) && body.maximumNumberOfLines == 3
                        && [view.reloadButton, view.closeButton].allSatisfy { ceil($0.attributedTitle.size().width) + 12 <= $0.frame.width },
                        "\(prefix) fitted content stays inside pane")
                    check(abs(icon.frame.minY - title.frame.maxY - 16) < 0.01
                        && abs(title.frame.minY - body.frame.maxY - 8) < 0.01
                        && abs(body.frame.minY - view.reloadButton.frame.maxY - 24) < 0.01
                        && view.reloadButton.frame.maxX + 12 == view.closeButton.frame.minX,
                        "\(prefix) stack gaps 16/8/24 and button gap 12")
                    check(title.textColor?.isEqual(NSColor.labelColor) == true
                        && body.textColor?.isEqual(NSColor.secondaryLabelColor) == true
                        && !icon.isAccessibilityElement(), "\(prefix) system content colors and decorative icon")
                } else { check(false, "\(prefix) scene content exists") }
                check(view.reloadButton.keyEquivalent == "\r" && view.reloadButton.accessibilityLabel() == "Reload"
                    && view.closeButton.accessibilityLabel() == "Close Tab"
                    && view.reloadButton.bezelColor?.isEqual(style.accentColor(appearance == .darkAqua ? .dark : .light).nsColor) == true
                    && view.closeButton.bezelColor == nil, "\(prefix) primary Reload and plain Close Tab")
                let bitmap = Bitmap(image: image)
                var darkest = Double.infinity, lightest = -Double.infinity
                for i in stride(from: 0, to: bitmap.data.count, by: 4) {
                    let luminance = 0.2126 * Double(bitmap.data[i]) + 0.7152 * Double(bitmap.data[i + 1]) + 0.0722 * Double(bitmap.data[i + 2])
                    darkest = min(darkest, luminance); lightest = max(lightest, luminance)
                }
                check(image.width == Int(width * 2) && image.height == 1080
                    && lightest - darkest > 30,
                    "\(prefix) production scene renders nonblank pixels at 2x")
            }
        }
    }
}
