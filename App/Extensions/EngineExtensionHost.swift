import AppKit
import OpenEngine
import OpenWeb
import OpenCommands
import OpenExtensionsUI
import OpenFeatures
import OpenSiteControl
import OpenModel

/// E1–E5/E7. The factory remains OEBrowser's delegate (including its tab requests).
@MainActor
final class EngineExtensionHost: ExtensionHost {
  let browser: OEBrowser
  var onActionsChanged: (@MainActor () -> Void)?
  var onActionChanged: (@MainActor (ExtensionActionInfo) -> Void)?
  private(set) var extensionActions: [ExtensionActionInfo] = []
  private(set) var duplicatesDropped = 0
  private(set) var listUpdateCount = 0
  private(set) var actionUpdateCount = 0
  var actionsReady: Bool { browser.extensionActionsReady }
  init(_ browser: OEBrowser) { self.browser = browser; reload() }
  func reload() {
    listUpdateCount += 1
    // Keep E1 order and the first snapshot if an engine model repeats an ID.
    // Log every affected list delivery so normalization cannot hide the engine defect.
    let values = browser.extensionActions
    var seen = Set<String>()
    let unique = values.filter { seen.insert($0.extensionIdentifier).inserted }
    duplicatesDropped = values.count - unique.count
    if duplicatesDropped > 0 {
      FileHandle.standardError.write(Data("Open: extension action list dropped \(duplicatesDropped) duplicate IDs\n".utf8))
    }
    guard unique.count <= 512 else {
      FileHandle.standardError.write(Data("Open: extension action list exceeds 512 actions\n".utf8))
      extensionActions = []; onActionsChanged?(); return
    }
    let next = unique.map(snapshot)
    guard ExtensionsUIContext.accepts(next) else {
      FileHandle.standardError.write(Data("Open: extension action snapshot exceeds UI limits\n".utf8))
      extensionActions = []; onActionsChanged?(); return
    }
    extensionActions = next; onActionsChanged?()
  }
  func didUpdate(_ action: OEExtensionAction) {
    actionUpdateCount += 1
    let value = snapshot(action)
    guard ExtensionsUIContext.accepts([value]), let index = extensionActions.firstIndex(where: { $0.id == value.id }) else { return }
    guard extensionActions[index] != value else { return }
    extensionActions[index] = value; onActionChanged?(value)
  }
  private func snapshot(_ a: OEExtensionAction) -> ExtensionActionInfo {
    ExtensionActionInfo(extensionID: a.extensionIdentifier, name: a.extensionName,
      accessibleName: a.accessibleName, tooltip: a.tooltip,
      toolbarImage: EngineExtensionImages.shared.image(a.toolbarImage), menuIcon: EngineExtensionImages.shared.image(a.icon),
      badgeText: a.badgeText, isEnabled: a.isEnabled, hasPopup: a.hasPopup, isPinned: a.isPinned,
      pinnedIndex: a.isPinned ? a.pinnedIndex : nil, wantsToRun: a.wantsToRun,
      isShowingPopup: a.isShowingPopup, shortcutKeys: ExtensionShortcutTable.keycaps(a.shortcutKeyEquivalent, flags: a.shortcutModifierFlags))
  }
  func executeAction(extensionID: String, source: ExtensionRunSource) -> Bool {
    let engineSource: OEBrowser.ExtensionActionSource = switch source {
      case .toolbarButton: .toolbarButton; case .menuEntry: .menuEntry; case .command: .command
    }
    return browser.executeExtensionAction(extensionID, source: engineSource)
  }
  func setPinned(_ pinned: Bool, extensionID: String) { browser.setExtensionAction(extensionID, pinned: pinned) }
  func movePinned(extensionID: String, to index: Int) {
    let pinned = extensionActions.filter(\.isPinned)
    guard let current = pinned.firstIndex(where: { $0.id == extensionID }) else { return }
    let destination = min(max(0, index), pinned.count - 1)
    guard current != destination else { return }
    browser.moveExtensionAction(extensionID, toPinnedIndex: UInt(destination))
  }
  func contextMenu(extensionID: String, fromMenuItem: Bool) -> (any ExtensionMenu)? {
    browser.contextMenu(forExtensionAction: extensionID, source: fromMenuItem ? .menuItem : .toolbarAction).map(EngineExtensionMenu.init)
  }
  func closePopup() { browser.closeExtensionPopup() }
}

