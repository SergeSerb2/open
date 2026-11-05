import Foundation
import OpenDesign

public enum ExtensionStripStyle: Sendable { case urlField, paneBar, toolbar }
/// Pure point math shared by production views and the CLI. Frames are host coordinates.
public struct ExtensionStripLayout: Sendable {
    public let nMax: Int
    public let actionFrames: [CGRect]
    public let moreFrame: CGRect?
    public let overflowCount: Int
    public let stripWidth: CGFloat
    public var frames: [CGRect] { (moreFrame.map { [$0] } ?? []) + actionFrames }
    public init(style: ExtensionStripStyle, width: CGFloat, pinnedCount: Int, hostTextWidth: CGFloat = 120, focused: Bool = true) {
        let w = width.isFinite ? max(0, min(width, 16384)) : 0
        let count = max(0, min(pinnedCount, 512)), pitch = ExtensionsMetrics.pitch
        let available: CGFloat
        let minimumAvailable: CGFloat
        let right: CGFloat
        switch style {
        case .urlField:
            right = w - 70; available = right - (URLFieldMetrics.hostX + ExtensionsMetrics.urlFieldHostMinimum + 2)
            minimumAvailable = available
        case .paneBar, .toolbar:
            // PaneChromeView.layout: reload.maxX + barControlGap = 115.
            let left = SplitMetrics.reload.maxX + SplitMetrics.barControlGap
            right = style == .toolbar ? ToolbarMetrics.extensionsSlot(width: w).maxX : w - 105
            // guess (lead), capture C1: toolbar reserves SCC (32) plus its gap (4)
            // to the left of the strip. Right remains w - 5, with no trailing reserve.
            let controls: CGFloat = style == .toolbar ? 36 : 0
            let text = hostTextWidth.isFinite ? max(0, hostTextWidth) : 0
            let host = 2 * SplitMetrics.hostSlot + min(ExtensionsMetrics.paneHostCap, max(SplitMetrics.hostMinimumWidth, text + 4))
            available = right - left - host - controls
            minimumAvailable = right - left - (2 * SplitMetrics.hostSlot + SplitMetrics.hostMinimumWidth) - controls
        }
        let maxCount = style == .paneBar && !focused ? 0 : max(0, Int(floor(max(0, available) / pitch)))
        nMax = maxCount
        let fallback = style != .urlField && (style != .paneBar || focused) && maxCount == 0 && minimumAvailable >= pitch
        let slots = min(count, maxCount == 0 && fallback ? 1 : maxCount)
        let overflow = count > slots && slots > 0
        let actions = max(0, slots - (overflow ? 1 : 0))
        let y: CGFloat = style == .urlField ? 49 : 2
        let side: CGFloat = style == .urlField ? 30 : 28
        func frame(_ i: Int) -> CGRect { CGRect(x: right - pitch * CGFloat(slots - i), y: y, width: side, height: side) }
        moreFrame = overflow ? frame(0) : nil
        actionFrames = (0..<actions).map { frame($0 + (overflow ? 1 : 0)) }
        overflowCount = count - actions
        stripWidth = CGFloat(slots) * pitch
    }
}
