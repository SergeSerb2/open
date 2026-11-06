import AppKit

/// Immutable native resources shared by every Find bar in the process.
/// Static initialization stays lazy; no pane or window owns these values.
@MainActor
enum FindBarResources {
  static let queryFont = NSFont.systemFont(ofSize: 13)
  static let countFont: NSFont? = {
    let features: [[NSFontDescriptor.FeatureKey: Int]] = [
      [.typeIdentifier: 37, .selectorIdentifier: 1], [.typeIdentifier: 38, .selectorIdentifier: 1]]
    return NSFont(descriptor: NSFont.systemFont(ofSize: 12).fontDescriptor.addingAttributes([.featureSettings: features]), size: 12)
  }()
  static let search = symbol("magnifyingglass", size: 15, title: nil)
  static let previous = symbol("chevron.up", size: 16, title: "Previous Match")
  static let next = symbol("chevron.down", size: 16, title: "Next Match")
  static let close = symbol("xmark", size: 16, title: "Close Find")
  static let light = Palette(dark: false)
  static let dark = Palette(dark: true)
  static let error = NSColor(displayP3Red: 0.788, green: 0.2, blue: 0.2, alpha: 1)
  static let separator = NSColor(displayP3Red: 0, green: 0, blue: 0, alpha: 0.10)
  static let shadow = NSColor(displayP3Red: 0.082, green: 0.110, blue: 0.196, alpha: 1)

  struct Palette {
    let background: NSColor
    let text: NSColor
    let tint: NSColor
    init(dark: Bool) {
      background = NSColor(displayP3Red: dark ? 0.082 : 0.980, green: dark ? 0.110 : 0.984, blue: dark ? 0.188 : 1, alpha: 1)
      text = dark ? NSColor.white.withAlphaComponent(0.80)
        : NSColor(displayP3Red: 0.0549, green: 0.0588, blue: 0.0627, alpha: 0.90)
      tint = NSColor(displayP3Red: dark ? 0.980 : 0.055, green: dark ? 0.984 : 0.059, blue: dark ? 1 : 0.063, alpha: dark ? 0.90 : 0.80)
    }
  }
  static func image(_ name: String) -> NSImage? {
    switch name {
    case "chevron.up": previous
    case "chevron.down": next
    case "xmark": close
    default: nil
    }
  }
  private static func symbol(_ name: String, size: CGFloat, title: String?) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: title)?
      .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
  }
}
