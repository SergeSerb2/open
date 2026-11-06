import AppKit
import OpenExtensionsUI

/// Retained by AppDelegate; the menu's delegate is weak. Build only when tracking starts.
@MainActor
final class ExtensionsMainMenuProvider: NSObject, NSMenuDelegate {
  unowned let app: AppDelegate
  private var injected: [NSMenuItem] = []
  init(app: AppDelegate) { self.app = app }
  func menuNeedsUpdate(_ menu: NSMenu) {
    for item in injected where item.menu === menu { menu.removeItem(item) }
    injected.removeAll()
    // The first Little Open frame precedes its browser. Do not borrow a main
    // window's actions during that gap.
    if app.keyLittleOpen != nil && app.littleOpenExtensionFactory() == nil { return }
    guard let factory = app.littleOpenExtensionFactory() ?? NSApp.keyWindow.flatMap({ app.factory(forKeyWindow: $0) })
      ?? app.frontWindowController.flatMap({ app.hostFactories[$0.windowID] }) else { return }
    let built = ExtensionsMenuBuilder.menu(actions: factory.extensions.context.actions, kind: .bar,
      run: { [weak factory] id, source in factory?.extensions.run(id, source: source) }, command: { _ in })
    // Keep the registry's existing hidden picker and Manage/Add commands and key targets.
    let actions = built.items.dropLast(2)
    for item in actions {
      built.removeItem(item); menu.insertItem(item, at: injected.count); injected.append(item)
    }
  }
}
