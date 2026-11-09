import AppKit

/// Presenters call this only for windows they create. Native remote children never opt in.
/// Pass false before installing an explicit appearance: this removes tracking and
/// resets a still-installed host pin to nil. An appearance installed by another
/// owner is left intact. Pass true to install and track inherited content appearance.
@MainActor
public protocol WindowContentAppearanceHost: AnyObject {
    func contentAppearanceDidChange(for window: NSWindow, inheritsAppearance: Bool)
}
