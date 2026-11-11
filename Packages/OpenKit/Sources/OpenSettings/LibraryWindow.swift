import AppKit
import SwiftUI
import OpenDesign
import OpenModel

public struct LibraryContent:View {
    @Bindable var viewModel:LibraryViewModel
    public init(viewModel:LibraryViewModel){self.viewModel=viewModel}
    public var body:some View {HStack(spacing:0) {
        LibrarySidebar(viewModel:viewModel).frame(width:180)
        Divider()
        VStack(spacing:0) {
            VStack(spacing:8) {
                ZStack {Text(viewModel.section.title).font(.system(size:13,weight:.semibold))
                    if viewModel.section == .archive {HStack {Spacer();Button("Delete Selected…",role:.destructive){viewModel.requestDeleteArchive(viewModel.archiveRows.filter{viewModel.selectedIDs.contains($0.id.description)}.map(\.id))}.disabled(viewModel.selectedIDs.isEmpty);Button("Clear Archive…"){viewModel.requestClearArchive()}.disabled(viewModel.archiveTotalCount == 0)}.buttonStyle(SettingsButtonStyle())}
                }.frame(height:24)
                if viewModel.section != .spaces { LibraryToolbar(model:viewModel) }
            }.padding(.horizontal,18).padding(.top,4).padding(.bottom,12).background(.bar)
            Divider()
            Group {switch viewModel.section {
            case .spaces:LibrarySpacesSection(model:viewModel)
            case .archive:ArchiveSection(model:viewModel)
            case .downloads:DownloadsSection(model:viewModel)
            case .boosts:BoostsSection(model:viewModel)
            case .captures,.media:CapturesSection(model:viewModel)
            case .history:HistorySection(model:viewModel)
            }}.padding(viewModel.section == .spaces ? 0 : 16).frame(maxWidth:.infinity,maxHeight:.infinity)
            if !viewModel.statusText.isEmpty {HStack {Text(viewModel.statusText).font(.caption).foregroundStyle(.secondary);if let space=viewModel.restoredSpaceID {Button("View"){viewModel.actions.viewSpace(id:space)}};Spacer()}.padding(.horizontal,16).padding(.bottom,10)}
        }
    }.font(Font(SettingsTokens.label.font)).controlSize(.regular).background(Color(nsColor:SettingsTokens.content.nsColor)).ignoresSafeArea()
    .accessibilityElement(children:.contain).accessibilityLabel("Library")
    .task(id:viewModel.filterIdentity){await viewModel.reload()}
    .task(id:viewModel.filterIdentity){await viewModel.watchHistory()}
    .background(WindowTitle(title:viewModel.section.title).frame(width:0,height:0))}
}
private struct WindowTitle:NSViewRepresentable {
    let title:String
    func makeNSView(context:Context)->NSView {NSView()}
    func updateNSView(_ view:NSView,context:Context){view.window?.title=title}
}
private struct LibraryToolbar:View {
    @Bindable var model:LibraryViewModel
    var body:some View {HStack(spacing:8) {
        switch model.section {
        case .spaces: EmptyView()
        case .archive:
            Picker("Space",selection:$model.archiveSpaceFilter){Text("All Spaces").tag(Optional<SpaceID>.none);ForEach(model.model.spaces,id:\.id){Text(model.model.displayTitle(for:$0)).tag(Optional($0.id))}}.labelsHidden()
            Picker("Reason",selection:$model.archiveReasonFilter){Text("All Reasons").tag(Optional<ArchiveReason>.none);ForEach([ArchiveReason.closed,.autoArchived,.clearedToday,.folderDeleted],id:\.self){Text($0.libraryTitle).tag(Optional($0))}}.labelsHidden()
            Picker("Origin",selection:$model.archiveOriginFilter){Text("All Origins").tag(OriginFilter.all);Text("Spaces").tag(OriginFilter.spaces);Text("Little Open").tag(OriginFilter.littleOpen)}.labelsHidden()
        case .downloads:
            Picker("Status",selection:$model.downloadStateFilter){Text("All Downloads").tag(Optional<DownloadState>.none);Text("In Progress").tag(Optional(DownloadState.inProgress));Text("Completed").tag(Optional(DownloadState.completed));Text("Failed").tag(Optional(DownloadState.failed))}.labelsHidden()
            if model.model.profiles.count > 1 { DownloadsProfileFilter(model: model).frame(maxWidth: 180) }
        case .captures,.media:
            if model.section == .media {Picker("Kind",selection:$model.mediaKind){Text("All Media").tag("All");Text("Captures").tag("Captures");Text("Screenshots").tag("Screenshots")}.labelsHidden()}
            Picker("Sort",selection:$model.captureSort){ForEach(["Newest","Oldest","Name"],id:\.self){Text($0).tag($0)}}.labelsHidden()
        case .history, .boosts:
            if model.section != .boosts || model.model.profiles.count > 1 {
                Picker("Profile",selection:$model.historyProfileID){ForEach(model.model.profiles,id:\.id){Text($0.name).tag($0.id)}}.labelsHidden()
            }
        }
        Spacer(minLength:0)
        TextField("Search \(model.section.title)",text:$model.query).textFieldStyle(.roundedBorder).frame(width:180)
    }.frame(height:24)}
}
private struct LibrarySidebar:NSViewRepresentable {
    let viewModel:LibraryViewModel
    func makeCoordinator()->Coordinator {Coordinator(viewModel)}
    func makeNSView(context:Context)->SourceBackgroundView {
        let effect=SourceBackgroundView()
        let scroll=NSScrollView();scroll.drawsBackground=false;scroll.hasVerticalScroller=false
        let table=NSTableView();table.headerView=nil;table.rowHeight=28;table.intercellSpacing = .zero;table.style = .sourceList;table.selectionHighlightStyle = .none;table.backgroundColor = .clear;table.allowsEmptySelection=false
        table.addTableColumn(NSTableColumn(identifier:.init("section")));table.delegate=context.coordinator;table.dataSource=context.coordinator
        context.coordinator.table=table;scroll.documentView=table;effect.addSubview(scroll);scroll.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo:effect.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:effect.trailingAnchor),scroll.topAnchor.constraint(equalTo:effect.topAnchor,constant:40),scroll.bottomAnchor.constraint(equalTo:effect.bottomAnchor)])
        return effect
    }
    func updateNSView(_ view:SourceBackgroundView,context:Context){if let row=LibrarySection.allCases.firstIndex(of:viewModel.section),context.coordinator.table?.selectedRow != row {context.coordinator.table?.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)};context.coordinator.refreshCells()}
    @MainActor final class Coordinator:NSObject,NSTableViewDataSource,NSTableViewDelegate {
        let model:LibraryViewModel;weak var table:NSTableView?
        init(_ model:LibraryViewModel){self.model=model}
        func numberOfRows(in tableView:NSTableView)->Int {LibrarySection.allCases.count}
        func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
            let section=LibrarySection.allCases[row];let cell=SourceCellView();let icon=NSImageView();icon.image=NSImage(systemSymbolName:section.symbol,accessibilityDescription:nil);icon.contentTintColor = .secondaryLabelColor;let text=NSTextField(labelWithString:section.title);text.font=SettingsTokens.label.font
            cell.addSubview(icon);cell.addSubview(text);cell.imageView=icon;cell.textField=text;icon.translatesAutoresizingMaskIntoConstraints=false;text.translatesAutoresizingMaskIntoConstraints=false
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo:cell.leadingAnchor),icon.widthAnchor.constraint(equalToConstant:16),icon.heightAnchor.constraint(equalToConstant:16),icon.centerYAnchor.constraint(equalTo:cell.centerYAnchor),text.leadingAnchor.constraint(equalTo:icon.trailingAnchor,constant:8),text.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-4),text.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
            return cell
        }
        func tableViewSelectionDidChange(_ notification:Notification){guard let table,LibrarySection.allCases.indices.contains(table.selectedRow) else {return};model.section=LibrarySection.allCases[table.selectedRow];refreshCells()}
        func refreshCells(){guard let table else{return};for row in 0..<table.numberOfRows {if let cell=table.view(atColumn:0,row:row,makeIfNecessary:true) as? SourceCellView {cell.selected=row == table.selectedRow;cell.needsDisplay=true}}}
    }
}
@MainActor public enum LibraryWindow {
    public static func makeWindow(viewModel:LibraryViewModel)->NSWindow {
        let window=LibraryNativeWindow(contentRect:.init(x:0,y:0,width:960,height:640),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.libraryModel = viewModel.model
        window.titlebarAppearsTransparent=true;window.titleVisibility = .hidden
        window.contentViewController=NSHostingController(rootView:LibraryContent(viewModel:viewModel));window.title=viewModel.section.title;window.minSize = .init(width:720,height:480);window.isReleasedWhenClosed=false
        window.setFrame(.init(x:200,y:200,width:960,height:640),display:false);return window
    }
}
@MainActor public final class LibraryPresenter:NSObject,NSWindowDelegate {
    public let viewModel:LibraryViewModel;public private(set) var window:NSWindow?
    public init(viewModel:LibraryViewModel){self.viewModel=viewModel;super.init()}
    /// Compatibility target for actions and sheets hosted by the in-window Library.
    /// The browser controller keeps its delegate and owns this window's lifetime.
    public func attach(to browserWindow: NSWindow) { window = browserWindow }
    public func show(section:LibrarySection?=nil){if let section {viewModel.section=section};viewModel.refreshSpaceManagerView();if window == nil {window=LibraryWindow.makeWindow(viewModel:viewModel);window?.delegate=self};Task {await viewModel.refreshExternalState()};window?.makeKeyAndOrderFront(nil)}
    public func windowDidBecomeKey(_ notification:Notification){viewModel.refreshSpaceManagerView();Task {await viewModel.refreshExternalState()}}
}

/// Supply undo before NSHostingController reads the window's environment.
/// A delegate installed after hosting can leave NSWindow's default manager cached.
private final class LibraryNativeWindow: NSWindow {
    weak var libraryModel: BrowserModel?
    private lazy var textUndoManager = UndoManager()
    override var undoManager: UndoManager? {
        if firstResponder is NSTextView || firstResponder is NSTextField { return textUndoManager }
        return libraryModel?.undoManager ?? super.undoManager
    }
    // Nil-target Edit menu actions. There is no separate key monitor/router.
    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) {
            menuItem.title = undoManager?.undoMenuItemTitle ?? "Undo"
            return undoManager?.canUndo == true
        }
        if menuItem.action == #selector(redo(_:)) {
            menuItem.title = undoManager?.redoMenuItemTitle ?? "Redo"
            return undoManager?.canRedo == true
        }
        return super.validateMenuItem(menuItem)
    }
}

/// Native table selection and keyboard navigation, with system accent painting in the
/// cell. This also renders without AppKit's GPU-only source-list selection material.
private final class SourceCellView:NSTableCellView {
    var selected=false
    override var allowsVibrancy:Bool {false}
    override func draw(_ dirtyRect:NSRect) {
        if selected {
            let active=window?.isKeyWindow == true
            NSColor.controlAccentColor.withAlphaComponent(active ? 1:0.18).setFill()
            NSBezierPath(roundedRect:bounds,xRadius:6,yRadius:6).fill()
            textField?.textColor=active ? .alternateSelectedControlTextColor:.labelColor
        } else {textField?.textColor = .labelColor}
        imageView?.contentTintColor=textField?.textColor
    }
}

private final class SourceBackgroundView:NSView {
    override func draw(_ dirtyRect:NSRect) {SettingsTokens.band.nsColor.setFill();dirtyRect.fill()}
}
