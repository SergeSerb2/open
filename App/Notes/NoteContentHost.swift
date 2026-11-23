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

  /// Every open editor. Several rows can show one Note (a duplicate row, another window), each
  /// with its own editor: an edit in one reloads the others, so none keeps an older copy that
  /// its next keystroke would write over the file.
  private static let openHosts = NSHashTable<NoteContentHost>.weakObjects()
  /// Automatic follows a live system Light/Dark switch, not only View ▸ Appearance
  /// (bug sweep r6, A11Y-09). One app-wide observation serves every open Note.
  private static var systemAppearanceObservation: NSKeyValueObservation?
  private static func observeSystemAppearance() {
    guard systemAppearanceObservation == nil else { return }
    systemAppearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
      // assumeIsolated requires every NSApp.appearance write to run on the main thread.
      MainActor.assumeIsolated { for host in openHosts.allObjects where !host.closed { host.updateAppearance() } }
    }
  }
  static func open(noteID: UUID) -> [NoteContentHost] { openHosts.allObjects.filter { $0.noteID == noteID && !$0.closed } }

  /// The stored Note changed outside this editor: every other open editor shows it. With
  /// `titleChanged`, every row of the Note in every window takes its title too.
  static func noteDidChange(_ noteID: UUID, store: NoteStore, except source: NoteContentHost? = nil, titleChanged: Bool) {
    for host in open(noteID: noteID) where host !== source { host.reloadFromStore() }
    guard titleChanged, let app = NSApp.delegate as? AppDelegate, !store.isUnreadable(noteID) else { return }
    // The editing row already has the new title (one row: nothing below changes), so post here (review r2 #2).
    app.easelsDidChange()
    let note = store.document(noteID)
    let title = note.title.isEmpty ? NoteTab.untitled : note.title
    var models = Set<ObjectIdentifier>(), changed = false
    for factory in app.hostFactories.values where models.insert(ObjectIdentifier(factory.model)).inserted {
      for tab in factory.model.allTabsForNotes() where NoteLink.id(from: tab.url) == noteID && tab.title != title {
        tab.title = title; changed = true
      }
    }
    guard changed else { return }
    for factory in app.hostFactories.values { factory.controller?.refresh(); factory.scheduleSave() }
  }

  init(tabID: ItemID, noteID: UUID, store: NoteStore, owner: EngineWebContentHostFactory) {
    self.tabID = tabID; self.noteID = noteID; self.store = store; self.owner = owner
    note = store.document(noteID)
    unreadable = store.isUnreadable(noteID)
    editor.setContent(title: note.title, body: Self.body(of: note, store: store))
    Self.openHosts.add(self)
    Self.observeSystemAppearance()
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
    editor.onOpenLink = { [weak self] url, flags in self?.openLink(url, flags: flags) }
  }

  private static func body(of note: NoteDocument, store: NoteStore) -> NSMutableAttributedString {
    let id = note.id
    return NoteRichText.attributed(text: note.text, formats: note.formats) { [store] name in
      store.assetURL(note: id, name: name).flatMap(NoteImages.image(contentsOf:))
    }
  }

  private func edited(title: String, body: NSAttributedString) {
    guard !closed, !unreadable, !reloading else { return }
    let titleChanged = title != note.title
    note.title = title; note.text = body.string
    note.importPlaceholder = nil
    note.formats = NoteRichText.formats(of: body)
    store.update(note)
    note = store.document(noteID)
    if titleChanged {
      // Split panes and the main pane both: the model row keeps the title for the snapshot.
      owner?.model.tab(id: tabID)?.title = self.title
      onTitleChange?(self.title); owner?.scheduleSave()
    }
    // Other rows of this Note: their editors and titles follow (one row is the common case).
    if titleChanged || Self.openHosts.count > 1 { Self.noteDidChange(noteID, store: store, except: self, titleChanged: titleChanged) }
  }

  private var reloading = false
  /// Shows the stored Note (written by another editor of it). Not an edit: nothing is saved.
  func reloadFromStore() {
    guard !closed, !unreadable else { return }
    let latest = store.document(noteID)
    guard latest.title != note.title || latest.text != note.text || latest.formats != note.formats else { return }
    let titleChanged = latest.title != note.title
    note = latest
    reloading = true; defer { reloading = false }
    editor.setContent(title: note.title, body: Self.body(of: note, store: store))
    if titleChanged { onTitleChange?(title) }
  }

  /// Row rename: the title field shows it and the Note saves it.
  func setTitle(_ title: String) {
    guard !closed, !unreadable else { return }
    editor.titleView.string = title
    edited(title: title, body: editor.bodyView.attributedString())
    editor.needsLayout = true
  }

  /// A link in the Note follows the window's link policy, like a link in a page: Peek for a
  /// pinned or Favorite Note's link to another site or with Shift (Settings ▸ Links), Little
  /// Open with ⌥⌘. Otherwise it opens in a new tab (⌘: in the background); the Note stays.
  func openLink(_ url: URL, flags: NSEvent.ModifierFlags) {
    guard !closed else { return }
    if let policy = shouldNavigate, !policy(url, flags) { return }
    _ = owner?.openNewTab(url: url, background: flags.contains(.command) && !flags.contains(.option), opener: tabID)
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
    Self.openHosts.remove(self)
    store.flush()
    editor.onChange = nil
    editor.removeFromSuperview()
    onURLChange = nil; onTitleChange = nil; onLoadingChange = nil; onFaviconChange = nil
    onPageBackgroundChange = nil; onLiveStateChange = nil; shouldNavigate = nil
    if owner?.noteHosts[tabID] === self { owner?.noteHosts[tabID] = nil }
  }
}
