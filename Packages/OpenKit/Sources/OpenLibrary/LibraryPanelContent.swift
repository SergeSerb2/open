import AppKit
import Observation
import OpenModel
import OpenSettings
import OpenSidebar
import UniformTypeIdentifiers
import OpenDesign

@MainActor
extension LibraryPanelView {
    public var hasPendingFirstScreen: Bool {
        guard section != .spaces, let host = hosts[section] else { return false }
        return !host.loaded || host.dirty || host.preparation != nil
    }
    /// The socket bench awaits the same provider task as the live panel, then
    /// submits its real native layout/drawing. This does not wait for motion.
    public func finishPendingContent() async {
        if hosts[section]?.loaded == false { await hosts[section]?.provider?.value }
        // A provider publication may cancel a superseded preparation. Await
        // the current generation, rather than replying with its old empty page.
        guard let host = hosts[section] else { return }
        for _ in 0..<32 {
            let generation = host.generation
            await host.preparation?.value
            await Task.yield()
            if generation == host.generation,host.preparation == nil,!host.dirty { return }
        }
    }
    public var listReuseState: [String:Int] { ["created":listView.totalCellsCreated,"configured":listView.cellsConfigured,"rows":listView.rowCount] }
    public var performanceCounters: [String:Double] {
        var state: [String:Double] = ["hosts":Double(hosts.count),"created":0,"configured":0,"reloadData":0,"tableUpdates":0,"formatting":0,"listLayout":0,"tasks":0,"timers":0,"displayLinks":0,"animations":Double((layer?.animationKeys() ?? []).filter { $0.hasPrefix("library") }.count)]
        state["tasks"] = idleWarming ? 1 : 0
        for host in hosts.values {
            state["animations",default:0] += Double((host.list.layer?.animationKeys() ?? []).filter { $0.hasPrefix("library") }.count)
            state["created",default:0] += Double(host.list.totalCellsCreated)
            state["configured",default:0] += Double(host.list.cellsConfigured)
            state["reloadData",default:0] += Double(host.list.reloads)
            state["tableUpdates",default:0] += Double(host.list.updates)
            state["formatting",default:0] += host.list.formattingMilliseconds
            state["listLayout",default:0] += host.list.layoutMilliseconds
            state["tasks",default:0] += Double((host.preparation == nil ? 0 : 1)+(host.append == nil ? 0 : 1))
            state["tasks",default:0] += Double((host.provider == nil ? 0 : 1)+host.list.pendingTasks)
            for (key,value) in host.list.table.phases { state["scroll."+key,default:0] += value }
        }
        for (key,value) in LibraryRaster.events { state["wake."+key] = value }
        state["rasterStores"] = LibraryRaster.stores; state["rasterPixels"] = LibraryRaster.pixels
        state["textRasters"] = LibraryRaster.text; state["glyphRasters"] = LibraryRaster.glyphs
        state["configureMaximum"] = hosts.values.map { $0.list.configureMaximumMilliseconds }.max() ?? 0
        let configurations = hosts.values.flatMap { $0.list.configureSamples }.sorted()
        for (name,fraction) in [("configureP50",0.5),("configureP95",0.95)] {
            state[name] = configurations.isEmpty ? 0 : configurations[min(configurations.count-1,Int(Double(configurations.count-1)*fraction))]
        }
        state["warmupComplete"] = warmedRows ? 1 : 0
        state["providerWarm"] = hosts[section]?.wasWarmed == true ? 1 : 0
        state["warmedSectionPages"] = Double(hosts.values.filter { $0.wasWarmed && $0.loaded }.count)
        for (key,value) in switchPhases { state["switch."+key] = value }
        for (key,value) in submissionPhases { state["last."+key] = value }
        for (key,value) in hosts[section]?.phaseMilliseconds ?? [:] { state["last."+key] = value }
        return state
    }
    /// Constant-cost counters for the display callback. Percentile sorting and
    /// full-host diagnostics are read outside the measured scroll series.
    public var scrollCounters: [String:Double] {
        var state = ["created":Double(listView.totalCellsCreated),"configured":Double(listView.cellsConfigured),"formatting":listView.formattingMilliseconds,"listLayout":listView.layoutMilliseconds]
        for (key,value) in listView.table.phases { state["scroll."+key] = value }
        for (key,value) in submissionPhases { state["last."+key] = value }
        for (key,value) in LibraryRaster.events { state["wake."+key] = value }
        return state
    }
    public func submitNativeFrame() {
        let start = ProcessInfo.processInfo.systemUptime
        window?.layoutIfNeeded(); layoutSubtreeIfNeeded()
        let laidOut = ProcessInfo.processInfo.systemUptime
        window?.displayIfNeeded()
        let drawn = ProcessInfo.processInfo.systemUptime
        CATransaction.flush()
        let flushed = ProcessInfo.processInfo.systemUptime
        nativeCommittedAt = flushed
        submissionPhases = ["layout":(laidOut-start)*1000,"display":(drawn-laidOut)*1000,"flush":(flushed-drawn)*1000]
    }
    public func scrollToRow(_ index:Int) -> Int {
        guard listView.rowCount > 0 else { return 0 }
        let row = max(0,min(index,listView.table.numberOfRows-1))
        listView.table.scrollRowToVisible(row); submitNativeFrame()
        return listView.table.rows(in:listView.table.visibleRect).length
    }
    public var filteredRowCount: Int { hosts[section]?.filtered.count ?? 0 }
    public var selectedRowID: String? { listView.selectedItem?.id }
    public var listFocused: Bool { window?.firstResponder === listView.table }
    public func filterDownloadProfile(_ raw:String) -> Bool {
        if raw == "all" { viewModel.downloadProfileFilter = nil }
        else if let profile = viewModel.model.profiles.first(where: { $0.id.description == raw }) { viewModel.downloadProfileFilter = profile.id }
        else { return false }
        hosts[section]?.dirty = true; renderRows(); return true
    }
    public func focusList() { listView.focus() }
    @discardableResult public func hoverRow(_ id:String,hovered:Bool) -> Bool { listView.hover(id:id,value:hovered) }
    @discardableResult public func performRow(_ id:String,action:String) -> Bool { listView.perform(id:id,action:action) }
    public func rowMenu(_ id:String,select:String? = nil) -> [[String:Any]]? { listView.menuState(id:id,select:select) }
    @discardableResult public func showRowMenu(_ id:String,escapeOnOpen:Bool = false) -> Bool { listView.showMenu(id:id,escapeOnOpen:escapeOnOpen) }
    public func dragPayload(_ id:String) -> [String:Any]? { listView.dragState(id:id) }
    public func selectRow(_ id:String) -> Bool {
        guard let row = listView.entryIndex(id) else { return false }
        listView.table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); listView.table.scrollRowToVisible(row); listView.focus(); return true
    }
    public func setBoostLayout(_ name:String) {
        let next: BoostsPresentation = name == "Gallery" ? .gallery : .list
        guard viewModel.boostsPresentation != next else { return }
        viewModel.boostsPresentation = next
        if contentActive { renderRows() } else { prebuiltReady = false }
    }
    public func setBoostProfile(_ name:String) -> Bool {
        guard let profile = viewModel.model.profiles.first(where: { $0.name == name }) else { return false }
        viewModel.historyProfileID = profile.id; hosts[section]?.loaded = false; hosts[section]?.dirty = true; refreshData(); renderRows(); return true
    }
    func showBoostProfiles() {
        let menu = NSMenu(); menu.autoenablesItems = false
        for profile in viewModel.model.profiles {
            let item = NSMenuItem(title:profile.name,action:nil,keyEquivalent:"")
            let target = LibraryProfileChoice { [weak self] in _ = self?.setBoostProfile(profile.name) }
            item.target = target; item.action = #selector(LibraryProfileChoice.select); item.representedObject = target
            item.state = profile.id == viewModel.historyProfileID ? .on : .off; menu.addItem(item)
        }
        menu.popUp(positioning:nil,at:CGPoint(x:0,y:boostsProfile.bounds.maxY),in:boostsProfile)
    }
    func beginContentUpdates() {
        // Reopening checks external stores once. A section switch does not.
        for host in hosts.values { host.loaded = false }
        observeContent(); refreshData()
    }
    func endContentUpdates() {
        skeletonTask?.cancel(); skeletonTask = nil; loadingSkeleton.isHidden = true
        reloadTask?.cancel(); reloadTask = nil; historyTask?.cancel(); historyTask = nil
        for host in hosts.values { host.cancel(); host.provider?.cancel(); host.provider = nil; host.providerGeneration += 1; host.list.cancelPrefetch() }
    }
    func refreshData() {
        let target = section, host = host(for:section)
        guard contentActive, !host.loaded else { return }
        if host.provider != nil { return }
        skeletonTask?.cancel()
        skeletonTask = Task { @MainActor [weak self,weak host] in
            try? await Task.sleep(for:.milliseconds(120))
            guard let self,let host,!Task.isCancelled,self.contentActive,self.section == target,!host.loaded else { return }
            self.loadingSkeleton.isHidden = false
            self.skeletonTask = nil
        }
        startProvider(target)
    }
    func loadProvider(_ target:LibraryPanelSection) async {
        let host = host(for:target)
        if host.loaded { return }
        startProvider(target)
        let generation = host.providerGeneration
        await withTaskCancellationHandler { await host.provider?.value } onCancel: {
            Task { @MainActor [weak host] in if host?.providerGeneration == generation { host?.provider?.cancel() } }
        }
    }
    func startProvider(_ target:LibraryPanelSection) {
        let host = host(for:target)
        if target == .easels { if !host.loaded, host.provider == nil { startEaselsProvider(host) }; return }
        guard !host.loaded,host.provider == nil,let mapped = target.modelSection else { return }
        if target == .archive { host.storeVersion = viewModel.archives.keys.sorted { $0.description < $1.description }.map { String(viewModel.archives[$0]!.contentVersion) }.joined(separator:",") }
        host.providerGeneration += 1
        let generation = host.providerGeneration
        host.provider = Task { @MainActor [weak self,weak host] in
            guard let self,let host else { return }
            defer { if generation == host.providerGeneration { host.provider = nil } }
            let started = ProcessInfo.processInfo.systemUptime
            await self.viewModel.refreshExternalState(for:mapped)
            guard !Task.isCancelled,host.providerGeneration == generation else { return }
            host.phaseMilliseconds["provider"] = (ProcessInfo.processInfo.systemUptime-started)*1000
            host.loaded = true; host.dirty = true
            if self.section == target,self.contentActive {
                self.skeletonTask?.cancel(); self.skeletonTask = nil; self.loadingSkeleton.isHidden = true
                self.renderRows()
            }
            if target == .history, host.storeWatch == nil, let store = self.viewModel.histories[self.viewModel.historyProfileID] {
                host.storeWatch = Task { @MainActor [weak self,weak host] in
                    let changes = await store.changes(); var initial = true
                    for await _ in changes {
                        guard let self,let host,!Task.isCancelled else { return }
                        if initial { initial = false; continue }
                        host.loaded = false; host.dirty = true
                        if self.contentActive,self.section == .history { self.refreshData() } else { self.prebuiltReady = false; self.onIdleRefresh?() }
                    }
                }
            }
        }
    }
    func observeContent() {
        for target in [LibraryPanelSection.downloads,.archive,.history,.media,.boosts] where !sourceObservationArmed.contains(target) {
            sourceObservationArmed.insert(target)
            let historyProfile = (target == .history || target == .boosts) ? viewModel.historyProfileID : nil
            withObservationTracking {
                switch target {
                case .downloads: _ = viewModel.downloads.downloads; _ = viewModel.downloadProfileFilter; _ = context.downloadBadge?.completedAt
                case .archive: _ = viewModel.archiveRows; _ = viewModel.archives.values.map(\.contentVersion)
                case .history: _ = viewModel.historyRows; _ = viewModel.historyProfileID
                case .media: _ = viewModel.captures.captures; _ = viewModel.thumbnailImages
                    _ = viewModel.mediaFolders?.files; _ = viewModel.mediaFolders?.enabled; _ = viewModel.mediaFolders?.onboarded
                case .boosts: _ = viewModel.boostsProvider?.libraryBoostsVersion; _ = viewModel.historyProfileID
                default: break
                }
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.sourceObservationArmed.remove(target)
                    var storeChanged = false
                    if (target == .history || target == .boosts), historyProfile != self.viewModel.historyProfileID {
                        // Profile changes alone retire the old subscription and
                        // provider. Ordinary opens and list updates keep both.
                        if let host = self.hosts[target] {
                            host.storeWatch?.cancel(); host.storeWatch = nil
                            host.provider?.cancel(); host.provider = nil; host.providerGeneration += 1
                            host.loaded = false; host.wasWarmed = false
                        }
                        storeChanged = true
                    }
                    if target == .archive, let host = self.hosts[target] {
                        let version = self.viewModel.archives.keys.sorted { $0.description < $1.description }.map { String(self.viewModel.archives[$0]!.contentVersion) }.joined(separator:",")
                        if version != host.storeVersion { host.storeVersion = version; host.loaded = false; storeChanged = true }
                    }
                    self.hosts[target]?.dirty = true
                    if target == .boosts { self.hosts[target]?.loaded = false; storeChanged = true }
                    self.prebuiltReady = false
                    if self.contentActive {
                        if self.section == target { if storeChanged { self.refreshData() } else { self.renderRows() } }
                    } else { self.onIdleRefresh?() }
                    self.observeContent()
                }
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
        let host = host(for:section)
        // Header/theme/empty-state work is independent of the data snapshot.
        updateContentChrome()
        guard contentActive else { return }
        if section == .spaces {
            if manager == nil {
                viewModel.refreshSpaceManagerView()
                if let manager = viewModel.spaceManagerView as? SpaceManagerView { manager.libraryLayout = true; self.manager = manager; addSubview(manager) }
            }
            updateContentChrome(); return
        }
        // External providers publish during refresh. Wait for that refresh's
        // completed snapshot instead of preparing both its intermediate value
        // and its final value (and configuring the first screen twice).
        guard host.loaded else { return }
        let identity = "\(viewModel.query)|\(viewModel.downloadProfileFilter?.description ?? "")|\(viewModel.historyProfileID)|\(archiveReasonChips.sorted())|\(archiveSpaceChips.sorted())|\(historyWhenChips.sorted())|\(viewModel.boostsPresentation)"
        guard host.dirty || host.identity != identity else { return }
        host.cancel(); host.generation += 1
        let generation = host.generation, target = section, query = viewModel.query
        let rebuild = host.dirty
        host.identity = identity; host.dirty = false
        if rebuild {
            let started = ProcessInfo.processInfo.systemUptime
            switch target {
            case .downloads: host.sources = downloadSources()
            case .archive: host.sources = archivedSources()
            case .history: host.sources = historySources()
            case .media: host.sources = ((viewModel.mediaFolders?.isEnabled(.capture) ?? true ? captureSources() : []) + mediaFileSources())
                .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            case .boosts: host.sources = boostSources()
            case .easels: host.sources = easelAndNoteSources()
            default: host.sources = []
            }
            host.sourceVersion += 1
            host.phaseMilliseconds["snapshot"] = (ProcessInfo.processInfo.systemUptime-started)*1000
        }
        let prepare = host.preparedVersion != host.sourceVersion
        let version = host.sourceVersion
        let seeds = prepare ? host.sources.enumerated().map { LibraryRowSeed(index:$0.offset,id:$0.element.id,date:$0.element.date,text:$0.element.text) } : []
        let cached = host.prepared
        let worker = Task.detached(priority:.userInitiated) {
            let prepared = prepare ? prepareLibraryRows(seeds) : cached
            return prepared
        }
        host.worker = worker
        host.preparation = Task { @MainActor [weak self,weak host] in
            let prepareStart = ProcessInfo.processInfo.systemUptime
            let prepared = await worker.value
            guard let self, let host, !Task.isCancelled, host.generation == generation else { return }
            host.prepared = prepared; host.preparedVersion = version
            host.phaseMilliseconds["prepareBackground"] = (ProcessInfo.processInfo.systemUptime-prepareStart)*1000
            let filterStart = ProcessInfo.processInfo.systemUptime
            let filter = Task.detached(priority:.userInitiated) {
                let key = query.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:.current)
                return key.isEmpty ? prepared : prepared.filter { !Task.isCancelled && $0.key.contains(key) }
            }
            host.worker = filter
            let filtered = await filter.value
            guard !Task.isCancelled, host.generation == generation else { return }
            host.filtered = filtered
            host.phaseMilliseconds["filterBackground"] = (ProcessInfo.processInfo.systemUptime-filterStart)*1000
            self.applyPage(host,target:target,count:min(60,filtered.count))
            host.preparation = nil; host.worker = nil
            // Append idle slices. They contain lazy sources, never formatted rows.
            host.append = Task { @MainActor [weak self,weak host] in
                var count = min(60,filtered.count)
                while count < filtered.count {
                    try? await Task.sleep(for:.milliseconds(16))
                    guard let self,let host,!Task.isCancelled,host.generation == generation,(self.contentActive || self.prebuiltReady) else { return }
                    count = min(count+240,filtered.count)
                    self.applyPage(host,target:target,count:count)
                }
                host?.append = nil
            }
        }
    }
    func applyPage(_ host:LibrarySectionHost,target:LibraryPanelSection,count:Int) {
        let started = ProcessInfo.processInfo.systemUptime
        let sources = host.filtered.prefix(count).map { item in
            let source = host.sources[item.index]; source.day = item.day; return source
        }
        host.list.gallery = target == .boosts && viewModel.boostsPresentation == .gallery
        host.list.update(sources)
        host.phaseMilliseconds["apply"] = (ProcessInfo.processInfo.systemUptime-started)*1000
        if section == target {
            updateContentChrome()
            if count < 8, (target == .archive || target == .history), hasActiveFilters { loadNextPage() }
        }
    }
    func updateContentChrome() {
        let rowsEmpty = listView.rowCount == 0
        updateEmptyCopy()
        if section == .media, viewModel.captures.loadFailed { emptyTitle.stringValue = "Could not load media"; emptyBody.stringValue = "Close the Library and try again." }
        statusLabel.stringValue = section == .downloads && !viewModel.downloads.downloadHistoryError.isEmpty ? viewModel.downloads.downloadHistoryError : viewModel.statusText
        statusLabel.isHidden = statusLabel.stringValue.isEmpty || section == .spaces
        for (target,host) in hosts { host.list.isHidden = target != section || (host.loaded && host.list.rowCount == 0) || section == .spaces }
        layoutActiveList()
        content.isHidden = !rowsEmpty || (section == .spaces && manager != nil) || (section != .spaces && hosts[section]?.loaded != true)
        manager?.isHidden = section != .spaces
        header.isHidden = section == .spaces || filterOpen; filter.isHidden = !section.hasFilter || filterOpen
        filter.showsDot = hasActiveFilters; filterEditor.isHidden = !filterOpen
        boostList.isHidden = section != .boosts; boostGallery.isHidden = section != .boosts; boostsProfile.isHidden = section != .boosts
        let boostsOff = section == .boosts && !viewModel.defaults.bool(forKey:"open.advanced.enableBoosts")
        boostDisabledText.isHidden = !boostsOff; boostTurnOn.isHidden = !boostsOff
        easelsCard.isHidden = section != .easels || filterOpen
        listView.identifier = .init(section == .boosts ? (viewModel.boostsPresentation == .gallery ? "boosts.gallery" : "boosts.list") : "library.rows")
        boostList.selected = viewModel.boostsPresentation == .list; boostGallery.selected = viewModel.boostsPresentation == .gallery
        boostsProfile.title = viewModel.model.profile(id:viewModel.historyProfileID)?.name ?? "Profile"
        if filterOpen { configureFilter() }
        let layoutKey = "\(section == .easels)|\(section == .spaces)|\(section.hasFilter)|\(filterOpen)|\(section == .boosts)|\(boostsOff)|\(statusLabel.isHidden)"
        if lastHeaderLayoutKey != layoutKey { lastHeaderLayoutKey = layoutKey; needsLayout = true }
    }
    func symbol(_ name:String) -> NSImage? {
        if let image = symbolCache[name] { return image }
        let image = NSImage(systemSymbolName:name,accessibilityDescription:nil); symbolCache[name] = image; return image
    }
    func downloadSources() -> [LibraryRowSource] {
        viewModel.downloads.downloads.filter { item in
            (viewModel.downloadProfileFilter == nil || item.profileID == viewModel.downloadProfileFilter) && (viewModel.downloadStateFilter == nil || item.state == viewModel.downloadStateFilter)
        }.map { item in
          LibraryRowSource(id:item.id,date:item.startedAt,text:item.fileName+" "+item.sourceHost,prepareText:{ LibraryRowText(title:item.fileName,subtitle:downloadSubtitle(item)) }) { [unowned self] prepared in
            let available = viewModel.fileAvailable(item)
            let progress = item.state == .inProgress || item.state == .paused
            let subtitle = prepared?.subtitle ?? downloadSubtitle(item)
            let actions = viewModel.actions, id = item.id
            // Arc's download menu, capture session 8 items 9–10 (`v10/27`, `v11/28a`, `v13/35`; read from the menu
            // window frames): "Open ‹kind›" · "Copy ‹kind›" · Show in Finder · — · … · Hide from Arc. ‹kind› is Arc's
            // file-kind word (`downloadKind`), else the extension ("Open txt"); no extension: "Open" (guess).
            // Arc has no pause, resume or retry menu items: Open keeps them as row hover controls.
            let word = downloadKind(item.fileName) ?? URL(fileURLWithPath:item.fileName).pathExtension
            let named = { (verb: String) in word.isEmpty ? verb : verb + " " + word }
            let done = item.state == .completed && available
            let hide = LibraryRowAction(title:"Hide from Open",run:{ actions.removeDownload(id:id) })
            var menu: [LibraryRowAction] = []
            var hover: [LibraryRowAction] = []
            switch item.state {
            case .inProgress, .paused:
                // Running: Open ‹kind› drawn enabled (guess: it opens the file when it is there), Copy and Show in Finder disabled.
                menu = [.init(title:named("Open"),run:{ actions.openDownload(id:id) }),.init(title:named("Copy"),enabled:false,run:{}),
                    .init(title:"Show in Finder",enabled:false,run:{}),.init(title:"-",run:{}),
                    .init(title:"Cancel Download",run:{ actions.cancelDownload(id:id) }),.init(title:"-",run:{}),hide]
                hover = [item.state == .paused ? .init(title:"Resume",glyph:.resume,run:{ actions.resumeDownload(id:id) })
                                               : .init(title:"Pause",glyph:.pause,run:{ actions.pauseDownload(id:id) }),
                         .init(title:"Cancel",glyph:.cancel,run:{ actions.cancelDownload(id:id) })]
            case .completed:
                menu = [.init(title:named("Open"),enabled:done,run:{ actions.openDownload(id:id) }),
                    .init(title:named("Copy"),enabled:done,run:{ actions.copyDownload(id:id) }),
                    .init(title:"Show in Finder",enabled:available,run:{ actions.revealDownload(id:id) }),
                    .init(title:"-",run:{}),hide,
                    .init(title:"Move to Trash",enabled:available,run:{ actions.trashDownload(id:id) })]
            case .cancelled, .failed:
                // Cancelled and interrupted: the three file items disabled · — · Hide from Arc; no Retry item.
                menu = [.init(title:named("Open"),enabled:false,run:{}),.init(title:named("Copy"),enabled:false,run:{}),
                    .init(title:"Show in Finder",enabled:false,run:{}),.init(title:"-",run:{}),hide]
                // Open's own: Retry stays a hover control on a failed download (Arc shows none).
                if item.state == .failed { hover = [.init(title:"Retry",glyph:.retry,run:{ actions.retryDownload(id:id) })] }
            }
            return LibraryRowItem(id:id,title:item.fileName,subtitle:subtitle,kind:"download",day:"",
                fileURL:progress ? nil : URL(fileURLWithPath:item.filePath ?? item.fileName),progress:progress ? item.progress ?? 0 : nil,
                dragURL:available && item.state == .completed ? item.filePath.map { URL(fileURLWithPath:$0) } : nil,
                activate:{ if available && item.state == .completed { actions.openDownload(id:id) } },actions:menu,hoverActions:hover,
                // Arc: a right-click on a download row opens no menu, it only selects the row; the More button opens it.
                contextMenu:false,moreTooltip:"More Options")
          }
        }
    }
    func archivedSources() -> [LibraryRowSource] {
        viewModel.archiveRows.filter { row in
            let reason = row.reason == .autoArchived ? "auto" : "manual"
            let space = row.spaceID?.description ?? "little"
            return (archiveReasonChips.isEmpty || archiveReasonChips.contains(reason)) && (archiveSpaceChips.isEmpty || archiveSpaceChips.contains(space))
        }.map { row in
          LibraryRowSource(id:row.id.description,date:row.archivedAt,text:row.title+" "+row.url.absoluteString) { [unowned self] _ in
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
            return LibraryRowItem(id:id.description,title:viewModel.archivedDisplayTitle(row),subtitle:row.url.absoluteString,kind:"archive",day:"",
                image:symbol(row.kind == .folder ? "folder" : "globe"),loadImage:row.kind == .folder ? nil : { [weak self] callback in self?.viewModel.loadRowIcon(row.url,completion:callback) },dragURL:row.kind == .folder ? nil : row.url,activate:restore,
                hoverActions:[.init(title:"Delete",glyph:.trash,run:remove),.init(title:"Restore",glyph:.undo,run:restore)])
          }
        }
    }
    func historySources() -> [LibraryRowSource] {
        let profile = viewModel.historyProfileID
        return viewModel.historyRows.filter { row in
            guard !historyWhenChips.isEmpty else { return true }
            let age = Calendar.current.dateComponents([.day],from:Calendar.current.startOfDay(for:row.lastVisit),to:Calendar.current.startOfDay(for:Date())).day ?? 0
            return (historyWhenChips.contains("today") && age == 0)
                || (historyWhenChips.contains("yesterday") && age == 1)
                || (historyWhenChips.contains("week") && age >= 0 && age < 7)
                || (historyWhenChips.contains("older") && age >= 7)
        }.map { row in
          LibraryRowSource(id:row.url.absoluteString,date:row.lastVisit,text:row.title+" "+row.url.absoluteString,prepareText:{ LibraryRowText(title:row.title.isEmpty ? row.url.host() ?? "Page" : row.title,subtitle:row.url.absoluteString+" · "+row.lastVisit.formatted(date:.omitted,time:.shortened)) }) { [unowned self] prepared in
            let open: () -> Void = { [weak self] in
                guard let self, self.viewModel.historyProfileID == profile else { return }
                self.viewModel.actions.openHistoryItem(url:row.url); self.onClose?()
            }
            return LibraryRowItem(id:row.url.absoluteString,title:row.title.isEmpty ? row.url.host() ?? "Page" : row.title,
                subtitle:prepared?.subtitle ?? row.url.absoluteString+" · "+row.lastVisit.formatted(date:.omitted,time:.shortened),kind:"history",day:"",
                image:symbol("globe"),loadImage:{ [weak self] callback in self?.viewModel.loadRowIcon(row.url,completion:callback) },dragURL:row.url,activate:open,
                hoverActions:[.init(title:"Delete",glyph:.trash,run:{ [weak self] in
                    self?.confirm("Delete this history entry?") { [weak self] in
                        guard let self, self.viewModel.historyProfileID == profile else { return }
                        self.viewModel.requestDeleteHistory([row.url]); Task { @MainActor in await self.viewModel.deleteHistoryConfirmed(); self.renderRows() }
                    }
                })])
          }
        }
    }
    /// "Send via iMessage" and "AirDrop" for a file, through the system share services.
    static func shareActions(_ url: URL?) -> [LibraryRowAction] {
        [("Send via iMessage", NSSharingService.Name.composeMessage), ("AirDrop", .sendViaAirDrop)].map { title, name in
            LibraryRowAction(title: title, enabled: url != nil) {
                guard let url, let service = NSSharingService(named: name) else { return }
                service.perform(withItems: [url])
            }
        }
    }
    /// Arc's "Copy ‹kind›" (its code appends a kind to "Copy "; "Copy Image" is a full title in the shared menu).
    static func copyTitle(_ url: URL) -> String {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true { return "Copy Image" }
        if type?.conforms(to: .movie) == true { return "Copy Video" }   // guess
        return "Copy"
    }
    func captureSources() -> [LibraryRowSource] {
        viewModel.captures.captures.map { item in
          LibraryRowSource(id:item.id.uuidString,date:item.createdAt,text:(item.title ?? "")+" "+item.fileName+" "+item.sourceHost,prepareText:{
              let title = (item.title ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
              return LibraryRowText(title:title.isEmpty ? "Capture of "+(item.sourceHost.isEmpty ? "page" : item.sourceHost) : title,subtitle:"Capture · "+(item.sourceHost.isEmpty ? "page" : item.sourceHost)+" · "+item.createdAt.formatted(date:.abbreviated,time:.omitted))
          }) { [unowned self] prepared in
            let id = item.id, actions = viewModel.actions
            return LibraryRowItem(id:id.uuidString,title:(item.title ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "Capture of "+(item.sourceHost.isEmpty ? "page" : item.sourceHost) : item.title!,subtitle:prepared?.subtitle ?? "Capture · "+(item.sourceHost.isEmpty ? "page" : item.sourceHost)+" · "+item.createdAt.formatted(date:.abbreviated,time:.omitted),kind:"capture",day:"",
                fileURL:viewModel.captureURL(item),dragURL:viewModel.captureURL(item),activate:{ actions.openCapture(id:id) },
                // Arc's Media menu, from the code that builds it (`HomeButton/MediaReducer.swift`, 1.172.2 at 0x102804e74…0x102806608,
                // small-string immediates in code order: Open in Preview · AirDrop · Copy … · Show in Finder · Hide from Arc ·
                // Open Source URL · Copy Source URL · Delete; plus the long string "Send via iMessage"). Order = code order (guess);
                // separators are a guess; no populated Media capture exists (C3 item 12 skipped). "Save As…" is Open's own.
                // Open Source URL / Copy Source URL need the capture's page URL, which the capture index does not store yet (follow-up).
                actions:[.init(title:"Open in Preview",run:{ actions.openCapture(id:id) })]
                    + Self.shareActions(viewModel.captureURL(item))
                    + [.init(title:"Copy Image",run:{ actions.copyCapture(id:id) }),
                    .init(title:"Show in Finder",run:{ actions.revealCapture(id:id) }),.init(title:"Save As…",run:{ [weak self] in self?.saveCapture(item) }),
                    .init(title:"-",run:{}),.init(title:"Delete",run:{ [weak self] in self?.confirm("Delete this capture?",message:"This permanently deletes the file.") { [weak self] in
                        self?.viewModel.pendingCaptureDelete = id; self?.viewModel.deleteCaptureConfirmed(); self?.renderRows()
                    } })])
          }
        }
    }
    /// Folder files (PB1). Same row as a capture; files can be hidden, never deleted (Arc LB-2).
    func mediaFileSources() -> [LibraryRowSource] {
        guard let folders = viewModel.mediaFolders else { return [] }
        return folders.files.map { file in
          let subtitle = file.source.title+" · "+file.date.formatted(date:.abbreviated,time:.omitted)
          return LibraryRowSource(id:"file:"+file.url.path,date:file.date,text:file.name+" "+file.source.title,prepareText:{
              LibraryRowText(title:file.name,subtitle:subtitle)
          }) { [unowned self] _ in
            let url = file.url
            let open: () -> Void = { NSWorkspace.shared.open(url) }
            return LibraryRowItem(id:"file:"+url.path,title:file.name,subtitle:subtitle,kind:"media",day:"",fileURL:url,dragURL:url,activate:open,
                // The same Arc builder as captures; a folder file hides ("Hide from Arc" → "Hide from Open"), it never deletes.
                actions:[.init(title:"Open in Preview",run:open)]
                    + Self.shareActions(url)
                    + [.init(title:Self.copyTitle(url),run:{ NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([url as NSURL]) }),
                    .init(title:"Show in Finder",run:{ NSWorkspace.shared.activateFileViewerSelecting([url]) }),
                    .init(title:"-",run:{}),
                    .init(title:"Hide from Open",run:{ [weak self] in folders.hide(file); self?.renderRows() })])
          }
        }
    }
    func boostSources() -> [LibraryRowSource] {
        let profile = viewModel.historyProfileID
        return viewModel.libraryBoostRows.map { item in
          LibraryRowSource(id:item.id,text:item.domain+" "+item.name) { [unowned self] _ in
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
                if self.contentActive, self.section == .history { self.renderRows() }
            }
        }
    }
    func loadNextArchivePage() {
        guard contentActive, section == .archive, viewModel.archiveHasMore, !viewModel.archiveLoading, !archivePageLoading else { return }
        archivePageLoading = true
        Task { @MainActor [weak self] in
            guard let self else { return }; await self.viewModel.loadNextArchivePage(); self.archivePageLoading = false
            if self.contentActive, self.section == .archive { self.renderRows() }
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
        hosts[section]?.dirty = true
        if section == .history { hosts[section]?.loaded = false }
        configureFilter(); refreshData(); renderRows(); return true
    }
}

@MainActor private final class LibraryProfileChoice: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func select() { run() }
}

/// Arc's download file-kind word (string keys "Sidebar download cell file type copy for a PDF / an image / a disk image /
/// a movie file / audio files / zip archives / generic archives"; titles from the code's small-string immediates:
/// PDF, Image, Disk Image, Movie, Audio, Zip Archive, Archive). Nil: no kind word (the caller uses the extension).
nonisolated func downloadKind(_ fileName: String) -> String? {
    let ext = URL(fileURLWithPath: fileName).pathExtension
    guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return nil }
    if type.conforms(to: .pdf) { return "PDF" }
    if type.conforms(to: .diskImage) { return "Disk Image" }
    if type.conforms(to: .zip) { return "Zip Archive" }
    if type.conforms(to: .archive) { return "Archive" }
    if type.conforms(to: .image) { return "Image" }
    if type.conforms(to: .movie) { return "Movie" }
    if type.conforms(to: .audio) { return "Audio" }
    return nil
}

nonisolated private func downloadSubtitle(_ item:DownloadItemSnapshot) -> String {
    switch item.state {
    // Arc's subtitle is the file-kind word ("PDF", "Archive"), else "Download" (capture session 8 item 9).
    case .completed: return item.fileExists == true ? (downloadKind(item.fileName) ?? "Download") : "File moved or deleted."
    case .failed: return "Failed"
    case .cancelled: return "Cancelled"
    case .paused: return "Paused"
    case .inProgress:
        let bytes = ByteCountFormatter(); bytes.countStyle = .file; bytes.allowsNonnumericFormatting = false
        var received = bytes.string(fromByteCount:item.receivedBytes)
        if let total = item.totalBytes {
            let target = bytes.string(fromByteCount:total)
            if let unit = target.split(separator:" ").last,received.hasSuffix(" "+unit) { received.removeLast(unit.count+1) }
            received += "/"+target
            if item.bytesPerSecond>0 { received += " · \(max(0,(total-item.receivedBytes)/item.bytesPerSecond))s" }
        }
        return received
    }
}
