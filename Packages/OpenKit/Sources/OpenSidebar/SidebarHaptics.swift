import AppKit
import OpenModel

/// One haptic path for sidebar and Library Space Manager interactions.
/// The preference is read at use, so a Settings change applies to an active drag.
@MainActor
public final class SidebarHaptics {
    private var insertion: Insertion?
    private struct Insertion: Equatable { let parent: NodeParent; let index: Int }

    func insertionChanged(parent: NodeParent, index: Int) {
        let next = Insertion(parent: parent, index: index)
        guard insertion != next else { return }
        insertion = next
        perform(.alignment)
    }

    func endDrag() { insertion = nil }
    func dropped(_ accepted: Bool) { endDrag(); if accepted { perform(.generic) } }

    func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        let key = "open.advanced.hapticOnTabReorder"
        guard UserDefaults.standard.object(forKey: key) == nil || UserDefaults.standard.bool(forKey: key) else { return }
        let name: String
        switch pattern {
        case .alignment: name = "alignment"
        case .levelChange: name = "levelChange"
        default: name = "generic"
        }
        SidebarDiagnostics.haptics[name, default: 0] += 1
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

extension SidebarDiagnostics {
    public internal(set) static var haptics: [String: Int] = [:]
}
