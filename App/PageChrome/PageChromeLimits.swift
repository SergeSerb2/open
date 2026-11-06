import Foundation
import OpenEngine

/// Checkpoint bounds, checked before AppKit copies page text. The largest
/// accepted string is 8 KiB; at most eight requests per page are retained.
@MainActor
enum PageChromeLimits {
  static let messageBytes = 8192
  static let promptBytes = 4096
  static let urlBytes = 65536
  static let pendingRequests = 8

  static func dialogFailure(_ dialog: OEJavaScriptDialog) -> String? {
    if dialog.message.utf8.count > messageBytes { return "Page dialog exceeds 8192 UTF-8 bytes." }
    if dialog.defaultPromptText.utf8.count > promptBytes { return "Page prompt exceeds 4096 UTF-8 bytes." }
    return nil
  }
}
