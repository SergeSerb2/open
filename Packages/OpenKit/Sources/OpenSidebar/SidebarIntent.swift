import AppKit
import OpenModel

/// Where a command-bar request came from. The command bar opens differently
/// for "edit current URL" and "new tab".
public enum CommandBarSource: Sendable, Equatable {
    case urlField
    case newTabRow
    case plusButton
}

/// Every user intent the sidebar can produce. The sidebar never changes the
/// model or talks to the engine itself; it reports intents to its delegate.
/// `ModelSidebarActions` maps the model-only intents to `BrowserModel` commands.
public enum SidebarIntent: Equatable, Sendable {
    // Window chrome
    case toggleSidebar
    /// Notification after a resize gesture commits a hidden sidebar (hint owner: lane A1).
    case sidebarHiddenByGesture
    case goBack
    case goForward
    case reload
    case stopLoading
    case openCommandBar(CommandBarSource)
    case copyCurrentURL
    case showSiteControls
    /// The optional content toolbar (commandbar-completion §4.6): "Show as Toolbar" on the URL
    /// field, "Hide Toolbar" on the toolbar. `ModelSidebarActions` runs the model command.
    case setToolbarShown(Bool)
    /// Toolbar right-click "Show Full URL" / "Hide Full URL" (`open.advanced.showFullURLWithToolbar`). App.
    case setShowFullURL(Bool)
    /// "Manage Extensions" on the URL field and the toolbar. App.
    case manageExtensions
    /// The status button under the URL field (page-platform §4.7.3). `anchor` is the button's
    /// frame in window coordinates; the App anchors its popover there. App.
    case showTranslation(anchor: CGRect)
    case shareQuote(anchor: CGRect)

    // Selection and Spaces
    case select(nodeID: ItemID, space: SpaceID)
    case selectFavorite(tabID: ItemID)
    case switchSpace(SpaceID)
    case showLibrary
    /// "Show media from:" on the Library button (PB1): toggles one Library media source.
    case toggleLibraryMediaSource(String)
    case newSpace
    case newFolder(in: NodeParent)
    case manageSpaces
    /// Space header chevron: collapse or expand the pinned section.
    case setPinnedCollapsed(space: SpaceID, collapsed: Bool)

    case media(MediaIntent)

    // Row actions
    case close(nodeID: ItemID)
    /// "Close and keep pinned": drop the web content, keep the pinned entry.
    case unloadTab(ItemID)
    case unloadFolder(folderID: ItemID)
    case toggleMute(tabID: ItemID)
    case resetToPinnedURL(tabID: ItemID)
    case replacePinnedURL(tabID: ItemID)
    case editPinnedURL(tabID: ItemID)
    case rename(nodeID: ItemID, title: String)
    case setExpanded(folderID: ItemID, expanded: Bool)
    case setFolderExpansion(folderID: ItemID, expansion: FolderExpansion)
    case pin(tabID: ItemID)
    case unpin(tabID: ItemID)
    case duplicate(nodeID: ItemID)
    case copyLink(nodeID: ItemID, markdown: Bool)
    case copyAllLinks(folderID: ItemID, markdown: Bool)
    case share(nodeID: ItemID)
    case changeIcon(nodeID: ItemID)
    case customizePage(tabID: ItemID)
    case openInSplitView(tabID: ItemID)
    case addSplitView(tabID: ItemID)
    case separateSplit(splitID: ItemID)
    /// Split row menu: "Separate from Split View" for one pane.
    case separatePane(splitID: ItemID, tabID: ItemID)
    /// Split row menu: "Convert to Horizontal/Vertical Split View".
    case setSplitOrientation(splitID: ItemID, orientation: SplitOrientation)
    /// Split row menu: "Add Tab…". The App adds an empty pane and opens the command bar.
    case addTabToSplit(splitID: ItemID)
    case newNestedFolder(parentFolderID: ItemID)
    case turnFolderIntoSpace(folderID: ItemID)
    case deleteFolder(folderID: ItemID)
    case clearToday(space: SpaceID)

    // Selection actions. The App confirms deleteFolders before archiving the
    // supplied selection (which can also contain tabs and splits on Delete).
    case moveNodes(ids: [ItemID], to: NodeParent, index: Int?)
    case moveNodesToSpace(ids: [ItemID], space: SpaceID)
    case moveNodesToNewSpace(ids: [ItemID])
    case archiveNodes(ids: [ItemID])
    case deleteFolders(ids: [ItemID])
    case newFolderFromSelection(ids: [ItemID])
    case setPinned(ids: [ItemID], pinned: Bool)
    case duplicateNodes(ids: [ItemID])
    case copyLinks(ids: [ItemID], markdown: Bool)
    case clearTodayKeeping(space: SpaceID, keep: Set<ItemID>)
    case separateFromPinned(tabID: ItemID)
    /// Model-only API; no Archive Folder menu item (lead decision Q1).
    case archiveFolder(folderID: ItemID)

    // App-owned preview panels and auto-archive education.
    case hoverPreview(SidebarHoverPreviewRequest?)
    case openProfileSettings(ProfileID)
    case dismissAutoArchiveBanner

    // Structure (drag and drop, "Move to")
    case move(nodeID: ItemID, to: NodeParent, index: Int?)
    case moveToSpace(nodeID: ItemID, space: SpaceID)
    case moveToNewSpace(nodeID: ItemID)
    case addFavorite(tabID: ItemID, index: Int?)
    case moveFavorite(tabID: ItemID, index: Int)
    case removeFavorite(tabID: ItemID)
    case openURL(URL, in: NodeParent, index: Int?)

    // Space header menu
    case changeSpaceIcon(SpaceID)
    case renameSpace(SpaceID, title: String)
    case editSpaceTheme(SpaceID)
    case setSpaceProfile(space: SpaceID, profile: ProfileID)
    case newProfile(space: SpaceID)
    case shareSpace(SpaceID)
    /// Space menu ▸ Live Folders ▸ GitHub (live-data §2.2): create or remove the Space's Live Folder.
    case toggleLiveFolder(SpaceID)
    /// Live Folder menu (live-data §2.2): Repositories toggle, Refresh, Delete Live Folder (alert),
    /// and the header-state action (opens github.com sign-in or the pulls page).
    case setLiveRepository(folderID: ItemID, repository: String, hidden: Bool)
    case refreshLiveFolder(ItemID)
    case deleteLiveFolder(ItemID)
    case openLiveFolderState(ItemID)
    case exportSpaceIntoFolder(space: SpaceID, destination: SpaceID)
    case deleteSpace(SpaceID)
    case moveSpace(SpaceID, toIndex: Int)
    /// Bottom-bar plus menu.
    case newTab
    case newSplitView
    /// New Easel (plus menu, ⌃⇧E): handled by the App.
    case newEasel
    /// Easel row menu: save as a web page, delete permanently (App).
    case exportEasel(tabID: ItemID)
    case deleteEasel(tabID: ItemID)
}


/// Media intents are handled by the App; drawer state stays in the view (PP-15/16).
public enum MediaIntent: Equatable, Sendable {
    case play(ItemID), pause(ItemID), previousTrack(ItemID), nextTrack(ItemID), toggleMute(ItemID)
    case setVolume(ItemID, Double), toggleVolumeDrawer(ItemID), openPictureInPicture(ItemID)
    case close(ItemID), backToTab(ItemID), toggleMicrophone(ItemID), toggleCamera(ItemID)
}