/// Weak identity keys cannot alias a later NSImage at a recycled address. No PNG round trip,
/// no NSImage size mutation. The largest accepted CGImage is 2048²×4 (16 MiB).
@MainActor
final class EngineExtensionImages {
  static let shared = EngineExtensionImages()
  private let cache = NSMapTable<NSImage, ImageBox>(keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
  private(set) var conversionCount = 0
  private final class ImageBox: NSObject { let image: ExtensionImage; init(_ image: ExtensionImage) { self.image = image } }
  func image(_ source: NSImage?) -> ExtensionImage? {
    guard let source else { return nil }
    if let box = cache.object(forKey: source) { return box.image }
    guard source.size.width > 0, source.size.height > 0, source.size.width <= 512, source.size.height <= 512 else { return nil }
    let reps = source.representations.compactMap { $0 as? NSBitmapImageRep }.sorted { $0.pixelsWide < $1.pixelsWide }
    guard reps.count <= 4, reps.allSatisfy({ $0.pixelsWide <= 2048 && $0.pixelsHigh <= 2048 }),
          let largest = reps.last?.cgImage ?? source.cgImage(forProposedRect: nil, context: nil, hints: nil),
          largest.width <= 2048, largest.height <= 2048,
          let image = ExtensionImage(cgImage: largest, pointSize: source.size,
            image1x: reps.first(where: { $0.pixelsWide == Int(source.size.width) })?.cgImage) else { return nil }
    cache.setObject(ImageBox(image), forKey: source); conversionCount += 1; return image
  }
}

@MainActor
final class EngineExtensionMenu: ExtensionMenu {
  private let source: OEExtensionActionMenu
  private var answered = false
  private(set) var didRun = false
  init(_ source: OEExtensionActionMenu) { self.source = source }
  var items: [ExtensionMenuItem] { Self.items(source.items) }
  private static func items(_ values: [OEContextMenuItem]) -> [ExtensionMenuItem] {
    values.map { ExtensionMenuItem(command: $0.commandIdentifier, title: $0.title, isEnabled: $0.isEnabled,
      isSeparator: $0.isSeparator, isChecked: $0.isChecked, submenu: items($0.submenu)) }
  }
  func select(command: Int) { guard !answered else { return }; answered = true; didRun = source.select(command: command) }
  func cancel() { guard !answered else { return }; answered = true; source.cancel() }
  isolated deinit { if !answered { source.cancel() } }
}

/// One transient context per window. Engine delegates deliver changes explicitly; no polling.
@MainActor
final class WindowExtensions {
  unowned let factory: EngineWebContentHostFactory
  let context = ExtensionsUIContext()
  private(set) var host: EngineExtensionHost?
  lazy var popup = ExtensionPopupController(factory: factory)
  var siteControl: SiteControlController? {
    didSet { siteControl?.extensionsUIContext = context; siteControl?.refreshExtensions() }
  }
  private var tabID: OpenModel.ItemID?
  private var menu: NSMenu?
  #if OPEN_AUTOMATION
  var capturesMenus = false
  var capturedMenu: NSMenu?
  #endif
  init(factory: EngineWebContentHostFactory) { self.factory = factory }
  func attach() {
    factory.controller?.context.extensionsUI = context
    factory.controller?.container.extensionsUI = context
    context.run = { [weak self] id, source, anchor in self?.run(id, source: source, anchor: anchor) }
    context.closePopup = { [weak self] in self?.host?.closePopup() }
    context.togglePin = { [weak self] id in
      guard let self, let value = self.context.actions.first(where: { $0.id == id }) else { return }
      self.host?.setPinned(!value.isPinned, extensionID: id)
    }
    context.movePinned = { [weak self] id, index in self?.host?.movePinned(extensionID: id, to: index) }
    context.contextMenu = { [weak self] id, anchor, event in self?.showContextMenu(id, anchor: anchor, event: event) }
    context.overflow = { [weak self] hidden, anchor in self?.showOverflow(hidden: hidden.count, anchor: anchor) }
    context.addExtension = { [weak factory] in _ = factory?.performAppCommand("add-extension") }
    context.manageExtensions = { [weak factory] in _ = factory?.performAppCommand("manage-extensions") }
    focusChanged()
  }
  func focusChanged() {
    guard !factory.isClosing else { return }
    let browser = factory.focusedBrowser
    if host?.browser !== browser {
      host?.closePopup(); host?.onActionsChanged = nil; host?.onActionChanged = nil
      host = browser.map(EngineExtensionHost.init)
      host?.onActionsChanged = { [weak self] in self?.reload() }
      host?.onActionChanged = { [weak self] value in
        guard let self else { return }; _ = self.context.updateAction(value); self.siteControl?.refreshExtensions()
      }
      reload()
    }
    if tabID != factory.selectedTab?.id { popup.close(); tabID = factory.selectedTab?.id }
    sidebarVisibilityChanged()
    factory.app.extensionPrompts.registerContexts()
  }
  private func reload() {
    _ = context.setActions(host?.extensionActions ?? []); siteControl?.refreshExtensions()
  }
  func sidebarVisibilityChanged() {
    if factory.windowState.sidebarMode == .hidden { popup.sidebarDidHide() }
  }
  func run(_ id: String, source: ExtensionRunSource, anchor: NSView? = nil) {
    popup.prepareAnchor(anchor, extensionID: id)
    _ = host?.executeAction(extensionID: id, source: source)
  }
  func showContextMenu(_ id: String, anchor: NSView, event: NSEvent? = nil) {
    guard let source = host?.contextMenu(extensionID: id, fromMenuItem: !(anchor is ExtensionActionButton)),
          let native = ExtensionsMenuBuilder.contextMenu(source) else { return }
    #if OPEN_AUTOMATION
    if capturesMenus { capturedMenu = native; return }
    #endif
    track(native, anchor: anchor, flag: .contextMenu)
  }
  func showOverflow(hidden: Int, anchor: NSView) {
    let pinned = context.actions.filter(\.isPinned).count
    let native = ExtensionsMenuBuilder.menu(actions: context.actions, kind: .overflow(visiblePinned: pinned - hidden),
      run: { [weak self, weak anchor] id, source in self?.run(id, source: source, anchor: anchor) },
      command: { [weak factory] id in _ = factory?.performAppCommand(id) })
    track(native, anchor: anchor, flag: .overflowMenu)
  }
  private func track(_ native: NSMenu, anchor: NSView, flag: ExtensionsUIContext.ForcedVisibility) {
    guard anchor.window != nil else { return }
    #if OPEN_AUTOMATION
    if capturesMenus { capturedMenu = native; return }
    #endif
    let strip = strips.first { anchor === $0.moreButton || anchor.isDescendant(of: $0) }
    strip?.forcedVisibility.insert(flag)
    menu = native
    native.popUp(positioning: nil, at: CGPoint(x: anchor.bounds.minX, y: anchor.bounds.maxY), in: anchor)
    strip?.forcedVisibility.remove(flag); menu = nil
  }
  var strips: [ExtensionStripView] {
    var result: [ExtensionStripView] = []
    if let strip = factory.controller?.sidebar.extensionsStrip { result.append(strip) }
    result += factory.controller?.container.slots.compactMap { $0.paneChrome?.extensionStrip } ?? []
    return result
  }
  #if OPEN_AUTOMATION
  func releaseBrowserOwnershipForAutomation() {
    host?.onActionsChanged = nil; host?.onActionChanged = nil; host = nil
  }
  #endif
  func closeAll() {
    menu?.cancelTrackingWithoutAnimation(); menu = nil
    popup.close(); siteControl?.dismiss(reason: .command, animated: false)
    host?.onActionsChanged = nil; host?.onActionChanged = nil; host = nil
  }
}
