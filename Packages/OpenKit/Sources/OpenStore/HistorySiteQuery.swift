import Foundation
import SQLite3

extension HistoryStore {
    /// Newest visited URLs whose URL contains `phrase` as adjacent FTS tokens (for example
    /// "linear app" for linear.app). The caller filters hosts exactly. Used by the Recents
    /// hover card (docs/re/live-data.md §3.4); runs on this actor, never at launch.
    public func recentURLs(matchingURLPhrase phrase: String, limit: Int = 200) -> [HistoryMatch] {
        open()
        guard let db else { return [] }
        let tokens = phrase.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let query = "url : \"" + tokens.joined(separator: " ") + "\""
        let statement = db.prepare("SELECT u.url, u.title, u.visit_count, u.typed_count, u.last_visit FROM history_fts f JOIN urls u ON u.id = f.rowid WHERE history_fts MATCH ? ORDER BY u.last_visit DESC LIMIT ?")
        defer { sqlite3_finalize(statement) }
        db.bindText(statement, 1, query)
        db.bindInt(statement, 2, Int64(max(0, min(limit, 1_000))))
        var rows: [HistoryMatch] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = db.columnText(statement, 0), let url = URL(string: text) else { continue }
            rows.append(HistoryMatch(url: url, title: db.columnText(statement, 1) ?? "",
                visitCount: Int(db.columnInt(statement, 2)), typedCount: Int(db.columnInt(statement, 3)),
                lastVisit: Date(timeIntervalSince1970: db.columnDouble(statement, 4)), score: 0))
        }
        return rows
    }
}
