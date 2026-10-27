import Foundation
import OpenEngine

/// Bounds apply before App-owned UI copies or recursive menu construction.
/// Largest accepted text payload is 64 KiB (a URL); menu copies have at most
/// 128 nodes and 8 levels. No PartitionAlloc buffer is allocated by this layer;
/// upstream OE request decoding remains the engine's responsibility.
@MainActor
enum PageChromeLimits {
  // Chromium truncated the real long ASCII alert to 10240 bytes before
  // this callback. Keep
  // our limit below that boundary so a real page can prove refusal.
  static let messageBytes = 8 * 1024
  static let promptBytes = 4096
  static let urlBytes = 64 * 1024
  static let selectionBytes = 16 * 1024
  static let pendingRequests = 8
  static let menuNodes = 128
  static let menuDepth = 8
  static func dialogFailure(_ dialog: OEJavaScriptDialog) -> String? {
    if dialog.message.utf8.count > messageBytes { return "Page dialog exceeds 8192 UTF-8 bytes." }
    if dialog.defaultPromptText.utf8.count > promptBytes { return "Page prompt exceeds 4096 UTF-8 bytes." }
    return nil
  }
  static func menuFailure(_ menu: OEContextMenu) -> String? {
    if menu.selectionText.utf8.count > selectionBytes { return "Menu selection exceeds 16384 UTF-8 bytes." }
    if [menu.linkURL, menu.sourceURL, menu.pageURL].compactMap({ $0 }).contains(where: { $0.absoluteString.utf8.count > urlBytes }) {
      return "Menu URL exceeds 65536 UTF-8 bytes."
    }
    var count = 0
    func visit(_ items: [OEContextMenuItem], depth: Int) -> Bool {
      guard depth <= menuDepth, items.count <= menuNodes else { return false }
      for item in items {
        count += 1
        guard count <= menuNodes, item.title.utf8.count <= 1024 else { return false }
        if !item.submenu.isEmpty, !visit(item.submenu, depth: depth + 1) { return false }
      }
      return true
    }
    return visit(menu.items, depth: 1) ? nil : "Menu exceeds 128 items, 8 levels or a 1024-byte title."
  }
}
