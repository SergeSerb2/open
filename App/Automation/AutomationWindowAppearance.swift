#if OPEN_AUTOMATION
import AppKit

extension AutomationController {
  /// Bounded, text-free appearance evidence for the real window's visible chrome.
  func chromeViewAppearances(in root: NSView?) -> [[String: String]] {
    guard let root else { return [] }
    var pending: [(NSView, Int)] = [(root, 0)]
    var result: [[String: String]] = []
    var visited = 0
    let names = ["Toast", "Preview", "Find", "Prompt", "CommandBar", "ThemeEditor", "BoostEditor", "Extension"]
    while let (view, depth) = pending.popLast(), visited < 512, result.count < 80 {
      visited += 1
      guard !view.isHiddenOrHasHiddenAncestor else { continue }
      let name = String(describing: type(of: view))
      if view === root || names.contains(where: name.contains) {
        result.append(["class": name, "appearance": view.effectiveAppearance.name.rawValue,
          "explicitAppearance": view.appearance?.name.rawValue ?? ""])
      }
      if depth < 24 { pending.append(contentsOf: view.subviews.prefix(512 - visited).map { ($0, depth + 1) }) }
    }
    return result
  }
}
#endif
