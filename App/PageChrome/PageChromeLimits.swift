import Foundation
import OpenEngine

/// Bound text before AppKit copies it. Each displayed string is at most 10 KiB
/// (far below allocator ceilings); at most eight requests per page are retained.
@MainActor
enum PageChromeLimits {
  static let dialogTextBytes = 10240
  static let urlBytes = 65536
  static let pendingRequests = 8

  static func dialogText(_ text: String) -> String {
    guard text.utf8.count > dialogTextBytes else { return text }
    // Reserve the ellipsis's three bytes, then back up past any partial UTF-8 scalar.
    // The only temporary byte buffer is at most 10,237 bytes.
    var bytes = Array(text.utf8.prefix(dialogTextBytes - 3))
    while !bytes.isEmpty {
      if let prefix = String(bytes: bytes, encoding: .utf8) { return prefix + "…" }
      bytes.removeLast()
    }
    return "…"
  }
}
