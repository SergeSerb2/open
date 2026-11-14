import AppKit
import OpenModel

/// Maps the intents that only touch the model to `BrowserModel` commands.
/// The App target calls this for model intents and handles engine and UI
/// intents (navigation, command bar, sharing, dialogs) itself. The renderer
/// and checks use it as their whole delegate.
@MainActor
public struct ModelSidebarActions {
    public let context: SidebarContext

    public init(context: SidebarContext) { self.context = context }

    private var model: BrowserModel { context.model }
    private var windowID: WindowID { context.windowID }

    /// Returns false when the intent needs the App (engine, panels, pasteboard).
    @discardableResult
    public func perform(_ intent: SidebarIntent) -> Bool {
        switch intent {
        case .media: return false
        case .setToolbarShown(let shown): return model.setToolbarShown(windowID: windowID, shown)
        case .select(let id, let space):
            if case .splitPane(let splitID) = model.parent(of: id) {
                model.focusSplitPane(splitID: splitID, tabID: id)
                model.selectNode(windowID: windowID, spaceID: space, nodeID: splitID)
            } else { model.selectNode(windowID: windowID, spaceID: space, nodeID: id) }
        case .selectFavorite(let id):
            guard let space = context.focusedSpace else { return false }
            model.selectNode(windowID: windowID, spaceID: space.id, nodeID: id)
        case .switchSpace(let id):
            model.focusSpace(windowID: windowID, spaceID: id)
        case .close(let id):
            return model.archiveNodes(ids: [id]) > 0
        case .moveNodes(let ids, let parent, let index):
            return model.moveNodes(ids: ids, to: parent, at: index) > 0
        case .moveNodesToSpace(let ids, let space):
            return model.moveNodes(ids: ids, toSpace: space, markUnread: context.focusedSpace?.id != space) > 0
        case .archiveNodes(let ids):
            return model.archiveNodes(ids: ids) > 0
        case .splitNodes(let ids):
            return model.makeSplit(tabIDs: ids) != nil
        case .newFolderFromSelection(let ids):
            guard let first = ids.first, let parent = model.parent(of: first),
                  let index = siblings(in: parent).firstIndex(where: { $0.id == first }),
                  let folder = model.createFolder(in: parent, at: index, withNodes: ids) else { return false }
            context.sidebar?.renameInsertedNode(folder.id)
            context.manager?.renameInsertedNode(folder.id)
            return true
        case .setPinned(let ids, let pinned):
            return model.setPinned(ids: ids, pinned: pinned) > 0
        case .duplicateNodes(let ids):
            return !model.duplicateNodes(ids: ids).isEmpty
        case .duplicate(let id):
            return !model.duplicateNodes(ids: [id]).isEmpty
        case .clearTodayKeeping(let space, let keep):
            guard model.space(id: space) != nil else { return false }
            model.clearToday(space: space, keeping: keep)
        case .archiveFolder(let id):
            return model.archiveFolder(id: id)
        case .exportSpaceIntoFolder(let space, let destination):
            return model.turnSpaceIntoFolder(id: space, destination: destination) != nil
        case .setExpanded(let id, let expanded):
            model.setFolderExpansion(folderID: id, context.folderExpansion(folderID: id, expanded: expanded))
        case .setFolderExpansion(let id, let expansion):
            model.setFolderExpansion(folderID: id, expansion)
        case .setPinnedCollapsed(let space, let collapsed):
            model.setPinnedSectionCollapsed(spaceID: space, collapsed: collapsed)
        case .pin(let id):
            model.pinTab(id: id)
        case .unpin(let id):
            model.unpinTab(id: id)
        case .rename(let id, let title):
            model.renameNode(id: id, title: title)
        case .resetSplitCustomization(let id):
            return model.resetSplitCustomization(id: id)
        case .renameSpace(let id, let title):
            // Trims and stores an empty name as untitled, like the App's rename path.
            model.renameSpace(id: id, title: title)
        case .move(let id, let parent, let index):
            if case .favorites(let profile) = parent {
                return model.addFavorite(tabID: id, to: profile, at: index)
            }
            return model.moveNode(id: id, to: parent, at: index)
        case .moveToSpace(let id, let space):
            return model.moveNode(id: id, to: SidebarPasteboard.destination(for: id, in: space, model: model), at: 0)
        case .addFavorite(let id, let index):
            guard let profile = context.favoritesProfile else { return false }
            return model.addFavorite(tabID: id, to: profile.id, at: index)
        case .moveFavorite(let id, let index):
            guard let profile = context.favoritesProfile else { return false }
            return model.moveNode(id: id, to: .favorites(profile.id), at: index)
        case .removeFavorite(let id):
            return model.removeFavorite(tabID: id, into: context.focusedSpace?.id)
        case .clearToday(let space):
            model.clearToday(space: space)
        case .deleteFolder(let id):
            model.closeTab(id: id)
        case .newFolder(let parent):
            return model.createFolder(in: parent) != nil
        case .newNestedFolder(let parent):
            return model.createFolder(in: .folder(parent)) != nil
        case .separateSplit(let id):
            model.unsplit(splitID: id)
        case .separatePane(let split, let tab):
            guard model.parent(of: tab) == .splitPane(split) else { return false }
            model.removePane(splitID: split, tabID: tab, archive: false)
        case .setSplitOrientation(let split, let orientation):
            guard model.node(id: split)?.split != nil else { return false }
            model.setSplitOrientation(splitID: split, orientation: orientation)
        case .resetToPinnedURL(let id):
            model.resetPinnedTab(id: id)
        case .replacePinnedURL(let id):
            model.replacePinnedURL(id: id)
        case .toggleMute(let id):
            guard let tab = model.tab(id: id) else { return false }
            model.setMuted(tabID: id, muted: !tab.isMuted)
        case .deleteSpace(let id):
            model.deleteSpace(id: id)
        case .moveSpace(let id, let index):
            model.moveSpace(id: id, to: index)
        case .setSpaceProfile(let space, let profile):
            return model.moveSpace(id: space, toProfile: profile)
        case .openURL(let url, let parent, let index):
            switch parent {
            case .spacePinned(let s), .spaceToday(let s):
                let tab = model.newTab(in: s, url: url, title: url.host() ?? url.absoluteString, at: index)
                if case .spacePinned = parent { return model.moveNode(id: tab.id, to: parent, at: index) }
            case .folder, .favorites:
                guard let space = context.focusedSpace else { return false }
                let tab = model.newTab(in: space.id, url: url, title: url.host() ?? url.absoluteString)
                if case .favorites(let p) = parent { return model.addFavorite(tabID: tab.id, to: p, at: index) }
                return model.moveNode(id: tab.id, to: parent, at: index)
            case .splitPane:
                return false
            }
        default:
            return false
        }
        return true
    }

    private func siblings(in parent: NodeParent) -> [SidebarNode] {
        switch parent {
        case .spacePinned(let id): model.space(id: id)?.pinned ?? []
        case .spaceToday(let id): model.space(id: id)?.today ?? []
        case .folder(let id): model.node(id: id)?.folder?.children ?? []
        case .favorites, .splitPane: []
        }
    }
}
