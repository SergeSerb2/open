import AppKit
import OpenDesign
import OpenModel

@MainActor
public final class SplitDividerView: NSView {
    public var orientation: SplitOrientation = .horizontal
    public var pairIndex = 0
    public var isEnabled = true
    var onBegin: (() -> [CGRect])?
    var onDrag: (([CGRect]) -> Void)?
    var onCommit: (([CGRect]) -> Void)?
    private var start: CGPoint = .zero
    private var initial: [CGRect] = []
    private var current: [CGRect] = []
    public override func resetCursorRects() { addCursorRect(bounds, cursor: orientation == .horizontal ? .resizeLeftRight : .resizeUpDown) }
    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }; start = event.locationInWindow; initial = onBegin?() ?? []; current = initial
        if event.clickCount == 2 { resize(delta: 0, equal: true); onCommit?(current) }
    }
    public override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        resize(delta: orientation == .horizontal ? event.locationInWindow.x - start.x : start.y - event.locationInWindow.y)
    }
    /// A press without a drag leaves the frames as they were. Committing them would store fractions
    /// rebuilt from integer-rounded frames, which differ slightly from the saved ones and register
    /// an undo step that changes nothing visible.
    public override func mouseUp(with event: NSEvent) { if isEnabled && !current.isEmpty && current != initial { onCommit?(current) }; initial = []; current = [] }
    /// The same live resize path used by mouse events; harness supplies the delta directly.
    public func drag(by delta: CGFloat, commit: Bool = true) {
        initial = onBegin?() ?? []; current = initial; resize(delta: delta)
        if commit { onCommit?(current) }
    }
    private func resize(delta: CGFloat, equal: Bool = false) {
        guard initial.indices.contains(pairIndex + 1) else { return }
        let i = pairIndex, j = i + 1, horizontal = orientation == .horizontal
        let a = initial[i], b = initial[j], first = horizontal ? a.width : a.height, second = horizontal ? b.width : b.height
        let total = first + second, minimum = min(SplitMetrics.minimumPane, total / 2)
        let size = equal ? total / 2 : max(minimum, min(total - minimum, first + delta))
        current = initial
        if horizontal { current[i].size.width = size; current[j].origin.x = a.minX + size + SplitMetrics.gap; current[j].size.width = total - size }
        else { current[i].origin.y = a.maxY - size; current[i].size.height = size; current[j].size.height = total - size }
        onDrag?(current)
    }
}
