import AppKit
import OpenEngine

/// Section 3 owns media actions; section 6 owns extension actions. Neither hook changes
/// Chromium's surviving order. Actions use the menu session's single-completion path.
@MainActor
struct PageContextMenuHooks {
  struct Item {
    let title: String
    var isEnabled = true
    let action: @MainActor () -> Void
  }
  var mediaItems: (OEContextMenu) -> [Item] = { _ in [] }
  var extensionItems: (OEContextMenu) -> [Item] = { _ in [] }

  init(manageExtensions: @escaping @MainActor () -> Void) {
    extensionItems = { request in
      return [Item(title: "Manage Extensions", action: manageExtensions)]
    }
  }
}
