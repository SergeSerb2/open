import AppKit

/// Groups native phase/momentum events, with an idle fallback for wheel mice.
@MainActor
final class EditorScrollGesture {
    private var timer: Timer?
    private var finishAction: (@MainActor () -> Void)?

    func update(_ event: NSEvent, change: @MainActor () -> Void,
                finish: @escaping @MainActor () -> Void) {
        if event.phase.contains(.began), finishAction != nil { self.finish() }
        timer?.invalidate(); timer = nil
        // Starting the model gesture may finish another control's gesture.
        // Install our completion only after that first change has returned.
        change()
        finishAction = finish
        if event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended)
            || event.momentumPhase.contains(.cancelled) {
            self.finish()
        } else if event.phase.contains(.ended) || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            let delay = event.phase.contains(.ended) ? 0.08 : 0.15
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func finish() {
        timer?.invalidate(); timer = nil
        let action = finishAction; finishAction = nil
        action?()
    }
}
