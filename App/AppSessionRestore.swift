import AppKit
import OpenModel

extension AppDelegate {
  /// Runs on the loaded snapshot, before T2 composes any native windows.
  /// UserDefaults is the only preference read; the sidebar model stays intact.
  func applyLaunchWindowPreference(to model: BrowserModel) {
    guard UserDefaults.standard.object(forKey: "open.advanced.restoreWindowsOnLaunch") as? Bool == false else { return }
    let standard = model.windows.filter { $0.style == .standard }
    let recent = standard.max { ($0.lastFocusedAt ?? .distantPast) < ($1.lastFocusedAt ?? .distantPast) }
    guard let space = recent.flatMap({ model.space(id: $0.focusedSpaceID) }) ?? model.spaces.first else { return }
    let state = BrowserWindowState(focusedSpaceID: space.id, selectedNodeBySpace: recent?.selectedNodeBySpace ?? [:])
    if let screen = NSScreen.main {
      let frame = screen.visibleFrame
      state.frameX = frame.midX - state.frameWidth / 2
      state.frameY = frame.midY - state.frameHeight / 2
    }
    // Little Open sessions are managed separately and never restored here.
    model.windows = [state]
  }
}
