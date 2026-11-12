import Foundation
import CoreGraphics

/// One Easel: a 1000-point-wide, vertically growing canvas (docs/re/easels-notes.md §3.4).
/// Object frames are stored in document points (width 1000), not in view points, so a
/// relaunch at another window width restores them exactly.
public struct EaselDocument: Codable, Equatable, Sendable {
    public static let width: CGFloat = 1000
    public static let currentFormatVersion = 1
    public static let untitled = "Untitled Easel"

    public var formatVersion: Int
    public var id: UUID
    /// Nil or empty shows the "Untitled Easel" placeholder.
    public var title: String?
    public var palette: EaselPalette
    public var createdAt: Date
    public var modifiedAt: Date
    public var objects: [EaselObject]

    public init(id: UUID = UUID(), title: String? = nil, palette: EaselPalette = .vibrant,
                createdAt: Date = Date(), objects: [EaselObject] = []) {
        self.formatVersion = Self.currentFormatVersion
        self.id = id; self.title = title; self.palette = palette
        self.createdAt = createdAt; self.modifiedAt = createdAt; self.objects = objects
    }

    /// Hard limits for documents and pasteboard objects read from outside the process.
    /// A file over `maxFileBytes` is refused before decoding; a decoded document over any
    /// count or length limit is refused (`EaselStore.setAsideRefused` renames the file and the
    /// row shows a fresh empty Easel). Worst accepted decode: 10,000 objects × (≤ 64 KiB text or
    /// ≤ 20,000 points × 16 B) stays far below 2 GiB because the file itself is ≤ 64 MiB.
    public static let maxFileBytes = 64 << 20
    public static let maxObjects = 10_000
    public static let maxTextLength = 65_536
    public static let maxPoints = 20_000
    public static let maxTitleLength = 1_000

    public static func isValid(_ objects: [EaselObject]) -> Bool {
        guard objects.count <= maxObjects else { return false }
        for o in objects {
            guard o.frame.minX.isFinite, o.frame.minY.isFinite, o.frame.width.isFinite, o.frame.height.isFinite,
                  abs(o.frame.minX) < 1e6, abs(o.frame.minY) < 1e7, o.frame.width >= 0, o.frame.height >= 0,
                  o.frame.width < 1e6, o.frame.height < 1e7 else { return false }
            switch o.content {
            case .text(let t): if t.string.utf16.count > maxTextLength { return false }
            case .shape(_, _, let arrow, let points):
                if (points?.count ?? 0) > maxPoints { return false }
                let all = (points ?? []) + (arrow.map { [$0.start, $0.end] } ?? [])
                if all.contains(where: { !$0.x.isFinite || !$0.y.isFinite || abs($0.x) > 1e3 || abs($0.y) > 1e3 }) { return false }
            }
        }
        return true
    }
    public var isValid: Bool {
        formatVersion <= Self.currentFormatVersion && (title?.utf16.count ?? 0) <= Self.maxTitleLength && Self.isValid(objects)
    }

    public var displayTitle: String {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Self.untitled }
        return title
    }

    public func index(of id: UUID) -> Int? { objects.firstIndex { $0.id == id } }
    public func object(_ id: UUID) -> EaselObject? { index(of: id).map { objects[$0] } }
    /// Objects in paint order (low z first; ties keep insertion order).
    public var paintOrder: [EaselObject] {
        objects.enumerated().sorted { ($0.element.zIndex, $0.offset) < ($1.element.zIndex, $1.offset) }.map(\.element)
    }
    public var maxZ: Int { objects.map(\.zIndex).max() ?? 0 }
    public var minZ: Int { objects.map(\.zIndex).min() ?? 0 }
    /// Bottom edge of the lowest object, in document points.
    public var contentBottom: CGFloat { objects.map { $0.frame.maxY }.max() ?? 0 }
}

public struct EaselObject: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Document points (x 0…1000).
    public var frame: CGRect
    public var zIndex: Int
    public var content: EaselContent
    public var createdAt: Date

    public init(id: UUID = UUID(), frame: CGRect, zIndex: Int, content: EaselContent, createdAt: Date = Date()) {
        self.id = id; self.frame = frame; self.zIndex = zIndex; self.content = content; self.createdAt = createdAt
    }
}

public enum EaselShapeKind: String, Codable, Sendable, CaseIterable {
    case rectangle, circle, arrow, freehand
}

