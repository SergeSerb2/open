import Foundation

/// The final native view's viewport, in device pixels. The engine binds a
/// request to that view's current attachment and document, not just a timer.
public struct WebContentFrameViewport: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let scale: Double
    public init(width: Int, height: Int, scale: Double) {
        self.width = width; self.height = height; self.scale = scale
    }
}

public struct WebContentFrameReceipt: Sendable, Equatable {
    public let requestID: UUID
    public let viewport: WebContentFrameViewport
    public init(requestID: UUID, viewport: WebContentFrameViewport) {
        self.requestID = requestID; self.viewport = viewport
    }
}

@MainActor
public protocol WebContentFrameRequest: AnyObject {
    func cancel()
}

/// OpenEngine's App adapter implements this when the presentation seam lands.
/// A successful callback means this view has presented the matching document
/// and viewport after the request. A matching retained surface is sufficient.
/// Close, detach, document/renderer loss and supersession cancel with nil.
/// Completion is once-only, on the main actor, and may be synchronous.
@MainActor
public protocol WebContentFramePresentation: AnyObject {
    /// Nil means unavailable/refused, never successful. No deadline reveals
    /// live content when the engine cannot produce a qualifying receipt.
    func firstFramePresented(at viewport: WebContentFrameViewport, requestID: UUID,
                             completion: @escaping @MainActor (WebContentFrameReceipt?) -> Void)
        -> (any WebContentFrameRequest)?
}
