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
      // The file is gone (deleted outside Open or never written): start an empty Easel with
      // the row's title so the row and the page agree.
      let rowTitle = owner.model.tab(id: tabID)?.title
      document = EaselDocument(id: documentID, title: rowTitle == EaselDocument.untitled ? nil : rowTitle)
      store.save(document!)
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
    canvas.onAddSplit = { [weak self] in
      guard let self, let owner = self.owner else { return }
      owner.controller?.splitController.addEmptyPane()
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
    owner?.app.easels.flush(wait: false)
    canvas.removeFromSuperview()
    onURLChange = nil; onTitleChange = nil; onLoadingChange = nil; onFaviconChange = nil
    onPageBackgroundChange = nil; onLiveStateChange = nil; shouldNavigate = nil
    if owner?.easelHosts[tabID] === self { owner?.easelHosts[tabID] = nil }
  }
}
