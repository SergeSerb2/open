import AppKit
import Observation
import OpenDesign
import OpenEngine
import OpenModel

/// Settings ▸ Advanced "Allow websites to get your theme data" (`open.advanced.allowSitesThemeData`,
/// off by default, as in Arc). Arc evidence (1.170.0 `strings -a`, next to
/// `Arc/BrowserExtensionsMainMenuProvider.swift`): page CSS custom properties `--arc-palette-*`
/// (12 roles) and `--arc-background-{gradient-color,gradient-overlay-color,simple-color}`.
/// LEAD 10:00: expose Arc's names for site compatibility and the same values under `--open-*`.
/// Capture C3-PB1-d (C-report-s6 §6) settles the list, format and values. Difference kept: Arc injects a
/// user stylesheet the page cannot see as a node; Open sets them inline on <html> (per-tab Space values).
@MainActor
enum ThemeData {
  static let defaultsKey = "open.advanced.allowSitesThemeData"
  static var enabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
  /// True once the setting was on in this process: only then can a page carry variables to remove.
  static private(set) var active = false
  private static var lastEnabled: Bool?

  /// The defaults observer's hook: flips re-apply (on) or remove (off) on every live page.
  static func settingMaybeChanged(app: AppDelegate) {
    let now = enabled
    guard now != lastEnabled else { return }
    let first = lastEnabled == nil
    lastEnabled = now
    if now { active = true; watchThemes(app: app) }
    if !(first && !now) { refreshAll(app: app) }
  }

  private static var watching = false
  /// While the setting is on, a Space theme edit re-applies to every live page (Space is @Observable).
  static func watchThemes(app: AppDelegate) {
    guard enabled, !watching else { return }
    watching = true
    withObservationTracking {
      for space in app.model.spaces { _ = space.theme }
    } onChange: {
      Task { @MainActor [weak app] in
        watching = false
        guard let app, enabled else { return }
        refreshAll(app: app); watchThemes(app: app)
      }
    }
  }
  /// A page committed or finished loading.
  static func pageChanged(_ host: EngineWebContentHost, factory: EngineWebContentHostFactory) {
    guard enabled || active else { return }
    if enabled { active = true; watchThemes(app: factory.app) }
    apply(variables(tabID: host.tabID, factory: factory), to: host.content)
  }
  /// Theme edits and window changes: the front window's shown tabs only.
  static func refreshVisible(app: AppDelegate) {
    guard enabled, let controller = app.frontWindowController, let factory = app.hostFactories[controller.windowID] else { return }
    for tab in factory.visibleTabs { if let host = factory.hosts[tab.id], !host.closed { apply(variables(tabID: tab.id, factory: factory), to: host.content) } }
  }

  /// Arc's palette variable names, in Arc's string order, mapped to Open's semantic palette roles.
  static let paletteNames: [(String, KeyPath<SemanticPalette, RGBA>)] = [
    ("foregroundPrimary", \.foregroundPrimary), ("foregroundSecondary", \.foregroundSecondary),
    ("foregroundTertiary", \.foregroundTertiary), ("maxContrastColor", \.maxContrast),
    ("minContrastColor", \.minContrast), ("backgroundExtra", \.backgroundExtra), ("background", \.background),
    ("focus", \.focus), ("hover", \.hover), ("cutoutColor", \.cutout), ("title", \.title), ("subtitle", \.subtitle),
  ]
  /// Every name Open may set (both prefixes), so turning the setting off can remove them all.
  static let allNames: [String] = {
    let suffixes = paletteNames.map { "palette-" + $0.0 } + ["background-gradient-color", "background-gradient-overlay-color", "background-simple-color"]
    return suffixes.flatMap { ["--arc-" + $0, "--open-" + $0] }
  }()

