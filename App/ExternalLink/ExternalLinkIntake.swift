import AppKit
import Carbon
import OpenModel
import OpenRouting

@MainActor
protocol LinkDestinationExecutor: AnyObject {
  func openInSpace(_ url: URL, spaceID: SpaceID)
  func openInLittleOpen(_ url: URL, profileHint: ProfileID?)
  func bootstrapFirstSpace() -> Bool
}

/// One funnel for both macOS delivery APIs. Clicked URLs stay in the bounded,
/// memory-only RoutingDecisionLog; never print them to the system log.
@MainActor
final class ExternalLinkIntake {
  let decisionLog = RoutingDecisionLog()
  private let evaluator = RoutingEvaluator()
  private let executor: any LinkDestinationExecutor
  private let snapshot: () -> RoutingSnapshot
  private var pending: [RoutingRequest] = []
  private var recent: [String: TimeInterval] = [:]
  private(set) var ready = false
  private(set) var duplicatesDropped = 0
  private(set) var queuedCount = 0
  private(set) var drainedCount = 0
  var pendingCount: Int { pending.count }

  init(executor: any LinkDestinationExecutor, snapshot: @escaping () -> RoutingSnapshot) {
    self.executor = executor; self.snapshot = snapshot
  }

  func handle(urls: [URL], source: RoutingSource) {
    let now = ProcessInfo.processInfo.systemUptime
    recent = recent.filter { now - $0.value < 2 }
    for url in urls {
      let request = RoutingRequest(url: url, source: source)
      guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
        // Rejected schemes never enter the queue or the dedupe table.
        decisionLog.record(evaluator.evaluate(request, in: snapshot()))
        continue
      }
      // canonicalURLString already includes the original percent-encoded query.
      let key = HostNormalizer.canonicalURLString(url) + "|" + (source.bundleID ?? "?")
      if recent[key] != nil { duplicatesDropped += 1; continue }
      recent[key] = now
      if ready { route(request) }
      else { pending.append(request); queuedCount += 1 }
    }
  }

  func markReady() {
    guard !ready else { return }
    ready = true
    let queued = pending; pending.removeAll()
    for request in queued { route(request); drainedCount += 1 }
  }

  private func route(_ request: RoutingRequest, afterBootstrap: Bool = false) {
    // Build inside the loop: executing one queued link changes window order
    // and the most recent Space used to resolve the next queued link.
    let decision = evaluator.evaluate(request, in: snapshot())
    decisionLog.record(decision)
    switch decision.resolved {
    case .space(let id, _): executor.openInSpace(request.url, spaceID: id)
    case .littleOpen(let hint): executor.openInLittleOpen(request.url, profileHint: hint)
    case nil:
      guard case .noSpaces = decision.via else { return }
      // Routing plan §8.7: bootstrap the first Space, then evaluate once more
      // with a fresh snapshot. A second noSpaces opens Little Open with no hint.
      if !afterBootstrap, executor.bootstrapFirstSpace() { route(request, afterBootstrap: true) }
      else {
        AppDelegate.commandLog("External link found no Space after bootstrap; opening Little Open.")
        executor.openInLittleOpen(request.url, profileHint: nil)
      }
    }
  }
}

extension AppDelegate {
  func consumeFirstExternalDestination(opensLittleOpen: Bool) {
    guard !executedExternalLink else { return }
    executedExternalLink = true
    defer { autoCreatedLaunchWindowID = nil }
    // Lead decision (routing §9.7): preserve every restored window. Only the
    // explicitly tagged, still-unused fallback can close for the first link.
    guard opensLittleOpen, let id = autoCreatedLaunchWindowID else { return }
    discardUnusedLaunchWindow(id)
  }
  func completeLinkRestoration() {
    #if OPEN_AUTOMATION
    // Guess (verification fixture): LaunchServices can deliver after a fast
    // launch is ready. Delay only this handoff to exercise a genuinely pending
    // AppleEvent through the same intake, executor and model. No URL injection.
    if ProcessInfo.processInfo.environment["OPEN_AUTOMATION_ROUTING_SLOW_READY"] == "1" {
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.finishExternalLinkRestoration() }
      return
    }
    #endif
    finishExternalLinkRestoration()
  }

  private func finishExternalLinkRestoration() {
    linkIntake.markReady()
    deepLinks.markReady()
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    NSAppleEventManager.shared().setEventHandler(self,
      andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
      forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
  }

  @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
    guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
      let url = URL(string: text), url.scheme != nil else {
      Self.commandLog("Ignored malformed external URL event."); return
    }
    if DeepLinkRouter.matches(url) { deepLinks.handle(url); return }
    linkIntake.handle(urls: [url], source: SourceAppResolver.source(from: event))
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    // AppKit can prefer this newer delegate method for open-document events
    // too. Give local shortcut files the same bounded reader as openFile.
    for url in urls {
      if url.isFileURL, self.application(application, openFile: url.path) { continue }
      if DeepLinkRouter.matches(url) { deepLinks.handle(url); continue }
      linkIntake.handle(urls: [url], source: .unknown)
    }
  }

  func application(_ sender: NSApplication, openFile filename: String) -> Bool {
    var accepted = false
    defer { if !accepted { Self.commandLog("Ignored an unsupported or unreadable external link file.") } }
    let file = URL(fileURLWithPath: filename)
    // A tiny, local .webloc/.url reader, not a document importer. Refuse large
    // files before decoding (at most 64 KiB input; no archive or recursive walk).
    guard ["webloc", "url"].contains(file.pathExtension.lowercased()),
      let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
      values.isRegularFile == true, let size = values.fileSize, size <= 65_536,
      let input = try? FileHandle(forReadingFrom: file) else { return false }
    defer { try? input.close() }
    // Bound the read too: a file can grow between metadata and open.
    guard let data = try? input.read(upToCount: 65_537), data.count <= 65_536 else { return false }
    let text: String?
    if file.pathExtension.lowercased() == "webloc" {
      text = (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])?["URL"] as? String
    } else {
      text = String(data: data, encoding: .utf8)?.components(separatedBy: .newlines)
        .first(where: { $0.hasPrefix("URL=") }).map { String($0.dropFirst(4)) }
    }
    guard let text, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
    linkIntake.handle(urls: [url], source: .unknown); accepted = true; return true
  }
}
