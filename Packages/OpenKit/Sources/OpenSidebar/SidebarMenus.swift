import AppKit
import OpenLiveData
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

    private func moveTo(_ ids: [ItemID]) -> NSMenuItem {
        let parent = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        let current = Set(ids.compactMap { context.model.parent(of: $0).flatMap(spaceID(of:)) })
        var items = context.model.spaces.map { space in
            item(context.title(of: space), enabled: current != Set([space.id]), .moveNodesToSpace(ids: ids, space: space.id))
        }
        items.append(.separator())
        items.append(item("New Space…", enabled: context.canMoveNodesToNewSpace(ids), .moveNodesToNewSpace(ids: ids)))
        parent.submenu = menu(items)
        return parent
    }

    /// Selection menu; folders use Delete only (lead decision Q1).
    func emptyIncognito() -> NSMenu { menu([item("New Tab", .newTab)]) }

    func selection(_ ids: [ItemID]) -> NSMenu {
        if context.isIncognito {
            return menu([item("Copy Links", .copyLinks(ids: ids, markdown: false)),
                item("Duplicate", .duplicateNodes(ids: ids)), item("Close Tabs", .archiveNodes(ids: ids))])
        }
        let folders = ids.filter { context.model.node(id: $0)?.folder != nil }
        let tabs = ids.filter { context.model.node(id: $0).map { $0.folder == nil } ?? false }
        func hasLinks(_ node: SidebarNode) -> Bool {
            switch node {
            case .tab: return true
            case .split(let split): return !split.panes.isEmpty
            case .folder(let folder): return folder.children.contains(where: hasLinks)
            }
        }
        let canCopy = ids.contains { context.model.node(id: $0).map(hasLinks) ?? false }
        var items: [NSMenuItem] = [
            item("Copy Links", enabled: canCopy, .copyLinks(ids: ids, markdown: false)),
            item("Copy links as Markdown", enabled: canCopy, .copyLinks(ids: ids, markdown: true)),
            .separator(),
            item("New Folder with \(ids.count) Items", .newFolderFromSelection(ids: ids)),
            moveTo(ids),
            .separator(),
        ]
        if folders.isEmpty {
            let unpin = ids.allSatisfy { context.model.isPinned(tabID: $0) }
            items.append(item(unpin ? "Unpin Tabs" : "Pin Tabs", .setPinned(ids: ids, pinned: !unpin)))
        }
        items += [item("Duplicate", .duplicateNodes(ids: ids)), .separator()]
        if !tabs.isEmpty { items.append(item("Archive Items", .archiveNodes(ids: tabs))) }
        if !folders.isEmpty { items.append(item("Delete", .deleteFolders(ids: folders))) }
        return menu(items)
    }

    private func spaceID(of parent: NodeParent) -> SpaceID? {
        switch parent {
        case .spacePinned(let s), .spaceToday(let s): return s
        case .folder(let id), .splitPane(let id): return context.model.parent(of: id).flatMap(spaceID(of:))
        case .favorites: return nil
        }
    }

    /// Share… asks the App to anchor the system picker at this tab's row.
    private func share(_ tab: Tab) -> NSMenuItem {
        item("Share…", .share(nodeID: tab.id))
    }

    /// Today (unpinned) tab: capture session 2, 08-folder-preview frame 0050.
    /// Archive Other Tabs remains a guessed Option alternate.
    func todayTab(_ tab: Tab) -> NSMenu {
        if Self.isEasel(tab) { return easel(tab) }
        if context.isIncognito {
            return menu([item("Copy Link", .copyLink(nodeID: tab.id, markdown: false)),
                item("Open in Split View", .openInSplitView(tabID: tab.id)),
                item("Duplicate", .duplicate(nodeID: tab.id)), item("Close Tab", .close(nodeID: tab.id))])
        }
        var items: [NSMenuItem] = [
            item("Copy Link", .copyLink(nodeID: tab.id, markdown: false)),
            .separator(),
            item("Open in Split View", .openInSplitView(tabID: tab.id)),
            moveTo(tab.id),
            .separator(),
            item("Archive Tab", .close(nodeID: tab.id)),
        ]
        if let space = context.model.parent(of: tab.id).flatMap(spaceID(of:)) {
            var keep = Set(context.selection.ids)
            keep.insert(tab.id)
            let alternate = item("Archive Other Tabs", .clearTodayKeeping(space: space, keep: keep))
            alternate.isAlternate = true
            alternate.keyEquivalentModifierMask = .option
            items.append(alternate)
            let today = context.model.space(id: space)?.today ?? []
            let below = today.firstIndex(where: { $0.id == tab.id }).map { Array(today.dropFirst($0 + 1).map(\.id)) } ?? []
            items.append(item("Archive Tabs Below", enabled: !below.isEmpty, .archiveNodes(ids: below)))
        }
        return menu(items)
    }

    /// Pinned tab, at the top level or in a folder (F0116).
    func pinnedTab(_ tab: Tab) -> NSMenu {
        if Self.isEasel(tab) { return easel(tab) }
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

    static func isEasel(_ tab: Tab) -> Bool { tab.url.scheme?.lowercased() == "open" && tab.url.host()?.lowercased() == "easel" }

    /// Easel row in Arc's order (C-measurements-s4 `e7-row-menu-ax`, LEAD 04:05): Copy Link · — ·
    /// Change Icon… · Rename… · — · Add Split View · Move to ▸ · — · Remove Easel from Sidebar ·
    /// Delete Easel. Copy Link copies the Easel's own address (`open://easel/…`, opens it from
    /// the command bar); Arc's per-Easel "save as a web page" row sits with it.
    func easel(_ tab: Tab) -> NSMenu {
        let rename = ClosureMenuItem("Rename…") { [beginRename] in beginRename(tab.id) }
        return menu([
            item("Copy Link", .copyLink(nodeID: tab.id, markdown: false)),
            item("Save as Web Page…", .exportEasel(tabID: tab.id)),
            .separator(),
            item("Change Icon…", .changeIcon(nodeID: tab.id)),
            rename,
            .separator(),
            item("Add Split View", .addSplitView(tabID: tab.id)),
            moveTo(tab.id),
            .separator(),
            item("Remove Easel from Sidebar", .close(nodeID: tab.id)),
            item("Delete Easel", .deleteEasel(tabID: tab.id)),
        ])
    }

    /// Favorite tile. guess: not captured; built from the pinned-tab menu.
    func favorite(_ tab: Tab) -> NSMenu {
        let rename = ClosureMenuItem("Rename…") { [beginRename] in beginRename(tab.id) }
        return menu(liveCalendarItems(tab) + [
            item("Copy Link", .copyLink(nodeID: tab.id, markdown: false)),
            share(tab),
            .separator(),
            item("Change Icon…", .changeIcon(nodeID: tab.id)),
            rename,
            .separator(),
            item("Remove from Favorites", .removeFavorite(tabID: tab.id)),
        ])
    }

    /// Live Calendar items of a calendar Favorite (LD §4: "Show Meeting Link" with "Copy Link" and "Dismiss",
    /// `G:FUN_101d28c10`; the reminder times of `LiveCalendarInterval`). Placement first, then a separator:
    /// GUESS — capture pending (F2 item 7). Arc picks the reminder time in the reminder card; Open also lists it here.
    func liveCalendarItems(_ tab: Tab) -> [NSMenuItem] {
        guard let actions = context.liveCalendar, CalendarProvider.match(url: tab.url) != nil else { return [] }
        var items: [NSMenuItem] = []
        if let state = context.liveCalendarTiles[tab.id] {
            let show = NSMenuItem(title: "Show Meeting Link", action: nil, keyEquivalent: "")
            let link = NSMenuItem(title: state.link.url.absoluteString, action: nil, keyEquivalent: "")
            link.isEnabled = false
            show.submenu = menu([
                link, .separator(),
                ClosureMenuItem("Copy Link") { actions.copyLink(state) },
                ClosureMenuItem("Dismiss") { actions.dismiss(state) },
            ])
            items.append(show)
        }
        let remind = NSMenuItem(title: "Meeting Reminder", action: nil, keyEquivalent: "")
        let current = actions.interval()
        remind.submenu = menu(LiveCalendar.ReminderInterval.allCases.map { interval in
            let item = ClosureMenuItem(interval.title) { actions.setInterval(interval) }
            item.state = interval == current ? .on : .off
            return item
        })
        items.append(remind)
        items.append(.separator())
        return items
    }

    /// Split row. Not captured; the items and their order follow Arc's split-row
    /// menu builder (Arc 1.170.0 arm64, function at 0x102eccc9c; docs/re/menus-and-hotkeys.md).
    /// Left out: "Share Split View" (account link), "Reset Name and Icon", "Change Icon…",
    /// and "Rename…" (Open's splits have no custom name or icon), and staff-only items.
    /// guess: "Move to" sits before the last separator, as in the captured tab menus.
    func split(_ split: Split) -> NSMenu {
        let convert: NSMenuItem = split.orientation == .horizontal
            ? item("Convert to Vertical Split View", .setSplitOrientation(splitID: split.id, orientation: .vertical))
            : item("Convert to Horizontal Split View", .setSplitOrientation(splitID: split.id, orientation: .horizontal))
        let header = NSMenuItem(title: "Tab Options", action: nil, keyEquivalent: "")
        header.isEnabled = false
        var items: [NSMenuItem] = [
            item("Separate All Tabs", .separateSplit(splitID: split.id)),
            item("Add Tab…", enabled: split.panes.count < 4, .addTabToSplit(splitID: split.id)),
            convert,
            .separator(),
            header,
        ]
        items += split.panes.map { pane(of: split, $0) }
        items += [.separator(), item("Duplicate", .duplicate(nodeID: split.id))]
        if !context.isIncognito { items.append(moveTo(split.id)) }
        items += [.separator(), item(context.isIncognito ? "Close Split View" : "Archive Item", .close(nodeID: split.id))]
        return menu(items)
    }

    /// One pane of a split: a submenu titled with the pane title, cut to 30
    /// characters plus "…" (Arc's per-pane builder at 0x102ecf180).
    private func pane(of split: Split, _ tab: Tab) -> NSMenuItem {
        var title = tab.displayTitle
        if title.count > 30 { title = String(title.prefix(30)) + "…" }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = menu([
            item("Separate from Split View", .separatePane(splitID: split.id, tabID: tab.id)),
            .separator(),
            item(tab.isMuted ? "Unmute" : "Mute", enabled: tab.live.isAudible || tab.isMuted, .toggleMute(tabID: tab.id)),
            item("Copy Link", .copyLink(nodeID: tab.id, markdown: false)),
            item("Copy Link as Markdown", .copyLink(nodeID: tab.id, markdown: true)),
            .separator(),
            item("Archive Item", .close(nodeID: tab.id)),
        ])
        return parent
    }

    /// Folder (F0119, F0134).
    func folder(_ folder: Folder) -> NSMenu {
        let rename = ClosureMenuItem("Rename…") { [beginRename] in beginRename(folder.id) }
        return menu([
            item("Share Folder…", .share(nodeID: folder.id)),
            .separator(),
            item("New Nested Folder…", .newNestedFolder(parentFolderID: folder.id)),
            item("Turn “\(folder.title)” into Space", .turnFolderIntoSpace(folderID: folder.id)),
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

    /// Shared Set Profile choices, also opened by Spaces ▸ Change Profile.
    func profile(_ space: Space) -> NSMenu {
        var profiles: [NSMenuItem] = context.model.profiles.map { p in
            let i = item(p.name, .setSpaceProfile(space: space.id, profile: p.id))
            i.state = p.id == space.profileID ? .on : .off
            return i
        }
        profiles.append(.separator())
        profiles.append(item("New Profile…", .newProfile(space: space.id)))
        return menu(profiles)
    }

    /// Space: right-click on the Space title or on empty sidebar space (F0117, A0414).
    func space(_ space: Space) -> NSMenu {
        let profile = NSMenuItem(title: "Set Profile", action: nil, keyEquivalent: "")
        profile.submenu = self.profile(space)

        let export = NSMenuItem(title: "Export “\(context.title(of: space))” into Folder", action: nil, keyEquivalent: "")
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
            item("Share Space…", enabled: false, .shareSpace(space.id)),
            export,
            .separator(),
            item("Manage Spaces…", .manageSpaces),
            .separator(),
            item("Delete Space", enabled: context.model.spaces.count > 1, .deleteSpace(space.id)),
        ])
    }

    /// Bottom-bar plus button. guess: not captured.
    /// Right-click on the URL field (CC-36; order guess).
    func urlField() -> NSMenu {
        menu([item("Show as Toolbar", .setToolbarShown(true)), .separator(), item("Manage Extensions", .manageExtensions)])
    }

    /// Right click on the Library button (capture C-report-s3 Part D): a disabled
    /// "Show media from:" header, then Documents · Desktop · Screenshots · Captures · Downloads.
    func libraryMediaSources() -> NSMenu? {
        let sources = context.libraryMediaSources
        guard !sources.isEmpty else { return nil }
        var items: [NSMenuItem] = [ClosureMenuItem("Show media from:", enabled: false) {}]
        for source in sources {
            let entry = item(source.title, .toggleLibraryMediaSource(source.id))
            entry.state = source.enabled ? .on : .off
            entry.identifier = NSUserInterfaceItemIdentifier("library-media-source-" + source.id)
            items.append(entry)
        }
        return menu(items)
    }

    func plus() -> NSMenu {
        let space = context.focusedSpace
        let canSplit: Bool = {
            guard let tab = context.currentTab, let parent = context.model.parent(of: tab.id) else { return false }
            switch parent {
            case .favorites: return false
            case .splitPane(let id): return (context.model.node(id: id)?.split?.panes.count ?? 4) < 4
            default: return true
            }
        }()
        return menu([
            item("New Tab", .newTab),
            item("New Split View", enabled: canSplit, .newSplitView),
            space.map { item("New Folder", .newFolder(in: .spacePinned($0.id))) } ?? .separator(),
            {
                // Arc's plus popover row "New Easel ⌃⇧E" (interaction-states.md S2 01).
                let row = item("New Easel", enabled: !context.isIncognito, .newEasel)
                row.keyEquivalent = "e"; row.keyEquivalentModifierMask = [.control, .shift]
                return row
            }(),
            .separator(),
            item("New Space…", .newSpace),
        ])
    }
}
