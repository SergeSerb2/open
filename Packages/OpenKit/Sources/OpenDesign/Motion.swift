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
    /// General row insert/remove. Folder expansion has dedicated tokens below.
    public static let rowStructure: CFTimeInterval = 0.22
    /// S2 folder motion fit: RE interaction-states §20.12 (not general row edits).
    public static let folderExpand: CFTimeInterval = 0.20
    public static let folderCollapse: CFTimeInterval = 0.25
    public static var folderExpandTiming: CAMediaTimingFunction { easeOut }
    public static var folderCollapseTiming: CAMediaTimingFunction { CAMediaTimingFunction(name: .default) }
    /// Provisional Little Open window fades, using the existing 0.12 s panel
    /// fade duration until capture C14-7 supplies its measured timing.
    public static let littleOpenFade: CFTimeInterval = 0.12
    /// Tooltip fade in and out.
    public static let tooltipFade: CFTimeInterval = 0.12
    /// Sidebar hide and show (Cmd+S) slide.
    public static let sidebarToggle = SpringToken(response: 0.10, dampingFraction: 0.95)
    /// C14-2 show: equivalent image fit, not Arc's internal native animation.
    /// Two marker fits agree within 0.48 pt; evidence: docs/re/sidebar-motion.md.
    public static let sidebarShowDuration: CFTimeInterval = 0.075834
    public static var sidebarShowTiming: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.01055, 0.50742, 0.55930, 0.98516)
    }
    public static func sidebarAnimation(keyPath: String, showing: Bool) -> CABasicAnimation {
        guard showing else { return sidebarToggle.animation(keyPath: keyPath) }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.duration = sidebarShowDuration
        animation.timingFunction = sidebarShowTiming
        return animation
    }
    /// Capture session 2, V 26.63 s; app-shell §3.3: 2.9 pt overshoot on 223 pt travel.
    public static let revealCardIn = SpringToken(response: 0.164, dampingFraction: 0.81)
    public static let revealCardOut: CFTimeInterval = 0.105
    /// Toast appear (page-platform §4.1.2, PG-1.9, PG-14 V 69.99–70.45 s): the pill grows from
    /// a small scale at the top center of its final frame with this spring (settled ≈ 0.46 s)
    /// while it fades in linearly.
    public static let toastIn = SpringToken(response: 0.32, dampingFraction: 0.8)
    public static let toastInScale: CGFloat = 0.3
    public static let toastFadeIn: CFTimeInterval = 0.12
    /// Toast exit: it shrinks back up toward its top center and fades out in ≈ 0.16 s
    /// (PG-14 V 74.95–75.11 s; the plan's 0.20 s fade to 0.96 was a guess before that capture).
    public static let toastOut: CFTimeInterval = 0.16
    public static let toastOutScale: CGFloat = 0.3
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
    /// Audio starts in a row: the title slides right and the speaker is revealed left to right
    /// (capture PB1-f, C-report-s6 §6: about 0.16 s, 47/75/89/95 % at 45/75/100/128 ms, no overshoot).
    public static let rowAudioReveal: CFTimeInterval = 0.16
    /// Quadratic ease-out, the closest standard curve to those four samples.
    public static let rowAudioRevealCurve: (Float, Float, Float, Float) = (0.25, 0.46, 0.45, 0.94)
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


/// The download start animation (Arc `DownloadToLibrary`, `ProjectileIconKeyframeAnimation`): a file
/// icon flies from the page to the sidebar Library button. Values are capture PB1-b (C-report-s10 (b),
/// Arc 1.172.2, 56 fps): the icon appears 0.17 s after the click at about 34 pt, rises 31 pt to its apex
/// after about 0.16 s, then falls with about 2,600 pt/s²; its horizontal speed is constant (about
/// −360 pt/s over that 330 pt flight); it grows to 47 pt at the apex and shrinks to 10 pt at the end;
/// the captured flight took about 0.90 s. Points use a top-left origin (y grows downward).
public struct DownloadFlight: Sendable, Equatable {
    public static let startDelay: CFTimeInterval = 0.17
    public static let rise: CGFloat = 31
    public static let gravity: CGFloat = 2600
    public static let startSize: CGFloat = 34
    public static let apexSize: CGFloat = 47
    public static let endSize: CGFloat = 10

    public let start: CGPoint
    public let target: CGPoint

    public init(start: CGPoint, target: CGPoint) { self.start = start; self.target = target }

    /// Launch speed upward that reaches `rise` under `gravity` (apex after about 0.154 s).
    static var launchSpeed: CGFloat { (2 * gravity * rise).squareRoot() }
    public var apexTime: CFTimeInterval { CFTimeInterval(Self.launchSpeed / Self.gravity) }
    /// Time to fall from the apex to the target's height. A target above the apex ends at the apex.
    public var duration: CFTimeInterval {
        let drop = max(0, target.y - (start.y - Self.rise))
        return apexTime + CFTimeInterval((2 * drop / Self.gravity).squareRoot())
    }
    /// Constant: the horizontal distance over the whole flight.
    public var horizontalSpeed: CGFloat { duration > 0 ? (target.x - start.x) / CGFloat(duration) : 0 }

    public func position(at time: CFTimeInterval) -> CGPoint {
        let t = CGFloat(min(max(0, time), duration))
        return CGPoint(x: start.x + horizontalSpeed * t,
                       y: start.y - Self.launchSpeed * t + Self.gravity * t * t / 2)
    }
    public func size(at time: CFTimeInterval) -> CGFloat {
        let t = min(max(0, time), duration)
        if t <= apexTime { return Self.startSize + (Self.apexSize - Self.startSize) * CGFloat(apexTime > 0 ? t / apexTime : 1) }
        let fall = duration - apexTime
        return Self.apexSize + (Self.endSize - Self.apexSize) * CGFloat(fall > 0 ? (t - apexTime) / fall : 1)
    }
}
