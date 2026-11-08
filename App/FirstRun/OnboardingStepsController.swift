import AppKit
import SwiftUI
import Observation
import QuartzCore
import ImageIO
import UniformTypeIdentifiers
import OpenModel
import OpenSettings
import OpenDesign
import OpenSpaceEditor

/// Presentation only. Section 7 still owns import, consent, progress and finish.
@MainActor
final class OnboardingStepsController: NSViewController, NSTextFieldDelegate {
  enum Step: String { case name, importData = "import", favorites, theme, blocker, defaultBrowser, ready }
  struct Site {
    let name: String
    let host: String
    var url: URL { URL(string: "https://" + host + "/")! }
  }
  static let sites = [Site(name: "Gmail", host: "mail.google.com"), Site(name: "Google Calendar", host: "calendar.google.com"), Site(name: "YouTube", host: "youtube.com"), Site(name: "Notion", host: "notion.so"), Site(name: "Slack", host: "slack.com"), Site(name: "Figma", host: "figma.com"), Site(name: "GitHub", host: "github.com"), Site(name: "Linear", host: "linear.app"), Site(name: "Spotify", host: "spotify.com"), Site(name: "WhatsApp", host: "web.whatsapp.com"), Site(name: "ChatGPT", host: "chatgpt.com"), Site(name: "Wikipedia", host: "wikipedia.org")]
  unowned let app: AppDelegate
  let firstRun: FirstRunViewModel
  let replay: Bool
  let reduceMotion: Bool
  private(set) var step: Step = .name
  private(set) var name = ""
  private(set) var selectedFavorites = Set<Int>()
  private(set) var blocker = true
  private(set) var defaultYes = true
  private(set) var cardPattern = 0
  private(set) var defaultPending = false
  private(set) var finishing = false
  private(set) var confettiPlayed = false
  private var confetti: CAEmitterLayer?
  private var entered: [Step] = []
  private var tasks: [Task<Void, Never>] = []
  private var addedFavorites = Set<Int>()
  private var iconTasks: [Task<Void, Never>] = []
  private var siteImages: [Int: NSImage] = [:]
  private var themeState = ThemeEditorState()
  private var themeBaseline: SpaceTheme = .init()
  private var themeChanged = false
  private var observationGeneration = 0
  private let panel = OnboardingPanel()
  private let titleLabel = NSTextField(wrappingLabelWithString: "")
  private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
  private let controls = OnboardingSurface()
  private let footer = OnboardingSurface()
  let preview = OnboardingPreview()
  private var host: NSHostingController<FirstRunView>?
  private var primary: OnboardingButton?
  private var skipButton: OnboardingButton?
  private var backButton: OnboardingButton?
  private var nameField: NSTextField?
  private var favoriteButtons: [OnboardingFavoriteButton] = []
  private var cardButtons: [OnboardingButton] = []
  private var presetStrip: PresetStripView?
  private var colorPad: OpenSpaceEditor.ColorPadView?
  private var modeBar: AppearanceModeBar?
  private var statusLabel: NSTextField?
  private(set) var savePanel: NSSavePanel?
  private let started = Date()
  var focusedSpace: Space? { app.model.windows.first.flatMap { app.model.space(id: $0.focusedSpaceID) } ?? app.model.spaces.first }
  init(app: AppDelegate, firstRun: FirstRunViewModel, replay: Bool, reduceMotion: Bool) {
    self.app = app; self.firstRun = firstRun; self.replay = replay; self.reduceMotion = reduceMotion
    super.init(nibName: nil, bundle: nil)
    resetTheme()
  }
  required init?(coder: NSCoder) { nil }
  isolated deinit { tasks.forEach { $0.cancel() }; iconTasks.forEach { $0.cancel() } }
  override func loadView() {
    let root = OnboardingSurface(); root.onEscape = { [weak self] in self?.back() }
    view = root; root.wantsLayer = true
    root.addSubview(panel); root.addSubview(preview); preview.layer?.masksToBounds = true
    for child in [titleLabel, descriptionLabel, controls, footer] { panel.addSubview(child) }
    titleLabel.font = .systemFont(ofSize: 32, weight: .semibold); titleLabel.maximumNumberOfLines = 3
    titleLabel.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
    descriptionLabel.font = .systemFont(ofSize: 15); descriptionLabel.textColor = .secondaryLabelColor
    descriptionLabel.maximumNumberOfLines = 3
    render(direction: 0); observeImport()
  }
  func didAttach() { render(direction: 0) }
  @objc private func acceptName(_ sender: Any?) { if step == .name { next() } }
  override func viewDidLayout() {
    super.viewDidLayout()
    let width = min(520, view.bounds.width * 0.48)
    panel.frame = NSRect(x: 0, y: 0, width: width, height: view.bounds.height)
    titleLabel.frame = NSRect(x: 56, y: 72, width: width-112, height: 88)
    let titleHeight = titleLabel.cell?.cellSize(forBounds: titleLabel.frame).height ?? 40
    titleLabel.frame.size.height = min(112, titleHeight)
    descriptionLabel.frame = NSRect(x: 56, y: titleLabel.frame.maxY+12, width: width-112, height: 66)
    controls.frame = NSRect(x: 56, y: descriptionLabel.frame.maxY+32, width: width-112, height: max(40, view.bounds.height-descriptionLabel.frame.maxY-32-112))
    footer.frame = NSRect(x: 56, y: view.bounds.height-88, width: width-112, height: 40)
    backButton?.frame = NSRect(x: 0, y: 4, width: 32, height: 32)
    skipButton?.frame = NSRect(x: step == .name ? 0:44, y: 0, width: 130, height: 40)
    primary?.frame = NSRect(x: footer.bounds.width-120, y: 0, width: 120, height: 40)
    preview.frame = NSRect(x: width, y: 0, width: view.bounds.width-width, height: view.bounds.height)
    let cardWidth = min(620, preview.frame.width-96)
    for (index, button) in cardButtons.enumerated() {
      button.frame = NSRect(x: preview.frame.midX-46+CGFloat(index)*52,
        y: view.bounds.midY+cardWidth*0.625/2+24, width: 40, height: 40)
    }
    host?.view.frame = controls.bounds
    statusLabel?.frame = NSRect(x: 0, y: 150, width: controls.bounds.width, height: 90)
    preview.needsDisplay = true
  }
  var stepTitle: String {
    switch step {
    case .name: "What should we call you?"
    case .importData: "Bring your tabs with you."
    case .favorites: "Choose the sites you use most."
    case .theme: "Make it yours."
    case .blocker: "Fewer ads, fewer trackers."
    case .defaultBrowser: "Make Open your default browser?"
    case .ready: name.isEmpty ? "Welcome to Open." : "Welcome to Open, \(name)."
    }
  }
  var detail: String {
    switch step {
    case .name: "Any name or nickname works. It stays on this Mac."
    case .importData: "Open can bring in your Spaces, pinned tabs, Favorites, archive, and history from Arc. Nothing in Arc changes."
    case .favorites: "They become Favorites at the top of your sidebar, one click away."
    case .theme: "Pick a color for your first Space. Every Space can have its own."
    case .blocker: "Open's built-in blocker hides most ads and stops many trackers. You can turn it off for any site."
    case .defaultBrowser: "Links from other apps will open here. You can change this any time in Settings."
    case .ready: "Here's your Open card, made from your color and the day you started."
    }
  }
  private func button(_ text: String, primary: Bool = false, action: @escaping @MainActor () -> Void) -> OnboardingButton {
    OnboardingButton(text, primary: primary, reduceMotion: reduceMotion, action: action)
  }
  private func render(direction: Int) {
    guard isViewLoaded else { return }
    host?.view.removeFromSuperview(); host = nil
    controls.subviews.forEach { $0.removeFromSuperview() }; footer.subviews.forEach { $0.removeFromSuperview() }
    cardButtons.forEach { $0.removeFromSuperview() }; cardButtons.removeAll()
    if step != .ready { confetti?.removeFromSuperlayer(); confetti = nil }
    nameField = nil; statusLabel = nil; presetStrip = nil; colorPad = nil; modeBar = nil; favoriteButtons = []
    titleLabel.stringValue = stepTitle; descriptionLabel.stringValue = detail
    if step == .importData {
      let host = NSHostingController(rootView: FirstRunView(model: firstRun, startsProbe: false, embeddedImport: true))
      host.sizingOptions = []; self.host = host; controls.addSubview(host.view)
    }
    if step == .name {
      let field = NSTextField(string: name); field.placeholderString = "Your name"; field.font = .systemFont(ofSize: 20)
      field.setAccessibilityLabel("Your name"); field.delegate = self; field.target = self; field.action = #selector(acceptName(_:))
      field.frame = NSRect(x: 0, y: 0, width: 380, height: 40); controls.addSubview(field); nameField = field
    }
    if step == .favorites {
      for (index, site) in Self.sites.enumerated() {
        let tile = OnboardingFavoriteButton(site.name, primary: false, reduceMotion: reduceMotion) { [weak self] in self?.toggleFavorite(index) }
        tile.siteImage = siteImages[index]; tile.selected = selectedFavorites.contains(index)
        tile.frame = NSRect(x: (index%4)*100, y: (index/4)*88, width: 88, height: 76)
        controls.addSubview(tile); favoriteButtons.append(tile)
      }
      fetchIcons()
    }
    if step == .theme {
      let strip = PresetStripView(frame: NSRect(x: 0, y: 0, width: 360, height: 32))
      let pad = OpenSpaceEditor.ColorPadView(frame: NSRect(x: 0, y: 56, width: 360, height: 210))
      let bar = AppearanceModeBar(frame: NSRect(x: 0, y: 282, width: 120, height: 32))
      strip.onAction = { [weak self] in self?.editTheme($0) }; pad.onAction = strip.onAction
      bar.onSelect = { [weak self] in self?.editTheme(.setAppearance($0)) }
      controls.addSubview(strip); controls.addSubview(pad); controls.addSubview(bar)
      let shuffle = button("Shuffle") { [weak self] in self?.shuffleTheme() }; shuffle.frame = NSRect(x: 260, y: 282, width: 100, height: 32); controls.addSubview(shuffle)
      presetStrip = strip; colorPad = pad; modeBar = bar; updateThemeControls()
    }
    if step == .blocker {
      let label = NSTextField(labelWithString: "Block ads and trackers"); label.font = .systemFont(ofSize: 17, weight: .medium)
      label.frame = NSRect(x: 0, y: 12, width: 300, height: 30); controls.addSubview(label)
      let toggle = NSSwitch(frame: NSRect(x: 330, y: 8, width: 52, height: 32)); toggle.state = blocker ? .on:.off
      toggle.setAccessibilityLabel("Block ads and trackers"); toggle.target = self; toggle.action = #selector(blockerChanged(_:)); controls.addSubview(toggle)
      let note = NSTextField(wrappingLabelWithString: "You can change this later in Settings ▸ Advanced.")
      note.font = .systemFont(ofSize: 13); note.textColor = .secondaryLabelColor; note.frame = NSRect(x: 0, y: 68, width: 380, height: 44); controls.addSubview(note)
    }
    if step == .defaultBrowser {
      if firstRun.isDefaultBrowser {
        let label = NSTextField(labelWithString: "Open is your default browser."); label.frame = NSRect(x: 0, y: 0, width: 380, height: 30); controls.addSubview(label)
      } else {
        for (index, text) in ["Yes, make Open my default.", "Not yet. I'm still looking around."].enumerated() {
          let radio = NSButton(radioButtonWithTitle: text, target: self, action: #selector(defaultChanged(_:)))
          radio.font = .systemFont(ofSize: 15); radio.tag = index; radio.state = defaultYes == (index == 0) ? .on:.off
          radio.frame = NSRect(x: 0, y: index*64, width: 395, height: 52); radio.setAccessibilityLabel(text); controls.addSubview(radio)
        }
      }
      statusLabel = NSTextField(wrappingLabelWithString: defaultOutcome); if let statusLabel { controls.addSubview(statusLabel) }
    }
    if step == .ready {
      let shuffle = button("Shuffle card pattern") { [weak self] in self?.shuffleCard() }
      shuffle.image = NSImage(systemSymbolName: "shuffle", accessibilityDescription: "Shuffle card pattern"); shuffle.imagePosition = .imageOnly
      let save = button("Save card image…") { [weak self] in self?.saveCard() }
      save.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save card image…"); save.imagePosition = .imageOnly
      cardButtons = [shuffle, save]; cardButtons.forEach { view.addSubview($0) }
      statusLabel = NSTextField(wrappingLabelWithString: firstRun.errorText ?? ""); if let statusLabel { statusLabel.textColor = .systemRed; controls.addSubview(statusLabel) }
    }
    backButton = nil; skipButton = nil
    if step != .name {
      let back = button("Back") { [weak self] in self?.back() }; back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back"); back.imagePosition = .imageOnly
      footer.addSubview(back); backButton = back; back.isEnabled = !firstRun.busy && !defaultPending && !finishing
    }
    let skip: String? = switch step { case .name, .favorites: "Skip for now"; case .importData: [.report, .importing].contains(firstRun.step) ? nil:firstRun.step == .secretsConsent ? PasswordsImportCopy.skipButton:"Start fresh"; case .theme: "Do this later"; case .blocker: "Not now"; default: nil }
    if let skip { let b = button(skip) { [weak self] in self?.skip() }; footer.addSubview(b); skipButton = b; b.isEnabled = !firstRun.busy && !finishing }
    var text = "Next"
    if step == .importData { text = firstRun.step == .secretsConsent ? PasswordsImportCopy.allowButton : firstRun.step == .report ? "Next" : firstRun.step == .failed ? "Try Again" : "Import" }
    if step == .ready { text = "Get Started" }
    let next = button(text, primary: true) { [weak self] in self?.next() }; next.keyEquivalent = "\r"
    next.isEnabled = !firstRun.busy && !defaultPending && !finishing && (step != .importData || firstRun.step == .report || firstRun.hasSelection)
    footer.addSubview(next); primary = next; view.window?.defaultButtonCell = next.cell as? NSButtonCell
    updatePreview(); view.needsLayout = true; view.layoutSubtreeIfNeeded()
    // Native AppKit key loop includes every control and the shared import host.
    view.window?.recalculateKeyViewLoop()
    if step == .name { view.window?.makeFirstResponder(nameField) }
    if direction != 0 { transition(titleLabel, direction: direction, response: 0.4); transition(descriptionLabel, direction: direction, response: 0.5) }
    let fade = CATransition(); fade.type = .fade; fade.duration = reduceMotion ? 0.2:0.35; preview.layer?.add(fade, forKey: "step-preview")
    NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [.announcement: stepTitle, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    if step == .ready && !confettiPlayed && !reduceMotion { celebrate() }
  }
  private func transition(_ view: NSView, direction: Int, response: Double) {
    view.wantsLayer = true
    let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = reduceMotion ? 0.2:response; view.layer?.add(fade, forKey: "step-fade")
    guard !reduceMotion else { return }
    let spring = CASpringAnimation(keyPath: "transform.translation.x"); spring.fromValue = direction*24; spring.toValue = 0
    spring.mass = 1; spring.stiffness = pow(2 * .pi / response, 2); spring.damping = 2*0.8*sqrt(spring.stiffness); spring.duration = spring.settlingDuration
    view.layer?.add(spring, forKey: "step-slide")
  }
  private func go(_ target: Step, back: Bool = false) {
    guard !finishing else { return }
    if !back { entered.append(step) }; step = target
    if target == .defaultBrowser { firstRun.enterDefaultBrowser() }
    render(direction: back ? -1:1)
  }
  func next() {
    guard !firstRun.busy, !defaultPending, !finishing else { return }
    switch step {
    case .name:
      setName(nameField?.stringValue ?? name)
      if let probe = firstRun.probe { go(probe.sidebarFound || probe.historyFound || probe.archiveFound || probe.secretsFound ? .importData:.favorites); if step == .importData { if firstRun.outcome == nil { firstRun.showImport() }; render(direction: 0) } }
      else {
        primary?.isEnabled = false
        tasks.append(Task { [weak self] in guard let self else { return }; await firstRun.refreshProbe(); guard !Task.isCancelled, step == .name else { return }; next() })
      }
    case .importData:
      if replay { go(.favorites); return }
      if firstRun.step == .report { resetTheme(); if firstRun.wizard.reportCount("Favorites") > 0 { selectedFavorites.removeAll() }; go(firstRun.wizard.reportCount("Favorites") > 0 ? .theme:.favorites) }
      else { tasks.append(Task { [weak self] in guard let self else { return }; if firstRun.step == .secretsConsent { await firstRun.allowPasswords() } else { await firstRun.continueImport() } }) }
    case .favorites: go(.theme)
    case .theme: go(.blocker)
    case .blocker: go(.defaultBrowser)
    case .defaultBrowser:
      if defaultYes && !firstRun.isDefaultBrowser && !replay {
        defaultPending = true; firstRun.makeDefault(); render(direction: 0)
        tasks.append(Task { [weak self] in
          try? await Task.sleep(for: .seconds(1.2)); guard !Task.isCancelled, let self else { return }
          firstRun.refreshDefaultBrowserStatus(); defaultPending = false; go(.ready)
        })
      } else { go(.ready) }
    case .ready:
      if replay { finishing = true; if app.windowControllers.isEmpty { app.showFirstRunBrowser() }; app.frontWindowController?.window?.makeKeyAndOrderFront(nil); app.onboardingWindowController?.finish(); return }
      firstRun.finish(); if app.firstRunSaved { finishing = true }
      else { render(direction: 0) }
    }
  }
  /// Legacy first-run automation keeps its importer proofs, but walks the new
  /// visible screens using their real actions instead of opening the old window.
  func skipToDefault() async {
    if step == .name { if firstRun.probe == nil { await firstRun.refreshProbe() }; next() }
    for _ in 0..<6 {
      if step == .defaultBrowser || step == .ready { break }
      if step == .importData && firstRun.step == .report { next() }
      else { skip() }
    }
  }
  func finishFromDefault() {
    guard step == .defaultBrowser || step == .ready else { return }
    if step == .defaultBrowser { chooseDefault(false); next() }
    next()
  }
  func back() {
    guard !firstRun.busy, !defaultPending, !finishing else { return }
    if step == .importData && firstRun.step == .secretsConsent { firstRun.cancelPasswords(); return }
    guard let previous = entered.popLast() else { return }; go(previous, back: true)
  }
  func skip() {
    guard !firstRun.busy, !finishing else { return }
    switch step {
    case .name: setName(""); next()
    case .importData:
      guard ![.report, .importing].contains(firstRun.step) else { return }
      if firstRun.step == .secretsConsent { tasks.append(Task { [weak self] in await self?.firstRun.skipPasswords() }) }
      else { go(firstRun.wizard.reportCount("Favorites") > 0 ? .theme:.favorites) }
    case .favorites: selectedFavorites.removeAll(); go(.theme)
    case .theme: themeChanged = false; themeState = ThemeEditorState(style: SpaceStyle.seed(from: themeBaseline)); go(.blocker)
    case .blocker: blocker = false; go(.defaultBrowser)
    default: break
    }
  }
  func setName(_ value: String) { name = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)); nameField?.stringValue = name; updatePreview() }
  func controlTextDidChange(_ obj: Notification) {
    guard let nameField else { return }; let value = String(nameField.stringValue.prefix(40)); nameField.stringValue = value; name = value.trimmingCharacters(in: .whitespacesAndNewlines); updatePreview()
  }
  func toggleFavorite(_ index: Int) {
    guard Self.sites.indices.contains(index) else { return }
    if !selectedFavorites.insert(index).inserted { selectedFavorites.remove(index) }
    if favoriteButtons.indices.contains(index) { favoriteButtons[index].selected = selectedFavorites.contains(index) }
    updatePreview(); if !reduceMotion { let spring = CASpringAnimation(keyPath: "transform.scale"); spring.fromValue = 0.96; spring.toValue = 1; spring.mass = 1; spring.stiffness = pow(2 * .pi / 0.3, 2); spring.damping = 2*0.7*sqrt(spring.stiffness); spring.duration = spring.settlingDuration; preview.layer?.add(spring, forKey: "favorites") }
  }
  func setBlocker(_ on: Bool) { blocker = on; updatePreview() }
  @objc private func blockerChanged(_ sender: NSSwitch) { setBlocker(sender.state == .on) }
  func chooseDefault(_ yes: Bool) { defaultYes = yes; render(direction: 0) }
  @objc private func defaultChanged(_ sender: NSButton) { chooseDefault(sender.tag == 0) }
  private var defaultOutcome: String { firstRun.errorText ?? (firstRun.defaultWasAttempted ? (firstRun.isDefaultBrowser ? "Open is your default browser.":"Open is not your default browser yet. You can set it later in Settings."):"") }
  private func resetTheme() { themeChanged = false; themeBaseline = focusedSpace?.theme ?? .init(); themeState = ThemeEditorState(style: SpaceStyle.seed(from: themeBaseline)) }
  func editTheme(_ action: ThemeEditorAction) { let old = themeState.style; themeState.apply(action); if old != themeState.style { themeChanged = true }; updateThemeControls(); updatePreview() }
  private func updateThemeControls() { presetStrip?.apply(page: themeState.presetPage); colorPad?.apply(themeState); modeBar?.mode = themeState.appearance }
  func shuffleTheme() { editTheme(.selectPreset(index: Int.random(in: SpaceStylePresets.all.indices))) }
  func shuffleCard() { cardPattern = (cardPattern+1)%6; updatePreview() }
  var card: OpenCardDrawing { .init(name: name, theme: themeChanged ? SpaceTheme(style: themeState.style):themeBaseline, date: started, pattern: cardPattern) }
  func saveCard() {
    guard let window = view.window, savePanel == nil else { return }
    let save = NSSavePanel(); savePanel = save; save.allowedContentTypes = [.png]; save.nameFieldStringValue = "Open card.png"; save.canCreateDirectories = true
    save.beginSheetModal(for: window) { [weak self] response in
      self?.savePanel = nil
      guard response == .OK, let self, let url = save.url else { return }
      do { try self.card.png().write(to: url, options: .atomic) }
      catch { self.statusLabel?.stringValue = "Open could not save the card image. Try again." }
    }
  }
  /// Called by the existing D3 finish path. Retry adds each selected Favorite once.
  func applyChoices() throws {
    guard !replay, let space = focusedSpace else { return }
    if let profile = app.model.defaultProfile {
      for index in selectedFavorites.sorted() where !addedFavorites.contains(index) {
        let site = Self.sites[index]; let tab = app.model.newTab(in: space.id, url: site.url, title: site.name)
        _ = app.model.addFavorite(tabID: tab.id, to: profile.id); addedFavorites.insert(index)
      }
    }
    if themeChanged { app.model.updateSpace(id: space.id, theme: SpaceTheme(style: themeState.style)) }
    // This is the same store and global setting used by Settings > Advanced.
    guard let store = app.stores.adBlock else { throw CocoaError(.fileWriteUnknown) }
    try store.setEnabled(blocker)
  }
  func persistName() { guard !replay else { return }; UserDefaults.standard.set(name, forKey: "open.onboarding.name") }
  private func observeImport() {
    let generation = observationGeneration
    withObservationTracking { _ = firstRun.step; _ = firstRun.busy; _ = firstRun.probe; _ = firstRun.errorText; _ = firstRun.isDefaultBrowser } onChange: { [weak self] in
      Task { @MainActor [weak self] in guard let self, observationGeneration == generation else { return }; if step == .importData { render(direction: 0) } else if step == .ready || step == .defaultBrowser { statusLabel?.stringValue = step == .ready ? firstRun.errorText ?? "":defaultOutcome }; updatePreview(); observeImport() }
    }
  }
  private func updatePreview() { preview.update(step: step.rawValue, name: name, favorites: selectedFavorites.sorted().map { Self.sites[$0].name }, count: firstRun.outcome?.importedCount("Imported tabs") ?? firstRun.probe?.sidebarItems ?? 0, report: firstRun.step == .report, blocker: blocker, card: card, reduceMotion: reduceMotion) }
  private func celebrate() {
    confettiPlayed = true
    let emitter = CAEmitterLayer(); emitter.frame = preview.bounds; emitter.emitterPosition = CGPoint(x: preview.bounds.midX, y: preview.bounds.height); emitter.emitterSize = CGSize(width: 300, height: 1); emitter.emitterShape = .line
    emitter.emitterCells = [NSColor.systemBlue, .systemOrange, .systemPink, .white].map { color in
      let cell = CAEmitterCell(); cell.birthRate = 28; cell.lifetime = 3; cell.velocity = 160; cell.velocityRange = 70; cell.emissionLongitude = -.pi/2; cell.emissionRange = .pi/2; cell.yAcceleration = -100; cell.spinRange = 3
      let image = NSImage(size: NSSize(width: 8, height: 5), flipped: false) { rect in color.setFill(); rect.fill(); return true }; cell.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil); return cell
    }
    preview.layer?.addSublayer(emitter); confetti = emitter
    tasks.append(Task { [weak self, weak emitter] in try? await Task.sleep(for: .milliseconds(250)); emitter?.birthRate = 0; try? await Task.sleep(for: .seconds(4)); emitter?.removeFromSuperlayer(); self?.confetti = nil })
  }
  private func fetchIcons() {
    guard iconTasks.isEmpty else { return }
    for (index, site) in Self.sites.enumerated() {
      iconTasks.append(Task { [weak self] in
        // Direct site request only. Ephemeral sessions neither send nor store cookies.
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 2; config.timeoutIntervalForResource = 2; config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: OnboardingIconRedirect(), delegateQueue: nil); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: site.url.appendingPathComponent("favicon.ico")); request.timeoutInterval = 2
        guard let (bytes, response) = try? await session.bytes(for: request), !Task.isCancelled,
          let response = response as? HTTPURLResponse, response.statusCode == 200,
          response.url?.host == site.url.host, response.expectedContentLength <= 256*1024 else { return }
        // Bound bytes before decoding. At most 256 KiB per site and a 64 px thumbnail.
        var data = Data()
        do { for try await byte in bytes { guard !Task.isCancelled, data.count < 256*1024 else { return }; data.append(byte) } } catch { return }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let small = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary), let self else { return }
        let icon = NSImage(cgImage: small, size: NSSize(width: 32, height: 32)); siteImages[index] = icon
        if favoriteButtons.indices.contains(index) { favoriteButtons[index].siteImage = icon }
      })
    }
  }
  var state: [String: Any] { ["screen": step.rawValue, "name": name, "title": stepTitle, "favorites": selectedFavorites.sorted(), "blocker": blocker, "defaultYes": defaultYes, "defaultPending": defaultPending, "defaultOutcome": defaultOutcome, "defaultAttempted": firstRun.defaultWasAttempted, "alreadyDefault": firstRun.isDefaultBrowser, "cardPattern": cardPattern, "reduceMotion": reduceMotion, "offset": reduceMotion ? 0:24, "confettiPlayed": confettiPlayed, "confettiActive": confetti != nil, "importStep": firstRun.step.rawValue, "error": firstRun.errorText ?? "", "replay": replay, "themePresetPage": themeState.presetPage, "theme": String(describing: themeState.style), "savePanel": savePanel != nil, "controls": accessibleControls(view)] }
  private func accessibleControls(_ root: NSView) -> [[String: String]] {
    var result: [[String: String]] = []
    if root is NSButton || root is NSSwitch || (root as? NSTextField)?.isEditable == true || root is ThemeEditorButton || root is PresetSwatchView || root is OpenSpaceEditor.ColorPadView { result.append(["role": root.accessibilityRole()?.rawValue ?? "", "label": root.accessibilityLabel() ?? (root as? NSButton)?.title ?? ""]) }
    for child in root.subviews { result += accessibleControls(child) }; return result
  }
}

