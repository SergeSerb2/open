import AppKit
import OpenBoosts
import OpenEngine
import OpenModel
import OpenWeb
import OpenFeatures

/// User scripts belong to a Profile, not to a tab. Compile every reachable matcher
/// result at store change, and gate each script by the exact active scope set.
/// This avoids one tab replacing another tab's plan, including after restart.
@MainActor
final class BoostEngineAdapter {
  unowned let boosts: AppBoosts
  private struct Registration {
    weak var context: OEBrowserContext?
    let profile: ProfileID
    var scripts: [UserScript] = []
  }
  private var registrations: [ObjectIdentifier: Registration] = [:]
  private var livePlans: [ObjectIdentifier: String] = [:]
  private var deliveries: [ObjectIdentifier: Task<Void, Never>] = [:]
  private(set) var refreshCount = 0
  private(set) var completedRefreshCount = 0
  private(set) var lastRefreshMilliseconds = 0.0
  private(set) var lastRefreshPageCount = 0
  private(set) var lastRefreshSkippedPageCount = 0
  private(set) var javaScriptDeliveryCount = 0
  private(set) var applyFailureCount = 0
  init(boosts: AppBoosts) { self.boosts = boosts }

  func prepare(_ context: OEBrowserContext, profile: ProfileID) {
    let key = ObjectIdentifier(context)
    guard registrations[key]?.context !== context else { return }
    registrations[key] = Registration(context: context, profile: profile)
    replaceScripts(context, profile: profile)
  }
  func committed(_ host: EngineWebContentHost, url: URL) {
    prepare(host.content.context, profile: host.profileID)
    let plan = plan(url: url, profile: host.profileID, ephemeral: host.content.context.isEphemeral)
    deliver(plan, to: host, url: url)
  }
  func refresh(profile: ProfileID, startedAt start: TimeInterval) {
    for registration in Array(registrations.values) where registration.profile == profile {
      if let context = registration.context { replaceScripts(context, profile: profile) }
    }
    refreshPages(profile: profile, start: start)
  }
  func globalSwitchChanged() {
    let start = ProcessInfo.processInfo.systemUptime
    for registration in Array(registrations.values) {
      if let context = registration.context { replaceScripts(context, profile: registration.profile) }
    }
    refreshPages(profile: nil, start: start)
  }
  private func plan(url: URL, profile: ProfileID, ephemeral: Bool, matcher: BoostMatcher? = nil) -> InjectionPlan {
    guard boosts.app.model.profile(id: profile) != nil,
      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
      return InjectionPlan(planID: "empty", url: url, profileID: profile, boosts: [])
    }
    return BoostInjectionPlanner.plan(url: url, profileID: profile, matcher: matcher ?? boosts.matcher(for: profile),
      boostsGloballyEnabled: boosts.boostsGloballyEnabled, context: ephemeral ? .incognito : .normal)
  }
  func preview(_ boost: Boost, host: EngineWebContentHost) {
    guard boosts.boostsGloballyEnabled, !host.closed, let url = host.content.url else { return }
    var values = boosts.store(for: host.profileID).allBoosts().filter { $0.id != boost.id }
    values.append(BoostStore.normalizedForPreview(boost))
    deliver(plan(url: url, profile: host.profileID, ephemeral: host.content.context.isEphemeral, matcher: BoostMatcher(boosts: values)), to: host, url: url)
  }
  private func refreshPages(profile: ProfileID?, start: TimeInterval) {
    let pages = boosts.app.hostFactories.values.flatMap { Array($0.hosts.values) } + Array(boosts.app.littleOpenHosts.values)
    let hosts = Dictionary(pages.map { (ObjectIdentifier($0), $0) }, uniquingKeysWith: { first, _ in first }).values.filter { profile == nil || $0.profileID == profile }
    lastRefreshPageCount = 0; lastRefreshSkippedPageCount = 0; refreshCount += 1
    let generation = refreshCount
    // Dispatch all page requests in this actor turn; no serial per-tab round trips.
    let tasks = hosts.compactMap { host -> Task<Void, Never>? in
      guard canDeliver(to: host) else {
        closed(host); lastRefreshSkippedPageCount += 1; return nil
      }
      guard let url = host.content.url else { return nil }
      let task = deliver(plan(url: url, profile: host.profileID, ephemeral: host.content.context.isEphemeral), to: host, url: url)
      if task != nil { lastRefreshPageCount += 1 }
      return task
    }
    Task { [weak self] in
      for task in tasks { await task.value }
      guard let self, generation == self.refreshCount else { return }
      self.lastRefreshMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
      self.completedRefreshCount = generation
    }
  }
  private func canDeliver(to host: EngineWebContentHost) -> Bool {
    !host.closed && host.content.isLive && !host.content.isDiscarded
  }
  private func replaceScripts(_ context: OEBrowserContext, profile: ProfileID) {
    let web = EngineWebProfile(context), key = ObjectIdentifier(context)
    let scripts = makeScripts(profile: profile, ephemeral: context.isEphemeral)
    let previous = registrations[key]?.scripts ?? []
    guard previous != scripts else { return }
    // OpenEngine has no batch setter. This synchronous main-actor transaction
    // has no suspension point; only our namespace is replaced.
    for script in previous { web.removeUserScript(id: script.id) }
    // Blocked on P7: isolated world
    for script in scripts { web.addUserScript(script) }
    registrations[key]?.scripts = scripts
  }
  private func makeScripts(profile: ProfileID, ephemeral: Bool) -> [UserScript] {
    guard boosts.boostsGloballyEnabled, boosts.app.model.profile(id: profile) != nil else { return [] }
    let values = boosts.store(for: profile).allBoosts().filter { $0.isEnabled && !$0.siteMatch.domain.isEmpty }
    guard !values.isEmpty else { return [] }
    let matcher = boosts.matcher(for: profile)
    // A matcher changes only at a host boundary or path-prefix boundary. Probe
    // their cross product, including ancestor path rules on a more specific host.
    var plans: [String: InjectionPlan] = [:]
    for domain in Set(values.map { $0.siteMatch.domain }) {
      let host = domain.contains(":") ? "[\(domain)]" : domain
      let paths = Set(values.map { $0.siteMatch.pathPrefix ?? "/" })
      for path in paths {
        guard let url = URL(string: "https://\(host)\(path)") else { continue }
        let p = plan(url: url, profile: profile, ephemeral: ephemeral, matcher: matcher)
        if !p.isEmpty { plans[p.planID] = p }
      }
    }
    let scopes: [[String: Any]] = values.map { ["id": $0.id.description, "domain": $0.siteMatch.domain,
      "path": $0.siteMatch.pathPrefix ?? "", "ip": $0.siteMatch.targetsIPAddress] }
    let scopeJSON = Self.json(scopes)
    var scripts: [UserScript] = []
    for p in plans.values.sorted(by: { $0.planID < $1.planID }) {
      let ids = Self.json(p.boosts.map { $0.boostID.description }.sorted())
      let gate = """
      const u = new URL(location.href), h = u.hostname.toLowerCase().replace(/\\.$/, '').replace(/^\\[|\\]$/g, ''), path = u.pathname || '/';
      if (u.protocol !== 'http:' && u.protocol !== 'https:') return;
      const ids = \(scopeJSON).filter(s => (h === s.domain || (!s.ip && h.endsWith('.' + s.domain))) && (!s.path || path === s.path || path.startsWith(s.path + '/'))).map(s => s.id).sort();
      if (JSON.stringify(ids) !== JSON.stringify(\(ids))) return;
      """
      let patterns = Array(Set(p.boosts.compactMap { resolved -> String? in
        guard let boost = values.first(where: { $0.id == resolved.boostID }) else { return nil }
        let host = boost.siteMatch.domain.contains(":") ? "[\(boost.siteMatch.domain)]" : boost.siteMatch.domain
        return "*://\(boost.siteMatch.targetsIPAddress ? host : "*." + host)/*"
      })).sorted()
      scripts.append(UserScript(id: "open.boosts.applier.\(p.planID)", source: "(() => {\n\(gate)\n\(BoostResources.applierJS)\n\(Self.applySource(p))\n})();", injectionTime: .documentStart, matchPatterns: patterns, mainFrameOnly: true))
      if p.containsJS {
        // Main-world user script, separate from the managed stylesheet runtime.
        scripts.append(UserScript(id: "open.boosts.js.\(p.planID)", source: "(() => {\n\(gate)\n\(p.combinedJS)\n})();", injectionTime: .documentStart, matchPatterns: patterns, mainFrameOnly: true))
      }
    }
    return scripts
  }
  @discardableResult private func deliver(_ plan: InjectionPlan, to host: EngineWebContentHost, url: URL) -> Task<Void, Never>? {
    let key = ObjectIdentifier(host)
    // A discarded page has no renderer. Its Profile scripts are already current;
    // document start and the normal commit hook apply them when it wakes/reloads.
    // Forget the old document, without waking the tab or scheduling a retry.
    guard canDeliver(to: host) else { closed(host); return nil }
    // The unmatched-page fast path creates no runtime, observer, or engine request.
    if plan.isEmpty && livePlans[key] == nil { return nil }
    deliveries[key]?.cancel()
    if plan.isEmpty { livePlans[key] = nil } else { livePlans[key] = plan.planID }
    let source = plan.isEmpty ? "window.__openBoosts?.clear();" : BoostResources.applierJS + "\n" + Self.applySource(plan)
    let task = Task { [weak self, weak host] in
      guard let self, let host, !Task.isCancelled, !self.boosts.app.shutdownPrepared else { return }
      guard self.canDeliver(to: host) else { self.closed(host); return }
      do {
        // Do not deliver an old document's plan into a newly navigated page.
        self.javaScriptDeliveryCount += 1
        _ = try await host.content.evaluateJavaScript("(() => { if (location.href !== \(Self.json(url.absoluteString))) return false; \(source) return true; })()")
      } catch {
        guard !Task.isCancelled, !self.boosts.app.shutdownPrepared else { return }
        let failure = error as NSError
        // Close/discard can race the async engine reply. These are lifecycle
        // events, including OEErrorWebContentClosed, rather than apply failures.
        guard self.canDeliver(to: host),
          !(failure.domain == OEErrorDomain && failure.code == OEError.Code.webContentClosed.rawValue) else {
          self.closed(host); return
        }
        self.applyFailureCount += 1
        host.owner?.controller?.toasts.show(ToastContent(title: plan.isEmpty ? "Could not clear Boosts." : "Could not apply Boosts."))
      }
    }
    deliveries[key] = task
    return task
  }
  private static func applySource(_ plan: InjectionPlan) -> String {
    var live = plan; live.combinedJS = ""; live.containsJS = false
    let wire = BridgeDecode.encode(.applyBoosts(live))
    return "window.__openBoosts.apply(\(wire.payloadJSON));"
  }
  static func json(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }
  func closed(_ host: EngineWebContentHost) {
    let key = ObjectIdentifier(host); deliveries.removeValue(forKey: key)?.cancel(); livePlans[key] = nil
  }
  func stop() {
    for task in deliveries.values { task.cancel() }; deliveries = [:]; livePlans = [:]
    for registration in registrations.values { if let context = registration.context { let web = EngineWebProfile(context); for script in registration.scripts { web.removeUserScript(id: script.id) } } }
    registrations = [:]
  }
}
