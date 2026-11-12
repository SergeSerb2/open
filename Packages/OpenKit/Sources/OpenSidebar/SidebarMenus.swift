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
        if context.isWindowOnly {
            // A Blank Window's tab moves into one of the browser's Spaces (the App handles the intent).
            parent.submenu = menu((context.windowOnlyMoveSpaces?() ?? []).map { item($0.title, .moveToSpace(nodeID: nodeID, space: $0.id)) })
            return parent
        }
        let current = context.model.parent(of: nodeID).flatMap(spaceID(of:))
        // One row per Space in dock order, the current one checked (capture session 8 item 2).
        var items: [NSMenuItem] = context.model.spaces.map { space in
            let row = space.id == current ? ClosureMenuItem(context.title(of: space)) {}
                : item(context.title(of: space), .moveToSpace(nodeID: nodeID, space: space.id))
            row.state = space.id == current ? .on : .off
            return row
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
            // A Note has no shareable address in Open (its own row menu disables Copy Link).
            case .tab(let tab): return !Self.isNote(tab)
            case .split(let split): return !split.panes.isEmpty
            case .folder(let folder): return folder.children.contains(where: hasLinks)
            }
        }
        let canCopy = ids.contains { context.model.node(id: $0).map(hasLinks) ?? false }
        // Capture session 8 item 6 (AX of the open menu, `i6a-two-today`, `i6b-pinned-today`, `i6c-tab-folder`):
        // tabs: Copy Links · Share N Items… · — · Change Icon… (disabled) · Mute · — · Open in Split View ·
        // Duplicate · Move to ▸ · New Folder with N Items · — · Archive Tabs (+ the ⌥ group when all are Today tabs);
        // with a folder: Copy Links · Share N Items… · — · Open in Split View (disabled) · Move to ▸ ·
        // New Folder with N Items · — · Delete.
        // Open's own, behind ⌥ so the drawn menu is Arc's: "Copy links as Markdown" (guess: Arc has the
        // plural string but does not list it here) and "Pin Tabs" / "Unpin Tabs".
        let c = context
        let tabObjects = tabs.compactMap { context.model.tab(id: $0) }
        let onlyTabs = folders.isEmpty && tabObjects.count == ids.count
        let canSplit = onlyTabs && (2...4).contains(ids.count) && !ids.contains { if case .favorites? = context.model.parent(of: $0) { true } else { false } }
        var items: [NSMenuItem] = [
            item("Copy Links", enabled: canCopy, .copyLinks(ids: ids, markdown: false)),
            alternate(item("Copy links as Markdown", enabled: canCopy, .copyLinks(ids: ids, markdown: true))),
            item("Share \(ids.count) Items…", enabled: canCopy, .shareNodes(ids: ids)),
            .separator(),
        ]
        if folders.isEmpty {
            let canMute = tabObjects.contains { $0.live.isAudible || $0.isMuted }
            let unmute = !tabObjects.contains { $0.live.isAudible && !$0.isMuted } && tabObjects.contains(where: \.isMuted)
            items += [
                ClosureMenuItem("Change Icon…", enabled: false) {},
                ClosureMenuItem(unmute ? "Unmute" : "Mute", enabled: canMute) {
                    for tab in tabObjects where (tab.live.isAudible || tab.isMuted) && tab.isMuted == unmute { c.send(.toggleMute(tabID: tab.id)) }
                },
                .separator(),
            ]
        }
        items.append(item("Open in Split View", enabled: canSplit, .splitNodes(ids: ids)))
        if folders.isEmpty {
            let unpin = ids.allSatisfy { context.model.isPinned(tabID: $0) }
            items += [item("Duplicate", .duplicateNodes(ids: ids)),
                      alternate(item(unpin ? "Unpin Tabs" : "Pin Tabs", .setPinned(ids: ids, pinned: !unpin)))]
        }
        items += [moveTo(ids), item("New Folder with \(ids.count) Items", .newFolderFromSelection(ids: ids)), .separator()]
        if !tabs.isEmpty {
            // With a folder Arc draws only "Delete" (nothing was executed in the capture); Open keeps the
            // tabs' archive item beside it until a capture shows what Delete does to the tabs.
            // Arc STR has the plurals "Remove Notes from Sidebar" / "Remove Easels from Sidebar" beside the rows'
            // singulars (easels-notes.md §3.2, §4.3); used when every selected row is a Note, or every one an Easel.
            // GUESS: their place in this menu. A Note row cannot be captured (Arc 1.172); the Easel selection
            // menu can (capture item C-EZ1 in PB4-questions.md).
            let only = folders.isEmpty && !tabObjects.isEmpty && tabObjects.count == ids.count
            let title = only && tabObjects.allSatisfy(Self.isNote) ? "Remove Notes from Sidebar"
                : only && tabObjects.allSatisfy(Self.isEasel) ? "Remove Easels from Sidebar" : "Archive Tabs"
            items.append(item(title, .archiveNodes(ids: tabs)))
            let spaces = Set(ids.map { context.model.parent(of: $0) }.map { parent -> SpaceID? in
                if case .spaceToday(let id)? = parent { id } else { nil }
            })
            if folders.isEmpty, spaces.count == 1, let space = spaces.first ?? nil {
                let today = context.model.space(id: space)?.today ?? []
                items += [
                    alternate(item("Archive Other Tabs", enabled: today.contains { !ids.contains($0.id) }, .clearTodayKeeping(space: space, keep: Set(ids)))),
                    ClosureMenuItem("Archive Tabs Below", enabled: false) {},
                    alternate(ClosureMenuItem("Archive Tabs Above", enabled: false) {}),
                ]
            }
        }
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
    /// "Share ▸": the system share services of this Mac, in their own order (capture session 8 item 1:
    /// AirDrop · Mail · Messages · Notes · … with their icons; the same submenu on Today, pinned,
    /// favourite rows and the URL field). The App shares the link without trackers.
    private func share(_ tab: Tab) -> NSMenuItem {
        let parent = NSMenuItem(title: "Share", action: nil, keyEquivalent: "")
        let clean = URLCleaner.clean(tab.url).url
        parent.submenu = menu(ShareServices.list(for: [clean]).map { service in
            let row = item(service.title, .shareVia(nodeID: tab.id, service: service.title))
            row.image = service.image
            return row
        })
        parent.isEnabled = !(parent.submenu?.items.isEmpty ?? true)
        return parent
    }

    /// Option alternate: drawn in place of `primary` while ⌥ is held (capture session 8: Archive Tab ↔
    /// Archive Other Tabs, Archive Tabs Below ↔ Archive Tabs Above).
    private func alternate(_ row: NSMenuItem) -> NSMenuItem {
        row.isAlternate = true; row.keyEquivalentModifierMask = .option; return row
    }

    /// The current tab's split item: "Add Split View" on the selected tab, "Open in Split View"
    /// on another (capture session 8 item 3c).
    private func splitItem(_ tab: Tab) -> NSMenuItem {
        context.currentTab?.id == tab.id ? item("Add Split View", .addSplitView(tabID: tab.id))
            : item("Open in Split View", .openInSplitView(tabID: tab.id))
    }

    /// Copy Link; the selected tab's shows the Copy URL shortcut ⌘⇧C (session 8 item 3c).
    private func copyLink(_ tab: Tab) -> NSMenuItem {
        let row = item("Copy Link", .copyLink(nodeID: tab.id, markdown: false))
        if context.currentTab?.id == tab.id { row.keyEquivalent = "c"; row.keyEquivalentModifierMask = [.command, .shift] }
        return row
    }

    /// Today (unpinned) tab: capture session 2, 08-folder-preview frame 0050.
    /// Archive Other Tabs remains a guessed Option alternate.
    func todayTab(_ tab: Tab) -> NSMenu {
        if Self.isEasel(tab) { return easel(tab) }
        if Self.isNote(tab) { return note(tab) }
        if context.isIncognito {
            return menu([item("Copy Link", .copyLink(nodeID: tab.id, markdown: false)),
                item("Open in Split View", .openInSplitView(tabID: tab.id)),
                item("Duplicate", .duplicate(nodeID: tab.id)), item("Close Tab", .close(nodeID: tab.id))])
        }
        // Arc 1.172.2 order (capture session 3 Part D, `s9/15-menus`; docs/re/sidebar-menus-parity.md §1).
        let rename = ClosureMenuItem("Rename…") { [beginRename] in beginRename(tab.id) }
        var items: [NSMenuItem] = [
            copyLink(tab),
            share(tab),
            .separator(),
            item("Change Icon…", .changeIcon(nodeID: tab.id)),
            rename,
            mute(tab),
            .separator(),
            splitItem(tab),
            item("Duplicate", .duplicate(nodeID: tab.id)),
            moveTo(tab.id),
            .separator(),
            item("Archive Tab", .close(nodeID: tab.id)),
        ]
        items += archiveAlternates(tab.id)
        return menu(items)
    }

    /// After "Archive Tab" / "Archive Item" of a Today row: ⌥ Archive Other Tabs, Archive Tabs Below,
    /// ⌥ Archive Tabs Above. Drawn: the primary and Archive Tabs Below; with ⌥ the two alternates
    /// (capture session 8, `i3b-menu` against `i3b-opt`; split rows show the same AX pattern, item 5).
    private func archiveAlternates(_ nodeID: ItemID) -> [NSMenuItem] {
        guard let space = context.model.parent(of: nodeID).flatMap(spaceID(of:)) else { return [] }
        var keep = Set(context.selection.ids)
        keep.insert(nodeID)
        let today = context.model.space(id: space)?.today ?? []
        let index = today.firstIndex(where: { $0.id == nodeID })
        let below = index.map { Array(today.dropFirst($0 + 1).map(\.id)) } ?? []
        let above = index.map { Array(today.prefix($0).map(\.id)) } ?? []
        return [
            alternate(item("Archive Other Tabs", enabled: today.contains { !keep.contains($0.id) }, .clearTodayKeeping(space: space, keep: keep))),
            item("Archive Tabs Below", enabled: !below.isEmpty, .archiveNodes(ids: below)),
            alternate(item("Archive Tabs Above", enabled: !above.isEmpty, .archiveNodes(ids: above))),
        ]
    }

    /// Mute / Unmute; disabled for a silent, unmuted tab (S3D: "Mute (disabled)").
    private func mute(_ tab: Tab) -> NSMenuItem {
        item(tab.isMuted ? "Unmute" : "Mute", enabled: tab.live.isAudible || tab.isMuted, .toggleMute(tabID: tab.id))
    }

    /// "Edit Pinned Page ▸" (pinned tabs and favourites, F0116, S3D).
    private func editPinnedPage(_ tab: Tab) -> NSMenuItem {
        let edit = NSMenuItem(title: "Edit Pinned Page", action: nil, keyEquivalent: "")
        edit.submenu = menu([
            item("Replace Pinned URL with Current", enabled: tab.hasLeftPinnedURL, .replacePinnedURL(tabID: tab.id)),
            item("Edit…", .editPinnedURL(tabID: tab.id)),
        ])
        return edit
    }

    /// Pinned tab, at the top level or in a folder (F0116).
    func pinnedTab(_ tab: Tab) -> NSMenu {
        if Self.isEasel(tab) { return easel(tab) }
        if Self.isNote(tab) { return note(tab) }
        return menu(pinnedItems(tab) + [item("Remove Pin", .unpin(tabID: tab.id))])
    }

    /// The shared pinned / favourite list up to the last separator (S3D: the favourite menu is
    /// the pinned menu with "Remove Favorite" last). Arc has no "Customize Page…" here; Boosts
    /// open from Site Controls (C-report-s3 Part G).
    private func pinnedItems(_ tab: Tab) -> [NSMenuItem] {
        let rename = ClosureMenuItem("Rename…") { [beginRename] in beginRename(tab.id) }
        return [
            copyLink(tab),
            share(tab),
            .separator(),
            item("Change Icon…", .changeIcon(nodeID: tab.id)),
            rename,
            mute(tab),
            editPinnedPage(tab),
            .separator(),
            splitItem(tab),
            item("Duplicate", .duplicate(nodeID: tab.id)),
            moveTo(tab.id),
            .separator(),
        ]
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

    static func isNote(_ tab: Tab) -> Bool { tab.url.scheme?.lowercased() == "open" && tab.url.host()?.lowercased() == "note" }

    /// Note row, in the Easel row's order (LEAD 07:50). Arc STR: "Remove Note from Sidebar";
    /// "Delete Note" and "Export Note…" are GUESS (Arc 1.172 cannot show a Note row). Copy Link
    /// stays disabled: a Note has no shareable address in Open.
    func note(_ tab: Tab) -> NSMenu {
        let rename = ClosureMenuItem("Rename…") { [beginRename] in beginRename(tab.id) }
        return menu([
            item("Copy Link", enabled: false, .copyLink(nodeID: tab.id, markdown: false)),
            item("Export Note…", .exportNote(tabID: tab.id)),
            .separator(),
            item("Change Icon…", .changeIcon(nodeID: tab.id)),
            rename,
            .separator(),
            item("Add Split View", .addSplitView(tabID: tab.id)),
            moveTo(tab.id),
            .separator(),
            item("Remove Note from Sidebar", .close(nodeID: tab.id)),
            item("Delete Note", .deleteNote(tabID: tab.id)),
        ])
    }

    /// Favorite tile (S3D): the pinned menu with "Remove Favorite" last.
    func favorite(_ tab: Tab) -> NSMenu {
        menu(liveCalendarItems(tab) + tileItems(tab) + pinnedItems(tab) + [item("Remove Favorite", .removeFavorite(tabID: tab.id))])
    }

    /// Arc's Top App switches (audit A2; `ContextMenus/SidebarMenu+PlatformSpecificItems.swift`,
    /// `FUN_102ee07bc`): checkmark items "Show Unread Badge" (an unread-count app) and "Show Time to
    /// Next Meeting" (a Live Calendar tile). Placement before the pinned items: GUESS — capture pending.
    func tileItems(_ tab: Tab) -> [NSMenuItem] {
        let context = self.context
        let url = tab.url
        var items: [NSMenuItem] = []
        if context.favoriteBadgesEnabled, FavoriteApp.match(url: url)?.hasUnreadBadge == true {
            let on = context.favoriteTileSettings.showsBadge(url: url)
            let badge = ClosureMenuItem("Show Unread Badge") { context.updateFavoriteTileSettings { $0.setShowsBadge(!on, url: url) } }
            badge.state = on ? .on : .off
            items.append(badge)
        }
        if context.liveCalendar != nil, CalendarProvider.match(url: url) != nil {
            let on = context.favoriteTileSettings.showsSubtitle(url: url)
            let subtitle = ClosureMenuItem("Show Time to Next Meeting") { context.updateFavoriteTileSettings { $0.setShowsSubtitle(!on, url: url) } }
            subtitle.state = on ? .on : .off
            items.append(subtitle)
        }
        if !items.isEmpty { items.append(.separator()) }
        return items
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
        // Capture session 8 item 5 (`v6/32-d2-item-5b`): Share Split View… · — · Separate All Tabs · Add Tab… ·
        // Convert … · — · Tab Options · panes ▸ · — · Change Icon… · Rename… · — · Duplicate · Move to ▸ · — ·
        // Archive Item · Archive Tabs Below (⌥ alternates). Change Icon… / Rename… need a split name and
        // icon in the model and a capture of a renamed split row: follow-up (C3 item 15).
        var items: [NSMenuItem] = []
        if !context.isIncognito { items += [item("Share Split View…", .shareSplit(splitID: split.id)), .separator()] }
        items += [
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
        if !context.isIncognito { items += archiveAlternates(split.id) }
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
            share(tab),
            mute(tab),
            item("Copy Link", .copyLink(nodeID: tab.id, markdown: false)),
            // Arc's title has a lower-case "link" here (capture session 8 item 5).
            item("Copy link as Markdown", .copyLink(nodeID: tab.id, markdown: true)),
            .separator(),
            item("Archive Item", .close(nodeID: tab.id)),
        ])
        return parent
    }

    /// Folder (F0119, F0134).
    func folder(_ folder: Folder) -> NSMenu {
        if let live = folder.live, !context.isIncognito { return liveFolder(folder, live) }
        let rename = ClosureMenuItem("Rename…") { [beginRename] in beginRename(folder.id) }
        return menu([
            item("Share Folder…", .share(nodeID: folder.id)),
            .separator(),
            item("New Nested Folder…", .newNestedFolder(parentFolderID: folder.id)),
            item("Turn “\(folder.title)” into Space", .turnFolderIntoSpace(folderID: folder.id)),
        ] + (folder.children.isEmpty ? [] : [
            // S3D: an empty folder has no Copy items; their place with tabs is pending (C3 item 4).
            item("Copy All Links", .copyAllLinks(folderID: folder.id, markdown: false)),
            item("Copy All Links as Markdown", .copyAllLinks(folderID: folder.id, markdown: true)),
        ]) + [
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

    /// Live Folder menu (live-data §2.2, `G:FUN_102eb5460` family): header, an optional
    /// "Failed to update", Repositories (one toggle per repository with an active PR, plus the
    /// hidden ones so they can come back) and its note, Single Sign-On ▸ Required and its note,
    /// Refresh, Copy All Links, Delete Live Folder. Order: GUESS — capture pending (F2 item 3).
    private func liveFolder(_ folder: Folder, _ live: LiveFolderConfig) -> NSMenu {
        func note(_ text: String) -> NSMenuItem { let i = NSMenuItem(title: text, action: nil, keyEquivalent: ""); i.isEnabled = false; return i }
        var items: [NSMenuItem] = [note(folder.title)]
        if live.lastFetch?.outcome == .failed { items.append(note("Failed to update")) }
        items.append(.separator())
        let active = Set(folder.children.compactMap { node -> String? in
            if case .tab(let tab) = node, let url = tab.liveItemURL { return LiveFolderConfig.repository(of: url) }; return nil
        })
        let repositories = active.union(live.hiddenRepositories).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let repoMenu = NSMenuItem(title: "Repositories", action: nil, keyEquivalent: "")
        repoMenu.submenu = menu(repositories.map { repo in
            let hidden = live.hiddenRepositories.contains(repo)
            let i = item(repo, .setLiveRepository(folderID: folder.id, repository: repo, hidden: !hidden))
            i.state = hidden ? .off : .on
            return i
        } + [.separator(), note("This list is generated based on your currently active pull requests.")])
        repoMenu.isEnabled = true
        let sso = NSMenuItem(title: "Single Sign-On", action: nil, keyEquivalent: "")
        let required = note("Required"); required.state = live.lastFetch?.outcome == .needsSSO ? .on : .off
        sso.submenu = menu([required, .separator(), note("SSO ensures all of your organizations' PRs appear")])
        items += [repoMenu, sso, item("Refresh", .refreshLiveFolder(folder.id)), .separator(),
                  item("Copy All Links", .copyAllLinks(folderID: folder.id, markdown: false)), .separator(),
                  item("Delete Live Folder", .deleteLiveFolder(folder.id))]
        return menu(items)
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
    /// `inLibrary`: Library › Spaces card header and footer "…" show the same menu without "Manage Spaces…"
    /// (capture session 8 item 13, `v13/34-item-13`).
    func space(_ space: Space, inLibrary: Bool = false) -> NSMenu {
        let profile = NSMenuItem(title: "Set Profile", action: nil, keyEquivalent: "")
        profile.submenu = self.profile(space)

        let export = NSMenuItem(title: "Export “\(context.title(of: space))” into Folder", action: nil, keyEquivalent: "")
        export.submenu = menu(context.model.spaces.map { other in
            item(context.title(of: other), enabled: other.id != space.id, .exportSpaceIntoFolder(space: space.id, destination: other.id))
        })
        let rename = ClosureMenuItem("Rename Space…") { [beginRename] in beginRename(nil) }
        // "Show/Hide Space Header" only where it matters: a single unnamed Space. GUESS — capture PB5-a pending
        // (Arc strings "Show Space Header"/"Hide Space Header", "Menu item to toggle space header visibility").
        var header: [NSMenuItem] = []
        if context.incognitoTitle == nil, context.isSingleUnnamedSpace(space) {
            let shown = SpaceHeaderPreference.shared.showOnSingleUnnamedSpace
            header = [ClosureMenuItem(shown ? "Hide Space Header" : "Show Space Header") {
                SpaceHeaderPreference.shared.showOnSingleUnnamedSpace = !shown
            }]
        }
        return menu([
            item("Change Space Icon…", .changeSpaceIcon(space.id)),
            rename,
            item("Edit Theme Color…", .editSpaceTheme(space.id)),
            profile,
        ] + header + [
            .separator(),
            item("New Folder", .newFolder(in: .spacePinned(space.id))),
            liveFolders(space),
            .separator(),
            item("Share Space…", enabled: false, .shareSpace(space.id)),
            export,
            .separator(),
        ] + (inLibrary ? [] : [item("Manage Spaces…", .manageSpaces), .separator()]) + [
            item("Delete Space", enabled: context.model.spaces.count > 1, .deleteSpace(space.id)),
        ])
    }

    /// "Live Folders ▸ GitHub" (live-data §2.2: G:FUN_102ed863c / FUN_102edaf50); GitHub is a
    /// checkmark toggle. Incognito windows have no Live Folders.
    private func liveFolders(_ space: Space) -> NSMenuItem {
        let github = item("GitHub", enabled: context.incognitoTitle == nil, .toggleLiveFolder(space.id))
        github.state = context.model.liveFolder(in: space.id) == nil ? .off : .on
        let parent = NSMenuItem(title: "Live Folders", action: nil, keyEquivalent: "")
        parent.submenu = menu([github])
        return parent
    }

    /// Right-click on the URL field, Arc 1.172.2 (capture session 3 Part D): Copy URL · Share ▸ ·
    /// Capture… · Capture Full Page · Capture in Portrait Mode · — · Show as Toolbar ·
    /// Disable Shared Quotes. Share stays Open's picker until C3 records Arc's submenu.
    func urlField() -> NSMenu {
        let tab = context.currentTab
        let quotes = UserDefaults.standard.object(forKey: SidebarContext.sharedQuotesKey) as? Bool ?? true
        return menu([
            item("Copy URL", enabled: tab != nil, .copyCurrentURL),
            tab.map(share) ?? ClosureMenuItem("Share", enabled: false) {},
            item("Capture…", enabled: tab != nil, .performCommand("capture-page")),
            item("Capture Full Page", enabled: tab != nil, .performCommand("capture-full-page")),
            item("Capture in Portrait Mode", enabled: tab != nil, .performCommand("capture-portrait")),
            .separator(),
            item("Show as Toolbar", .setToolbarShown(true)),
            item(quotes ? "Disable Shared Quotes" : "Enable Shared Quotes", .setSharedQuotes(!quotes)),
        ])
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

    /// Bottom-bar "+", Arc 1.172.2 items and order (capture session 3 Part D): New Space ·
    /// New Folder · — · New Easel ⌃⇧E · New Boost · — · New Split ⌃⇧= · New Tab ⌘T.
    /// Arc draws it as a popover tinted with the Space title colour; its geometry and colours
    /// are capture pending (C3 session 8 item 7), so Open keeps a native menu until then.
    /// New Boost and New Split need a page (enabled in S3D with a page loaded).
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
        func keyed(_ row: NSMenuItem, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
            row.keyEquivalent = key; row.keyEquivalentModifierMask = modifiers; return row
        }
        return menu([
            item("New Space", .newSpace),
            space.map { item("New Folder", .newFolder(in: .spacePinned($0.id))) } ?? ClosureMenuItem("New Folder", enabled: false) {},
            .separator(),
            keyed(item("New Easel", enabled: !context.isIncognito, .newEasel), "e", [.control, .shift]),
            item("New Boost", enabled: !context.isIncognito && context.currentTab != nil, .performCommand("new-boost")),
            .separator(),
            keyed(item("New Split", enabled: canSplit, .newSplitView), "=", [.control, .shift]),
            keyed(item("New Tab", .newTab), "t", .command),
        ])
    }
}