@MainActor class OnboardingSurface: NSView {
  var onEscape: (() -> Void)?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func cancelOperation(_ sender: Any?) { onEscape?() }
}
@MainActor private final class OnboardingPanel: OnboardingSurface {
  override func draw(_ rect: NSRect) { (effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 30/255, alpha: 1):.white).setFill(); bounds.fill() }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor class OnboardingButton: NSButton {
  let prominent: Bool
  let reduceMotion: Bool
  private let press: @MainActor () -> Void
  private var hovered = false
  init(_ title: String, primary: Bool, reduceMotion: Bool, action: @escaping @MainActor () -> Void) {
    prominent = primary; self.reduceMotion = reduceMotion; press = action
    super.init(frame: .zero); self.title = title; isBordered = false; target = self; self.action = #selector(invoke)
    font = .systemFont(ofSize: 15, weight: primary ? .semibold:.regular); wantsLayer = true; setAccessibilityLabel(title)
  }
  required init?(coder: NSCoder) { nil }
  override var acceptsFirstResponder: Bool { true }
  @objc private func invoke() { guard isEnabled else { return }; press() }
  override func updateTrackingAreas() { super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea); addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)) }
  override func mouseEntered(with event: NSEvent) { hovered = true; animateScale(1.02) }
  override func mouseExited(with event: NSEvent) { hovered = false; animateScale(1) }
  override func mouseDown(with event: NSEvent) { animateScale(0.98); super.mouseDown(with: event); animateScale(hovered ? 1.02:1) }
  private func animateScale(_ value: Double) { guard !reduceMotion, isEnabled else { return }; let spring = CASpringAnimation(keyPath: "transform.scale"); spring.fromValue = layer?.presentation()?.value(forKeyPath: "transform.scale") ?? 1; spring.toValue = value; spring.mass = 1; spring.stiffness = pow(2 * .pi / 0.3, 2); spring.damping = 2*0.45*sqrt(spring.stiffness); spring.duration = spring.settlingDuration; spring.fillMode = .forwards; spring.isRemovedOnCompletion = false; layer?.add(spring, forKey: "button-scale") }
  override func draw(_ dirtyRect: NSRect) {
    if prominent { NSColor(srgbRed: 26/255, green: 63/255, blue: 208/255, alpha: isEnabled ? 1:0.4).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 20, yRadius: 20).fill() }
    if imagePosition == .imageOnly, let image { image.draw(in: NSRect(x: bounds.midX-9, y: bounds.midY-9, width: 18, height: 18), from: .zero, operation: .sourceOver, fraction: isEnabled ? 1:0.4) }
    else { let style = NSMutableParagraphStyle(); style.alignment = .center; let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 15), .foregroundColor: prominent ? NSColor.white : NSColor.secondaryLabelColor, .paragraphStyle: style]; (title as NSString).draw(in: NSRect(x: 4, y: (bounds.height-20)/2, width: bounds.width-8, height: 20), withAttributes: attributes) }
    if window?.firstResponder === self { NSColor.keyboardFocusIndicatorColor.setStroke(); let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 18, yRadius: 18); path.lineWidth = 2; path.stroke() }
  }
}
@MainActor private final class OnboardingFavoriteButton: OnboardingButton {
  var selected = false { didSet { setAccessibilityValue(selected ? 1:0); needsDisplay = true } }
  var siteImage: NSImage? { didSet { needsDisplay = true } }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.quaternaryLabelColor.withAlphaComponent(0.08).setFill(); let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10); outline.fill()
    if selected { NSColor(srgbRed: 26/255, green: 63/255, blue: 208/255, alpha: 1).setStroke(); outline.lineWidth = 2; outline.stroke() }
    let icon = NSRect(x: bounds.midX-16, y: 29, width: 32, height: 32)
    if let siteImage { siteImage.draw(in: icon) } else { NSColor.quaternaryLabelColor.setFill(); NSBezierPath(roundedRect: icon, xRadius: 7, yRadius: 7).fill(); (String(title.prefix(1)) as NSString).draw(at: NSPoint(x: icon.minX+9, y: icon.minY+6), withAttributes: [.font: NSFont.systemFont(ofSize: 19, weight: .semibold), .foregroundColor: NSColor.labelColor]) }
    let style = NSMutableParagraphStyle(); style.alignment = .center
    (title as NSString).draw(in: NSRect(x: 2, y: 7, width: bounds.width-4, height: 17), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
    if selected { ("✓" as NSString).draw(at: NSPoint(x: bounds.width-19, y: bounds.height-20), withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: NSColor.systemBlue]) }
  }
}

private final class OnboardingIconRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}
