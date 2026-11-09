import AppKit

/// Presenters call this only for windows they create, after selecting an
/// explicit appearance or inheritance. Native remote windows never opt in.
@MainActor
public protocol WindowContentAppearanceHost: AnyObject {
    func contentAppearanceDidChange(for window: NSWindow, inheritsAppearance: Bool)
}
