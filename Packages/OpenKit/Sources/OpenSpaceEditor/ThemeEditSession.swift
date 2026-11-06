import Foundation
import OpenDesign
import OpenModel

/// One open editor's model boundary. Preview writes neither save nor undo;
/// the controller pairs the commit with its in-session pad-state undo record.
@MainActor
public final class ThemeEditSession {
    public let spaceID: SpaceID
    public private(set) var baseline: SpaceTheme
    public private(set) var draft: SpaceStyle?
    public let registry: ThemePreviewRegistry
    public private(set) var previewCount = 0
    public private(set) var commitSequence = 0
    public private(set) var committedPreviewCount = 0
    /// Exact value captured by commitSpaceTheme's redo registration. Both reads
    /// run in one MainActor call with no suspension or intervening model write.
    public private(set) var lastCommittedTheme: SpaceTheme?
    private let model: BrowserModel
    private let lease = UUID()
    private var closed = false

    public init(model: BrowserModel, spaceID: SpaceID, registry: ThemePreviewRegistry = .shared) {
        self.model = model; self.spaceID = spaceID; self.registry = registry
        baseline = model.space(id: spaceID)?.theme ?? SpaceTheme()
        draft = SpaceStyle.seed(from: baseline)
    }
    isolated deinit { registry.end(lease) }

    public func captureBaseline() { baseline = model.space(id: spaceID)?.theme ?? baseline }
    public func preview(_ style: SpaceStyle?, live: Bool) {
        guard !closed, model.space(id: spaceID) != nil else { return }
        draft = style
        if live { registry.begin(lease, spaceID: spaceID) }
        else { registry.end(lease) }
        previewCount += 1
        model.previewSpaceTheme(id: spaceID, theme: SpaceTheme(style: style))
        registry.publish(spaceID)
    }
    @discardableResult public func commit() -> Bool {
        guard !closed else { return false }
        defer { registry.end(lease); captureBaseline() }
        let committed = model.space(id: spaceID)?.theme
        let changed = model.commitSpaceTheme(id: spaceID, from: baseline)
        if changed {
            lastCommittedTheme = committed
            committedPreviewCount = previewCount; commitSequence += 1
        }
        return changed
    }
    public func restored(_ theme: SpaceTheme, publish: Bool = true) {
        baseline = theme; draft = SpaceStyle.seed(from: theme)
        registry.end(lease); if publish { registry.publish(spaceID) }
    }
    public func close() { closed = true; registry.end(lease) }
}
