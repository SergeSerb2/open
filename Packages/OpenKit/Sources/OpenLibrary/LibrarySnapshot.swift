import AppKit

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
    private let make: @MainActor () -> LibraryRowItem
    private var cached: LibraryRowItem?
    init(id: String, date: Date? = nil, text: String, make: @escaping @MainActor () -> LibraryRowItem) {
        self.id = id; self.date = date; self.text = text; self.make = make
    }
    func resolve() -> LibraryRowItem {
        if let cached { return cached }
        var row = make(); row.day = day; cached = row; return row
    }
}

@MainActor
final class LibrarySectionHost {
    let list = LibraryListView()
    var storeVersion = ""
    var storeWatch: Task<Void,Never>?
    var loaded = false
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
    isolated deinit { preparation?.cancel(); worker?.cancel(); append?.cancel(); storeWatch?.cancel() }
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
