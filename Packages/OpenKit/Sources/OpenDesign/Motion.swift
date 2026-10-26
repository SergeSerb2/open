import Foundation
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

/// Every number below is PROVISIONAL. Evidence: docs/re/interaction-states.md §9–§10
/// (frames ≈ 0.47 s apart, so only progress points and upper bounds exist).
public enum Motion {
    /// Sidebar completion guesses until unread motion is captured.
    public static let unreadAppear = SpringToken(response: 0.2, dampingFraction: 0.8)
    public static let unreadClearFade: CFTimeInterval = 0.12
    /// Space page slide after a click or shortcut. Visible part ≈ 0.2–0.35 s; the
    /// slide leads the background fade (A0222: slide 0.65, fade 0.53).
    public static let spaceSwitch = SpringToken(response: 0.3, dampingFraction: 1.0)
    /// Snap after a two-finger swipe ends.
    public static let spaceSwipeSnap = SpringToken(response: 0.26, dampingFraction: 0.92)
    /// Background cross-fade on a Space switch: linear, 0.21 s. With the 0.3 s
    /// critically damped slide this reproduces both measured progress pairs
    /// (slide 0.65 / fade 0.53 and slide 0.88 / fade 0.77, A0222 and A0227).
    public static let themeCrossfade: CFTimeInterval = 0.21
    public static var themeCrossfadeTiming: CAMediaTimingFunction { CAMediaTimingFunction(name: .linear) }
    /// Row hover fill fade in and out.
    public static let hoverFade: CFTimeInterval = 0.08
    /// Selected fill moving to a new row.
    public static let selectionFade: CFTimeInterval = 0.12
    /// Folder expand and collapse, row insert and remove (< 0.5 s measured).
    public static let rowStructure: CFTimeInterval = 0.22
    /// Tooltip fade in and out.
    public static let tooltipFade: CFTimeInterval = 0.12
    /// Sidebar hide and show (Cmd+S) slide.
    public static let sidebarToggle = SpringToken(response: 0.3, dampingFraction: 1.0)
    public static var easeInOut: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeInEaseOut) }
    public static var easeOut: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }

    /// Spring progress at time `t` (critically damped or underdamped), 0 → 1.
    /// Used by interactive drivers that step a spring per frame.
    public static func springProgress(_ spring: SpringToken, at t: Double) -> Double {
        let omega = 2 * Double.pi / spring.response
        let zeta = spring.dampingFraction
        if zeta >= 1 { return 1 - (1 + omega * t) * exp(-omega * t) }
        let wd = omega * (1 - zeta * zeta).squareRoot()
        return 1 - exp(-zeta * omega * t) * (cos(wd * t) + zeta * omega / wd * sin(wd * t))
    }
}

extension Motion {
    /// Guesses centralized per media plan §4.2.7 and §4.4.7; reduce motion uses fades.
    /// Finite fallback approved after the native offscreen transition produced no effect keys.
    public static let rowMediaFallback: CFTimeInterval = 0.25
    public static let miniPlayerStack = SpringToken(response: 0.3, dampingFraction: 1)
    public static let miniPlayerResize: CFTimeInterval = 0.2
    public static let miniPlayerTitle: CFTimeInterval = 0.12
    public static let miniPlayerReveal: CFTimeInterval = 0.15
    public static let miniPlayerAppearDelay: CFTimeInterval = 0.05
    public static let miniPlayerDisappear: CFTimeInterval = 0.12
    public static let reducedMedia: CFTimeInterval = 0.1
    public static let pipPresent = SpringToken(response: 0.3, dampingFraction: 1)
    public static let pipFade: CFTimeInterval = 0.15
    public static let pipControlsHide: CFTimeInterval = 0.3
    public static let previewIn: CFTimeInterval = 0.15
    public static let previewOut: CFTimeInterval = 0.10
    public static let previewSwap: CFTimeInterval = 0.10
    public static let bannerIn: CFTimeInterval = 0.22
    public static let bannerOut: CFTimeInterval = 0.18
    public static let pipBackToTab: CFTimeInterval = 0.25
}
