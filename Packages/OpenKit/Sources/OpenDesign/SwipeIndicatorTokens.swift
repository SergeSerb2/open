import CoreGraphics
import QuartzCore

/// Open's two-finger swipe indicator (page-platform §4.4.2). Guesses pending capture C-S1.
public enum SwipeIndicatorMetrics {
    public static let diameter: CGFloat = 40
    /// From the page view edge when fully revealed.
    public static let edgeInset: CGFloat = 16
    public static let glyphPointSize: CGFloat = 17
    /// Fill alpha = `baseAlpha + (1 − baseAlpha) × progress`.
    public static let baseAlpha: CGFloat = 0.35
    /// At progress 1 the circle grows to this scale with `Motion.toastIn`.
    public static let readyScale: CGFloat = 1.12
    /// Completed: fade out while the page navigates.
    public static let completedFade: CFTimeInterval = 0.18
    /// Cancelled: slide back to hidden with ease-out.
    public static let cancelledSlide: CFTimeInterval = 0.20
    /// Reduce Motion: the circle fades in at its final position.
    public static let reduceMotionFade: CFTimeInterval = 0.12

    /// The circle's leading x in the page view for `progress` (back swipes; forward mirrors it):
    /// `−diameter` (hidden) at 0, `edgeInset` at 1.
    public static func offset(progress: Double) -> CGFloat {
        let p = CGFloat(min(1, max(0, progress)))
        return -diameter + (diameter + edgeInset) * p
    }
}
