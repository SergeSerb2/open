import AppKit
import OpenDocuments
import OpenFeatures
import OpenModel

/// The native content of a Note tab. Same slot API as a web page, so the main
/// pane, Split View panes and Little Open place it with no new layout code.
@MainActor
final class NoteContentHost: WebContentHost {
  let tabID: ItemID
  let noteID: UUID
  weak var owner: EngineWebContentHostFactory?
  let editor = NoteEditorView()
  private let store: NoteStore
  private var note: NoteDocument
  private(set) var closed = false
  private(set) var unreadable = false
  var view: NSView { editor }
  var currentURL: URL? { NoteLink.url(for: noteID) }
  var title: String { note.title.isEmpty ? NoteTab.untitled : note.title }
  var canGoBack: Bool { false }
  var canGoForward: Bool { false }
  var isLoading: Bool { false }
  var pageBackgroundColor: NSColor? { NoteLook.background.resolve(editor.isDark) }
  var onURLChange: ((URL) -> Void)?
  var onTitleChange: ((String) -> Void)?
  var onLoadingChange: ((Bool) -> Void)?
  var onFaviconChange: ((Data?) -> Void)?
  var shouldNavigate: ((URL, NSEvent.ModifierFlags) -> Bool)?
  var onPageBackgroundChange: ((NSColor?) -> Void)?
  var onLiveStateChange: ((WebContentLiveState) -> Void)?
  var document: NoteDocument { note }

  init(tabID: ItemID, noteID: UUID, store: NoteStore, owner: EngineWebContentHostFactory) {
    self.tabID = tabID; self.noteID = noteID; self.store = store; self.owner = owner
    note = store.document(noteID)
    unreadable = store.isUnreadable(noteID)
    let id = noteID
    let body = NoteRichText.attributed(text: note.text, formats: note.formats) { [store] name in
      store.assetURL(note: id, name: name).flatMap(NoteImages.image(contentsOf:))
    }
    editor.setContent(title: note.title, body: body)
    if unreadable {
      // Arc's error title (STR). Never overwrite a file we could not read.
      editor.titleView.placeholder = "Can't load this note"
      editor.bodyView.placeholder = ""
      editor.titleView.isEditable = false; editor.bodyView.isEditable = false
    }
    updateAppearance()
    editor.onChange = { [weak self] title, body in self?.edited(title: title, body: body) }
    editor.onImage = { [weak self] data, ext in
      guard let self, !self.unreadable else { return nil }
      return try? self.store.writeAsset(data, ext: ext, note: self.noteID)
    }
    editor.onOpenLink = { [weak self] url in self?.owner?.openFromNote(url) }
  }

  private func edited(title: String, body: NSAttributedString) {
    guard !closed, !unreadable else { return }
    let titleChanged = title != note.title
    note.title = title; note.text = body.string
    note.formats = NoteRichText.formats(of: body)
    store.update(note)
    note = store.document(noteID)
    if titleChanged {
      // Split panes and the main pane both: the model row keeps the title for the snapshot.
      owner?.model.tab(id: tabID)?.title = self.title
      onTitleChange?(self.title); owner?.scheduleSave()
    }
  }

  /// View ▸ Appearance (website colour scheme) decides; Automatic follows the system.
  func updateAppearance() {
    let dark: Bool
    switch UserDefaults.standard.string(forKey: WebsiteAppearance.defaultsKey) {
    case "light": dark = false
    case "dark": dark = true
    default: dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    let changed = dark != editor.isDark
    editor.setDark(dark)
    if changed { onPageBackgroundChange?(pageBackgroundColor) }
  }

  func load(_ url: URL) {
    guard !closed else { return }
    if NoteLink.id(from: url) == noteID {
      onURLChange?(url)
      // An unreadable Note keeps the row title from the snapshot.
      if !unreadable { onTitleChange?(title) }
      onFaviconChange?(NoteTab.faviconPNG)
      updateAppearance(); onPageBackgroundChange?(pageBackgroundColor)
    } else if !WelcomeTab.isInternal(url) {
      // A typed address on a Note opens a new tab; the Note stays.
      owner?.openFromNote(url)
    }
  }
  func reload() {}
  func stop() {}
  func goBack() {}
  func goForward() {}
  func focus() {
    guard !closed, let window = editor.window else { return }
    let responder = window.firstResponder
    if responder === editor.titleView || responder === editor.bodyView { return }
    window.makeFirstResponder(note.title.isEmpty && note.text.isEmpty ? editor.titleView : editor.bodyView)
  }
  func close() {
    guard !closed else { return }; closed = true
    store.flush()
    editor.onChange = nil
    editor.removeFromSuperview()
    onURLChange = nil; onTitleChange = nil; onLoadingChange = nil; onFaviconChange = nil
    onPageBackgroundChange = nil; onLiveStateChange = nil; shouldNavigate = nil
    if owner?.noteHosts[tabID] === self { owner?.noteHosts[tabID] = nil }
  }
}
