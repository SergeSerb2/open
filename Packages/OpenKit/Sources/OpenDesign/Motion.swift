import Foundation
import QuartzCore
import AppKit

/// Spring parameters use SwiftUI-style response and damping. Window motion is
/// fitted to capture session 2 (docs/plans/app-shell.md §3.3); other tokens remain
/// estimates from the first capture. Keep animation parameters in these tokens.
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

/// Motion tokens. Evidence and remaining estimates: docs/design.md §2.4.
public enum Motion {
    /// Process-only automation negative control; nil on the shipping path.
    @MainActor public static var sidebarDelayOverride: CFTimeInterval?
    /// Theme editor container motion; PROVISIONAL, plan §5.10.
    public static let editorOpen = SpringToken(response: 0.25, dampingFraction: 0.85)
    public static let editorFade: CFTimeInterval = 0.12
    public static let editorCloseScale: Double = 0.96
    public static let editorKnobReturn = SpringToken(response: 0.2, dampingFraction: 0.85)
    /// Sidebar completion guesses until unread motion is captured.
    public static let unreadAppear = SpringToken(response: 0.2, dampingFraction: 0.8)
    public static let unreadClearFade: CFTimeInterval = 0.12
    /// Space page slide: capture session 2 V 35.05 / 43.63 s, response 0.20 s.
    public static let spaceSwitch = SpringToken(response: 0.20, dampingFraction: 1.0)
    /// Snap after a two-finger swipe ends.
    public static let spaceSwipeSnap = SpringToken(response: 0.26, dampingFraction: 0.92)
    /// Background cross-fade: linear, 0.21 s; unchanged from the first capture fit.
    /// Session 2 used equal themes and did not re-measure the cross-fade.
    public static let themeCrossfade: CFTimeInterval = 0.21
    public static var themeCrossfadeTiming: CAMediaTimingFunction { CAMediaTimingFunction(name: .linear) }
    /// Row hover fill fade in and out.
    public static let hoverFade: CFTimeInterval = 0.08
    /// Selected fill moving to a new row.
    public static let selectionFade: CFTimeInterval = 0.12
    /// Folder expand and collapse, row insert and remove (< 0.5 s measured).
    public static let rowStructure: CFTimeInterval = 0.22
    /// S2 folder motion fit: RE interaction-states §20.12 (not general row edits).
    public static let folderExpand: CFTimeInterval = 0.20
    public static let folderCollapse: CFTimeInterval = 0.25
    public static var folderExpandTiming: CAMediaTimingFunction { easeOut }
    public static var folderCollapseTiming: CAMediaTimingFunction { CAMediaTimingFunction(name: .default) }
    /// Tooltip fade in and out.
    public static let tooltipFade: CFTimeInterval = 0.12
    /// Sidebar hide and show (Cmd+S) slide.
    public static let sidebarToggle = SpringToken(response: 0.10, dampingFraction: 0.95)
    /// Capture session 2, V 26.63 s; app-shell §3.3: 2.9 pt overshoot on 223 pt travel.
    public static let revealCardIn = SpringToken(response: 0.164, dampingFraction: 0.81)
    public static let revealCardOut: CFTimeInterval = 0.105
    /// Process-local automation override; never changes the system preference.
    @MainActor public static var reduceMotionOverride: Bool?
    @MainActor public static var reducesMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
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
    // Media plan §13.6: guess from the measured 0.20 s Space spring (§20.12); pending mini-player O9 capture.
    public static let miniPlayerStack = SpringToken(response: 0.2, dampingFraction: 1)
    public static let miniPlayerResize: CFTimeInterval = 0.2
    public static let miniPlayerTitle: CFTimeInterval = 0.12
    public static let miniPlayerReveal: CFTimeInterval = 0.15
    public static let miniPlayerAppearDelay: CFTimeInterval = 0.05
    public static let miniPlayerDisappear: CFTimeInterval = 0.12
    public static let reducedMedia: CFTimeInterval = 0.1
    public static let pipPresentAlpha: CFTimeInterval = 0.1
    public static let pipPresent = SpringToken(response: 0.3, dampingFraction: 1)
    public static let pipFade: CFTimeInterval = 0.15
    public static let pipControlsHide: CFTimeInterval = 0.3
    /// Folder card fade in ≈ 0.08 s, out ≈ 0.10 s (V 46.11–46.19, 46.36–46.46 s; one sample).
    public static let previewIn: CFTimeInterval = 0.08
    public static let previewOut: CFTimeInterval = 0.10
    public static let previewSwap: CFTimeInterval = 0.10
    public static let bannerIn: CFTimeInterval = 0.22
    public static let bannerOut: CFTimeInterval = 0.18
    public static let pipBackToTab: CFTimeInterval = 0.25
}
