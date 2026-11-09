#if OPEN_AUTOMATION
import AppKit

/// Keep clipboard data inside the App. The harness receives no user formats or values.
@MainActor
enum AutomationPasteboard {
  private static var saved: [[(NSPasteboard.PasteboardType, Data)]]?

  static func preserve() -> Bool {
    guard saved == nil else { return false }
    saved = (NSPasteboard.general.pasteboardItems ?? []).map { item in
      // Keep each item's types in their original order (richest first).
      item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
    return true
  }

  static func restore() -> Bool {
    guard let values = saved else { return false }
    saved = nil
    let board = NSPasteboard.general
    board.clearContents()
    let items = values.map { formats in
      let item = NSPasteboardItem()
      for (type, data) in formats { item.setData(data, forType: type) }
      return item
    }
    return items.isEmpty || board.writeObjects(items)
  }
}
#endif
