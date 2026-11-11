import AppKit
import SwiftUI
import Observation
import QuartzCore
import ImageIO
import UniformTypeIdentifiers
import OpenStore
import OpenModel
import OpenSettings
import OpenDesign
import OpenOnboarding
import OpenSpaceEditor

/// Presentation only. Section 7 still owns import, consent, progress and finish.
@MainActor
final class OnboardingStepsController: NSViewController, NSTextFieldDelegate {
  enum Step: String { case name, importData = "import", favorites, theme, blocker, defaultBrowser, ready }
  struct Site {
    let name: String
    let host: String
    var iconSourceURL: URL? = nil
    var url: URL { URL(string: "https://" + host + "/")! }
  }
  // Gmail's own favicon on Google's static host; runtime download only.
  static let sites = [Site(name: "Gmail", host: "mail.google.com", iconSourceURL: URL(string: "https://ssl.gstatic.com/ui/v1/icons/mail/rfr/gmail.ico")), Site(name: "Google Maps", host: "maps.google.com"), Site(name: "YouTube", host: "youtube.com"), Site(name: "Notion", host: "notion.com"), Site(name: "Slack", host: "slack.com"), Site(name: "Figma", host: "figma.com"), Site(name: "GitHub", host: "github.com"), Site(name: "Linear", host: "linear.app"), Site(name: "Spotify", host: "spotify.com"), Site(name: "WhatsApp", host: "web.whatsapp.com"), Site(name: "ChatGPT", host: "chatgpt.com"), Site(name: "Wikipedia", host: "wikipedia.org")]
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
  private(set) var defaultResolved = false
  private(set) var finishing = false
  private(set) var confettiPlayed = false
  private var confettiWasBehindCard = false
  private var confettiLifetime = 0.0
  private var confetti: CAEmitterLayer?
  private var entered: [Step] = []
  private var tasks: [Task<Void, Never>] = []
  private var addedFavorites = Set<Int>()
  let icons: OnboardingFavicons
  private var themeState = ThemeEditorState()
  private var themeBaseline: SpaceTheme = .init()
  private var themeChanged = false
  private var observationGeneration = 0
  private let panel = OnboardingPanel()
  private let titleLabel = NSTextField(wrappingLabelWithString: "")
  private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
  private let controls = OnboardingControls()
  private let footer = OnboardingSurface()
  let preview = OnboardingPreview()
  private var host: NSHostingController<FirstRunView>?
  private var primary: OnboardingButton?
  private var skipButton: OnboardingButton?
  private var backButton: OnboardingButton?
  private var nameField: NSTextField?
  private var favoriteButtons: [OnboardingFavoriteButton] = []
  private var favoriteCounter: NSTextField?
  private var blockerSwitch: OnboardingAccentSwitch?
  private var cardButtons: [OnboardingButton] = []
  private var presetStrip: OnboardingPresetStrip?
  private var colorPad: OpenSpaceEditor.ColorPadView?
  private var modeBar: NSSegmentedControl?
  private var themeShuffle: OnboardingButton?
  private var colorField: OnboardingColorField?
  private var statusLabel: NSTextField?
  private(set) var savePanel: NSSavePanel?
  private let started = Date()
  var focusedSpace: Space? { app.frontWindowController?.context.focusedSpace ?? app.model.windows.first.flatMap { app.model.space(id: $0.focusedSpaceID) } ?? app.model.spaces.first }
  init(app: AppDelegate, firstRun: FirstRunViewModel, replay: Bool, reduceMotion: Bool, icons: OnboardingFavicons) {
    self.icons = icons
    self.app = app; self.firstRun = firstRun; self.replay = replay; self.reduceMotion = reduceMotion
    super.init(nibName: nil, bundle: nil)
    resetTheme()
    icons.onChange = { [weak self] index in
      guard let self, step == .favorites else { return }
      if favoriteButtons.indices.contains(index) {
        favoriteButtons[index].applyIcon(self.icons.tiles[index], animated: true)
      }
      updatePreview()
    }
  }
  required init?(coder: NSCoder) { nil }
  isolated deinit { tasks.forEach { $0.cancel() } }
  func releaseArtwork() {
    observationGeneration += 1
    tasks.forEach { $0.cancel() }; tasks.removeAll()
    icons.onChange = nil
    confetti?.removeFromSuperlayer(); confetti = nil
    host?.view.removeFromSuperview(); host = nil
    preview.removeFromSuperview()
  }
  override func loadView() {
    let root = OnboardingSurface()
    for surface in [root, panel, controls, footer] { surface.onEscape = { [weak self] in self?.back() } }
    view = root; root.wantsLayer = true
    root.addSubview(panel); root.addSubview(preview); preview.layer?.masksToBounds = true
    for child in [titleLabel, descriptionLabel, controls, footer] { panel.addSubview(child) }
    titleLabel.font = .systemFont(ofSize: 32, weight: .semibold); titleLabel.maximumNumberOfLines = 3
    titleLabel.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
    descriptionLabel.font = .systemFont(ofSize: 13); descriptionLabel.textColor = .secondaryLabelColor
    descriptionLabel.maximumNumberOfLines = 2
    render(direction: 0); observeImport()
  }
  func didAttach() { render(direction: 0) }
  @objc private func acceptName(_ sender: Any?) { if step == .name { next() } }
  override func viewDidLayout() {
    super.viewDidLayout()
    let width = min(520, view.bounds.width * 0.48)
    panel.frame = NSRect(x: 0, y: 0, width: width, height: view.bounds.height)
    let contentWidth = width-112
    titleLabel.frame = NSRect(x: 56, y: 72, width: contentWidth, height: 112)
    let titleHeight = titleLabel.cell?.cellSize(forBounds: titleLabel.frame).height ?? 40
    titleLabel.frame.size.height = ceil(min(112,titleHeight)/8)*8
    let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = 18; paragraph.maximumLineHeight = 18
    descriptionLabel.attributedStringValue = NSAttributedString(string: detail,attributes: [
      .font:NSFont.systemFont(ofSize: 13),.foregroundColor:NSColor.secondaryLabelColor,.paragraphStyle:paragraph])
    descriptionLabel.frame = NSRect(x: 56,y: titleLabel.frame.maxY+16,width: contentWidth,height: 40)
    let detailHeight = descriptionLabel.cell?.cellSize(forBounds: descriptionLabel.frame).height ?? 36
    descriptionLabel.frame.size.height = ceil(min(40,detailHeight)/8)*8
    let controlsY = descriptionLabel.frame.maxY+32
    controls.frame = NSRect(x: 56,y: controlsY,width: contentWidth,height: max(40,view.bounds.height-controlsY-112))
    footer.frame = NSRect(x: 56,y: view.bounds.height-88,width: contentWidth,height: 32)
    backButton?.frame = NSRect(x: 0,y: 2,width: 28,height: 28)
    skipButton?.frame = NSRect(x: 40,y: 0,width: 130,height: 32)
    let primaryWidth = max(88,ceil((primary?.title as NSString?)?.size(withAttributes: [.font:NSFont.systemFont(ofSize: 13,weight: .semibold)]).width ?? 0)+32)
    primary?.frame = NSRect(x: contentWidth-primaryWidth,y: 0,width: primaryWidth,height: 32)
    nameField?.frame = NSRect(x: 0,y: 0,width: contentWidth,height: 36)
    if step == .theme {
      presetStrip?.frame = NSRect(x: 0,y: 0,width: contentWidth,height: 32)
      let fieldHeight = min(280,max(200,controls.bounds.height-88))
      colorField?.frame = NSRect(x: 0,y: 48,width: contentWidth,height: fieldHeight)
      modeBar?.frame = NSRect(x: 0,y: fieldHeight+64,width: min(230,contentWidth-96),height: 28)
      themeShuffle?.frame = NSRect(x: contentWidth-80,y: fieldHeight+64,width: 80,height: 28)
    }
    preview.frame = NSRect(x: width, y: 0, width: view.bounds.width-width, height: view.bounds.height)
    let cardFrame = preview.convert(preview.cardRect, to: view)
    for (index, button) in cardButtons.enumerated() {
      button.frame = NSRect(x: cardFrame.midX-38+CGFloat(index)*44,
        y: cardFrame.maxY+16, width: 32, height: 32)
    }
    for card in controls.subviews where card is OnboardingFormCard || card is OnboardingChoiceCard {
      card.frame.size.width = contentWidth
      if let radio = card.subviews.first as? OnboardingChoiceRadio { radio.frame.size.width = contentWidth }
    }
    colorField?.apply(themeState)
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
    controls.allowsOverflow = step == .favorites
    host?.view.removeFromSuperview(); host = nil
    controls.subviews.forEach { $0.removeFromSuperview() }; footer.subviews.forEach { $0.removeFromSuperview() }
    cardButtons.forEach { $0.removeFromSuperview() }; cardButtons.removeAll()
    if step != .ready { confetti?.removeFromSuperlayer(); confetti = nil }
    nameField = nil; statusLabel = nil; presetStrip = nil; colorPad = nil; modeBar = nil; themeShuffle = nil; colorField = nil; favoriteButtons = []; favoriteCounter = nil; blockerSwitch = nil
    titleLabel.stringValue = stepTitle; descriptionLabel.stringValue = detail
    if step == .importData {
      let host = NSHostingController(rootView: FirstRunView(model: firstRun, startsProbe: false, embeddedImport: true))
      host.sizingOptions = []; self.host = host; controls.addSubview(host.view)
    }
    if step == .name {
      let field = OnboardingNameField(string: name); field.isBordered = false; field.isBezeled = false; field.drawsBackground = false; field.focusRingType = .none; field.placeholderString = "Your name"; field.font = .systemFont(ofSize: 15)
      field.setAccessibilityElement(true); field.setAccessibilityRole(.textField)
      field.setAccessibilityLabel("Your name"); field.delegate = self; field.target = self; field.action = #selector(acceptName(_:))
      field.frame = NSRect(x: 0, y: 0, width: 380, height: 40); controls.addSubview(field); nameField = field
    }
    if step == .favorites {
      for (index, site) in Self.sites.enumerated() {
        let tile = OnboardingFavoriteButton(site.name, primary: false, reduceMotion: reduceMotion) { [weak self] in self?.toggleFavorite(index) }
        tile.setAccessibilityRole(.checkBox)
        tile.iconView.arrivalDelay = min(0.18, Double(index)*0.018)
        tile.applyIcon(icons.tiles[index], animated: false); tile.selected = selectedFavorites.contains(index)
        tile.frame = NSRect(x: (index%4)*100, y: (index/4)*96, width: 88, height: 84)
        controls.addSubview(tile); favoriteButtons.append(tile)
      }
      let counter = NSTextField(labelWithString: "")
      counter.font = .systemFont(ofSize: 12, weight: .medium); counter.textColor = .secondaryLabelColor
      counter.frame = NSRect(x: 0, y: 292, width: 388, height: 18); controls.addSubview(counter); favoriteCounter = counter
    }
    if step == .theme {
      let strip = OnboardingPresetStrip()
      let field = OnboardingColorField()
      let pad = field.pad
      let bar = NSSegmentedControl(labels: ["Auto","Light","Dark"],trackingMode: .selectOne,target: self,action: #selector(appearanceChanged(_:)))
      bar.segmentStyle = .rounded; bar.font = .systemFont(ofSize: 13)
      bar.selectedSegmentBezelColor = OnboardingTokens.Room.space
      bar.setAccessibilityLabel("Appearance")
      strip.onAction = { [weak self] in self?.editTheme($0) }; pad.onAction = strip.onAction
      controls.addSubview(strip); controls.addSubview(field); controls.addSubview(bar)
      let shuffle = button("Shuffle") { [weak self] in self?.shuffleTheme() }; shuffle.outlined = true; controls.addSubview(shuffle)
      presetStrip = strip; colorField = field; colorPad = pad; modeBar = bar; themeShuffle = shuffle; updateThemeControls()
    }
    if step == .blocker {
      let card = OnboardingFormCard(); card.frame = NSRect(x: 0,y: 0,width: 408,height: 80); controls.addSubview(card)
      let label = NSTextField(labelWithString: "Block ads and trackers"); label.font = .systemFont(ofSize: 13,weight: .medium)
      label.frame = NSRect(x: 16,y: 16,width: 290,height: 18); card.addSubview(label)
      let toggle = OnboardingAccentSwitch(frame: NSRect(x: 340,y: 9,width: 52,height: 32)); toggle.state = blocker ? .on:.off
      toggle.setAccessibilityLabel("Block ads and trackers"); toggle.target = self; toggle.action = #selector(blockerChanged(_:)); card.addSubview(toggle)
      blockerSwitch = toggle
      let note = NSTextField(wrappingLabelWithString: "You can change this later in Settings › Ad Blocking.")
      note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor; note.frame = NSRect(x: 16,y: 46,width: 370,height: 18); card.addSubview(note)
      for (index,text) in ["Blocks ads with EasyList","Stops trackers with EasyPrivacy","Remembers your site exceptions"].enumerated() {
        let item = NSTextField(labelWithString: "✓  "+text); item.font = .systemFont(ofSize: 13); item.textColor = .secondaryLabelColor
        item.frame = NSRect(x: 0,y: 104+index*32,width: 408,height: 20); controls.addSubview(item)
      }
    }
    if step == .defaultBrowser {
      if firstRun.isDefaultBrowser {
        let label = NSTextField(labelWithString: "Open is your default browser."); label.frame = NSRect(x: 0, y: 0, width: 380, height: 30); controls.addSubview(label)
      } else {
        for (index, text) in ["Yes, make Open my default.", "Not yet. I'm still looking around."].enumerated() {
          let card = OnboardingChoiceCard(selected: defaultYes == (index == 0))
          card.onEscape = { [weak self] in self?.back() }
          card.frame = NSRect(x: 0, y: index*64, width: 408, height: 48)
          let radio = OnboardingChoiceRadio(radioButtonWithTitle: text,target: self,action: #selector(defaultChanged(_:)))
          radio.font = .systemFont(ofSize: 13); radio.tag = index; radio.state = defaultYes == (index == 0) ? .on:.off
          radio.frame = NSRect(x: 0,y: 0,width: 408,height: 48)
          radio.setAccessibilityElement(true); radio.setAccessibilityRole(.radioButton); radio.setAccessibilityLabel(text)
          card.addSubview(radio); controls.addSubview(card)
        }
      }
      statusLabel = NSTextField(wrappingLabelWithString: defaultOutcome); if let statusLabel { controls.addSubview(statusLabel) }
    }
    if step == .ready {
      let shuffle = button("Shuffle card pattern") { [weak self] in self?.shuffleCard() }
      shuffle.usesLightInk = true; shuffle.circular = true
      shuffle.image = NSImage(systemSymbolName: "shuffle", accessibilityDescription: "Shuffle card pattern"); shuffle.imagePosition = .imageOnly
      let save = button("Save card image…") { [weak self] in self?.saveCard() }
      save.usesLightInk = true; save.circular = true
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
    if step == .defaultBrowser && defaultYes && !firstRun.isDefaultBrowser { text = "Make default" }
    if step == .ready { text = "Get Started" }
    let next = button(text, primary: true) { [weak self] in self?.next() }; next.keyEquivalent = "\r"; next.keyEquivalentModifierMask = []
    next.isEnabled = !firstRun.busy && !defaultPending && !finishing && (step != .importData || firstRun.step == .report || firstRun.hasSelection)
    footer.addSubview(next); primary = next; view.window?.defaultButtonCell = next.cell as? NSButtonCell
    updatePreview(); view.needsLayout = true; view.layoutSubtreeIfNeeded()
    // Native AppKit key loop includes every control and the shared import host.
    view.window?.recalculateKeyViewLoop()
    if step == .name { view.window?.makeFirstResponder(nameField) }
    else if step == .favorites { view.window?.makeFirstResponder(favoriteButtons.first) }
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
  func performPrimaryAction() {
    guard primary?.isEnabled == true else { return }
    next()
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
        defaultPending = true; defaultResolved = false; firstRun.makeDefault(); render(direction: 0)
        tasks.append(Task { [weak self] in
          guard let self else { return }
          await firstRun.waitForDefaultBrowserRequest()
          guard !Task.isCancelled else { return }
          defaultResolved = true; render(direction: 0)
          try? await Task.sleep(for: .seconds(1.2)); guard !Task.isCancelled else { return }
          defaultPending = false; go(.ready)
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
    updatePreview()
  }
  func setBlocker(_ on: Bool) { blocker = on; blockerSwitch?.state = on ? .on:.off; updatePreview() }
  @objc private func blockerChanged(_ sender: OnboardingAccentSwitch) { setBlocker(sender.state == .on) }
  func chooseDefault(_ yes: Bool) { defaultYes = yes; render(direction: 0) }
  @objc private func defaultChanged(_ sender: NSButton) { chooseDefault(sender.tag == 0) }
  private var defaultOutcome: String { defaultPending && !defaultResolved ? "":firstRun.errorText ?? (firstRun.defaultWasAttempted ? (firstRun.isDefaultBrowser ? "Open is your default browser.":"Open is not your default browser yet. You can set it later in Settings."):"") }
  private func resetTheme() { themeChanged = false; themeBaseline = focusedSpace?.theme ?? .init(); themeState = ThemeEditorState(style: SpaceStyle.seed(from: themeBaseline)) }
  func editTheme(_ action: ThemeEditorAction) { let old = themeState.style; themeState.apply(action); if old != themeState.style { themeChanged = true }; updateThemeControls(); updatePreview() }
  @objc private func appearanceChanged(_ sender: NSSegmentedControl) {
    let modes: [SpaceStyleAppearance] = [.automatic,.light,.dark]
    guard modes.indices.contains(sender.selectedSegment) else { return }
    editTheme(.setAppearance(modes[sender.selectedSegment]))
  }
  private func updateThemeControls() {
    presetStrip?.apply(themeState); colorPad?.apply(themeState); colorField?.apply(themeState)
    modeBar?.selectedSegment = [.automatic,.light,.dark].firstIndex(of: themeState.appearance) ?? 0
  }
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
    // This is the same store and global setting used by Settings > Ad Blocking.
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
  private func updatePreview() {
    let countText = selectedFavorites.isEmpty ? "None selected" : "\(selectedFavorites.count) selected"
    if favoriteCounter?.stringValue != countText {
      favoriteCounter?.stringValue = countText
      if let favoriteCounter { NSAccessibility.post(element: favoriteCounter, notification: .valueChanged) }
    }
    preview.update(step: step.rawValue, name: name, favorites: selectedFavorites.sorted().map { (Self.sites[$0].name, icons.tiles[$0]) }, count: firstRun.outcome?.importedCount("Imported tabs") ?? firstRun.probe?.sidebarItems ?? 0, report: firstRun.step == .report, blocker: blocker, card: card, reduceMotion: reduceMotion, source: app.model)
  }
  private func celebrate() {
    confettiPlayed = true
    let emitter = CAEmitterLayer(); emitter.emitterShape = .line
    emitter.emitterCells = [NSColor.systemBlue, .systemOrange, .systemPink, .white].map { color in
      let cell = CAEmitterCell(); cell.birthRate = 28; cell.lifetime = 0.6; cell.velocity = 160; cell.velocityRange = 70; cell.emissionLongitude = -.pi/2; cell.emissionRange = .pi/2; cell.yAcceleration = -100; cell.spinRange = 3
      let image = NSImage(size: NSSize(width: 8, height: 5), flipped: false) { rect in color.setFill(); rect.fill(); return true }; cell.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil); return cell
    }
    preview.showConfetti(emitter); confetti = emitter
    confettiWasBehindCard = preview.confettiBehindCard
    confettiLifetime = Double(emitter.emitterCells?.first?.lifetime ?? 0)
    let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
    fade.beginTime = emitter.convertTime(CACurrentMediaTime(), from: nil)+0.45; fade.duration = 0.15
    fade.fillMode = .forwards; fade.isRemovedOnCompletion = false; emitter.add(fade, forKey: "confetti-fade")
    tasks.append(Task { [weak self, weak emitter] in
      try? await Task.sleep(for: .milliseconds(600)); emitter?.birthRate = 0
      emitter?.removeFromSuperlayer(); self?.confetti = nil
    })
  }
  private var favoriteIconState: [[String: Any]] {
    Self.sites.enumerated().map { index, site in
      let tile = icons.tiles[index]
      let button = favoriteButtons.indices.contains(index) ? favoriteButtons[index] : nil
      return ["index": index, "name": site.name, "iconState": tile.state,
        "iconSourceURL": (site.iconSourceURL?.absoluteString as Any?) ?? NSNull(),
        "renderedKind": tile.image == nil ? "monogram" : "icon", "sourceKind": (tile.info?.sourceKind?.rawValue as Any?) ?? NSNull(),
        "pixelSize": [tile.info?.width ?? 0, tile.info?.height ?? 0], "opaque": tile.info?.opaque ?? false,
        "iconStyle": tile.info.map { $0.opaque && min($0.width, $0.height) >= 64 ? "full-bleed":"plate" } ?? "monogram",
        "windowFrame": button.map { b in let r = b.convert(b.bounds, to: nil); return [r.minX, r.minY, r.width, r.height] } ?? [],
        "monogramColor": button?.iconView.monogramColor ?? 0, "monogramContrast": button?.iconView.monogramContrast ?? 0,
        "storeHit": tile.storeHit, "durationMS": tile.durationMS, "elapsedMS": tile.elapsedMS, "focused": button.map { $0.window?.firstResponder === $0 } ?? false, "frame": button.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } ?? [],
        "iconWindowFrame": button.map { b in
          let r = b.iconView.convert(b.iconView.bounds, to: nil)
          return [r.minX, r.minY, r.width, r.height]
        } ?? [], "iconFrame": [28, 12, 32, 32], "fadeDuration": button?.iconView.fadeDuration ?? 0,
        "style": button?.styleState ?? [:], "arrivalDelay": button?.iconView.arrivalDelay ?? 0]
    }
  }
  private var cardState: [String: Any] {
    let rect = preview.convert(preview.cardRect, to: view)
    return ["luminance": card.backgroundLuminance, "darkText": card.usesDarkText,
      "frame": [rect.minX, rect.minY, rect.width, rect.height],
      "buttons": cardButtons.map { button -> [String: Any] in
        ["label": button.accessibilityLabel() ?? "", "circle": button.circular,
          "frame": [button.frame.minX, button.frame.minY, button.frame.width, button.frame.height]]
      }]
  }
  var state: [String: Any] { ["screen": step.rawValue, "favoritePreview": preview.favoriteState, "favoriteCountLabel": favoriteCounter?.stringValue ?? "", "favoriteTiles": favoriteIconState, "faviconFetch": icons.state, "backingScale": view.window?.backingScaleFactor ?? 0, "name": name, "title": stepTitle, "favorites": selectedFavorites.sorted(), "blocker": blocker, "defaultYes": defaultYes, "defaultPending": defaultPending, "defaultOutcome": defaultOutcome, "defaultAttempted": firstRun.defaultWasAttempted, "alreadyDefault": firstRun.isDefaultBrowser, "cardPattern": cardPattern, "reduceMotion": reduceMotion, "offset": reduceMotion ? 0:24, "confettiPlayed": confettiPlayed, "confettiActive": confetti != nil, "confettiBehindCard": confettiWasBehindCard, "confettiLifetime": confettiLifetime, "card": cardState, "importStep": firstRun.step.rawValue, "error": firstRun.errorText ?? "", "replay": replay, "themePresetPage": themeState.presetPage, "theme": String(describing: themeState.style), "savePanel": savePanel != nil, "focus": (view.window?.firstResponder as? NSView)?.accessibilityLabel() ?? "", "controls": accessibleControls(view)] }
  private func accessibleControls(_ root: NSView) -> [[String: String]] {
    // Artwork is one AX image. Its native miniature controls are decorative
    // descendants, not extra controls in the setup keyboard/VoiceOver flow.
    if root.isAccessibilityElement(), root.accessibilityRole() == .image { return [] }
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
@MainActor private final class OnboardingControls: OnboardingSurface {
  var allowsOverflow = false
  override var wantsDefaultClipping: Bool { !allowsOverflow }
}
@MainActor private final class OnboardingPanel: OnboardingSurface {
  override func draw(_ rect: NSRect) { (effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 30/255, alpha: 1):.white).setFill(); bounds.fill() }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
@MainActor private final class OnboardingChoiceCard: OnboardingSurface {
  let selected: Bool
  init(selected: Bool) { self.selected = selected; super.init(frame: .zero) }
  required init?(coder: NSCoder) { nil }
  override var acceptsFirstResponder: Bool { false }
  override func draw(_ rect: NSRect) {
    let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
    NSColor.controlBackgroundColor.setFill(); outline.fill()
    (selected ? OnboardingTokens.Room.space:NSColor.separatorColor).setStroke()
    outline.lineWidth = selected ? 2:1; outline.stroke()
  }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor class OnboardingButton: NSButton {
  static var primaryBlue: NSColor { OnboardingTokens.Room.space }
  let prominent: Bool
  let reduceMotion: Bool
  var usesLightInk = false
  var circular = false
  var outlined = false
  private let press: @MainActor () -> Void
  private var hovered = false
  var interactionHoverScale: Double { 1.02 }
  var interactionPressedScale: Double { 0.98 }
  var interactionDuration: Double? { nil }
  func interactionHoverChanged(_ hovered: Bool) {}
  private var circularGlyph: NSImage?
  init(_ title: String, primary: Bool, reduceMotion: Bool, action: @escaping @MainActor () -> Void) {
    prominent = primary; self.reduceMotion = reduceMotion; press = action
    super.init(frame: .zero); self.title = title; isBordered = false; target = self; self.action = #selector(invoke)
    setButtonType(.momentaryPushIn)
    font = .systemFont(ofSize: 13, weight: primary ? .semibold:.regular); wantsLayer = true
    setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(title)
    if primary {
      layer?.masksToBounds = false; layer?.shadowColor = Self.primaryBlue.cgColor
      layer?.shadowOpacity = 0.4; layer?.shadowRadius = 11; layer?.shadowOffset = CGSize(width: 0, height: -8)
    }
  }
  override func layout() {
    super.layout()
    if prominent { layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 16, cornerHeight: 16, transform: nil) }
  }
  required init?(coder: NSCoder) { nil }
  override var acceptsFirstResponder: Bool { true }
  override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
  override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection([.command, .control, .option])
    if modifiers.isEmpty, event.keyCode == 49 {
      if !event.isARepeat { performClick(nil) }
      return
    }
    super.keyDown(with: event)
  }
  @objc private func invoke() { guard isEnabled else { return }; press() }
  override func accessibilityPerformPress() -> Bool { guard isEnabled else { return false }; invoke(); return true }
  override func updateTrackingAreas() { super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea); addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)) }
  override func mouseEntered(with event: NSEvent) { hovered = true; interactionHoverChanged(true); needsDisplay = true; animateScale(interactionHoverScale) }
  override func mouseExited(with event: NSEvent) { hovered = false; interactionHoverChanged(false); needsDisplay = true; animateScale(1) }
  override func mouseDown(with event: NSEvent) { animateScale(interactionPressedScale); super.mouseDown(with: event); animateScale(hovered ? interactionHoverScale:1) }
  private func animateScale(_ value: Double) {
    guard !reduceMotion, isEnabled else { return }
    if let interactionDuration {
      let animation = CABasicAnimation(keyPath: "transform.scale")
      animation.fromValue = layer?.presentation()?.value(forKeyPath: "transform.scale") ?? 1; animation.toValue = value
      animation.duration = interactionDuration; animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
      animation.fillMode = .forwards; animation.isRemovedOnCompletion = false; layer?.add(animation, forKey: "button-scale")
    } else {
      let spring = CASpringAnimation(keyPath: "transform.scale"); spring.fromValue = layer?.presentation()?.value(forKeyPath: "transform.scale") ?? 1; spring.toValue = value; spring.mass = 1; spring.stiffness = pow(2 * .pi / 0.3, 2); spring.damping = 2*0.45*sqrt(spring.stiffness); spring.duration = spring.settlingDuration; spring.fillMode = .forwards; spring.isRemovedOnCompletion = false; layer?.add(spring, forKey: "button-scale")
    }
  }
  override func draw(_ dirtyRect: NSRect) {
    if circular { NSColor.white.withAlphaComponent(hovered ? 0.24:0.16).setFill(); NSBezierPath(ovalIn: bounds).fill() }
    if prominent { Self.primaryBlue.withAlphaComponent(isEnabled ? 1:0.4).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).fill() }
    if title == "Back" || outlined {
      let plate = title == "Back" ? NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5,dy: 0.5)):NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5,dy: 0.5),xRadius: 7,yRadius: 7)
      NSColor.controlBackgroundColor.withAlphaComponent(hovered ? 0.95:0.65).setFill(); plate.fill()
      NSColor.separatorColor.setStroke(); plate.lineWidth = 1; plate.stroke()
    }
    if imagePosition == .imageOnly, let image {
      let tinted: NSImage
      if circular {
        if circularGlyph == nil {
          let glyph = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            image.draw(in: rect); NSColor.white.setFill(); rect.fill(using: .sourceIn); return true
          }
          glyph.isTemplate = false; circularGlyph = glyph
        }
        tinted = circularGlyph ?? image
      } else { tinted = image.withSymbolConfiguration(.init(paletteColors: [usesLightInk || prominent ? .white:.labelColor])) ?? image }
      tinted.draw(in: NSRect(x: bounds.midX-9, y: bounds.midY-9, width: 18, height: 18), from: .zero, operation: .sourceOver, fraction: (isEnabled ? 1:0.4)*(circular ? 0.9:1))
    }
    else { let style = NSMutableParagraphStyle(); style.alignment = .center; let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 15), .foregroundColor: prominent ? NSColor.white : outlined ? NSColor.labelColor : NSColor.secondaryLabelColor, .paragraphStyle: style]; (title as NSString).draw(in: NSRect(x: 4, y: (bounds.height-20)/2, width: bounds.width-8, height: 20), withAttributes: attributes) }
    if window?.firstResponder === self { Self.primaryBlue.withAlphaComponent(0.65).setStroke(); let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 18, yRadius: 18); path.lineWidth = 2; path.stroke() }
  }
}
