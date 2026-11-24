import AppKit
import Foundation
import OpenBoosts
import OpenDesign
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
    var counts: AppBoostPickerList?
    var work: Task<Void, Never>?
    var observers: [any NSObjectProtocol] = []
    var occlusion: [Double] = []
    var occlusionScheduled = false
    /// The page view's own setting, restored when the picker ends.
    var postedFrameChanges: Bool?
    init(host: EngineWebContentHost, boostID: BoostID, mode: PickerMode, store: BoostStore) {
      self.host = host; self.boostID = boostID; self.mode = mode
      coordinator = BoostPickerCoordinator(store: store)
    }
  }
  private var bindings: [ItemID: Binding] = [:]
  init(host: AppBoostEditorHost) { editor = host }

  func isAvailable(tabID: ItemID, boostID: BoostID? = nil) -> Bool {
    guard boosts.canEdit(tabID: tabID), !boosts.app.shutdownPrepared,
      let host = boosts.factory(for: tabID)?.hosts[tabID], host.content.isLive,
      !host.content.isLoading, !host.content.isDiscarded, host.content.crashState == .none else { return false }
    let session = host.owner?.controller?.boostEditor?.session
    if let session, session.context.tabID == tabID, !session.isEditable { return false }
    if let id = boostID ?? (session?.context.tabID == tabID ? session?.boost.id : nil) {
      guard let boost = boosts.store(for: host.profileID).boost(id: id), AppBoostPickerMessage.supports(boost) else { return false }
    }
    return true
  }

  func enter(boostID: BoostID, tabID: ItemID, mode: PickerMode) -> Bool {
    guard isAvailable(tabID: tabID, boostID: boostID), boosts.boostsGloballyEnabled,
      let host = boosts.factory(for: tabID)?.hosts[tabID], let url = host.content.url,
      let boost = boosts.store(for: host.profileID).boost(id: boostID),
      AppBoostPickerMessage.supports(boost) else { return false }
    if let binding = bindings[tabID], binding.host === host, binding.boostID == boostID, binding.mode == mode { return true }
    exit(tabID: tabID)
    let binding = Binding(host: host, boostID: boostID, mode: mode, store: boosts.store(for: host.profileID))
    bindings[tabID] = binding
    // First obtain this document's engine token. A private-world marker guards
    // the later injection if navigation happens between these two requests.
    let challenge = BoostEngineAdapter.json(binding.challenge)
    evaluate("""
      (() => {
        if (!\(BoostEngineAdapter.locationIs(url))) return false;
        if (typeof window.__openZap?.exit === 'function') window.__openZap.exit();
        window.__openZapBinding = \(challenge);
        __openNative.postMessage('picker:document', JSON.stringify({challenge: \(challenge)}));
        return true;
      })()
      """, binding: binding, tabID: tabID)
    return true
  }

  @discardableResult
  func receive(_ page: OEWebContent, type: String, payloadJSON: String, documentID: String) -> Bool {
    guard let (tabID, binding) = bindings.first(where: { $0.value.host?.content === page }),
      let host = binding.host,
      isAvailable(tabID: tabID, boostID: binding.boostID), boosts.boostsGloballyEnabled,
      !documentID.isEmpty, documentID.utf8.count <= 128, !documentID.contains("\0") else { return false }
    if type == "picker:document" {
      guard binding.documentID == nil, payloadJSON.utf8.count <= 128,
        let data = payloadJSON.data(using: .utf8),
        let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String],
        payload == ["challenge": binding.challenge],
        let command = binding.coordinator.enterZap(boostID: binding.boostID, for: documentID, mode: binding.mode),
        case let .enterZap(session) = command else { return false }
      binding.documentID = documentID; binding.session = session
      let install = """
        \(BoostResources.pickerJS)
        window.__open.postMessage = (type, payload) => __openNative.postMessage(type, JSON.stringify(payload));
        """
      send(command, binding: binding, tabID: tabID, prefix: install)
      return true
    }
    guard binding.documentID == documentID, let session = binding.session,
      var message = AppBoostPickerMessage.decode(type: type, payloadJSON: payloadJSON, session: session,
        selectors: boosts.store(for: host.profileID).boost(id: binding.boostID)?.zaps.map(\.selector) ?? []) else { return false }
    if case let .zapListResult(session, entries) = message {
      guard let result = binding.counts?.receive(payloadJSON: payloadJSON, chunk: entries) else { return false }
      switch result {
      case .partial: return true
      case let .complete(complete):
        binding.counts = nil
        message = .zapListResult(session: session, entries: complete)
      }
    }
    let changed = binding.coordinator.handle(message, from: documentID)
    if case .pickerReady = message { binding.ready = true; requestCounts(tabID: tabID); trackOcclusion(tabID: tabID, binding: binding) }
    if case let .revealRequested(_, selector) = message, changed { remove(selector, tabID: tabID) }
    if case .pickerExited = message { exit(tabID: tabID); return true }
    if let event = binding.coordinator.lastEvent { editor.publishPickerEvent(event, tabID: tabID) }
    if changed, let host = binding.host {
      boosts.refresh(profile: host.profileID)
      requestCounts(tabID: tabID)
    }
    return true
  }

  func requestCounts(tabID: ItemID) {
    guard let binding = bindings[tabID], binding.ready, let documentID = binding.documentID,
      let command = binding.coordinator.listZaps(for: documentID),
      case let .listZaps(session, selectors, labels) = command else { return }
    let request = AppBoostPickerList(selectors: selectors)
    // A counts transport problem must never end an otherwise usable picker.
    binding.counts = nil
    guard let commands = request.commands(session: session, selectors: selectors, labels: labels) else { return }
    binding.counts = request
    for payload in commands { send(type: "zap:list", payload: payload, binding: binding, tabID: tabID) }
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
    for observer in binding.observers { NotificationCenter.default.removeObserver(observer) }; binding.observers = []
    if let posted = binding.postedFrameChanges { binding.host?.view.postsFrameChangedNotifications = posted; binding.postedFrameChanges = nil }
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

  /// The Boost editor floats over the page's right edge (Arc centers it on the window's right
  /// edge, interaction-states §20.6). The picker learns which part of the viewport it covers, so
  /// its popup and Done stay clear of it. Measured when the picker is ready and after the browser
  /// window or the editor moves or resizes, or the page view's frame changes inside the window
  /// (sidebar, Split divider, content toolbar); at most once per run-loop turn, and only changes
  /// cross the bridge.
  private func trackOcclusion(tabID: ItemID, binding: Binding) {
    guard binding.observers.isEmpty, let view = binding.host?.view, let window = view.window else { return }
    let center = NotificationCenter.default
    let observe: (Notification.Name, AnyObject) -> Void = { [weak self] name, object in
      binding.observers.append(center.addObserver(forName: name, object: object, queue: .main) { _ in
        MainActor.assumeIsolated { self?.scheduleOcclusion(tabID: tabID) }
      })
    }
    var windows = [window]
    if let panel = binding.host?.owner?.controller?.boostEditor?.panel { windows.append(panel) }
    for observed in windows {
      for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] { observe(name, observed) }
    }
    binding.postedFrameChanges = view.postsFrameChangedNotifications
    view.postsFrameChangedNotifications = true
    observe(NSView.frameDidChangeNotification, view)
    sendOcclusion(tabID: tabID)
  }
  /// One measurement on the next turn, after the window's layout pass has given the page view its
  /// new frame. A drag posts several notifications per frame; they collapse into this one.
  private func scheduleOcclusion(tabID: ItemID) {
    guard let binding = bindings[tabID], !binding.occlusionScheduled else { return }
    binding.occlusionScheduled = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        binding.occlusionScheduled = false
        guard let self, self.bindings[tabID] === binding else { return }
        self.sendOcclusion(tabID: tabID)
      }
    }
  }
  private func sendOcclusion(tabID: ItemID) {
    guard let binding = bindings[tabID], binding.ready, let session = binding.session, let host = binding.host else { return }
    let view = host.view
    var value = [0.0, 0.0, 0.0]
    if let window = view.window, let panel = host.owner?.controller?.boostEditor?.panel, panel.isVisible,
      view.bounds.width > 0, view.bounds.height > 0 {
      let page = window.convertToScreen(view.convert(view.bounds, to: nil))
      let cover = page.intersection(panel.frame)
      // The editor is in its own place when it reaches the page's right edge, or when it sits at its
      // screen margin because the page runs past the screen (Dock, full screen, a window dragged
      // past the edge). An editor left over the middle of a widened window is not reported: plain
      // viewport clamping is the fallback.
      let screenRight = (panel.screen ?? window.screen).map { $0.visibleFrame.maxX - BoostEditorMetrics.screenMargin }
      let anchored = cover.maxX >= page.maxX - 1 || screenRight.map { panel.frame.maxX >= $0 - 1 } == true
      if !cover.isNull, cover.width > 0, cover.height > 0, anchored {
        // Viewport fractions (zoom-independent): a strip at the right edge, top to bottom.
        value = [Double((page.maxX - cover.minX) / page.width), Double((page.maxY - cover.maxY) / page.height),
                 Double((page.maxY - cover.minY) / page.height)]
      }
    }
    guard value != binding.occlusion else { return }
    binding.occlusion = value
    let payload: [String: Any] = ["boostID": session.boostID.description, "sessionNonce": session.sessionNonce,
                                  "right": value[0], "top": value[1], "bottom": value[2]]
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
    send(type: "zap:occlusion", payload: String(decoding: data, as: UTF8.self), binding: binding, tabID: tabID)
  }

  private func send(_ command: PickerOutbound, binding: Binding, tabID: ItemID, prefix: String = "") {
    let wire = BridgeDecode.encode(command)
    send(type: wire.type, payload: wire.payloadJSON, binding: binding, tabID: tabID, prefix: prefix)
  }
  private func send(type: String, payload: String, binding: Binding, tabID: ItemID, prefix: String = "") {
    guard type.utf8.count + payload.utf8.count <= AppBoostPickerList.wireLimit else {
      if type != "zap:list" && type != "zap:occlusion" { exit(tabID: tabID) }
      return
    }
    let source = """
      (() => {
        if (window.__openZapBinding !== \(BoostEngineAdapter.json(binding.challenge))) return false;
        \(prefix)
        window.__open.receive({v:1,type:\(BoostEngineAdapter.json(type)),payload:\(payload)});
        return true;
      })()
      """
    // Counts and the editor's cover are advisory: a failed delivery never ends a usable picker.
    evaluate(source, binding: binding, tabID: tabID, invalidatesOnFailure: type != "zap:list" && type != "zap:occlusion")
  }
  private func evaluate(_ source: String, binding: Binding, tabID: ItemID, ending: Bool = false, invalidatesOnFailure: Bool = true) {
    let previous = binding.work
    binding.work = Task { [weak self] in
      await previous?.value
      guard let self, let host = binding.host, !host.closed,
        host.content.isLive, !host.content.isDiscarded else { return }
      guard ending || self.bindings[tabID] === binding else { return }
      do {
        let result = try await host.content.evaluateJavaScript(source, inWorld: .open)
        if !ending, invalidatesOnFailure, result as? Bool != true, self.bindings[tabID] === binding { self.exit(tabID: tabID) }
      } catch {
        if !ending, invalidatesOnFailure, self.bindings[tabID] === binding { self.exit(tabID: tabID) }
      }
    }
  }
}
