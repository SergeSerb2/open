import AppKit
import OpenSettings

/// Changes only this process's icon. The signed application bundle is never written.
@MainActor final class ApplicationIconController {
  unowned let app: AppDelegate
  private var restoreScheduled = false
  private(set) var appliedID = "openDefault"
  private(set) var errorText = ""
  private(set) var restoreStartedMs: Double?
  private(set) var restoreElapsedMs: Double?
  private(set) var appliedImage: NSImage?
  init(app: AppDelegate) { self.app = app }

  @discardableResult func apply(id: String) -> String? {
    guard let option = AppIconOption(rawValue: id) else {
      errorText = "This application icon is not available."; return errorText
    }
    let image: NSImage?
    if option == .openDefault { image = nil }
    else {
      guard let rendered = AppIconArtwork.image(for: option) else {
        errorText = "The application icon could not be rendered. Try selecting it again."; return errorText
      }
      image = rendered
    }
    NSApp.applicationIconImage = image
    appliedImage = image; appliedID = id; errorText = ""
    return nil
  }

  /// Called only after the first window and first web paint (or the existing no-paint
  /// deadline). Queue the render after that content turn; never construct Settings here.
  func restoreAfterContent() {
    guard !restoreScheduled, app.windowControllers.contains(where: { $0.window?.isVisible == true }) else { return }
    restoreScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.app.shutdownPrepared, !self.app.terminationRequested else { return }
      let started = LaunchTiming.shared.elapsedMilliseconds
      self.restoreStartedMs = started
      LaunchTiming.shared.mark("appIconRestoreStarted")
      let error = self.apply(id: UserDefaults.standard.string(forKey: "open.appIcon.selectedID") ?? "openDefault")
      self.restoreElapsedMs = LaunchTiming.shared.elapsedMilliseconds - started
      LaunchTiming.shared.mark("appIconRestored")
      if let error { self.app.settingsPresenter.settings.appIcon.errorText = error }
    }
  }
}
