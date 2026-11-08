#if OPEN_AUTOMATION
import OpenEngine
import OpenWeb

extension AutomationController {
  func scriptWorld(_ args: [String: Any]) throws -> ScriptWorld {
    switch args["world"] as? String ?? "page" {
    case "page": return .page
    case "open": return .open
    default: throw Failure(message: "world must be page or open")
    }
  }

  func openWorldMessages(_ page: OEWebContent, factory: EngineWebContentHostFactory, clear: Bool, subscribe: Bool?) async throws -> Any {
    let identifier = page.identifier
    if let subscribe {
      let content: any WebContent = page
      content.onOpenWorldMessage = subscribe ? { [weak self] type, payloadJSON, documentID in
        guard let self else { return }
        self.recordedOpenWorldCallbacks.append(["content": identifier, "type": type,
          "payloadJSON": payloadJSON, "documentID": documentID])
        if self.recordedOpenWorldCallbacks.count > 64 { self.recordedOpenWorldCallbacks.removeFirst() }
      } : nil
    }
    let stats = try await page.openWorldMessageStatistics()
    let messages = factory.recordedOpenWorldMessages.filter { $0["content"] as? Int == page.identifier }
    let callbacks = recordedOpenWorldCallbacks.filter { $0["content"] as? Int == identifier }
    if clear {
      factory.recordedOpenWorldMessages.removeAll { $0["content"] as? Int == identifier }
      recordedOpenWorldCallbacks.removeAll { $0["content"] as? Int == identifier }
    }
    return ["messages": messages, "callbacks": callbacks, "statistics": stats] as [String: Any]
  }
}
#endif
