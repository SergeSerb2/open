import AppKit
import OpenWeb
import OpenExtensionsUI

@MainActor enum Synthetic {
    static func image(index: Int, badge: String? = nil, disabled: Bool = false, wantsToRun: Bool = false, size: CGFloat = 28) -> ExtensionImage {
        func rep(_ scale: CGFloat) -> CGImage {
            let pixels = Int(size * scale)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = CGSize(width: size, height: size)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
            let iconSize: CGFloat = size == 28 ? 16 : size
            let icon = CGRect(x: (size - iconSize) / 2, y: (size - iconSize) / 2, width: iconSize, height: iconSize)
            let colors: [NSColor] = [.systemBlue, .systemOrange, .systemPurple, .systemGreen, .systemPink, .systemTeal]
            (disabled ? NSColor.gray : colors[index % colors.count]).setFill()
            NSBezierPath(roundedRect: icon, xRadius: 4, yRadius: 4).fill()
            if wantsToRun {
                NSColor.systemBlue.setStroke(); let ring = NSBezierPath(ovalIn: icon.insetBy(dx: -2, dy: -2)); ring.lineWidth = 1; ring.stroke()
            }
            if let badge, !badge.isEmpty {
                // EX-14 / Chromium IconWithBadgeImageSource: 14 tall, >=14 wide,
                // text <=23, radius 4, 1 point cutout. Synthetic pixels only.
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white]
                let text = (badge as NSString).size(withAttributes: attrs)
                let width = min(28, max(14, min(23, ceil(text.width)) + 4))
                let rect = CGRect(x: size - width, y: 0, width: width, height: 14)
                let cutout = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 5, yRadius: 5)
                NSGraphicsContext.current?.compositingOperation = .copy; NSColor.clear.setFill(); cutout.fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                (disabled ? NSColor.darkGray : NSColor.systemRed).setFill(); NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
                NSGraphicsContext.current?.saveGraphicsState(); NSBezierPath(rect: rect.insetBy(dx: 2, dy: 0)).addClip()
                (badge as NSString).draw(at: CGPoint(x: rect.midX - text.width / 2, y: rect.midY - text.height / 2), withAttributes: attrs)
                NSGraphicsContext.current?.restoreGraphicsState()
            }
            NSGraphicsContext.restoreGraphicsState()
            return bitmap.cgImage!
        }
        return ExtensionImage(cgImage: rep(2), pointSize: CGSize(width: size, height: size), image1x: rep(1))!
    }
    static func actions(_ count: Int, pinned: Int? = nil) -> [ExtensionActionInfo] {
        let names = ["Bitwarden", "Dark Reader", "uBlock Origin Lite", "Action Probe", "Color Picker", "Zebra Tools"]
        return (0..<count).map { i in
            let badge = ["1", "99", "999+", "NEW"][i % 4]
            return ExtensionActionInfo(extensionID: "synthetic.\(i)", name: names[i % names.count] + (i < 6 ? "" : " \(i)"),
                accessibleName: names[i % names.count] + ", " + badge, tooltip: names[i % names.count] + " — Open action",
                toolbarImage: image(index: i, badge: badge, disabled: i == 1, wantsToRun: i == 2),
                menuIcon: image(index: i, size: 16), badgeText: badge, isEnabled: i != 1,
                isPinned: i < (pinned ?? count), pinnedIndex: i < (pinned ?? count) ? i : nil,
                wantsToRun: i == 2, isShowingPopup: i == 3, shortcutKeys: i == 0 ? ["⇧", "⌘", "Y"] : [])
        }
    }
    static func contextMenuItems() -> [ExtensionMenuItem] {
        [.init(command: 1, title: "Action Probe"), .init(isSeparator: true),
         .init(command: 100, title: "This Can Read and Change Site Data", submenu: [
            .init(command: 101, title: "When You Click the Extension", isChecked: true),
            .init(command: 102, title: "On example.com"), .init(command: 103, title: "On All Sites"),
            .init(isSeparator: true), .init(command: 104, title: "Learn More About Site Access")]),
         .init(command: 2, title: "Options", isEnabled: false), .init(command: 3, title: "Remove from Chromium"),
         .init(command: 4, title: "Pin to Toolbar"), .init(command: 5, title: "Manage Extension"),
         .init(command: 6, title: "View Web Permissions"), .init(command: 7, title: "Inspect Popup")]
    }
    static func menuModels() -> [String: [ExtensionsMenuEntry]] {
        let actions = actions(8, pinned: 6)
        return ["bar": ExtensionsMenuBuilder.model(actions: actions, kind: .bar),
                "overflow": ExtensionsMenuBuilder.model(actions: actions, kind: .overflow(visiblePinned: 2)),
                "little-open": ExtensionsMenuBuilder.model(actions: actions, kind: .littleOpen)]
    }
}
@MainActor final class SyntheticPrompt: ExtensionPromptModel {
    var type: ExtensionPromptType
    var extensionName: String
    var icon: ExtensionImage? = Synthetic.image(index: 0, size: 48)
    var chromiumTitle = "Repair Sample in Chromium?"
    var chromiumAcceptLabel = "Repair"
    var chromiumCancelLabel = "Cancel"
    var permissions: [ExtensionPermissionMessage]
    var triggeringExtensionName: String?
    var accepts = 0, cancels = 0
    init(_ type: ExtensionPromptType, permissions: Int = 0, name: String = "Sample") {
        self.type = type; extensionName = name
        self.permissions = (0..<permissions).map { ExtensionPermissionMessage("Read and change data on site \($0 + 1)", details: $0 == 0 ? ["Includes pages you open on this site.", "Read your settings for this extension."] : []) }
    }
    func accept() { accepts += 1 }
    func cancel() { cancels += 1 }
}
@MainActor final class SyntheticMenu: ExtensionMenu {
    var items: [ExtensionMenuItem]
    var selections: [Int] = [], cancels = 0
    init(_ items: [ExtensionMenuItem]) { self.items = items }
    func select(command: Int) { selections.append(command) }
    func cancel() { cancels += 1 }
}
