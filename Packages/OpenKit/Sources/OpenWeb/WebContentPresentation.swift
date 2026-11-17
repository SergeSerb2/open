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

extension WebContentPresentedFrame {
    /// How far a presentation time may lie after the moment it is checked.
    /// On macOS, Chromium reports the frame's target display time
    /// (`feedback.timestamp = display_time` in ca_layer_tree_coordinator.mm),
    /// in the same mach_absolute_time base as CACurrentMediaTime(). The
    /// receipt can arrive before that display time: up to 15 ms seen at 2x
    /// on the M1. 100 ms covers more than two refreshes at 30 Hz and still
    /// refuses a value from another clock.
    public static let maximumDisplayLead: TimeInterval = 0.1

    /// True when `presentedAt` is a plausible presentation time for a request
    /// armed at `armedAt` (0 when unknown), checked at `now`.
    public static func isValidPresentationTime(_ presentedAt: TimeInterval,
                                               armedAt: TimeInterval,
                                               now: TimeInterval) -> Bool {
        presentedAt.isFinite && presentedAt > 0 && presentedAt >= armedAt
            && presentedAt <= now + maximumDisplayLead
    }
}

/// Kill switches for the consumers of the engine frame-presentation seam.
/// Each consumer stays off (the shell keeps main's path) until its own lane
/// proves it on the adopted engine: functional rows plus one timing set
/// (lead ruling 2026-11-17 08:45). A proof run turns one on without a rebuild
/// with a launch argument, for example `-OpenSeamLibraryClose YES`.
public enum FramePresentationConsumer: String, CaseIterable, Sendable {
    /// D3: Library close holds the page until the resized frame is presented.
    case libraryClose = "OpenSeamLibraryClose"
    /// NT: the Space-switch cover waits for the destination frame.
    case spaceCover = "OpenSeamSpaceCover"
    /// Split: the START pane resize holds the old surface until presentation.
    case splitResize = "OpenSeamSplitResize"

    /// Off unless the user defaults (or a launch argument) turn it on.
    public var isEnabled: Bool { UserDefaults.standard.bool(forKey: rawValue) }
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
/// OpenKit never imports Chromium or OpenEngine. Baseline adapters return nil.
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
