import AppKit
import CoreText

struct LibraryRowText: Sendable { let title:String; let subtitle:String }
/// These objects are immutable after construction; CoreText supports worker
/// layout. The action closures and mutable native views stay on the main actor.
struct LibraryPreparedText: @unchecked Sendable {
    let text: LibraryRowText
    let title: NSAttributedString
    let subtitle: NSAttributedString
    let titleLine: CTLine
    let subtitleLine: CTLine
    init(_ text:LibraryRowText,color:[CGFloat],titleFont:String,subtitleFont:String) {
        self.text = text
        let space = CGColorSpaceCreateDeviceRGB()
        let ink = CGColor(colorSpace:space,components:color)!
        let muted = CGColor(colorSpace:space,components:Array(color.prefix(3))+[color[3]*0.68])!
        title = NSAttributedString(string:text.title,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName(titleFont as CFString,15,nil),NSAttributedString.Key(kCTForegroundColorAttributeName as String):ink])
        subtitle = NSAttributedString(string:text.subtitle,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName(subtitleFont as CFString,13,nil),NSAttributedString.Key(kCTForegroundColorAttributeName as String):muted])
        titleLine = CTLineCreateWithAttributedString(title); subtitleLine = CTLineCreateWithAttributedString(subtitle)
    }
}

/// Immutable input for background sorting, grouping and case/diacritic folding.
/// No AppKit objects or action closures cross the actor boundary.
struct LibraryRowSeed: Sendable {
    let index: Int
    let id: String
    let date: Date?
    let text: String
}
struct LibraryPreparedRow: Sendable {
    let index: Int
    let id: String
    let day: String
    let key: String
}

@MainActor
final class LibraryRowSource {
    let id: String
    let date: Date?
    let text: String
    var day = ""
    private let make: @MainActor (LibraryRowText?) -> LibraryRowItem
    private var cached: LibraryRowItem?
    let prepareText: (@Sendable () -> LibraryRowText)?
    var preparedText: LibraryPreparedText?
    init(id: String, date: Date? = nil, text: String, prepareText:(@Sendable () -> LibraryRowText)? = nil, make: @escaping @MainActor (LibraryRowText?) -> LibraryRowItem) {
        self.id = id; self.date = date; self.text = text; self.make = make; self.prepareText = prepareText
    }
    func resolve() -> LibraryRowItem {
        if let cached { return cached }
        var row = make(preparedText?.text); row.day = day
        if let preparedText { row.title = preparedText.text.title; row.subtitle = preparedText.text.subtitle }
        cached = row; return row
    }
}

@MainActor
final class LibrarySectionHost {
    let list = LibraryListView()
    var storeVersion = ""
    var storeWatch: Task<Void,Never>?
    var loaded = false
    var provider: Task<Void,Never>?
    var providerGeneration = 0
    var wasWarmed = false
    var dirty = true
    var identity = ""
    var sources: [LibraryRowSource] = []
    var prepared: [LibraryPreparedRow] = []
    var filtered: [LibraryPreparedRow] = []
    var sourceVersion = 0
    var preparedVersion = -1
    var generation = 0
    var preparation: Task<Void, Never>?
    var worker: Task<[LibraryPreparedRow], Never>?
    var append: Task<Void, Never>?
    var phaseMilliseconds: [String:Double] = [:]
    func cancel() { preparation?.cancel(); worker?.cancel(); append?.cancel(); preparation = nil; worker = nil; append = nil }
    isolated deinit { provider?.cancel(); preparation?.cancel(); worker?.cancel(); append?.cancel(); storeWatch?.cancel() }
}

@MainActor
final class LibrarySkeletonView: NSView {
    private var plates: [CALayer] = []
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override init(frame:NSRect) {
        super.init(frame:frame); wantsLayer = true
        for _ in 0..<6 { let plate = CALayer(); plate.cornerRadius = 10; layer?.addSublayer(plate); plates.append(plate) }
        setAccessibilityElement(false)
    }
    required init?(coder:NSCoder) { fatalError() }
    func tint(_ color:NSColor) { for plate in plates { plate.backgroundColor = color.withAlphaComponent(0.045).cgColor } }
    override func layout() {
        super.layout()
        for (index,plate) in plates.enumerated() { plate.frame = CGRect(x:12,y:CGFloat(index)*56+6,width:max(0,bounds.width-24),height:44) }
    }
}

nonisolated func prepareLibraryRows(_ seeds: [LibraryRowSeed]) -> [LibraryPreparedRow] {
    let calendar = Calendar.current, now = Date()
    let today = calendar.startOfDay(for:now)
    let yesterday = calendar.date(byAdding:.day,value:-1,to:today)!
    let week = calendar.date(byAdding:.day,value:-7,to:now)!
    // A day has one label, regardless of the number of rows on that day.
    var labels: [Date:String] = [:]
    let ordered = seeds.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    return ordered.compactMap { seed in
        guard !Task.isCancelled else { return nil }
        var label = ""
        if let date = seed.date {
            let day = calendar.startOfDay(for:date)
            if let cached = labels[day] { label = cached }
            else {
                label = day == today ? "Today" : day == yesterday ? "Yesterday" : date >= week ? "Last 7 days" : date.formatted(.dateTime.month(.wide).year())
                labels[day] = label
            }
        }
        return LibraryPreparedRow(index:seed.index,id:seed.id,day:label,key:seed.text.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:.current))
    }
}
