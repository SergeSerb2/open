#if OPEN_AUTOMATION
import Foundation
import OpenModel
import OpenSettings

extension AutomationController {
  func runHistoryCommand(_ cmd: String, _ args: [String: Any]) async throws -> Any {
    let requested: ProfileID?
    if let raw = args["profile"] as? String {
      guard let uuid = UUID(uuidString: raw), app.model.profile(id: ProfileID(rawValue: uuid)) != nil else { throw Failure(message: "unknown History Profile") }
      requested = ProfileID(rawValue: uuid)
    } else { requested = nil }
    let id = requested ?? (try? window.focusedProfile?.id) ?? app.model.defaultProfile?.id
    guard let id, let store = app.stores.history(for: id) else { throw Failure(message: "unknown History Profile") }
    await app.stores.flushHistory()
    switch cmd {
    case "history-state":
      let rows = await store.search(args["query"] as? String ?? "", limit: 1_000)
      let file = await store.fileURL
      return ["profile": id.description, "file": file.path,
        "rows": rows.map { ["url": $0.url.absoluteString, "title": $0.title, "visits": $0.visitCount, "typed": $0.typedCount] as [String: Any] },
        "enqueueMilliseconds": app.stores.historyEnqueueSamples, "writes": app.stores.historyWriteCount] as [String: Any]
    case "history-clear":
      let range: ClearDataRange
      if let raw = args["range"] as? String {
        guard let selected = ClearDataRange(rawValue: raw) else { throw Failure(message: "unknown History time range") }
        range = selected
      } else { range = .all }
      let error = await app.settingsPresenter.clearBrowsingData(profileID: id, kinds: .history, range: range)
      return ["error": error ?? ""]
    case "library-history-state":
      guard let library = app.settingsPresenter.library else { throw Failure(message: "Library not open") }
      if args["selectProfile"] as? Bool == true { library.historyProfileID = id; await library.reloadHistory() }
      return ["profile": library.historyProfileID.description, "rows": library.historyRows.map { ["url": $0.url.absoluteString, "title": $0.title] }]
    case "library-history-delete":
      guard let library = app.settingsPresenter.library else { throw Failure(message: "Library not open") }
      if args["all"] as? Bool == true { await library.clearHistoryConfirmed() }
      else {
        library.requestDeleteHistory((args["urls"] as? [String] ?? []).compactMap(URL.init(string:)))
        await library.deleteHistoryConfirmed()
      }
      return library.statusText
    default: throw Failure(message: "unknown History command")
    }
  }
}
#endif
