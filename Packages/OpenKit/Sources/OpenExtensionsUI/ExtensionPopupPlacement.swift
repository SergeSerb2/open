import Foundation
import OpenDesign

/// A4 priority is resolved by App, which knows visible browser chrome.
public enum ExtensionPopupAnchorKind: Sendable {
    case actionButton, paneBar, urlField, siteControls, contentTopLeading, littleOpen, overflow
}
public enum ExtensionPopupPlacement {
    /// Cocoa screen coordinates (y up), unlike the flipped strip's local frames.
    /// S2: recompute from the same anchor to retain the top-left edge on resize.
    public static func frame(anchor: CGRect, requestedSize: CGSize, visibleFrame: CGRect) -> CGRect {
        let screen = visibleFrame.insetBy(dx: ExtensionsMetrics.popupScreenMargin, dy: ExtensionsMetrics.popupScreenMargin)
        guard screen.width > 0, screen.height > 0, [anchor.minX, anchor.minY, anchor.width, anchor.height,
            screen.minX, screen.minY, screen.width, screen.height].allSatisfy(\.isFinite) else { return .zero }
        func dimension(_ value: CGFloat, _ minimum: CGFloat, _ maximum: CGFloat, _ available: CGFloat) -> CGFloat {
            min(available, max(minimum, min(maximum, value.isFinite ? value : minimum)))
        }
        let size = CGSize(width: dimension(requestedSize.width, 25, 800, screen.width), height: dimension(requestedSize.height, 25, 600, screen.height))
        let gap = ExtensionsMetrics.popupGap
        let below = max(0, anchor.minY - gap - screen.minY), above = max(0, screen.maxY - anchor.maxY - gap)
        let useAbove = size.height > below && above > below
        // S1: the page scrolls within the space on the chosen side.
        let height = min(size.height, useAbove ? above : below)
        let x = min(max(anchor.minX, screen.minX), screen.maxX - size.width)
        let y = useAbove ? anchor.maxY + gap : anchor.minY - gap - height
        return CGRect(x: x, y: min(max(y, screen.minY), screen.maxY - height), width: size.width, height: height)
    }
}
