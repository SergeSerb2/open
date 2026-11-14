import Foundation
import CoreGraphics

/// A compositor presentation, not renderer readiness, paint, RAF or a display tick.
public struct WebContentPresentedFrame: Sendable {
    public let generation: Int
    public let viewportSize: CGSize
    public let backingScale: CGFloat
    /// Host monotonic time, in the same time base as CACurrentMediaTime().
    public let presentedAt: TimeInterval

    public init(generation: Int, viewportSize: CGSize, backingScale: CGFloat, presentedAt: TimeInterval) {
        self.generation = generation; self.viewportSize = viewportSize
        self.backingScale = backingScale; self.presentedAt = presentedAt
    }
}

@MainActor
public protocol WebContentSurfaceRetention: AnyObject {
    /// Idempotently stop observing. Never clear the currently displayed surface.
    /// The engine also invalidates the request on navigation, replacement or close.
    func cancel()
}

public enum WebContentPresentationFailure: Error, Sendable {
    case invalidated
    case unavailable
}

/// Optional OpenEngine capability, adapted by the App alongside WebContent.
/// OpenKit never imports Chromium or OpenEngine. Older engines do not conform.
@MainActor
public protocol WebContentRetainedSurfaceResizing: AnyObject {
    /// Arm BEFORE the shell writes the native view's final geometry once.
    /// This call does not resize the NSView itself. Keep its current on-screen
    /// pixels until a frame at this logical size and scale is actually presented.
    /// Deliver at most one completion on the main actor, after the engine callback
    /// has unwound; it may close or replace the page. Nil refuses the capability.
    func retainSurfaceForResize(
        to viewportSize: CGSize, backingScale: CGFloat, generation: Int,
        completion: @escaping @MainActor (Result<WebContentPresentedFrame, WebContentPresentationFailure>) -> Void
    ) -> (any WebContentSurfaceRetention)?
}
