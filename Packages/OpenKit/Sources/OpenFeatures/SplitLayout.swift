import Foundation
import CoreGraphics
import OpenModel

public enum SplitLayout {
    /// The fraction array also supplies pane count (nil/empty defaults to two).
    /// Callers pass one equal fraction per pane when stored fractions are empty.
    public static func frames(content: CGRect, orientation: SplitOrientation,
                              fractions: [Double]?, gap: CGFloat, minPane: CGFloat) -> [CGRect] {
        let n = max(1, min(4, fractions?.isEmpty == false ? fractions!.count : 2))
        let horizontal = orientation == .horizontal
        let axis = max(0, horizontal ? content.width : content.height)
        let gap = min(max(0, gap), n > 1 ? axis / CGFloat(n - 1) : 0)
        let usable = max(0, axis - gap * CGFloat(n - 1))
        let raw = fractions ?? []
        let valid = raw.count == n && raw.allSatisfy { $0.isFinite && $0 >= 0 } && raw.reduce(0, +) > 0
        let sum = valid ? raw.reduce(0, +) : Double(n)
        var sizes = (0..<n).map { CGFloat(valid ? raw[$0] / sum : 1 / Double(n)) * usable }
        let minimum = min(max(0, minPane), usable / CGFloat(n))
        if usable < minPane * CGFloat(n) { sizes = Array(repeating: usable / CGFloat(n), count: n) }
        else {
            for i in sizes.indices where sizes[i] < minimum {
                let deficit = minimum - sizes[i]; sizes[i] = minimum
                var left = deficit
                for j in sizes.indices.sorted(by: { sizes[$0] > sizes[$1] }) where j != i {
                    let take = min(left, max(0, sizes[j] - minimum))
                    sizes[j] -= take; left -= take
                    if left <= 0 { break }
                }
            }
        }
        // Integer point boundaries; the last pane owns any fractional remainder.
        for i in 0..<max(0, n - 1) { sizes[i] = floor(sizes[i]) }
        sizes[n - 1] = max(0, usable - sizes.dropLast().reduce(0, +))
        var cursor: CGFloat = 0
        return sizes.map { size in
            defer { cursor += size + gap }
            if horizontal { return CGRect(x: content.minX + cursor, y: content.minY, width: size, height: max(0, content.height)) }
            return CGRect(x: content.minX, y: content.maxY - cursor - size, width: max(0, content.width), height: size)
        }
    }

    public static func fractions(forSizes sizes: [CGFloat]) -> [Double] {
        guard !sizes.isEmpty else { return [] }
        let clean = sizes.map { $0.isFinite ? max(0, $0) : 0 }, sum = sizes.filter { $0.isFinite && $0 > 0 }.reduce(0, +)
        guard sum > 0 else { return Array(repeating: 1 / Double(sizes.count), count: sizes.count) }
        return clean.map { Double($0 / sum) }
    }
}