/// Text families and sizes from Arc's export viewer (findings §3.4). E1 draws all four with
/// system faces; the bundled OFL fonts come with E4 (lead decision pending, F1 Q5).
public enum EaselFontFamily: String, Codable, Sendable, CaseIterable { case clean, mono, fancy, hip }
public enum EaselParagraphStyle: String, Codable, Sendable, CaseIterable {
    case body, h2, h1, h0, ultra
    public var larger: EaselParagraphStyle? {
        switch self { case .body: .h2; case .h2: .h1; case .h1: .h0; case .h0: .ultra; case .ultra: nil }
    }
    public var smaller: EaselParagraphStyle? {
        switch self { case .body: nil; case .h2: .body; case .h1: .h2; case .h0: .h1; case .ultra: .h0 }
    }
}

public struct EaselPoint: Codable, Equatable, Sendable {
    public var x: CGFloat; public var y: CGFloat
    public init(x: CGFloat, y: CGFloat) { self.x = x; self.y = y }
    public init(_ p: CGPoint) { x = p.x; y = p.y }
    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

/// Discriminated by `type`, the spelling of Arc's export viewer (findings §3.8), so the
/// E4 exporter and I1 importer map 1:1. E2+ adds image, webCard, browser, link.
public enum EaselContent: Equatable, Sendable {
    case text(EaselText)
    /// Arrow ends and freehand points are fractions of the object frame (0…1), so a resize
    /// scales them with the frame.
    case shape(kind: EaselShapeKind, color: EaselColor, arrow: (start: EaselPoint, end: EaselPoint)?, points: [EaselPoint]?)

    public static func == (a: EaselContent, b: EaselContent) -> Bool {
        switch (a, b) {
        case (.text(let x), .text(let y)): return x == y
        case let (.shape(k1, c1, a1, p1), .shape(k2, c2, a2, p2)):
            return k1 == k2 && c1 == c2 && p1 == p2 && a1?.start == a2?.start && a1?.end == a2?.end
        default: return false
        }
    }

    public var kindName: String {
        switch self {
        case .text: "text"
        case .shape(let kind, _, _, _): kind.rawValue
        }
    }
    public var color: EaselColor? { if case .shape(_, let c, _, _) = self { c } else { nil } }
}

public struct EaselText: Codable, Equatable, Sendable {
    public var string: String
    public var fontFamily: EaselFontFamily
    public var paragraphStyle: EaselParagraphStyle
    public init(string: String = "", fontFamily: EaselFontFamily = .clean, paragraphStyle: EaselParagraphStyle = .body) {
        self.string = string; self.fontFamily = fontFamily; self.paragraphStyle = paragraphStyle
    }
}

extension EaselContent: Codable {
    private enum Keys: String, CodingKey { case type, string, fontFamily, paragraphStyle, kind, color, arrow, points }
    private struct Arrow: Codable { var start: EaselPoint; var end: EaselPoint }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text":
            self = .text(EaselText(string: try c.decode(String.self, forKey: .string),
                                   fontFamily: try c.decodeIfPresent(EaselFontFamily.self, forKey: .fontFamily) ?? .clean,
                                   paragraphStyle: try c.decodeIfPresent(EaselParagraphStyle.self, forKey: .paragraphStyle) ?? .body))
        case "shape":
            let arrow = try c.decodeIfPresent(Arrow.self, forKey: .arrow)
            self = .shape(kind: try c.decode(EaselShapeKind.self, forKey: .kind),
                          color: try c.decode(EaselColor.self, forKey: .color),
                          arrow: arrow.map { ($0.start, $0.end) },
                          points: try c.decodeIfPresent([EaselPoint].self, forKey: .points))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown Easel content \(other)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: .type)
            try c.encode(t.string, forKey: .string)
            try c.encode(t.fontFamily, forKey: .fontFamily)
            try c.encode(t.paragraphStyle, forKey: .paragraphStyle)
        case .shape(let kind, let color, let arrow, let points):
            try c.encode("shape", forKey: .type)
            try c.encode(kind, forKey: .kind)
            try c.encode(color, forKey: .color)
            try c.encodeIfPresent(arrow.map { Arrow(start: $0.start, end: $0.end) }, forKey: .arrow)
            try c.encodeIfPresent(points, forKey: .points)
        }
    }
}
