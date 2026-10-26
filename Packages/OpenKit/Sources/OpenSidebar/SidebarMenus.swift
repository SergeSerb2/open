import AppKit
import OpenModel

/// A menu item that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, enabled: Bool = true, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// Context menus. Item lists and order follow the captured Arc menus
/// (docs/re/interaction-states.md §15). Every item reports a `SidebarIntent`;
/// the delegate does the work. Menus not captured in Arc are marked guess.
@MainActor
struct SidebarMenus {
    let context: SidebarContext
    /// Starts inline rename of a row or the Space title (the sidebar owns the editor).
    var beginRename: @MainActor (ItemID?) -> Void = { _ in }

    private func item(_ title: String, enabled: Bool = true, _ intent: SidebarIntent) -> NSMenuItem {
        let c = context
        return ClosureMenuItem(title, enabled: enabled) { c.send(intent) }
    }

    private func menu(_ items: [NSMenuItem]) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        items.forEach(m.addItem)
        return m
    }

    /// "Move to ▸": every other Space, a separator, "New Space…".
    private func moveTo(_ nodeID: ItemID) -> NSMenuItem {
        let parent = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        let current = context.model.parent(of: nodeID).flatMap(spaceID(of:))
        var items: [NSMenuItem] = context.model.spaces.map { space in
            item(context.title(of: space), enabled: space.id != current, .moveToSpace(nodeID: nodeID, space: space.id))
        }
        items.append(.separator())
        items.append(item("New Space…", .moveToNewSpace(nodeID: nodeID)))
        parent.submenu = menu(items)
        return parent
    }

    private func spaceID(of parent: NodeParent) -> SpaceID? {
        switch parent {
        case .spacePinned(let s), .spaceToday(let s): return s
        case .folder(let id), .splitPane(let id): return context.model.parent(of: id).flatMap(spaceID(of:))
        case .favorites: return nil
        }
    }

    /// Share ▸ with the system share menu for the tab's URL.
    private func share(_ tab: Tab) -> NSMenuItem {
        NSSharingServicePicker(items: [tab.url]).standardShareMenuItem
    }

    /// Today (unpinned) tab (F0115).
    func todayTab(_ tab: Tab) -> NSMenu {
        menu([
            item("Copy Link", .copyLink(nodeID: tab.id, markdown: false)),
            .separator(),
            item("Open in Split View", .openInSplitView(tabID: tab.id)),
            moveTo(tab.id),
            .separator(),
            item("Archive Item", .close(nodeID: tab.id)),
        ])
    }

    /// Pinned tab, at the top level or in a folder (F0116).
    func pinnedTab(_ tab: Tab) -> NSMenu {
        let edit = NSMenuItem(title: "Edit Pinned Page", action: nil, keyEquivalent: "")
        edit.submenu = menu([
            item("Replace Pinned URL with Current", enabled: tab.hasLeftPinnedURL, .replacePinnedURL(tabID: tab.id)),
            item("Edit…", .editPinnedURL(tabID: tab.id)),
        ])
        let rename = ClosureMenuItem("Rename…") { [beginRename] in beginRename(tab.id) }
        return menu([
            item("Copy Link", .copyLink(nodeID: tab.id, markdown: false)),
            share(tab),
            .separator(),
            item("Change Icon…", .changeIcon(nodeID: tab.id)),
            rename,
            item(tab.isMuted ? "Unmute" : "Mute", enabled: tab.live.isAudible || tab.isMuted, .toggleMute(tabID: tab.id)),
            item("Customize Page…", .customizePage(tabID: tab.id)),
            edit,
            .separator(),
            item("Add Split View", .addSplitView(tabID: tab.id)),
            item("Duplicate", .duplicate(nodeID: tab.id)),
            moveTo(tab.id),
            .separator(),
            item("Remove Pin", .unpin(tabID: tab.id)),
        ])
    }

    /// Favorite tile. guess: not captured; built from the pinned-tab menu.
    func favorite(_ tab: Tab) -> NSMenu {
        let rename = ClosureMenuItem("Rename…") { [beginRename] in beginRename(tab.id) }
        return menu([
            item("Copy Link", .copyLink(nodeID: tab.id, markdown: false)),
            share(tab),
            .separator(),
            item("Change Icon…", .changeIcon(nodeID: tab.id)),
            rename,
            .separator(),
            item("Remove from Favorites", .removeFavorite(tabID: tab.id)),
        ])
    }

    /// Split row. guess: not captured.
    func split(_ split: Split) -> NSMenu {
        menu([
            item("Separate Tabs", .separateSplit(splitID: split.id)),
            moveTo(split.id),
            .separator(),
            item("Archive Split View", .close(nodeID: split.id)),
        ])
    }

    /// Folder (F0119, F0134).
    func folder(_ folder: Folder) -> NSMenu {
        let rename = ClosureMenuItem("Rename…") { [beginRename] in beginRename(folder.id) }
        return menu([
            item("Share Folder…", .share(nodeID: folder.id)),
            .separator(),
            item("New Nested Folder…", .newNestedFolder(parentFolderID: folder.id)),
            item("Turn \"\(folder.title)\" into Space", .turnFolderIntoSpace(folderID: folder.id)),
            item("Copy All Links", .copyAllLinks(folderID: folder.id, markdown: false)),
            item("Copy All Links as Markdown", .copyAllLinks(folderID: folder.id, markdown: true)),
            .separator(),
            item("Change Icon…", .changeIcon(nodeID: folder.id)),
            rename,
            .separator(),
            item("Duplicate", .duplicate(nodeID: folder.id)),
            moveTo(folder.id),
            .separator(),
            item("Delete", .deleteFolder(folderID: folder.id)),
        ])
    }

    /// Space: right-click on the Space title or on empty sidebar space (F0117, A0414).
    func space(_ space: Space) -> NSMenu {
        let profile = NSMenuItem(title: "Set Profile", action: nil, keyEquivalent: "")
        var profiles: [NSMenuItem] = context.model.profiles.map { p in
            let i = item(p.name, .setSpaceProfile(space: space.id, profile: p.id))
            i.state = p.id == space.profileID ? .on : .off
            return i
        }
        profiles.append(.separator())
        profiles.append(item("New Profile…", .newProfile(space: space.id)))
        profile.submenu = menu(profiles)

        let export = NSMenuItem(title: "Export \"\(context.title(of: space))\" into Folder", action: nil, keyEquivalent: "")
        export.submenu = menu(context.model.spaces.map { other in
            item(context.title(of: other), enabled: other.id != space.id, .exportSpaceIntoFolder(space: space.id, destination: other.id))
        })
        let rename = ClosureMenuItem("Rename Space…") { [beginRename] in beginRename(nil) }
        return menu([
            item("Change Space Icon…", .changeSpaceIcon(space.id)),
            rename,
            item("Edit Theme Color…", .editSpaceTheme(space.id)),
            profile,
            .separator(),
            item("New Folder", .newFolder(in: .spacePinned(space.id))),
            .separator(),
            item("Share Space…", .shareSpace(space.id)),
            export,
            .separator(),
            item("Manage Spaces…", .manageSpaces),
            .separator(),
            item("Delete Space", enabled: context.model.spaces.count > 1, .deleteSpace(space.id)),
        ])
    }

    /// Bottom-bar plus button. guess: not captured.
    func plus() -> NSMenu {
        let space = context.focusedSpace
        return menu([
            item("New Tab", .newTab),
            item("New Split View", .newSplitView),
            space.map { item("New Folder", .newFolder(in: .spacePinned($0.id))) } ?? .separator(),
            .separator(),
            item("New Space…", .newSpace),
        ])
    }
}
