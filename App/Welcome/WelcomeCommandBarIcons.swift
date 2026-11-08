import AppKit
import OpenCommandBar

/// Created only when the command bar is shown for a Welcome tab. No network work.
@MainActor
final class WelcomeCommandBarIcons: CommandBarFaviconSource {
  private let image = WelcomeTab.faviconPNG.flatMap(NSImage.init(data:))
  func favicon(for pageURL: URL, loaded: @escaping @MainActor (URL) -> Void) -> NSImage? {
    WelcomeTab.matches(pageURL) ? image : nil
  }
}
