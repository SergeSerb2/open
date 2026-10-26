import QuartzCore

/// Motion tokens. PROVISIONAL: Arc stores its spring and duration numbers in
/// compiled code, not in strings (docs/re/design-tokens.md §4.3). These are our
/// best estimates from 4 fps captures and must be re-measured with a high-rate
/// capture. Keep every animation on these tokens so a later fix is one edit.
public struct SpringToken: Sendable, Hashable {
    /// SwiftUI-style response (seconds) and damping fraction.
    public var response: Double
    public var dampingFraction: Double

    public init(response: Double, dampingFraction: Double) {
        self.response = response; self.dampingFraction = dampingFraction
    }

    /// A Core Animation spring with the same response and damping.
    public func animation(keyPath: String) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = 1
        let omega = 2 * Double.pi / response
        a.stiffness = omega * omega
        a.damping = 2 * dampingFraction * omega
        a.initialVelocity = 0
        a.duration = a.settlingDuration
        return a
    }
}

public enum Motion {
    /// Space page slide after a click or shortcut. provisional.
    public static let spaceSwitch = SpringToken(response: 0.32, dampingFraction: 1.0)
    /// Snap after a two-finger swipe ends. provisional.
    public static let spaceSwipeSnap = SpringToken(response: 0.28, dampingFraction: 0.9)
    /// Row hover fill fade in/out. provisional.
    public static let hoverFade: CFTimeInterval = 0.08
    /// Selected fill moving to a new row. provisional.
    public static let selectionFade: CFTimeInterval = 0.12
    /// Folder expand/collapse and row insert/remove. provisional.
    public static let rowStructure: CFTimeInterval = 0.2
    /// Theme cross-fade on Space change (Arc's shader has a `progress` mix). provisional.
    public static let themeCrossfade: CFTimeInterval = 0.3
    public static var easeInOut: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeInEaseOut) }
    public static var easeOut: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }
}
