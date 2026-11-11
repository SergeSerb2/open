import AppKit
import Observation
import OpenModel
import OpenSettings
import OpenSidebar
import UniformTypeIdentifiers

@MainActor
extension LibraryPanelView {
    public var selectedRowID: String? { listView.selectedItem?.id }
    public var listFocused: Bool { window?.firstResponder === listView.table }
    public func filterDownloadProfile(_ raw:String) -> Bool {
        if raw == "all" { viewModel.downloadProfileFilter = nil }
        else if let profile = viewModel.model.profiles.first(where: { $0.id.description == raw }) { viewModel.downloadProfileFilter = profile.id }
        else { return false }
        renderRows(); return true
    }
    public func focusList() { listView.focus() }
    @discardableResult public func hoverRow(_ id:String,hovered:Bool) -> Bool { listView.hover(id:id,value:hovered) }
    @discardableResult public func performRow(_ id:String,action:String) -> Bool { listView.perform(id:id,action:action) }
    public func rowMenu(_ id:String,select:String? = nil) -> [[String:Any]]? { listView.menuState(id:id,select:select) }
    @discardableResult public func showRowMenu(_ id:String) -> Bool { listView.showMenu(id:id) }
    public func dragPayload(_ id:String) -> [String:Any]? { listView.dragState(id:id) }
    public func selectRow(_ id:String) -> Bool {
        guard let row = listView.entryIndex(id) else { return false }
        listView.table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); listView.table.scrollRowToVisible(row); listView.focus(); return true
    }
    public func setBoostLayout(_ name:String) { boostsLayout.selectedSegment = name == "Gallery" ? 1 : 0; changeBoostLayout() }
    public func setBoostProfile(_ name:String) -> Bool {
        guard boostsProfile.itemTitles.contains(name) else { return false }; boostsProfile.selectItem(withTitle:name); changeBoostProfile(); return true
    }
    func beginContentUpdates() { observeContent(); refreshData() }
    func endContentUpdates() { reloadTask?.cancel(); reloadTask = nil; historyTask?.cancel(); historyTask = nil }
    func refreshData() {
        reloadTask?.cancel(); historyTask?.cancel(); reloadGeneration += 1
        let generation = reloadGeneration
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.viewModel.refreshExternalState()
            guard !Task.isCancelled, self.isPresented, self.reloadGeneration == generation else { return }
            self.renderRows()
            if self.section == .media { for item in self.viewModel.captureItems.prefix(128) { guard !Task.isCancelled else { return }; await self.viewModel.loadThumbnail(item) } }
            if self.section == .history {
                self.historyTask = Task { @MainActor [weak self] in await self?.viewModel.watchHistory() }
            }
        }
    }
    func observeContent() {
        guard isPresented, !contentObservationArmed else { return }
        contentObservationArmed = true
        withObservationTracking {
            _ = viewModel.downloadItems; _ = viewModel.captureItems; _ = viewModel.archiveRows
            _ = viewModel.historyRows; _ = viewModel.boostItems; _ = viewModel.thumbnailImages
            _ = viewModel.faviconImages; _ = viewModel.historyFaviconImages
            _ = viewModel.statusText
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.contentObservationArmed = false
                if self.isPresented { self.renderRows(); self.observeContent() }
            }
        }
    }
    func dayLabel(_ date:Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if date >= calendar.date(byAdding:.day,value:-7,to:Date())! { return "Last 7 days" }
        return date.formatted(.dateTime.month(.wide).year())
    }
    func renderRows() {
        var rows: [LibraryRowItem] = []
        switch section {
        case .downloads: rows = downloadRows()
        case .archive: rows = archivedRows()
        case .history: rows = historyRows()
        case .boosts: rows = boostRows()
        case .media: rows = captureRows()
        case .spaces:
            if manager == nil {
                viewModel.refreshSpaceManagerView()
                if let manager = viewModel.spaceManagerView as? SpaceManagerView {
                    manager.libraryLayout = true; self.manager = manager; addSubview(manager)
                }
            }
        case .easels: break
        }
        updateEmptyCopy()
        if section == .media, viewModel.captures.loadFailed {
            emptyTitle.stringValue = "Could not load media"
            emptyBody.stringValue = "Close the Library and try again."
        }
        statusLabel.stringValue = section == .downloads && !viewModel.downloads.downloadHistoryError.isEmpty ? viewModel.downloads.downloadHistoryError : viewModel.statusText
        statusLabel.isHidden = statusLabel.stringValue.isEmpty || section == .spaces
        if rows.count < 8, (section == .archive && hasActiveFilters || section == .history && !historyWhenChips.isEmpty) { loadNextPage() }
        listView.gallery = section == .boosts && viewModel.boostsPresentation == .gallery
        listView.update(rows)
        listView.isHidden = rows.isEmpty || section == .spaces
        content.isHidden = !rows.isEmpty || (section == .spaces && manager != nil)
        manager?.isHidden = section != .spaces
        header.isHidden = section == .spaces || filterOpen
        filter.isHidden = !section.hasFilter || filterOpen
        filter.showsDot = hasActiveFilters
        filterEditor.isHidden = !filterOpen
        boostsLayout.isHidden = section != .boosts; boostsProfile.isHidden = section != .boosts
        let boostsOff = section == .boosts && !viewModel.defaults.bool(forKey:"open.advanced.enableBoosts")
        boostDisabledText.isHidden = !boostsOff; boostTurnOn.isHidden = !boostsOff
        listView.identifier = .init(section == .boosts ? (viewModel.boostsPresentation == .gallery ? "boosts.gallery" : "boosts.list") : "library.rows")
        boostsLayout.selectedSegment = viewModel.boostsPresentation == .gallery ? 1 : 0
        let profiles = viewModel.model.profiles
        boostsProfile.removeAllItems()
        for profile in profiles { boostsProfile.addItem(withTitle:profile.name); boostsProfile.lastItem?.representedObject = profile.id.description }
        if let index = profiles.firstIndex(where: { $0.id == viewModel.historyProfileID }) { boostsProfile.selectItem(at:index) }
        if filterOpen { configureFilter() }
        needsLayout = true
    }
    @objc func changeBoostLayout() { viewModel.boostsPresentation = boostsLayout.selectedSegment == 1 ? .gallery : .list; renderRows() }
    @objc func changeBoostProfile() {
        guard let raw = boostsProfile.selectedItem?.representedObject as? String, let id = UUID(uuidString:raw) else { return }
        viewModel.historyProfileID = ProfileID(rawValue:id); refreshData(); renderRows()
    }
    func fileIcon(_ name:String) -> NSImage {
        NSWorkspace.shared.icon(for:UTType(filenameExtension:URL(fileURLWithPath:name).pathExtension) ?? .data)
    }
    func symbol(_ name:String) -> NSImage? { NSImage(systemSymbolName:name,accessibilityDescription:nil) }
    func downloadRows() -> [LibraryRowItem] {
        viewModel.downloadItems.sorted { $0.startedAt > $1.startedAt }.map { item in
            let available = viewModel.fileAvailable(item)
            let progress = item.state == .inProgress || item.state == .paused
            let subtitle: String
            switch item.state {
            case .completed: subtitle = available ? "Download" : "File moved or deleted."
            case .failed: subtitle = "Failed"
            case .cancelled: subtitle = "Cancelled"
            case .paused: subtitle = "Paused"
            case .inProgress:
                let bytes = ByteCountFormatter(); bytes.countStyle = .file
                var received = bytes.string(fromByteCount:item.receivedBytes)
                if let total = item.totalBytes {
                    let target = bytes.string(fromByteCount:total)
                    if let unit = target.split(separator:" ").last, received.hasSuffix(" "+unit) { received.removeLast(unit.count+1) }
                    received += "/"+target
                    if item.bytesPerSecond > 0 { received += " · \(max(0,(total-item.receivedBytes)/item.bytesPerSecond))s" }
                }
                subtitle = received
            }
            let actions = viewModel.actions, id = item.id
            var menu: [LibraryRowAction] = []
            if progress {
                menu.append(.init(title:item.state == .paused ? "Resume" : "Pause",run:{ if item.state == .paused { actions.resumeDownload(id:id) } else { actions.pauseDownload(id:id) } }))
                menu.append(.init(title:"Cancel",run:{ actions.cancelDownload(id:id) }))
                menu.append(.init(title:"Show in Finder",enabled:available,run:{ actions.revealDownload(id:id) }))
            } else if item.state == .failed {
                menu.append(.init(title:"Retry",run:{ actions.retryDownload(id:id) }))
                menu.append(.init(title:"Hide from Open",run:{ actions.removeDownload(id:id) }))
            } else if item.state == .completed {
                menu = [.init(title:"Open",enabled:available,run:{ actions.openDownload(id:id) }),
                    .init(title:"Copy",enabled:available,run:{ actions.copyDownload(id:id) }),
                    .init(title:"Show in Finder",enabled:available,run:{ actions.revealDownload(id:id) }),
                    .init(title:"-",run:{}),.init(title:"Hide from Open",run:{ actions.removeDownload(id:id) }),
                    .init(title:"Move to Trash",enabled:available,run:{ actions.trashDownload(id:id) })]
            } else { menu = [.init(title:"Hide from Open",run:{ actions.removeDownload(id:id) })] }
            return LibraryRowItem(id:id,title:item.fileName,subtitle:subtitle,kind:"download",day:dayLabel(item.startedAt),
                image:progress ? nil : fileIcon(item.fileName),progress:progress ? item.progress ?? 0 : nil,
                dragURL:available && item.state == .completed ? item.filePath.map { URL(fileURLWithPath:$0) } : nil,
                activate:{ if available && item.state == .completed { actions.openDownload(id:id) } },actions:menu)
        }
    }
    func archivedRows() -> [LibraryRowItem] {
        viewModel.archiveRows.filter { row in
            let reason = row.reason == .autoArchived ? "auto" : "manual"
            let space = row.spaceID?.description ?? "little"
            return (archiveReasonChips.isEmpty || archiveReasonChips.contains(reason)) && (archiveSpaceChips.isEmpty || archiveSpaceChips.contains(space))
        }.map { row in
            let id = row.id
            let restore: () -> Void = { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }; await self.viewModel.restore(id:id)
                    if self.viewModel.restoredSpaceID != nil { self.onClose?() }
                }
            }
            let remove: () -> Void = { [weak self] in
                self?.confirm("Delete this archived tab?",message:"This cannot be undone.") { [weak self] in
                    guard let self else { return }; self.viewModel.requestDeleteArchive([id])
                    Task { @MainActor in await self.viewModel.deleteArchiveConfirmed(); self.renderRows() }
                }
            }
            return LibraryRowItem(id:id.description,title:viewModel.archivedDisplayTitle(row),subtitle:row.url.absoluteString,kind:"archive",day:dayLabel(row.archivedAt),
                image:viewModel.faviconImages[id] ?? symbol(row.kind == .folder ? "folder" : "globe"),dragURL:row.kind == .folder ? nil : row.url,activate:restore,
                hoverActions:[.init(title:"Delete",glyph:.trash,run:remove),.init(title:"Restore",glyph:.undo,run:restore)])
        }
    }
    func historyRows() -> [LibraryRowItem] {
        let profile = viewModel.historyProfileID
        return viewModel.historyRows.filter { row in
            guard !historyWhenChips.isEmpty else { return true }
            let age = Calendar.current.dateComponents([.day],from:Calendar.current.startOfDay(for:row.lastVisit),to:Calendar.current.startOfDay(for:Date())).day ?? 0
            let key = age == 0 ? "today" : age == 1 ? "yesterday" : age < 7 ? "week" : "older"
            return historyWhenChips.contains(key)
        }.map { row in
            let open: () -> Void = { [weak self] in
                guard let self, self.viewModel.historyProfileID == profile else { return }
                self.viewModel.actions.openHistoryItem(url:row.url); self.onClose?()
            }
            return LibraryRowItem(id:row.url.absoluteString,title:row.title.isEmpty ? row.url.host() ?? "Page" : row.title,
                subtitle:row.url.absoluteString+" · "+row.lastVisit.formatted(date:.omitted,time:.shortened),kind:"history",day:dayLabel(row.lastVisit),
                image:viewModel.historyFaviconImages[row.url] ?? symbol("globe"),dragURL:row.url,activate:open,
                hoverActions:[.init(title:"Delete",glyph:.trash,run:{ [weak self] in
                    self?.confirm("Delete this history entry?") { [weak self] in
                        guard let self, self.viewModel.historyProfileID == profile else { return }
                        self.viewModel.requestDeleteHistory([row.url]); Task { @MainActor in await self.viewModel.deleteHistoryConfirmed(); self.renderRows() }
                    }
                })])
        }
    }
    func captureRows() -> [LibraryRowItem] {
        viewModel.captureItems.map { item in
            let id = item.id, actions = viewModel.actions
            return LibraryRowItem(id:id.uuidString,title:item.fileName,subtitle:"Capture · "+item.createdAt.formatted(date:.abbreviated,time:.omitted),kind:"capture",day:dayLabel(item.createdAt),
                image:viewModel.thumbnailImages[id] ?? fileIcon(item.fileName),dragURL:viewModel.captureURL(item),activate:{ actions.openCapture(id:id) },
                actions:[.init(title:"Open",run:{ actions.openCapture(id:id) }),.init(title:"Copy",run:{ actions.copyCapture(id:id) }),
                    .init(title:"Show in Finder",run:{ actions.revealCapture(id:id) }),.init(title:"Save As…",run:{ [weak self] in self?.saveCapture(item) }),
                    .init(title:"-",run:{}),.init(title:"Delete",run:{ [weak self] in self?.confirm("Delete this capture?",message:"This permanently deletes the file.") { [weak self] in
                        self?.viewModel.pendingCaptureDelete = id; self?.viewModel.deleteCaptureConfirmed(); self?.renderRows()
                    } })])
        }
    }
    func boostRows() -> [LibraryRowItem] {
        let profile = viewModel.historyProfileID
        return viewModel.boostItems.map { item in
            let id = item.id
            let edit: () -> Void = { [weak self] in
                guard let self else { return }
                self.viewModel.actions.editBoost(id:id,profileID:profile)
            }
            return LibraryRowItem(id:id,title:item.domain,subtitle:item.name+" · "+(item.isEnabled ? "on" : "off"),kind:"boost",image:symbol("paintbrush.pointed"),activate:edit,
                actions:[.init(title:"Edit Boost",run:edit),.init(title:item.isEnabled ? "Turn Off" : "Turn On",run:{ [weak self] in
                    guard let self else { return }
                    self.viewModel.actions.setBoostEnabled(id:id,enabled:!item.isEnabled,profileID:profile); self.renderRows()
                }),.init(title:"-",run:{}),.init(title:"Delete",run:{ [weak self] in
                    self?.confirm("Delete this Boost?") { [weak self] in
                        guard let self, self.viewModel.historyProfileID == profile else { return }
                        self.viewModel.actions.deleteBoost(id:id,profileID:profile); self.renderRows()
                    }
                })])
        }
    }
    func confirm(_ title:String,message:String = "",action:@escaping @MainActor () -> Void) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle:"Delete"); alert.addButton(withTitle:"Cancel")
        alert.beginSheetModal(for:window) { response in if response == .alertFirstButtonReturn { action() } }
    }
    func confirmClearHistory() {
        let profile = viewModel.historyProfileID
        confirm("Clear all history for this Profile?") { [weak self] in
            guard let self, self.viewModel.historyProfileID == profile else { return }
            Task { @MainActor in await self.viewModel.clearHistoryConfirmed(); self.renderRows() }
        }
    }
    func saveCapture(_ item:CaptureItemSnapshot) {
        guard let window else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = item.fileName
        panel.beginSheetModal(for:window) { [weak self] response in if response == .OK, let url = panel.url { self?.viewModel.saveCapture(item,to:url) } }
    }
    func loadNextPage() {
        if section == .archive { loadNextArchivePage() }
        else if section == .history, isPresented, viewModel.historyHasMore, !viewModel.historyLoading, !historyPageLoading {
            historyPageLoading = true
            Task { @MainActor [weak self] in
                guard let self else { return }; await self.viewModel.loadNextHistoryPage(); self.historyPageLoading = false
                if self.isPresented, self.section == .history { self.renderRows() }
            }
        }
    }
    func loadNextArchivePage() {
        guard isPresented, section == .archive, viewModel.archiveHasMore, !viewModel.archiveLoading, !archivePageLoading else { return }
        archivePageLoading = true
        Task { @MainActor [weak self] in
            guard let self else { return }; await self.viewModel.loadNextArchivePage(); self.archivePageLoading = false
            if self.isPresented, self.section == .archive { self.renderRows() }
        }
    }
    var hasActiveFilters: Bool {
        switch section {
        case .downloads: viewModel.downloadProfileFilter != nil
        case .archive: !archiveReasonChips.isEmpty || !archiveSpaceChips.isEmpty
        case .history: !historyWhenChips.isEmpty || viewModel.historyProfileID != context.focusedSpace?.profileID
        default: false
        }
    }
    public func setFilterOpen(_ value:Bool) {
        filterOpen = value
        if value { configureFilter() }
        renderRows(); needsLayout = true; layoutSubtreeIfNeeded()
    }
    func configureFilter() {
        func profileChips(_ selected:ProfileID?) -> [LibraryFilterChip] {
            viewModel.model.profiles.map { .init(id:"profile:"+$0.id.description,title:$0.name,selected:$0.id == selected) }
        }
        let groups: [LibraryFilterGroup]
        switch section {
        case .downloads: groups = [.init(title:"Profiles",chips:profileChips(viewModel.downloadProfileFilter))]
        case .archive:
            groups = [.init(title:"How was the tab closed?",chips:[.init(id:"reason:auto",title:"Auto-Closed",selected:archiveReasonChips.contains("auto")),.init(id:"reason:manual",title:"Manually Closed",selected:archiveReasonChips.contains("manual"))]),
                .init(title:"Where was the tab?",chips:[.init(id:"space:little",title:"Little Open",selected:archiveSpaceChips.contains("little"))]+viewModel.model.spaces.map { .init(id:"space:"+$0.id.description,title:viewModel.model.displayTitle(for:$0),selected:archiveSpaceChips.contains($0.id.description)) })]
        case .history:
            groups = [.init(title:"Profiles",chips:profileChips(viewModel.historyProfileID)),.init(title:"When",chips:[("today","Today"),("yesterday","Yesterday"),("week","Last 7 days"),("older","Older")].map { .init(id:"when:"+$0.0,title:$0.1,selected:historyWhenChips.contains($0.0)) })]
        default: groups = []
        }
        filterEditor.update(title:section == .archive ? "Filter Archived Tabs" : "Filter \(section.title)…",groups:groups,foreground:foreground,overlay:overlay,clear:section == .history)
    }
    @discardableResult public func toggleChip(_ id:String) -> Bool {
        let parts = id.split(separator:":",maxSplits:1).map(String.init); guard parts.count == 2 else { return false }
        func toggle(_ value:String,in values:inout Set<String>) { if !values.insert(value).inserted { values.remove(value) } }
        switch parts[0] {
        case "profile":
            guard let uuid = UUID(uuidString:parts[1]),viewModel.model.profile(id:ProfileID(rawValue:uuid)) != nil else { return false }
            let profile = ProfileID(rawValue:uuid)
            if section == .downloads { viewModel.downloadProfileFilter = viewModel.downloadProfileFilter == profile ? nil : profile }
            else if section == .history { viewModel.historyProfileID = profile } else { return false }
        case "reason": toggle(parts[1],in:&archiveReasonChips)
        case "space": toggle(parts[1],in:&archiveSpaceChips)
        case "when": toggle(parts[1],in:&historyWhenChips)
        default: return false
        }
        configureFilter(); refreshData(); renderRows(); return true
    }
}