  /// Arc's default-theme values (capture C-report-s6 §6, PB1-d): the same in light and dark.
  static let defaultPalette: [String: String] = [
    "foregroundPrimary": "#3139FBFF", "foregroundSecondary": "#8489FBFF", "foregroundTertiary": "#ECEDFEFF",
    "maxContrastColor": "#212AFBFF", "minContrastColor": "#ECEDFEFF", "backgroundExtra": "#FDFDFFFF",
    "background": "#E9EAFEFF", "focus": "#9094FBFF", "hover": "#D3D4FDFF", "cutoutColor": "#ECEDFEFF",
    "title": "#0A0D4BFF", "subtitle": "#A6AAFBFF",
  ]

  /// The variables for a Space style. Capture PB1-d (C-report-s6 §6): uppercase `#RRGGBBAA`; values do
  /// not follow View › Appearance (Open uses the light palette); the default theme has the palette above and
  /// no background values; a one-colour theme sets `background-simple-color` = foregroundPrimary.
  /// GUESS: gradient values for multi-colour themes (only a one-colour theme was captured).
  static func variables(style: SpaceThemeStyle) -> [(String, String)] {
    var values: [(String, String)] = []
    if let palette = style.palette(for: .light) {
      for (name, path) in paletteNames { values.append(("palette-" + name, hex(palette[keyPath: path]))) }
      if case .blended(let base, let overlay) = style.fill {
        if base.count >= 2 {
          values.append(("background-gradient-color", hex(base[0])))
          if let first = overlay.first { values.append(("background-gradient-overlay-color", hex(first))) }
        } else {
          values.append(("background-simple-color", hex(palette.foregroundPrimary)))
        }
      }
    } else {
      for (name, _) in paletteNames { if let value = defaultPalette[name] { values.append(("palette-" + name, value)) } }
    }
    return values.flatMap { [("--arc-" + $0.0, $0.1), ("--open-" + $0.0, $0.1)] }
  }

  static func hex(_ color: RGBA) -> String {
    let srgb = color.nsColor.usingColorSpace(.sRGB) ?? color.nsColor
    func byte(_ v: CGFloat) -> String { String(format: "%02X", Int((max(0, min(1, v)) * 255).rounded())) }
    return "#" + byte(srgb.redComponent) + byte(srgb.greenComponent) + byte(srgb.blueComponent) + byte(srgb.alphaComponent)
  }

  /// The variables for one tab of a window (nil: setting off, or no Space theme for the tab).
  static func variables(tabID: ItemID, factory: EngineWebContentHostFactory) -> [(String, String)]? {
    guard enabled, let controller = factory.controller, let space = factory.space(for: tabID) else { return nil }
    return variables(style: controller.context.style(for: space))
  }

  /// Sets (or, when `values` is nil, removes) Open's theme variables on the page's <html>, through
  /// the Open world: the DOM is shared, so page scripts and stylesheets read them.
  static func apply(_ values: [(String, String)]?, to page: OEWebContent) {
    guard let url = page.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
    let set = values.map { Dictionary($0, uniquingKeysWith: { a, _ in a }) } ?? [:]
    guard let setJSON = try? JSONSerialization.data(withJSONObject: set), let namesJSON = try? JSONSerialization.data(withJSONObject: allNames),
          let setText = String(data: setJSON, encoding: .utf8), let namesText = String(data: namesJSON, encoding: .utf8) else { return }
    let source = "(() => { const s = document.documentElement && document.documentElement.style; if (!s) return false;"
      + " const set = \(setText); for (const n of \(namesText)) { if (n in set) s.setProperty(n, set[n]); else s.removeProperty(n); } return true; })()"
    Task { @MainActor in _ = try? await page.evaluateJavaScript(source, inWorld: .open) }
  }

  /// Re-applies to every live page of every window (setting change, theme change).
  static func refreshAll(app: AppDelegate) {
    for factory in app.hostFactories.values {
      for (tabID, host) in factory.hosts where !host.closed { apply(variables(tabID: tabID, factory: factory), to: host.content) }
    }
  }
}
