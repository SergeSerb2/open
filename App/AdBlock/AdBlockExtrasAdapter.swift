import Foundation
import OpenAdBlock
import OpenEngine
import OpenModel
import OpenWeb

/// PB2 row 1: the cosmetic rules the engine leaves out (`##+js(...)` scriptlets and
/// `:style()` rules) become document-start user scripts of the Profile's regular contexts.
/// Plain `:has()` hiding needs nothing here; the engine applies it.
///
/// The rules come from the live list generation. They are rebuilt off the main thread when the
/// store publishes a generation, changes the switch or an exclusion, and they are removed when ad
/// blocking is off. Private windows keep the engine's network and hide rules only.
@MainActor
final class AdBlockExtrasAdapter {
  unowned let app: AppDelegate
  private struct Installed {
    weak var context: OEBrowserContext?
    let profile: ProfileID
    var scripts: [UserScript] = []
  }
  private var installed: [ObjectIdentifier: Installed] = [:]
  private var scripts: [ProfileID: [UserScript]] = [:]
  private var builds: [ProfileID: Task<Void, Never>] = [:]
  private var generation: [ProfileID: Int] = [:]
  /// Parsed rules by live file set: an exclusion change does not reparse the lists.
  private var parsed: [ProfileID: (files: [URL], rules: AdBlockExtraRules)] = [:]
  private(set) var buildCount = 0

  init(app: AppDelegate) { self.app = app }

  nonisolated static let idPrefix = "open.adblock.extras."

  func contextCreated(_ context: OEBrowserContext, profileID: ProfileID) {
    guard context.originalContext == nil, !context.isEphemeral else { return }
    let key = ObjectIdentifier(context)
    if installed[key]?.context !== context { installed[key] = Installed(context: context, profile: profileID) }
    apply(profileID)
  }

  /// Rebuild after a store event. The `.enabled` switch has no Profile: rebuild every open one.
  func storeChanged(_ event: AdBlockEngineEvent, store: AdBlockStore?) {
    switch event {
    case let .configure(profile, _, _, _), let .exclusions(profile, _), let .reload(profile, _):
      rebuild(profile, store: store)
    case .enabled:
      for profile in app.model.profiles { rebuild(profile.id, store: store) }
    case let .closed(profile):
      builds.removeValue(forKey: profile)?.cancel()
      parsed[profile] = nil
      scripts[profile] = []
      apply(profile)
    case .privateExclusions:
      break
    }
  }

  private func rebuild(_ profile: ProfileID, store: AdBlockStore?) {
    builds.removeValue(forKey: profile)?.cancel()
    let next = (generation[profile] ?? 0) + 1
    generation[profile] = next
    guard let store, store.isEnabled, store.isProfileOpen(profile), !store.isRetired(profile) else {
      scripts[profile] = []
      apply(profile)
      return
    }
    let excluded = Set(store.excludedDomains(for: profile))
    let cached = parsed[profile]
    builds[profile] = Task { [weak self] in
      let files = await store.liveListFiles(for: profile)
      guard !Task.isCancelled else { return }
      let reuse = cached?.files == files ? cached?.rules : nil
      let work = Task.detached(priority: .utility) { () -> (AdBlockExtraRules, [UserScript]) in
        let rules = reuse ?? AdBlockExtraRules.load(files: files)
        return (rules, Self.scripts(rules.plans(excludedSites: excluded)))
      }
      let (rules, built) = await work.value
      guard let self, !Task.isCancelled, self.generation[profile] == next else { return }
      self.builds[profile] = nil
      self.parsed[profile] = (files, rules)
      self.scripts[profile] = built
      self.buildCount += 1
      self.apply(profile)
    }
  }

  nonisolated static func scripts(_ plans: [AdBlockExtraRules.Plan]) -> [UserScript] {
    var out: [UserScript] = []
    for plan in plans {
      let id = idPrefix + plan.domain
      if let source = plan.scriptletSource {
        // Main world: the scriptlets must replace page globals before page scripts run.
        out.append(UserScript(id: id + ".js", source: source, injectionTime: .documentStart,
          matchPatterns: plan.patterns, mainFrameOnly: false))
      }
      if let css = plan.styleSheet {
        out.append(UserScript(id: id + ".css", source: css, kind: .styleSheet, injectionTime: .documentStart,
          matchPatterns: plan.patterns, mainFrameOnly: false))
      }
      if let source = plan.styleSource {
        out.append(UserScript(id: id + ".style", source: source, injectionTime: .documentStart,
          matchPatterns: plan.patterns, mainFrameOnly: false, world: .open))
      }
    }
    return out
  }

  /// Replaces only this adapter's scripts; one main-actor turn, no suspension.
  private func apply(_ profile: ProfileID) {
    let wanted = scripts[profile] ?? []
    for (key, entry) in installed where entry.profile == profile {
      guard let context = entry.context, context.state == .live else { installed[key] = nil; continue }
      guard entry.scripts != wanted else { continue }
      let web = EngineWebProfile(context)
      for script in entry.scripts { web.removeUserScript(id: script.id) }
      for script in wanted { web.addUserScript(script) }
      installed[key]?.scripts = wanted
    }
  }

  #if OPEN_AUTOMATION
  func snapshot(profile: ProfileID) -> [String: Any] {
    let list = scripts[profile] ?? []
    return [
      "builds": buildCount,
      "pending": builds[profile] != nil,
      "scripts": list.map(\.id).sorted(),
      "installedContexts": installed.values.filter { $0.profile == profile && $0.context != nil && !$0.scripts.isEmpty }.count,
      "skipped": parsed[profile]?.rules.skipped ?? 0,
    ]
  }
  #endif
}
