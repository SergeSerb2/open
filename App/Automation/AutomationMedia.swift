#if OPEN_AUTOMATION
import AppKit
import AVFoundation
import MediaPlayer
import OpenDesign
import OpenEngine
import OpenFeatures
import OpenMedia
import OpenModel
import OpenSidebar
import OpenSleep
import OpenWeb

/// Media automation commands (media-pip §8.4, docs/automation.md "Media").
extension AutomationController {
  static let mediaCommands: Set<String> = ["media", "media-action", "mini-players", "media-click", "pip", "pip-action", "pip-frame",
                                           "now-playing", "sleep-visibility", "library-section", "capture-permission"]

  func runMediaCommand(_ cmd: String, _ a: [String: Any]) async throws -> Any {
    let media = app.media
    switch cmd {
    case "media":
      let tab = try mediaTab(a)
      return describeMedia(tab)
    case "media-action":
      if let all = a["action"] as? String, all == "mute-all" || all == "unmute-all" {
        // The command bar's Mute All Tabs / Unmute All Tabs run through this same App command dispatch.
        guard let factory = app.frontWindowController.flatMap({ app.hostFactories[$0.windowID] }) else { throw Failure(message: "no window") }
        return factory.performAppCommand(all == "mute-all" ? "mute-all-tabs" : "unmute-all-tabs")
      }
      let tab = try mediaTab(a)
      let id = tab.id
      let value = a["value"] as? Double ?? 0
      switch a["action"] as? String ?? "" {
      case "play": return media.perform(.play(id))
      case "pause": return media.perform(.pause(id))
      case "next": return media.perform(.nextTrack(id))
      case "previous": return media.perform(.previousTrack(id))
      case "toggle-mute": return media.perform(.toggleMute(id))
      case "close": return media.perform(.close(id))
      case "back-to-tab": return media.perform(.backToTab(id))
      case "pip": return media.perform(.openPictureInPicture(id))
      case "seek":
        guard let session = media.page(id)?.mediaSession else { throw Failure(message: "no media session") }
        session.seek(to: value); return true
      case "volume": return media.perform(.setVolume(id, value))
      case "exit-pip":
        guard let page = media.page(id) else { throw Failure(message: "no page") }
        page.exitPictureInPicture(pausing: a["pause"] as? Bool ?? false); return true
      default: throw Failure(message: "unknown media action")
      }
    case "mini-players":
      let controller = try mediaController(a)
      controller.contentView.layoutSubtreeIfNeeded()
      let view = controller.sidebar.mediaControls
      return [
        "window": controller.windowID.description, "expanded": view.isExpanded, "stackHeight": view.stackHeight,
        "frame": rect(view.convert(view.bounds, to: nil), in: controller.window),
        "displayed": controller.context.displayedTabIDs.map(\.description).sorted(),
        "pendingCollapse": view.pendingCollapseCount,
        // D-11: nothing animates while the stack rests (layer animation keys in the whole subtree).
        "animations": animationKeyCount(view),
        "cards": view.cards.map { describeCard($0, window: controller.window) },
      ] as [String: Any]
    case "media-click":
      let controller = try mediaController(a)
      guard let window = controller.window, let factory = app.hostFactories[controller.windowID] else { throw Failure(message: "no window") }
      let tabID = try mediaTab(a).id
      controller.contentView.layoutSubtreeIfNeeded()
      guard let card = controller.sidebar.mediaControls.cards.first(where: { $0.source.tabID == tabID }) else {
        throw Failure(message: "no mini player for the tab")
      }
      let target = a["target"] as? String ?? "play"
      let names = ["title": "media.titleRow", "play": "play", "next": "next", "previous": "previous", "volume": "volume",
                   "pip": "pip", "close": "close", "favicon": "favicon", "microphone": "microphone", "camera": "camera",
                   "volumeLow": "volumeLow", "volumeHigh": "volumeHigh", "slider": "media.volumeSlider"]
      guard let name = names[target] else { throw Failure(message: "unknown media-click target") }
      func control() -> NSView? {
        name.hasPrefix("media.") ? card.firstDescendant(identifier: name) : card.control(named: name)?.view
      }
      // Title-row controls show only while the stack is expanded: hover the card first, as a pointer would.
      // The volume drawer opens only on an expanded card (a pointer over the card expands it).
      if ["title", "pip", "close", "volume", "volumeLow", "volumeHigh", "slider"].contains(target) && !card.isExpanded {
        let center = point(of: card, in: window)
        // A pointer that comes from elsewhere, as a real one does: an earlier hover may have left the stack
        // "entered" (the card collapsed under it since, for example when a PiP window took over), and a
        // hover at the same place then delivers no new mouseEntered.
        _ = try await mouse(["action": "hover", "x": Double(window.frame.width) - 20, "y": Double(window.frame.height) / 2,
                             "window": window.windowNumber], factory)
        _ = try await mouse(["action": "hover", "x": center.x, "y": center.y, "window": window.windowNumber], factory)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !card.isExpanded || card.layer?.animationKeys()?.isEmpty == false || control()?.isHiddenOrHasHiddenAncestor != false {
          guard ContinuousClock.now < deadline else { throw Failure(message: "mini player did not expand") }
          try await Task.sleep(for: .milliseconds(10)); controller.contentView.layoutSubtreeIfNeeded()
        }
      }
      guard let view = control(), !view.isHiddenOrHasHiddenAncestor else { throw Failure(message: "control \(target) is not shown") }
      if target == "slider" {
        // A press and release at `fraction` of the knob's travel, as a pointer click on the track.
        let fraction = min(1, max(0, a["fraction"] as? Double ?? 0.5))
        let frame = view.convert(view.bounds, to: nil), knob = MiniPlayerMetrics.drawerKnob
        let x = frame.minX + knob / 2 + CGFloat(fraction) * max(0, frame.width - knob)
        let y = window.frame.height - frame.midY
        for action in ["down", "up"] {
          _ = try await mouse(["action": action, "x": Double(x), "y": Double(y), "window": window.windowNumber], factory)
        }
        return ["clicked": target, "at": [Double(x), Double(y)], "value": view.accessibilityValue() as? String ?? ""]
      }
      let center = point(of: view, in: window)
      _ = try await mouse(["action": "click", "x": center.x, "y": center.y, "window": window.windowNumber], factory)
      return ["clicked": target, "at": [center.x, center.y]]
    case "pip":
      return describePiP()
    case "capture-permission":
      // macOS camera and microphone authorization for this app. Reading it never prompts. Chromium
      // asks macOS while the status is notDetermined even for fake devices
      // (permission_bubble_media_access_handler.cc), so a suite checks this before it captures.
      func name(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "notDetermined"
        @unknown default: "unknown"
        }
      }
      return ["camera": name(AVCaptureDevice.authorizationStatus(for: .video)),
              "microphone": name(AVCaptureDevice.authorizationStatus(for: .audio))]
    case "pip-frame":
      // Phase 2: the engine's composited picture of Open's PiP video view (not the screen; the
      // window server leaves out GPU-process layers on macOS 26).
      guard let pip = media.pipHost?.pip else { throw Failure(message: "no Open PiP window") }
      let path = a["path"] as? String ?? NSTemporaryDirectory() + "open-pip-frame.png"
      let png: Data? = await withCheckedContinuation { continuation in
        pip.captureVideoFrame { continuation.resume(returning: $0) }
      }
      guard let png else { throw Failure(message: "no frame") }
      try png.write(to: URL(fileURLWithPath: path))
      return ["path": path, "bytes": png.count]
    case "pip-action":
      // Phase 2: Open's own window, through its real controls' paths.
      if let window = media.pipWindow {
        switch a["action"] as? String ?? "" {
        case "close": window.dismiss(reason: .userClosed); return true
        case "minimize": window.dismiss(reason: .minimized); return true
        case "back-to-tab": window.dismiss(reason: .backToTab); return true
        case "menu":
          let menu = window.menuBuilder.build()
          guard let title = a["item"] as? String else {
            return menu.items.map { $0.isSeparatorItem ? "-" : $0.title + ($0.state == .on ? " ✓" : "") }
          }
          guard let index = menu.items.firstIndex(where: { $0.title == title }), menu.items[index].isEnabled else {
            throw Failure(message: "no enabled PiP menu item \(title)")
          }
          menu.performActionForItem(at: index); return true
        default: throw Failure(message: "unknown pip action")
        }
      }
      // EM-7: the Document PiP panel's close button path.
      if let document = media.documentPiP, a["action"] as? String == "close" { document.close(); return true }
      // Phase 1 has Chromium's own PiP window; these run the same session paths its controls end in.
      guard let source = media.session.activeSource else { throw Failure(message: "no active PiP") }
      switch a["action"] as? String ?? "" {
      case "close":
        media.page(source.tabID)?.exitPictureInPicture(pausing: true); return true
      case "back-to-tab": return media.backToTab(source.tabID)
      default: throw Failure(message: "unknown pip action (phase 1: close, back-to-tab)")
      }
    case "now-playing":
      let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
      let center = MPRemoteCommandCenter.shared()
      let state: String
      switch MPNowPlayingInfoCenter.default().playbackState {
      case .playing: state = "playing"
      case .paused: state = "paused"
      case .stopped: state = "stopped"
      case .interrupted: state = "interrupted"
      default: state = "unknown"
      }
      return [
        "title": info[MPMediaItemPropertyTitle] as? String ?? NSNull(),
        "artist": info[MPMediaItemPropertyArtist] as? String ?? NSNull(),
        "rate": info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? NSNull(),
        "elapsed": info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? NSNull(),
        "playbackState": state,
        "commands": ["play": center.playCommand.isEnabled, "pause": center.pauseCommand.isEnabled,
                     "toggle": center.togglePlayPauseCommand.isEnabled, "next": center.nextTrackCommand.isEnabled,
                     "previous": center.previousTrackCommand.isEnabled],
      ] as [String: Any]
    case "library-section":
      // View Media (Window menu) opens the Library at its Media section.
      let presenter = app.settingsPresenter
      return ["visible": presenter.libraryPresenter?.window?.isVisible == true,
              "section": presenter.library.map { "\($0.section)" } ?? NSNull()] as [String: Any]
    case "sleep-visibility":
      media.feedSleep()
      let snapshot = media.visibility.sleepVisibility()
      return [
        "pictureInPicture": snapshot.pictureInPicture.map(\.description).sorted(),
        "mediaControls": snapshot.mediaControls.map(\.description).sorted(),
        "visible": snapshot.visibleTabIDs(in: app.model).map(\.description).sorted(),
        "windows": Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.key.description, String(describing: $0.value)) }),
      ] as [String: Any]
    default:
      throw Failure(message: "unknown media command")
    }
  }

  private func animationKeyCount(_ view: NSView) -> Int {
    func count(_ layer: CALayer) -> Int {
      (layer.animationKeys()?.count ?? 0) + (layer.sublayers ?? []).reduce(0) { $0 + count($1) }
    }
    return view.layer.map(count) ?? 0
  }

  private func mediaTab(_ a: [String: Any]) throws -> Tab {
    guard let s = a["tab"] as? String, let uuid = UUID(uuidString: s), let tab = app.model.tab(id: ItemID(rawValue: uuid)) else {
      throw Failure(message: "missing or unknown tab")
    }
    return tab
  }

  private func mediaController(_ a: [String: Any]) throws -> BrowserWindowController {
    if let id = a["window"] as? String {
      guard let c = app.windowControllers.first(where: { $0.windowID.description == id }) else { throw Failure(message: "unknown window") }
      return c
    }
    guard let c = app.frontWindowController else { throw Failure(message: "no window") }
    return c
  }

  /// Window coordinates with a top-left origin, as `mouse` takes them.
  private func point(of view: NSView, in window: NSWindow) -> (x: Double, y: Double) {
    let r = view.convert(view.bounds, to: nil)
    return (Double(r.midX), Double(window.frame.height - r.midY))
  }

  private func rect(_ r: CGRect, in window: NSWindow?) -> [Double] {
    let h = window?.frame.height ?? 0
    return [Double(r.minX), Double(h - r.maxY), Double(r.width), Double(r.height)]
  }

  private func describeCard(_ card: MiniPlayerCardView, window: NSWindow?) -> [String: Any] {
    let s = card.source
    var buttons: [String: Any] = [:]
    for name in ["favicon", "previous", "play", "next", "volume", "pip", "close", "microphone", "camera", "volumeLow", "volumeHigh"] {
      guard let c = card.control(named: name), !c.view.isHiddenOrHasHiddenAncestor else { continue }
      buttons[name] = ["frame": rect(c.view.convert(c.view.bounds, to: nil), in: window),
                       "tooltip": c.tooltip.map { String(describing: $0) } ?? "",
                       "enabled": (c.view as? NSControl)?.isEnabled ?? true]
    }
    return [
      "tab": s.tabID?.description ?? "", "kind": s.kind == .recording ? "recording" : "audioVideo",
      "playback": "\(s.playback)", "hasVideo": s.hasVideo, "muted": s.isMuted, "pip": "\(s.pip)",
      "expanded": card.isExpanded, "level": card.level, "retiring": card.isRetiring,
      "frame": rect(card.convert(card.bounds, to: nil), in: window), "buttons": buttons,
      "title": card.titleState.drawnText, "accessibility": card.accessibilityLabel() ?? "",
      "drawerOpen": card.drawerIsOpen, "height": card.frame.height,
      "slider": card.firstDescendant(identifier: "media.volumeSlider").flatMap { $0.isHiddenOrHasHiddenAncestor ? nil : $0.accessibilityValue() as? String } ?? NSNull(),
      "volume": s.volume ?? NSNull(), "microphoneOn": s.microphoneOn ?? NSNull(), "cameraOn": s.cameraOn ?? NSNull(),
    ]
  }

  private func describeMedia(_ tab: Tab) -> [String: Any] {
    let media = app.media
    let page = media.page(tab.id)
    let session = page?.mediaSession
    let state = MediaCoordinator.state(session)
    var actions: [String] = []
    let names: [(WebMediaActions, String)] = [(.play, "play"), (.pause, "pause"), (.previousTrack, "previousTrack"),
      (.nextTrack, "nextTrack"), (.seekBackward, "seekBackward"), (.seekForward, "seekForward"), (.seekTo, "seekTo"),
      (.skipAd, "skipAd"), (.stop, "stop"), (.enterPictureInPicture, "enterPictureInPicture"),
      (.exitPictureInPicture, "exitPictureInPicture"), (.enterAutoPictureInPicture, "enterAutoPictureInPicture"),
      (.toggleMicrophone, "toggleMicrophone"), (.toggleCamera, "toggleCamera"), (.hangUp, "hangUp")]
    for (bit, name) in names where state.actions.contains(bit) { actions.append(name) }
    let source = media.store.sources[tab.id]
    let decision = media.decisions[tab.id]
    return [
      "tab": tab.id.description, "live": page != nil, "session": session != nil,
      "playback": "\(state.playback)", "controllable": state.isControllable, "hasVideo": state.hasVideo,
      "hasAudio": session?.hasAudio ?? false, "largestVideoArea": state.largestVideoArea,
      "pictureInPicture": state.isPictureInPicture, "pictureInPictureDisabled": session?.isPictureInPictureDisabled ?? false,
      "actions": actions, "title": session?.title ?? NSNull(), "artist": session?.artist ?? NSNull(),
      "album": session?.album ?? NSNull(),
      "duration": session?.position.map { $0.duration.isFinite ? $0.duration : -1 } ?? NSNull(),
      "position": session?.position?.position ?? NSNull(),
      "audible": page?.isAudible ?? false, "muted": page?.isMuted ?? false, "modelMuted": tab.isMuted,
      "volume": state.volume ?? NSNull(), "pageVolume": page?.mediaVolume ?? NSNull(),
      "capturing": (page?.isCapturingCamera ?? false) || (page?.isCapturingMicrophone ?? false),
      "source": source.map { s in ["kind": s.kind == .recording ? "recording" : "audioVideo", "playback": "\(s.playback)",
                                   "window": s.windowID.description, "pip": "\(s.pip)"] as [String: Any] } ?? NSNull(),
      "decision": decision.map { ["value": "\($0.decision)", "at": $0.at] as [String: Any] } ?? NSNull(),
    ]
  }

  private func describePiP() -> [String: Any] {
    let media = app.media
    var state: [String: Any] = ["state": "idle"]
    switch media.session.state {
    case .idle: break
    case let .requesting(id, auto): state = ["state": "requesting", "tab": id.description, "automatic": auto]
    case let .active(id, auto): state = ["state": "active", "tab": id.description, "automatic": auto]
    case let .minimized(id): state = ["state": "minimized", "tab": id.description]
    case let .closed(id, reason): state = ["state": "closed", "tab": id.description, "reason": "\(reason)"]
    }
    // Phase 1: Chromium's own frameless PiP window lives in this process.
    let ours = Set(app.windowControllers.compactMap { $0.window.map(ObjectIdentifier.init) })
    let windows = NSApp.windows.filter { w in NSStringFromClass(type(of: w)).contains("NativeWidgetMac") && w.isVisible
      && !ours.contains(ObjectIdentifier(w)) }
    state["windows"] = windows.map { w in
      ["number": w.windowNumber, "class": NSStringFromClass(type(of: w)), "frame": [w.frame.minX, w.frame.minY, w.frame.width, w.frame.height],
       "level": w.level.rawValue] as [String: Any]
    }
    if let window = media.pipWindow?.window {
      state["openWindow"] = ["number": window.windowNumber, "frame": [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height],
                             "level": window.level.rawValue, "visible": window.isVisible, "closing": media.pipWindow?.isClosing ?? false,
                             "tab": media.pipHost?.tabID.description ?? ""] as [String: Any]
    }
    // EM-7: the Document PiP panel (its top bar and the PiP page's view).
    if let document = media.documentPiP, let controller = document.window, let window = controller.window {
      let page = document.pip.videoView
      state["documentWindow"] = ["number": window.windowNumber, "frame": [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height],
                                 "level": window.level.rawValue, "visible": window.isVisible, "tab": document.openerTabID.description,
                                 "class": NSStringFromClass(type(of: window)), "topBarHeight": controller.topBar.frame.height,
                                 "pageSize": [page.frame.width, page.frame.height], "pageInWindow": page.window === window,
                                 "requested": [document.pip.naturalSize.width, document.pip.naturalSize.height],
                                 "valid": document.pip.webContent != nil] as [String: Any]
    }
    state["phase"] = media.hostsPictureInPicture ? 2 : 1
    state["snoozed"] = media.session.snoozed.map(\.description).sorted()
    state["requests"] = media.pipRequests
    if let tab = media.session.activeSource?.tabID ?? {
      if case let .closed(id, _) = media.session.state { return id }; return nil }(), let t = media.pipTimes[tab] {
      state["requestedAt"] = t.requested; state["enteredAt"] = t.entered ?? NSNull()
    }
    state["now"] = ProcessInfo.processInfo.systemUptime
    return state
  }
}

private extension NSView {
  func firstDescendant(identifier: String) -> NSView? {
    if self.identifier?.rawValue == identifier { return self }
    for child in subviews { if let match = child.firstDescendant(identifier: identifier) { return match } }
    return nil
  }
}
#endif
