import AppKit
import OpenEasel
import OpenFeatures
import OpenModel

/// The native page for an Easel tab. The canvas is built on first show only; nothing Easel
/// related loads at launch.
@MainActor
final class EaselContentHost: WebContentHost {
  let tabID: ItemID
  let documentID: UUID
  weak var owner: EngineWebContentHostFactory?
  let canvas: EaselCanvasView
  private(set) var closed = false
  /// True when the file was missing and a fresh document was made for this tab.
  let recreated: Bool
  var view: NSView { canvas }
  var currentURL: URL? { EaselTab.url(for: documentID) }
  var title: String { canvas.document.displayTitle }
  var canGoBack: Bool { false }
  var canGoForward: Bool { false }
  var isLoading: Bool { false }
  var pageBackgroundColor: NSColor? { nil }
  var onURLChange: ((URL) -> Void)?
  var onTitleChange: ((String) -> Void)?
  var onLoadingChange: ((Bool) -> Void)?
  var onFaviconChange: ((Data?) -> Void)?
  var shouldNavigate: ((URL, NSEvent.ModifierFlags) -> Bool)?
  var onPageBackgroundChange: ((NSColor?) -> Void)?
  var onLiveStateChange: ((WebContentLiveState) -> Void)?

  init(tabID: ItemID, documentID: UUID, owner: EngineWebContentHostFactory) {
    self.tabID = tabID; self.documentID = documentID; self.owner = owner
    let store = owner.app.easels
    var document = store.load(documentID)
    recreated = document == nil
    if document == nil {
      store.setAsideRefused(documentID)
      // The file is gone (deleted outside Open or never written): start an empty Easel with
      // the row's title so the row and the page agree.
      let rowTitle = owner.model.tab(id: tabID)?.title
      // Nothing is written until the first edit: showing a row whose file is gone (an Undo,
      // a deletion outside Open) must not bring back a file.
      document = EaselDocument(id: documentID, title: rowTitle == EaselDocument.untitled ? nil : rowTitle)
    }
    canvas = EaselCanvasView(document: document!)
    canvas.onChange = { [weak self] doc in
      guard let self, let owner = self.owner else { return }
      owner.app.easels.save(doc)
      if let tab = owner.model.tab(id: self.tabID), tab.title != doc.displayTitle {
        self.onTitleChange?(doc.displayTitle)
        owner.scheduleSave()
      }
    }
    let id = documentID
    canvas.imageURL = { [weak store] file in store?.imageURL(document: id, file: file) }
    canvas.storeImage = { [weak store] data in store?.addImage(data, document: id) }
    canvas.onPickImage = { [weak self] in self?.pickImage() }
    canvas.onLink = { [weak self] url, point in self?.addLink(url, at: point) }
    canvas.liveViewProvider = { [weak self] objectID, url in self?.livePage(for: objectID, url: url) }
    canvas.liveViewRelease = { [weak self] objectID in self?.releaseLivePage(objectID) }
    canvas.onOpenURL = { [weak self] url in _ = self?.owner?.openNewTab(url: url, background: false) }
    canvas.onAddSplit = { [weak self] in
      guard let self, let owner = self.owner else { return }
      owner.controller?.splitController.addEmptyPane()
    }
  }

  /// The Image tool: an open panel sheet for pictures (several allowed).
  func pickImage() {
    guard let window = canvas.window, window.attachedSheet == nil else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic, .tiff]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.message = "Choose pictures to add to this Easel."
    openPanel = panel
    panel.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      self.openPanel = nil
      // The tab can close (or its Easel be deleted) while the sheet is up: never write to it then.
      guard response == .OK, !self.closed else { return }
      let pb = NSPasteboard(name: NSPasteboard.Name("open.easel.pick.\(UUID().uuidString)"))
      pb.clearContents(); pb.writeObjects(panel.urls as [NSURL])
      self.canvas.ingest(pb, at: self.canvas.visibleCenter, name: "Add Image")
      pb.releaseGlobally()
    }
  }
  private(set) var openPanel: NSOpenPanel?

  // MARK: Live web cards (pooled engine pages, at most EaselCanvasView.maxLive)

  private(set) var livePages: [UUID: any WebContentHost] = [:]
  private(set) var livePagesMade = 0
  /// A page for a live card: an engine page outside the sidebar model (like Peek's), in the
  /// Easel's Profile. Nil while the engine or Profile is not ready (the card keeps its screenshot).
  func livePage(for objectID: UUID, url: URL) -> NSView? {
    if let page = livePages[objectID] { return page.view }
    guard !closed, livePages.count < EaselCanvasView.maxLive, let owner,
          let profile = owner.profile(for: tabID),
          let page = owner.makeHost(tabID: ItemID(), profileID: profile.id, url: nil) else { return nil }
    livePages[objectID] = page
    livePagesMade += 1
    page.view.removeFromSuperview()
    page.view.isHidden = false
    // Links inside a live card open in a new tab, not in the card.
    page.shouldNavigate = { [weak owner] target, _ in
      guard let owner else { return false }
      _ = owner.openNewTab(url: target, background: false)
      return false
    }
    page.load(url)
    return page.view
  }
  func releaseLivePage(_ objectID: UUID) {
    guard let page = livePages.removeValue(forKey: objectID) else { return }
    page.close()
  }
  private(set) var pendingLinks = 0

  /// A link card appears at once with the address; its title, summary and picture follow.
  func addLink(_ url: URL, at point: CGPoint) {
    let id = canvas.insertLink(EaselLink(source: url.absoluteString), centeredAt: point)
    pendingLinks += 1
    let documentID = self.documentID
    Task { [weak self] in
      let (meta, picture) = await EaselLinkFetcher.fetch(url)
      guard let self else { return }
      self.pendingLinks -= 1
      guard !self.closed else { return }
      let image = picture.flatMap { self.owner?.app.easels.addImage($0, document: documentID) }
      self.canvas.updateLink(id) { link in
        link.title = meta.title; link.summary = meta.summary; link.imageFile = image?.file
      }
    }
  }

  func load(_ url: URL) {
    guard !closed else { return }
    if EaselTab.documentID(url) == documentID {
      onURLChange?(url); onTitleChange?(title); onFaviconChange?(EaselIcon.faviconPNG)
      onPageBackgroundChange?(nil)
    }
  }
  func reload() {}
  func stop() {}
  func goBack() {}
  func goForward() {}
  func focus() { if !closed { canvas.focus() } }
  func close() {
    guard !closed else { return }; closed = true
    canvas.commitPendingEdits()
    for id in Array(livePages.keys) { releaseLivePage(id) }
    owner?.app.easels.flush(wait: false)
    canvas.removeFromSuperview()
    onURLChange = nil; onTitleChange = nil; onLoadingChange = nil; onFaviconChange = nil
    onPageBackgroundChange = nil; onLiveStateChange = nil; shouldNavigate = nil
    if owner?.easelHosts[tabID] === self { owner?.easelHosts[tabID] = nil }
  }
}
