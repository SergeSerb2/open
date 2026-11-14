import AppKit
import OpenWeb

/// One bounded set of real, visible panes. No timer is a presentation event.
@MainActor
final class LibraryClosePresentation {
    struct Target {
        let source: any WebContentRetainedSurfaceResizing
        let view: NSView
        let size: CGSize
        let scale: CGFloat
        let isCurrent: @MainActor () -> Bool
    }

    let generation: Int
    let requestedAt: CFTimeInterval
    let targets: [Target]
    private(set) var frames: [Int: WebContentPresentedFrame] = [:]
    private var retentions: [any WebContentSurfaceRetention] = []
    private var deadline: Task<Void, Never>?
    private var committed = false
    private var cancelled = false
    private var delivered = false
    private(set) var timedOut = false
    var onReady: (@MainActor () -> Void)?
    var onDeadline: (@MainActor () -> Void)?
    var onInvalidated: (@MainActor () -> Void)?

    var isCurrent: Bool { targets.allSatisfy { $0.isCurrent() } }
    var presentedAt: CFTimeInterval { frames.values.map(\.presentedAt).max() ?? 0 }
    var evidence: [[String: Any]] {
        targets.enumerated().map { index, target in
            ["viewport": [target.size.width, target.size.height], "scale": target.scale,
             "presentedAt": frames[index]?.presentedAt ?? 0, "presented": frames[index] != nil]
        }
    }

    init(generation: Int, requestedAt: CFTimeInterval, targets: [Target]) {
        self.generation = generation; self.requestedAt = requestedAt; self.targets = targets
    }

    isolated deinit {
        deadline?.cancel()
        for retention in retentions { retention.cancel() }
    }

    func arm() -> Bool {
        guard targets.count <= 4, isCurrent else { return false }
        for (index, target) in targets.enumerated() {
            guard let retention = target.source.retainSurfaceForResize(
                to: target.size, backingScale: target.scale, generation: generation,
                completion: { [weak self] result in
                    guard let self, !self.cancelled, !self.delivered else { return }
                    switch result {
                    case .success(let frame): self.presented(frame, index: index)
                    case .failure: self.onInvalidated?()
                    }
                }
            ) else { cancel(); return false }
            retentions.append(retention)
        }
        return true
    }

    func widthCommitted() {
        committed = true
        deliverIfReady()
        guard !cancelled, !delivered else { return }
        let remaining = max(0, requestedAt + 0.050 - CACurrentMediaTime())
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard let self, !self.cancelled, !self.delivered else { return }
            self.timedOut = true
            // Keep the old retained pixels (or the stationary cover) until a
            // genuine presentation arrives. Never expose a cleared live layer.
            self.onDeadline?()
        }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true; deadline?.cancel(); deadline = nil
        onReady = nil; onDeadline = nil; onInvalidated = nil
        let pending = retentions; retentions.removeAll()
        for retention in pending { retention.cancel() }
    }

    private func presented(_ frame: WebContentPresentedFrame, index: Int) {
        guard !cancelled, !delivered, frames[index] == nil else { return }
        guard isCurrent else { onInvalidated?(); return }
        let target = targets[index]
        guard frame.generation == generation, frame.viewportSize == target.size,
              frame.backingScale == target.scale, frame.presentedAt.isFinite,
              frame.presentedAt > 0, frame.presentedAt <= CACurrentMediaTime() else { return }
        frames[index] = frame
        deliverIfReady()
    }

    private func deliverIfReady() {
        guard committed, !cancelled, !delivered, frames.count == targets.count else { return }
        delivered = true; deadline?.cancel(); deadline = nil
        onReady?()
    }
}
