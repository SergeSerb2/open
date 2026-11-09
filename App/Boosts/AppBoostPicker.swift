import Foundation
import OpenBoosts
import OpenEngine
import OpenModel

/// One native capability per bound tab. No nonce or document identity crosses
/// the page world, DOM, or a DOM event. The engine supplies the document token.
@MainActor
final class AppBoostPicker {
  unowned let editor: AppBoostEditorHost
  private var boosts: AppBoosts { editor.boosts }
  @MainActor private final class Binding {
    weak var host: EngineWebContentHost?
    let boostID: BoostID
    let mode: PickerMode
    let challenge = UUID().uuidString
    let coordinator: BoostPickerCoordinator
    var documentID: String?
    var session: PickerSession?
    var ready = false
    var work: Task<Void, Never>?
    init(host: EngineWebContentHost, boostID: BoostID, mode: PickerMode, store: BoostStore) {
      self.host = host; self.boostID = boostID; self.mode = mode
      coordinator = BoostPickerCoordinator(store: store)
    }
  }
  private var bindings: [ItemID: Binding] = [:]
  init(host: AppBoostEditorHost) { editor = host }

  func isAvailable(tabID: ItemID) -> Bool {
    guard boosts.canEdit(tabID: tabID), !boosts.app.shutdownPrepared,
      let host = boosts.factory(for: tabID)?.hosts[tabID], host.content.isLive,
      !host.content.isLoading, !host.content.isDiscarded, host.content.crashState == .none else { return false }
    if let session = host.owner?.controller?.boostEditor?.session, session.context.tabID == tabID {
      return session.isEditable
    }
    return true
  }

  func enter(boostID: BoostID, tabID: ItemID, mode: PickerMode) -> Bool {
    guard isAvailable(tabID: tabID), boosts.boostsGloballyEnabled,
      let host = boosts.factory(for: tabID)?.hosts[tabID], let url = host.content.url,
      let boost = boosts.store(for: host.profileID).boost(id: boostID),
      boost.zaps.count <= AppBoostPickerMessage.maxEntries,
      boost.zaps.allSatisfy({ AppBoostPickerMessage.validSelector($0.selector) }) else { return false }
    if let binding = bindings[tabID], binding.host === host, binding.boostID == boostID, binding.mode == mode { return true }
    exit(tabID: tabID)
    let binding = Binding(host: host, boostID: boostID, mode: mode, store: boosts.store(for: host.profileID))
    bindings[tabID] = binding
    // First obtain this document's engine token. A private-world marker guards
    // the later injection if navigation happens between these two requests.
    let challenge = BoostEngineAdapter.json(binding.challenge)
    evaluate("""
      (() => {
        if (location.href !== \(BoostEngineAdapter.json(url.absoluteString))) return false;
        if (typeof window.__openZap?.exit === 'function') window.__openZap.exit();
        window.__openZapBinding = \(challenge);
        __openNative.postMessage('picker:document', JSON.stringify({challenge: \(challenge)}));
        return true;
      })()
      """, binding: binding, tabID: tabID)
    return true
  }

  func receive(_ page: OEWebContent, type: String, payloadJSON: String, documentID: String) {
    guard let (tabID, binding) = bindings.first(where: { $0.value.host?.content === page }),
      let host = binding.host,
      isAvailable(tabID: tabID), boosts.boostsGloballyEnabled,
      !documentID.isEmpty, documentID.utf8.count <= 128, !documentID.contains("\0") else { return }
    if type == "picker:document" {
      guard binding.documentID == nil, payloadJSON.utf8.count <= 128,
        let data = payloadJSON.data(using: .utf8),
        let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String],
        payload == ["challenge": binding.challenge],
        let command = binding.coordinator.enterZap(boostID: binding.boostID, for: documentID, mode: binding.mode),
        case let .enterZap(session) = command else { return }
      binding.documentID = documentID; binding.session = session
      let install = """
        \(BoostResources.pickerJS)
        window.__open.postMessage = (type, payload) => __openNative.postMessage(type, JSON.stringify(payload));
        """
      send(command, binding: binding, tabID: tabID, prefix: install)
      return
    }
    guard binding.documentID == documentID, let session = binding.session,
      let message = AppBoostPickerMessage.decode(type: type, payloadJSON: payloadJSON, session: session,
        selectors: boosts.store(for: host.profileID).boost(id: binding.boostID)?.zaps.map(\.selector) ?? []) else { return }
    let changed = binding.coordinator.handle(message, from: documentID)
    if case .pickerReady = message { binding.ready = true; requestCounts(tabID: tabID) }
    if case let .revealRequested(_, selector) = message, changed { remove(selector, tabID: tabID) }
    if case .pickerExited = message { exit(tabID: tabID); return }
    if let event = binding.coordinator.lastEvent { editor.publishPickerEvent(event, tabID: tabID) }
    if changed, let host = binding.host {
      boosts.refresh(profile: host.profileID)
      requestCounts(tabID: tabID)
    }
  }

  func requestCounts(tabID: ItemID) {
    guard let binding = bindings[tabID], binding.ready, let documentID = binding.documentID,
      let command = binding.coordinator.listZaps(for: documentID) else { return }
    send(command, binding: binding, tabID: tabID)
  }
  func remove(_ selector: String, tabID: ItemID) {
    guard let binding = bindings[tabID], let documentID = binding.documentID,
      AppBoostPickerMessage.validSelector(selector),
      let command = binding.coordinator.removeZap(selector: selector, for: documentID) else { return }
    // The coordinator/session already owns the store mutation. The native
    // removal echo clears only picker preview state, never a second store edit.
    send(command, binding: binding, tabID: tabID)
  }
  func exit(tabID: ItemID) {
    guard let binding = bindings.removeValue(forKey: tabID) else { return }
    if let documentID = binding.documentID { binding.coordinator.invalidate(pageID: documentID) }
    let source = """
      (() => {
        if (window.__openZapBinding !== \(BoostEngineAdapter.json(binding.challenge))) return true;
        window.__openZap?.exit(); delete window.__openZapBinding; return true;
      })()
      """
    evaluate(source, binding: binding, tabID: tabID, ending: true)
    editor.publishPickerEvent(.exited, tabID: tabID)
  }
  func stop() { for tabID in Array(bindings.keys) { exit(tabID: tabID) } }

  private func send(_ command: PickerOutbound, binding: Binding, tabID: ItemID, prefix: String = "") {
    let wire = BridgeDecode.encode(command)
    guard wire.type.utf8.count + wire.payloadJSON.utf8.count <= 65_536 else { exit(tabID: tabID); return }
    let source = """
      (() => {
        if (window.__openZapBinding !== \(BoostEngineAdapter.json(binding.challenge))) return false;
        \(prefix)
        window.__open.receive({v:1,type:\(BoostEngineAdapter.json(wire.type)),payload:\(wire.payloadJSON)});
        return true;
      })()
      """
    evaluate(source, binding: binding, tabID: tabID)
  }
  private func evaluate(_ source: String, binding: Binding, tabID: ItemID, ending: Bool = false) {
    let previous = binding.work
    binding.work = Task { [weak self] in
      await previous?.value
      guard let self, let host = binding.host, !host.closed,
        host.content.isLive, !host.content.isDiscarded else { return }
      guard ending || self.bindings[tabID] === binding else { return }
      do {
        let result = try await host.content.evaluateJavaScript(source, inWorld: .open)
        if !ending, result as? Bool != true, self.bindings[tabID] === binding { self.exit(tabID: tabID) }
      } catch {
        if !ending, self.bindings[tabID] === binding { self.exit(tabID: tabID) }
      }
    }
  }
}
