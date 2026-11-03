#if OPEN_AUTOMATION
  import AppKit
  import OpenFeatures
  import OpenTranslate
  import Translation

  /// `translate` (docs/automation.md, page-platform §8.3): reads or drives the focused page's
  /// translation session through the real status button and the popover's real buttons.
  extension AutomationController {
    func translateCommand(_ a: [String: Any]) async throws -> Any {
      let w = try window
      let adapter = w.translate
      let action = a["action"] as? String ?? "state"
      func ensurePopover() throws -> TranslatePopoverController {
        if let p = adapter.popover, p.isPresented { return p }
        guard let sidebar = w.controller?.sidebar, sidebar.pressURLStatus(), let p = adapter.popover, p.isPresented else {
          throw Failure(message: "no translation offer (status button not shown)")
        }
        return p
      }
      switch action {
      case "state": return adapter.stateForAutomation()
      case "offer": _ = try ensurePopover(); return adapter.stateForAutomation()
      case "translate", "revert", "never", "choose", "settings":
        let p = try ensurePopover()
        let pressed: TranslatePopoverAction
        switch action {
        case "translate": pressed = .translate
        case "revert": pressed = .showOriginal
        case "never": pressed = .neverTranslate
        case "settings": pressed = .languageSettings
        default:
          guard let target = a["target"] as? String else { throw Failure(message: "choose needs target") }
          pressed = .chooseLanguage(target)
        }
        guard p.view.press(pressed) else { throw Failure(message: "popover has no \(action) button now") }
        return adapter.stateForAutomation()
      case "dismiss": adapter.popover?.dismiss(); return adapter.stateForAutomation()
      case "detect":
        // The real detector on a text (X1: the translated body is no longer French).
        let text = String((a["text"] as? String ?? "").prefix(PageLanguageDetector.maxProbeCharacters))
        let found = PageLanguageDetector.detect(PageLanguageProbe(langAttribute: "", text: text))
        return ["language": found?.code ?? "", "confidence": found?.confidence ?? 0] as [String: Any]
      case "reset":
        // The Settings ▸ Advanced button's action.
        let profile = app.model.profiles.first?.id
        guard let profile else { throw Failure(message: "no profile") }
        return ["result": app.settingsPresenter.resetTranslatePrompts(profileID: profile) ?? "Done",
          "neverTranslateHosts": TranslatePreferences().neverTranslateHosts] as [String: Any]
      case "availability":
        let source = Locale.Language(identifier: a["source"] as? String ?? "fr")
        let target = Locale.Language(identifier: a["target"] as? String ?? "en")
        return ["status": await Self.pairStatus(source, target)]
      default: throw Failure(message: "translate action: state|offer|translate|revert|never|choose|settings|dismiss|reset|availability")
      }
    }

    nonisolated private static func pairStatus(_ s: Locale.Language, _ t: Locale.Language) async -> String {
      let status = await LanguageAvailability().status(from: s, to: t)
      return status == .installed ? "installed" : status == .supported ? "supported" : "unsupported"
    }
  }
#endif
