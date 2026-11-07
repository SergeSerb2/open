import AppKit
import OpenEngine
import OpenFeatures
import OpenModel
import OpenWeb

extension OESavePrompt: @retroactive SavePromptRequest {
  // Both APIs intentionally call this property `kind`, but use their own
  // enums. Give the protocol its mapped witness without changing the engine API.
  @_implements(SavePromptRequest, kind)
  public var openSavePromptKind: SavePromptKind {
    let value: OESavePrompt.Kind = kind
    switch value {
    case .password: return .password
    case .passwordUpdate: return .passwordUpdate
    case .card: return .card
    case .address: return .address
    case .addressUpdate: return .addressUpdate
    @unknown default: return .password
    }
  }

  public func answer(_ answer: SavePromptAnswer) {
    guard !isAnswered else { return }
    let mapped: OESavePrompt.Answer = switch answer {
    case .save: .save
    case .neverForSite: .neverForSite
    case .dismiss: .dismiss
    }
    #if OPEN_AUTOMATION
    AutomationController.savePromptOwner?.recordRealSavePrompt(self, answer: mapped == .save ? "save" : mapped == .neverForSite ? "never" : "dismiss")
    #endif
    self.answer(mapped)
  }
}

extension EngineWebContentHost {
  func webContent(_ page: OEWebContent, showSavePrompt prompt: OESavePrompt) {
    guard !closed else { return }
    owner?.webContent(page, showSavePrompt: prompt)
  }
  func webContent(_ page: OEWebContent, withdrawSavePrompt prompt: OESavePrompt) {
    owner?.webContent(page, withdrawSavePrompt: prompt)
  }
  func webContent(_ page: OEWebContent, openAutofillPage destination: OEAutofillPage) {
    guard !closed else { return }
    owner?.webContent(page, openAutofillPage: destination)
  }
  func webContentDidFailToSavePasswordForKeychainError(_ page: OEWebContent) {
    owner?.webContentDidFailToSavePasswordForKeychainError(page)
  }
}

extension EngineWebContentHostFactory {
  func webContent(_ page: OEWebContent, showSavePrompt prompt: OESavePrompt) {
    guard !isClosing, !page.context.isEphemeral else { return }
    attachSavePrompts()
    #if OPEN_AUTOMATION
    AutomationController.savePromptOwner?.recordRealSavePrompt(prompt, answer: "pending")
    #endif
    savePrompts?.enqueue(prompt, page: AnyHashable(page.identifier))
  }
  func webContent(_ page: OEWebContent, withdrawSavePrompt prompt: OESavePrompt) {
    #if OPEN_AUTOMATION
    AutomationController.savePromptOwner?.recordRealSavePrompt(prompt, answer: "ignored")
    #endif
    savePrompts?.withdraw(prompt)
  }
  func webContent(_ page: OEWebContent, openAutofillPage destination: OEAutofillPage) {
    guard let target = AutofillPage(rawValue: destination.rawValue) else { return }
    #if OPEN_AUTOMATION
    AutomationController.savePromptOwner?.recordAutofillPage(target)
    #endif
    // Peek hosts retain their source Space even though they are not model tabs.
    let host = hosts.values.first { $0.content === page }
    let source = host?.spaceID.flatMap { model.space(id: $0) }
      ?? tabID(for: page).flatMap { space(for: $0) }
      ?? host.flatMap { model.mostRecentlyFocusedSpace(profileID: $0.profileID) }
    guard let source else { return }
    // Focusing a Space can close a Peek. Leave the engine delegate callback
    // before a selection change can destroy the page that called it.
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.isClosing, self.model.space(id: source.id) === source else { return }
      if self.controller != nil { self.openAutofillPage(target, in: source); return }
      // A Little Open page has its own window but uses its own profile's Space.
      let browser = self.app.windowControllers.first { self.app.hostFactories[$0.windowID]?.focusedSpace?.id == source.id }
        ?? self.app.makeWindow(focusedSpaceID: source.id)
      if let browser, let factory = self.app.hostFactories[browser.windowID] {
        self.app.focusWindow(browser.windowID, activate: true)
        factory.openAutofillPage(target, in: source)
      }
    }
  }
  func webContentDidFailToSavePasswordForKeychainError(_ page: OEWebContent) {
    let message = ToastContent(title: "Open couldn't use your Keychain, so this password wasn't saved.")
    if let controller { controller.toasts.show(message) }
    else if let view = standaloneSurface?.surfacePage?.view ?? littleOpenController?.window?.contentView {
      if autofillToastCenter == nil {
        let overlay = ToastOverlayView(frame: view.bounds)
        overlay.autoresizingMask = [.width, .height]
        view.addSubview(overlay)
        autofillToastCenter = ToastCenter(overlay: overlay) { [weak view] in
          let name = view?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
          return .defaultTheme(system: name == .aqua ? .light : .dark)
        }
      }
      autofillToastCenter?.show(message)
    }
  }
}
