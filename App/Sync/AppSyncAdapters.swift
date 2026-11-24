import AppKit
import Foundation
import OpenAdBlock
import OpenBoosts
import OpenCommands
import OpenDocuments
import OpenEasel
import OpenEngine
import OpenLiveData
import OpenModel
import OpenStore
import OpenSync

/// Part of a local bundle. Sendable so file scans and hashing can run off the main actor.
struct SyncBundlePart: Sendable {
  var records: [SyncLocalRecord] = []
  var blobs: [SyncLocalBlob] = []
  var complete: Set<SyncCollection> = []
  var warnings: [String] = []

  mutating func merge(_ other: SyncBundlePart) {
    records += other.records; blobs += other.blobs
    complete.formUnion(other.complete); warnings += other.warnings
  }
}

/// The App's `SyncDataAdapter`: reads every synced collection from the live stores and installs
/// remote records into them. Called only by `SyncEngine`, on the main actor.
@MainActor
final class AppSyncDataAdapter: SyncDataAdapter {
  unowned let app: AppDelegate
  weak var coordinator: AppSyncCoordinator?

  init(app: AppDelegate) { self.app = app }

  // MARK: Collect

  func collectLocalData(categories: SyncCategorySettings, blobHasher: SyncBlobHasher) async throws -> SyncLocalBundle {
    guard app.model != nil, app.directories != nil else { throw SyncError.noDataAdapter }
    var part = SyncBundlePart()
    part.merge(try collectWorkspace(categories))
    if categories.isEnabled(.archive) { part.merge(try await collectArchive()) }
    if categories.isEnabled(.settingsAndShortcuts) {
      part.merge(try collectPreferences())
      part.merge(collectKeyBindings())
    }
    if categories.isEnabled(.adBlocking) { part.merge(await collectAdBlock()) }
    if categories.isEnabled(.boostsEaselsNotes) {
      part.merge(try collectBoosts())
      part.merge(await collectEasels(blobHasher))
      part.merge(await collectNotes(blobHasher))
    }
    if categories.isEnabled(.history) { part.merge(try await collectHistory()) }
    if categories.isEnabled(.extensions) { part.merge(try collectExtensions()) }
    if categories.isEnabled(.credentialsAndPermissions) {
      part.merge(await collectSitePermissions())
      part.merge(await collectCredentials())
    }
    // One blob per ID: an image used by two documents uploads once.
    var seen = Set<String>()
    let blobs = part.blobs.filter { seen.insert($0.blobId).inserted }
    return SyncLocalBundle(records: part.records, blobs: blobs, completeCollections: part.complete, warnings: part.warnings)
  }

  private var profiles: [Profile] { app.model?.profiles ?? [] }

  private func collectWorkspace(_ categories: SyncCategorySettings) throws -> SyncBundlePart {
    guard categories.isEnabled(.workspace) || categories.isEnabled(.todayTabs), let model = app.model else { return SyncBundlePart() }
    // The front standard window of the main model (a Blank Window's model has its own windows).
    let front = app.frontStandardWindowController.flatMap { controller in model.windows.first { $0.id == controller.windowID } }
    let layout = front ?? model.windows.first { $0.style == .standard } ?? model.windows.first
    let result = try SyncWorkspaceCodec.localRecords(from: model, categories: categories, layoutWindow: layout)
    return SyncBundlePart(records: result.records, complete: result.complete)
  }

  private func collectArchive() async throws -> SyncBundlePart {
    var part = SyncBundlePart()
    for profile in profiles {
      let store = app.archiveSink.store(for: profile.id)
      let rows = await store.recent(limit: SyncLimits.maxArchiveRecordsPerProfile)
      let dto = SyncedArchiveProfileDTO(profileID: profile.id.rawValue, records: rows.map(SyncedArchivedTabRecord.init))
      part.records.append(try SyncLocalRecord(collection: .archiveProfile, recordId: profile.id.rawValue.uuidString, value: dto))
    }
    part.complete.insert(.archiveProfile)
    return part
  }

  /// Portable `open.*` values the user set (the persistent domain only: registered defaults and
  /// launch arguments never sync).
  static func portablePreferences() -> [String: SyncPreferenceValue] {
    let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) } ?? [:]
    var values: [String: SyncPreferenceValue] = [:]
    for (key, value) in domain where SyncedPreferencesDTO.isPortable(key) {
      if let converted = SyncPreferenceValue(userDefaultsValue: value) { values[key] = converted }
    }
    return values
  }

  private func collectPreferences() throws -> SyncBundlePart {
    let values = Self.portablePreferences()
    coordinator?.lastPortablePreferences = values
    let record = try SyncLocalRecord(collection: .settingsPreferences, recordId: "global", value: SyncedPreferencesDTO(values: values))
    return SyncBundlePart(records: [record], complete: [.settingsPreferences])
  }

  private var keyBindingsFile: URL { app.options.userDataDirectory.appendingPathComponent("State/keybindings.json") }

  private func collectKeyBindings() -> SyncBundlePart {
    let file = keyBindingsFile
    do {
      var store = KeyBindingStore.empty
      if FileManager.default.fileExists(atPath: file.path) { store = try KeyBindingStore.load(from: file) }
      let record = try SyncLocalRecord(collection: .settingsKeybindings, recordId: "global", value: SyncedKeyBindingsDTO(store: store))
      return SyncBundlePart(records: [record], complete: [.settingsKeybindings])
    } catch {
      // Never push an empty set over the cloud copy because the local file is damaged.
      return SyncBundlePart(warnings: ["Keyboard shortcuts were not synced: the shortcuts file could not be read."])
    }
  }

  /// The ad-block store, prepared on a worker when it does not exist yet.
  private func adBlockStore() async -> AdBlockStore? {
    if let store = app.stores.existingAdBlock { return store }
    return await app.stores.adBlockForFreshProfile()
  }

  private func openAdBlockProfile(_ store: AdBlockStore, _ profile: Profile) async -> Bool {
    if store.isProfileOpen(profile.id) { return true }
    guard !store.isRetired(profile.id) else { return false }
    do {
      try await store.openProfile(profile.id, directory: app.directories.adBlockDirectory(for: profile),
                                  scheduleUpdates: app.adBlockEngineAdapter.isSupported)
      return store.isProfileOpen(profile.id)
    } catch { return false }
  }

  private func collectAdBlock() async -> SyncBundlePart {
    guard let store = await adBlockStore() else {
      return SyncBundlePart(warnings: ["Ad blocking settings were not synced: the ad-block store could not be opened."])
    }
    var profilesDTO: [String: SyncedAdBlockProfile] = [:]
    var warnings: [String] = []
    var allOpened = true
    for profile in profiles {
      guard await openAdBlockProfile(store, profile) else {
        allOpened = false
        warnings.append("Ad blocking settings of the Profile “\(profile.name)” were not synced."); continue
      }
      profilesDTO[profile.id.rawValue.uuidString] = SyncedAdBlockProfile(
        enabledListIDs: store.enabledListIDs(for: profile.id), excludedDomains: store.excludedDomains(for: profile.id))
    }
    // One record holds every Profile: a partial read would drop the others' settings everywhere.
    guard allOpened else { return SyncBundlePart(warnings: warnings) }
    do {
      let record = try SyncLocalRecord(collection: .adblockConfig, recordId: "global",
                                       value: SyncedAdBlockConfigDTO(globalEnabled: store.isEnabled, profiles: profilesDTO))
      return SyncBundlePart(records: [record], complete: [.adblockConfig], warnings: warnings)
    } catch {
      return SyncBundlePart(warnings: warnings + ["Ad blocking settings were not synced: \(error.localizedDescription)"])
    }
  }

  private func collectBoosts() throws -> SyncBundlePart {
    var part = SyncBundlePart()
    let boosts = app.stores.boosts
    var complete = true
    for profile in profiles {
      // A skipped Profile's Boosts must not become tombstones on other Macs.
      guard !boosts.isRetired(profile.id) else { complete = false; continue }
      for boost in boosts.store(for: profile.id).allBoosts() {
        let dto = SyncedBoostDTO(profileID: profile.id.rawValue, boost: boost)
        part.records.append(try SyncLocalRecord(collection: .boostItem, recordId: dto.recordID, value: dto))
      }
    }
    if complete { part.complete.insert(.boostItem) }
    return part
  }

  private func collectEasels(_ hasher: SyncBlobHasher) async -> SyncBundlePart {
    // Unsaved canvas edits first, so the files hold what the user sees.
    if app.hasEaselStore { app.easels.flush(wait: true) }
    let root = app.directories.root
    return await Task.detached(priority: .utility) { Self.scanEasels(root: root, hasher: hasher) }.value
  }

  private func collectNotes(_ hasher: SyncBlobHasher) async -> SyncBundlePart {
    if app.notes.hasPendingWrites { app.notes.flush() }
    let root = app.directories.root
    return await Task.detached(priority: .utility) { Self.scanNotes(root: root, hasher: hasher) }.value
  }

  private nonisolated static func documentDecoder() -> JSONDecoder {
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
  }

  private nonisolated static func fileSize(_ url: URL) -> Int? {
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { return nil }
    return values.fileSize
  }

  /// Reads one asset file for upload: regular, at most 20 MiB.
  private nonisolated static func assetData(_ url: URL) -> Data? {
    guard let size = fileSize(url), size <= SyncLimits.maxBlobBytes else { return nil }
    return try? Data(contentsOf: url)
  }

  nonisolated static func scanEasels(root: URL, hasher: SyncBlobHasher) -> SyncBundlePart {
    let fm = FileManager.default
    let directory = root.appendingPathComponent("Easels", isDirectory: true)
    var part = SyncBundlePart()
    guard fm.fileExists(atPath: directory.path) else { part.complete.insert(.easelDocument); return part }
    guard let folders = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
      part.warnings.append("Easels were not synced: the Easels folder could not be read."); return part
    }
    let decoder = documentDecoder()
    var complete = true
    for folder in folders.prefix(10_000) {
      guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
      let file = folder.appendingPathComponent("document.json")
      guard fm.fileExists(atPath: file.path) else { continue }
      guard let size = fileSize(file), size <= EaselDocument.maxFileBytes, let data = try? Data(contentsOf: file),
            let doc = try? decoder.decode(EaselDocument.self, from: data), doc.id == id, doc.isValid else {
        // Never let an unreadable Easel become a deletion on other Macs.
        complete = false
        part.warnings.append("An Easel could not be read and was not synced."); continue
      }
      let images = folder.appendingPathComponent("images", isDirectory: true)
      var assets: [SyncedAssetRef] = []
      for name in Set(doc.objects.flatMap { $0.content.imageFiles }).sorted() where EaselDocument.isImageFileName(name) {
        guard let bytes = assetData(images.appendingPathComponent(name)) else {
          if fm.fileExists(atPath: images.appendingPathComponent(name).path) { part.warnings.append("An Easel picture over 20 MB was not synced.") }
          continue
        }
        let asset = hasher.asset(filename: name, data: bytes)
        assets.append(asset.ref); part.blobs.append(asset.blob)
      }
      do {
        part.records.append(try SyncLocalRecord(collection: .easelDocument, recordId: id.uuidString.lowercased(),
                                                value: SyncedEaselDTO(document: doc, assets: assets)))
      } catch { complete = false; part.warnings.append("An Easel could not be prepared for sync.") }
    }
    if complete { part.complete.insert(.easelDocument) }
    return part
  }

  private nonisolated static func isNoteAssetName(_ name: String) -> Bool {
    name.range(of: #"^[0-9a-f]{64}\.(png|jpg|jpeg|gif|heic|tiff|webp)$"#, options: .regularExpression) != nil
  }

  nonisolated static func scanNotes(root: URL, hasher: SyncBlobHasher) -> SyncBundlePart {
    let fm = FileManager.default
    let directory = root.appendingPathComponent("Notes", isDirectory: true)
    var part = SyncBundlePart()
    guard fm.fileExists(atPath: directory.path) else { part.complete.insert(.noteDocument); return part }
    guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
      part.warnings.append("Notes were not synced: the Notes folder could not be read."); return part
    }
    let decoder = documentDecoder()
    var complete = true
    for file in files.prefix(20_000) where file.pathExtension == "json" {
      guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
      guard let size = fileSize(file), size <= NoteStore.maxFileBytes, let data = try? Data(contentsOf: file),
            let note = try? decoder.decode(NoteDocument.self, from: data), note.id == id else {
        complete = false
        part.warnings.append("A Note could not be read and was not synced."); continue
      }
      let assetsFolder = directory.appendingPathComponent(id.uuidString.lowercased() + ".assets", isDirectory: true)
      var assets: [SyncedAssetRef] = []
      if let names = try? fm.contentsOfDirectory(atPath: assetsFolder.path) {
        for name in names.sorted() where isNoteAssetName(name) {
          guard let bytes = assetData(assetsFolder.appendingPathComponent(name)) else {
            part.warnings.append("A Note image over 20 MB was not synced."); continue
          }
          let asset = hasher.asset(filename: name, data: bytes)
          assets.append(asset.ref); part.blobs.append(asset.blob)
        }
      }
      do {
        part.records.append(try SyncLocalRecord(collection: .noteDocument, recordId: id.uuidString.lowercased(),
                                                value: SyncedNoteDTO(document: note, assets: assets)))
      } catch { complete = false; part.warnings.append("A Note could not be prepared for sync.") }
    }
    if complete { part.complete.insert(.noteDocument) }
    return part
  }

  private func collectHistory() async throws -> SyncBundlePart {
    var part = SyncBundlePart()
    var complete = true
    for profile in profiles {
      guard let store = app.stores.history(for: profile.id) else { complete = false; continue }
      var entries: [SyncedHistoryEntry] = []
      // HistoryStore.recent returns at most 1,000 rows per call.
      while entries.count < SyncLimits.maxHistoryEntriesPerProfile {
        let page = await store.recent(limit: 1_000, offset: entries.count)
        entries += page.map {
          SyncedHistoryEntry(url: $0.url.absoluteString, title: $0.title, lastVisitedAt: $0.lastVisit.timeIntervalSince1970,
                             visitCount: $0.visitCount, typedCount: $0.typedCount)
        }
        if page.count < 1_000 { break }
      }
      let dto = SyncedHistoryProfileDTO(profileID: profile.id.rawValue, entries: entries)
      part.records.append(try SyncLocalRecord(collection: .historyProfile, recordId: profile.id.rawValue.uuidString, value: dto))
    }
    if complete { part.complete.insert(.historyProfile) }
    return part
  }

  // MARK: Engine contexts

  /// The Profile's live engine context if one exists; never creates one.
  func existingContext(for profile: Profile) -> OEBrowserContext? {
    guard app.engineReady, !app.shutdownPrepared else { return nil }
    let context: OEBrowserContext? = profile.id == app.model.defaultProfile?.id
      ? OEEngine.shared.defaultContext
      : OEEngine.shared.contexts.first(where: { $0.identifier == profile.dataDirectoryName })
    guard let context, context.state == .live, !context.isEphemeral else { return nil }
    return context
  }

  /// The Profile's regular context through the normal creation path (no window needed).
  func liveContext(for profile: Profile) -> OEBrowserContext? {
    guard app.engineReady, !app.shutdownPrepared, !app.terminationRequested else { return nil }
    return EngineWebContentHostFactory.createRegularContext(profileID: profile.id, directory: profile.dataDirectoryName, app: app)
  }

  /// A window's extension browser for the Profile (pins live in the Profile's preferences).
  private func extensionBrowser(for profile: Profile) -> OEBrowser? {
    for factory in app.hostFactories.values where !factory.isIncognito {
      if let browser = factory.extensions.host?.browser, browser.context.identifier == profile.dataDirectoryName { return browser }
    }
    return nil
  }

  private func waitUntilReady(_ manager: OEExtensionManager, seconds: Double) async -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while !manager.isReady {
      guard ProcessInfo.processInfo.systemUptime < deadline, !app.terminationRequested, !Task.isCancelled else { return false }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return true
  }

  /// A Chrome Web Store ID: 32 letters a…p.
  static func isWebStoreID(_ id: String) -> Bool {
    id.utf8.count == 32 && id.utf8.allSatisfy { (97...112).contains($0) }
  }

  private func collectExtensions() throws -> SyncBundlePart {
    var part = SyncBundlePart()
    var complete = true
    for profile in profiles {
      // Pins are known only through a window of the Profile; without one the record keeps its cloud copy.
      guard let context = existingContext(for: profile), context.extensions.isReady,
            let browser = extensionBrowser(for: profile) else { complete = false; continue }
      var pins: [String: Int] = [:]
      for action in browser.extensionActions where action.isPinned { pins[action.extensionIdentifier] = action.pinnedIndex }
      let records = context.extensions.installedExtensions
        .filter { $0.fromWebStore && Self.isWebStoreID($0.identifier) }
        .map { SyncedExtensionRecord(extensionID: $0.identifier, name: $0.name, fromWebStore: true, isEnabled: $0.isEnabled,
                                     isPinned: pins[$0.identifier] != nil, pinnedIndex: pins[$0.identifier] ?? -1) }
      let dto = SyncedExtensionsProfileDTO(profileID: profile.id.rawValue, extensions: records)
      part.records.append(try SyncLocalRecord(collection: .extensionsProfile, recordId: profile.id.rawValue.uuidString, value: dto))
    }
    if complete { part.complete.insert(.extensionsProfile) }
    return part
  }

  static let permissionNames: [(kind: OEPermissionKind, name: String)] = [
    (.camera, "camera"), (.microphone, "microphone"), (.geolocation, "geolocation"), (.notifications, "notifications"),
    (.clipboard, "clipboard"), (.MIDI, "midi"), (.multipleDownloads, "multipleDownloads"), (.storageAccess, "storageAccess"),
    (.windowManagement, "windowManagement"), (.localFonts, "localFonts"), (.idleDetection, "idleDetection"),
  ]

  private static func permissionName(_ kind: OEPermissionKind) -> String? { permissionNames.first { $0.kind == kind }?.name }
  private static func permissionKind(_ name: String) -> OEPermissionKind? { permissionNames.first { $0.name == name }?.kind }

  private static func decisionName(_ state: OEPermissionState) -> String {
    switch state {
    case .allow: return "allow"
    case .block: return "block"
    default: return "ask"
    }
  }

  private static func decisionState(_ name: String) -> OEPermissionState? {
    switch name {
    case "allow": return .allow
    case "block": return .block
    case "ask": return .ask
    default: return nil
    }
  }

  private func collectSitePermissions() async -> SyncBundlePart {
    var part = SyncBundlePart()
    var complete = true
    for profile in profiles {
      guard let context = existingContext(for: profile) else { complete = false; continue }
      let store = SitePermissionStore.forContext(context)
      // The origin index loads on a worker; its decisions are listable only after that.
      await store.persistenceTask?.value
      guard store.indexReady else { complete = false; continue }
      let decisions = store.allDecisions().compactMap { decision -> SyncedPermissionDecision? in
        guard let name = Self.permissionName(decision.kind) else { return nil }
        return SyncedPermissionDecision(origin: decision.origin.absoluteString, permission: name, decision: Self.decisionName(decision.state))
      }
      var settings: [SyncedSiteSetting] = []
      for origin in Set(decisions.map(\.origin)).sorted() {
        guard let url = URL(string: origin) else { continue }
        settings += context.changedSiteSettings(origin: url).map { SyncedSiteSetting(origin: origin, setting: $0.kind, value: $0.state) }
      }
      let dto = SyncedSitePermissionsProfileDTO(profileID: profile.id.rawValue, permissions: decisions, siteSettings: settings)
      do {
        part.records.append(try SyncLocalRecord(collection: .sitePermissionsProfile, recordId: profile.id.rawValue.uuidString, value: dto))
      } catch { complete = false }
    }
    if complete { part.complete.insert(.sitePermissionsProfile) }
    return part
  }

  // MARK: Apply

  func applyRemoteData(_ bundle: SyncRemoteBundle, mode: SyncApplyMode, categories: SyncCategorySettings) async throws -> SyncApplyOutcome {
    guard app.model != nil, app.directories != nil else { throw SyncError.noDataAdapter }
    var outcome = SyncApplyOutcome()
    // A full cloud replacement is the whole account: a collection with no cloud records is
    // empty in the cloud, so its local data is cleared too (on every local Profile).
    let fullReplace = mode == .replaceLocal && bundle.isFullSnapshot
    func applies(_ collection: SyncCollection) -> Bool { fullReplace || bundle.contains(collection) }
    // Profiles first: every other collection refers to them.
    try applyWorkspace(bundle, mode: mode, categories: categories)
    if categories.isEnabled(.archive), applies(.archiveProfile) {
      outcome.warnings += await applyArchive(bundle, mode: mode)
    }
    if categories.isEnabled(.settingsAndShortcuts) {
      if applies(.settingsPreferences) { try applyPreferences(bundle, mode: mode) }
      if applies(.settingsKeybindings) { outcome.warnings += applyKeyBindings(bundle, mode: mode) }
    }
    if categories.isEnabled(.adBlocking), applies(.adblockConfig) {
      outcome.warnings += await applyAdBlock(bundle, mode: mode)
    }
    if categories.isEnabled(.boostsEaselsNotes) {
      if applies(.boostItem) { outcome.warnings += applyBoosts(bundle, mode: mode) }
      if applies(.easelDocument) { outcome.warnings += applyEasels(bundle, mode: mode) }
      if applies(.noteDocument) { outcome.warnings += applyNotes(bundle, mode: mode) }
    }
    if categories.isEnabled(.history), applies(.historyProfile) {
      outcome.warnings += await applyHistory(bundle, mode: mode)
    }
    if categories.isEnabled(.extensions), bundle.contains(.extensionsProfile) {
      let result = await applyExtensions(bundle)
      outcome.pendingExtensionInstalls += result.pending
      outcome.warnings += result.warnings
    }
    if categories.isEnabled(.credentialsAndPermissions) {
      if applies(.sitePermissionsProfile) { outcome.warnings += applySitePermissions(bundle, mode: mode) }
      if bundle.contains(.credentialsProfile) { outcome.warnings += await applyCredentials(bundle) }
    }
    return outcome
  }

  /// Like `profileRecords`, and in a full cloud replacement also every local Profile the cloud
  /// has no record for, with the `empty` value (its local data is then cleared).
  private func profileRecords<T: Decodable>(_ bundle: SyncRemoteBundle, _ collection: SyncCollection, as type: T.Type,
                                            mode: SyncApplyMode, empty: (Profile) -> T,
                                            warnings: inout [String]) -> [(profile: Profile, value: T?)] {
    var result = profileRecords(bundle, collection, as: type, warnings: &warnings)
    guard mode == .replaceLocal, bundle.isFullSnapshot else { return result }
    let present = Set(result.map { $0.profile.id })
    for profile in profiles where !present.contains(profile.id) { result.append((profile: profile, value: empty(profile))) }
    return result
  }

  /// Record IDs of one per-Profile collection that this Mac has a Profile for.
  private func profileRecords<T: Decodable>(_ bundle: SyncRemoteBundle, _ collection: SyncCollection, as type: T.Type,
                                            warnings: inout [String]) -> [(profile: Profile, value: T?)] {
    var result: [(profile: Profile, value: T?)] = []
    for record in bundle.records(in: collection) {
      guard let uuid = UUID(uuidString: record.recordId), let profile = app.model.profile(id: ProfileID(rawValue: uuid)) else { continue }
      do { result.append((profile: profile, value: try record.decode(type))) }
      catch { warnings.append(error.localizedDescription) }
    }
    return result
  }

  private func applyWorkspace(_ bundle: SyncRemoteBundle, mode: SyncApplyMode, categories: SyncCategorySettings) throws {
    let clearsToday = mode == .replaceLocal && bundle.isFullSnapshot && categories.isEnabled(.todayTabs)
    guard clearsToday || !bundle.collections.isDisjoint(with: SyncWorkspaceCodec.collections) else { return }
    guard let model = app.model else { return }
    var changed = false
    if categories.isEnabled(.workspace), let record = bundle.records(in: .workspaceWindowLayout).last(where: { !$0.deleted }),
       let layout = try record.decode(SyncedWindowLayoutDTO.self) {
      for window in model.windows where window.style == .standard { SyncWorkspaceCodec.applyWindowLayout(layout, to: window) }
      changed = true
    }
    // A new Profile must not take a folder that exists under Profiles/ or Engine/, a retired
    // name, or a current Profile's name (APFS ignores case; the codec lowercases).
    var reserved = Set(model.profiles.map { $0.dataDirectoryName.lowercased() })
    do { reserved.formUnion(try app.directories.unavailableDirectoryNames()) }
    catch { throw SyncError.storage("The Profile folders could not be listed: \(error.localizedDescription)") }
    if let resolved = try SyncWorkspaceCodec.resolveWorkspace(current: model, bundle: bundle, mode: mode, categories: categories,
                                                              reservedDirectoryNames: reserved) {
      // Every Profile's folders exist before its Spaces or tabs can make an engine context.
      for profile in resolved.profiles { try app.directories.ensureProfileDirectories(for: profile) }
      model.applySyncedWorkspace(profiles: resolved.profiles, spaces: resolved.spaces,
                                 routingRules: resolved.routingRules, defaultDestination: resolved.defaultDestination)
      app.settingsPresenter.refreshProfilesIfLoaded()
      // The sleep policy owns onProfileCreated; ad blocking composes over it (as installModel does).
      app.tabSleep.installSettingsPolicy()
      app.adBlockEngineAdapter.installProfilePolicy()
      changed = true
    }
    guard changed else { return }
    for factory in app.hostFactories.values where factory.model === model { factory.controller?.refresh() }
    app.scheduleMenuRebuild()
    // During first run the snapshot is written by finishFirstRun (its absence marks first run).
    if !app.isFirstRun || app.firstRunSaved { try app.snapshotStore.saveNow(model: model) }
  }

  private func applyArchive(_ bundle: SyncRemoteBundle, mode: SyncApplyMode) async -> [String] {
    var warnings: [String] = []
    for (profile, dto) in profileRecords(bundle, .archiveProfile, as: SyncedArchiveProfileDTO.self, mode: mode,
                                         empty: { SyncedArchiveProfileDTO(profileID: $0.id.rawValue, records: []) }, warnings: &warnings) {
      guard let dto else { continue }
      let store = app.archiveSink.store(for: profile.id)
      do {
        if mode == .replaceLocal { try await store.deleteAll() }
        // Stored IDs count as duplicates and keep their rows: applying the same record twice is a no-op.
        let rows = dto.records.compactMap(\.archivedTabRecord)
        if !rows.isEmpty { _ = try await store.importRecordsWithUndo(rows) }
      } catch {
        warnings.append("Archived tabs of the Profile “\(profile.name)” could not be updated.")
      }
    }
    app.scheduleMenuRebuild()
    return warnings
  }

  private func applyPreferences(_ bundle: SyncRemoteBundle, mode: SyncApplyMode) throws {
    let dto: SyncedPreferencesDTO
    if let record = bundle.records(in: .settingsPreferences).last {
      guard let decoded = try record.decode(SyncedPreferencesDTO.self) else { return }
      dto = decoded
    } else if mode == .replaceLocal, bundle.isFullSnapshot {
      // The cloud holds no settings: replacing local data removes this Mac's portable values.
      dto = SyncedPreferencesDTO(values: [:])
    } else {
      return
    }
    let defaults = UserDefaults.standard
    let local = Self.portablePreferences()
    var changed = Set<String>()
    for (key, value) in dto.values where SyncedPreferencesDTO.isPortable(key) && local[key] != value {
      defaults.set(value.userDefaultsValue, forKey: key); changed.insert(key)
    }
    // The record is the whole portable set. The first-sign-in merge keeps this Mac's other values.
    if mode == .replaceLocal || !bundle.isFullSnapshot {
      for key in local.keys where dto.values[key] == nil { defaults.removeObject(forKey: key); changed.insert(key) }
    }
    coordinator?.lastPortablePreferences = Self.portablePreferences()
    guard !changed.isEmpty else { return }
    applyPreferenceEffects(changed)
  }

  /// Live effects of preference keys written by a remote apply (Settings would do these itself).
  private func applyPreferenceEffects(_ keys: Set<String>) {
    if keys.contains(where: { $0.hasPrefix("open.favorites.") }) {
      NotificationCenter.default.post(name: FavoriteTileSettings.didChange, object: UserDefaults.standard)
    }
    if keys.contains(WebsiteAppearance.defaultsKey) {
      WebsiteAppearance.applyToLiveContexts()
      for factory in app.hostFactories.values { factory.refreshNoteAppearance() }
    }
    if keys.contains("open.advanced.tabSleepMode") { app.tabSleep.reconcileSettingsPolicy() }
    if keys.contains(AppCommand.showFullURLKey) { app.applyToolbarSettings() }
    if keys.contains("open.links.littleOpenHotkeyEnabled"), app.commandServicesPrepared { app.updateLittleOpenHotkey() }
    app.settingsPresenter.refreshPreferencesIfLoaded()
    app.scheduleMenuRebuild()
  }

  private func applyKeyBindings(_ bundle: SyncRemoteBundle, mode: SyncApplyMode) -> [String] {
    // No cloud record in a full replacement means the cloud has no custom shortcuts.
    guard let record = bundle.records(in: .settingsKeybindings).last else {
      guard mode == .replaceLocal, bundle.isFullSnapshot, FileManager.default.fileExists(atPath: keyBindingsFile.path) else { return [] }
      do { try FileManager.default.removeItem(at: keyBindingsFile) }
      catch { return ["Synced keyboard shortcuts could not be saved: \(error.localizedDescription)"] }
      if app.commandServicesPrepared { app.reloadKeyBindings() }
      return []
    }
    let file = keyBindingsFile
    do {
      if record.deleted {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
      } else {
        guard let dto = try record.decode(SyncedKeyBindingsDTO.self) else { return [] }
        // Validate what this build can use; keep the other Mac's bindings for commands it does not know.
        let usable = dto.store.droppingUnknownCommands
        guard usable.isSupported, ConflictChecker.unexpected(ConflictChecker.check(overrides: usable)).isEmpty else {
          return ["Synced keyboard shortcuts conflict on this Mac and were not applied."]
        }
        var current: KeyBindingStore? = .empty
        if FileManager.default.fileExists(atPath: file.path) { current = try? KeyBindingStore.load(from: file) }
        guard current != dto.store else { return [] }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try dto.store.save(to: file)
      }
    } catch {
      return ["Synced keyboard shortcuts could not be saved: \(error.localizedDescription)"]
    }
    // Before command services start, their first load reads the new file.
    if app.commandServicesPrepared { app.reloadKeyBindings() }
    return []
  }

  private func applyAdBlock(_ bundle: SyncRemoteBundle, mode: SyncApplyMode) async -> [String] {
    let fullReplace = mode == .replaceLocal && bundle.isFullSnapshot
    let record = bundle.records(in: .adblockConfig).last
    guard record != nil || fullReplace else { return [] }
    var remoteConfig: SyncedAdBlockConfigDTO?
    if let record {
      do {
        guard let decoded = try record.decode(SyncedAdBlockConfigDTO.self) else { return [] }
        remoteConfig = decoded
      } catch { return [error.localizedDescription] }
    }
    guard let store = await adBlockStore() else { return ["Ad blocking settings could not be applied: the store could not be opened."] }
    var warnings: [String] = []
    if let dto = remoteConfig {
      do { if store.isEnabled != dto.globalEnabled { try store.setEnabled(dto.globalEnabled) } }
      catch { warnings.append("Ad blocking could not be switched \(dto.globalEnabled ? "on" : "off").") }
    }
    if fullReplace {
      // A local Profile the cloud has no settings for goes back to the default lists and no allowed sites.
      let listed = Set((remoteConfig?.profiles ?? [:]).keys.compactMap { UUID(uuidString: $0) })
      for profile in profiles where !listed.contains(profile.id.rawValue) {
        guard await openAdBlockProfile(store, profile) else {
          warnings.append("Ad blocking settings of the Profile “\(profile.name)” could not be reset."); continue
        }
        do {
          for domain in store.excludedDomains(for: profile.id).sorted() { try store.setExcluded(domain, excluded: false, profile: profile.id) }
          try await store.resetListChoices(profile: profile.id)
        } catch { warnings.append("Ad blocking settings of the Profile “\(profile.name)” could not be reset.") }
      }
    }
    guard let dto = remoteConfig else {
      app.settingsPresenter.refreshProfilesIfLoaded()
      return warnings
    }
    let removes = mode == .replaceLocal || !bundle.isFullSnapshot
    for (key, remote) in dto.profiles.sorted(by: { $0.key < $1.key }) {
      guard let uuid = UUID(uuidString: key), let profile = app.model.profile(id: ProfileID(rawValue: uuid)) else { continue }
      guard await openAdBlockProfile(store, profile) else {
        warnings.append("Ad blocking settings of the Profile “\(profile.name)” could not be applied."); continue
      }
      let localDomains = Set(store.excludedDomains(for: profile.id)), remoteDomains = Set(remote.excludedDomains)
      do {
        for domain in remoteDomains.subtracting(localDomains).sorted() { try store.setExcluded(domain, excluded: true, profile: profile.id) }
        if removes { for domain in localDomains.subtracting(remoteDomains).sorted() { try store.setExcluded(domain, excluded: false, profile: profile.id) } }
      } catch { warnings.append("Some allowed sites of the Profile “\(profile.name)” could not be applied.") }
      let localLists = Set(store.enabledListIDs(for: profile.id)), remoteLists = Set(remote.enabledListIDs)
      var toggles = remoteLists.subtracting(localLists).sorted().map { ($0, true) }
      if removes { toggles += localLists.subtracting(remoteLists).sorted().map { ($0, false) } }
      for (id, on) in toggles {
        do { try await store.setListEnabled(id, on, profile: profile.id) }
        catch { warnings.append("The block list \(id) could not be turned \(on ? "on" : "off").") }
      }
    }
    app.settingsPresenter.refreshProfilesIfLoaded()
    return warnings
  }

  private func applyBoosts(_ bundle: SyncRemoteBundle, mode: SyncApplyMode) -> [String] {
    var warnings: [String] = []
    let boosts = app.stores.boosts
    var touched = Set<ProfileID>()
    var remoteIDs: [ProfileID: Set<BoostID>] = [:]
    for record in bundle.records(in: .boostItem) {
      let parts = record.recordId.split(separator: ":", maxSplits: 1).map(String.init)
      guard parts.count == 2, let profileUUID = UUID(uuidString: parts[0]), let boostUUID = UUID(uuidString: parts[1]) else { continue }
      let profileID = ProfileID(rawValue: profileUUID), boostID = BoostID(rawValue: boostUUID)
      guard app.model.profile(id: profileID) != nil, !boosts.isRetired(profileID) else { continue }
      let store = boosts.store(for: profileID)
      if record.deleted {
        if store.delete(id: boostID) { touched.insert(profileID) }
        continue
      }
      do {
        guard let dto = try record.decode(SyncedBoostDTO.self), dto.boost.id == boostID, dto.profileID == profileUUID else { continue }
        remoteIDs[profileID, default: []].insert(boostID)
        if store.boost(id: boostID) != dto.boost { store.upsert(dto.boost); touched.insert(profileID) }
      } catch { warnings.append(error.localizedDescription) }
    }
    if mode == .replaceLocal {
      for profile in profiles where !boosts.isRetired(profile.id) {
        let store = boosts.store(for: profile.id), keep = remoteIDs[profile.id] ?? []
        for boost in store.allBoosts() where !keep.contains(boost.id) {
          if store.delete(id: boost.id) { touched.insert(profile.id) }
        }
      }
    }
    for profileID in touched {
      boosts.store(for: profileID).saveNow()
      boosts.refresh(profile: profileID)
    }
    return warnings
  }

  /// A downloaded asset to write, after the file name passed `validName`.
  private static func writeAsset(_ data: Data, to url: URL) throws {
    if let existing = try? Data(contentsOf: url), existing == data { return }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try data.write(to: url, options: .atomic)
  }

  private func removeEasel(_ id: UUID) {
    let easels = app.easels
    guard easels.exists(id) else { return }
    app.closeEaselHosts(documentID: id)
    easels.flush()
    // A copy whose write failed is queued again; it must not bring the folder back.
    easels.discard(id)
    let folder = easels.fileURL(for: id).deletingLastPathComponent()
    if FileManager.default.fileExists(atPath: folder.path) {
      if (try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)) == nil { try? FileManager.default.removeItem(at: folder) }
    }
  }

  private func applyEasels(_ bundle: SyncRemoteBundle, mode: SyncApplyMode) -> [String] {
    var warnings: [String] = []
    let easels = app.easels
    var remote = Set<UUID>()
    var changed = false
    for record in bundle.records(in: .easelDocument) {
      guard let id = UUID(uuidString: record.recordId) else { continue }
      if record.deleted { if easels.exists(id) { removeEasel(id); changed = true }; continue }
      remote.insert(id)
      do {
        guard let dto = try record.decode(SyncedEaselDTO.self), dto.document.id == id, dto.document.isValid else {
          warnings.append("A synced Easel was not valid and was skipped."); continue
        }
        for asset in dto.assets {
          guard EaselDocument.isImageFileName(asset.filename), let url = easels.imageURL(document: id, file: asset.filename) else {
            warnings.append("A synced Easel picture had an invalid name and was skipped."); continue
          }
          guard let data = bundle.blobs[asset.blobId] else {
            if !FileManager.default.fileExists(atPath: url.path) { warnings.append("A synced Easel picture is missing.") }
            continue
          }
          try Self.writeAsset(data, to: url)
        }
        guard easels.load(id) != dto.document else { continue }
        // Close canvases first: a close commits open edits and queues a write over the new file.
        app.closeEaselHosts(documentID: id)
        easels.flush()
        easels.discard(id)
        let file = easels.fileURL(for: id)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try EaselStore.encoder.encode(dto.document).write(to: file, options: .atomic)
        changed = true
      } catch {
        warnings.append("A synced Easel could not be saved: \(error.localizedDescription)")
      }
    }
    if mode == .replaceLocal {
      for entry in EaselStore.readIndex(directory: easels.directory) where !remote.contains(entry.id) {
        removeEasel(entry.id); changed = true
      }
    }
    if changed {
      app.reshowEaselWindows()
      app.easelsDidChange()
    }
    return warnings
  }

  private func closeNoteEditors(_ id: UUID) {
    for host in NoteContentHost.open(noteID: id) {
      host.owner?.controller?.container.closeHost(for: host.tabID); host.close()
    }
  }

  private func applyNotes(_ bundle: SyncRemoteBundle, mode: SyncApplyMode) -> [String] {
    var warnings: [String] = []
    let notes = app.notes
    var remote = Set<UUID>()
    var changed = false
    for record in bundle.records(in: .noteDocument) {
      guard let id = UUID(uuidString: record.recordId) else { continue }
      if record.deleted {
        if FileManager.default.fileExists(atPath: notes.fileURL(for: id).path) { closeNoteEditors(id); notes.delete(id); changed = true }
        continue
      }
      remote.insert(id)
      do {
        guard let dto = try record.decode(SyncedNoteDTO.self), dto.document.id == id else {
          warnings.append("A synced Note was not valid and was skipped."); continue
        }
        for asset in dto.assets {
          guard let url = notes.assetURL(note: id, name: asset.filename) else {
            warnings.append("A synced Note image had an invalid name and was skipped."); continue
          }
          guard let data = bundle.blobs[asset.blobId] else {
            if !FileManager.default.fileExists(atPath: url.path) { warnings.append("A synced Note image is missing.") }
            continue
          }
          try Self.writeAsset(data, to: url)
        }
        guard notes.load(id) != dto.document else { continue }
        if notes.replace(dto.document) {
          NoteContentHost.noteDidChange(id, store: notes, titleChanged: true)
          changed = true
        } else {
          warnings.append("A synced Note is too large to save on this Mac.")
        }
      } catch {
        warnings.append("A synced Note could not be saved: \(error.localizedDescription)")
      }
    }
    if mode == .replaceLocal, let files = try? FileManager.default.contentsOfDirectory(at: notes.directory, includingPropertiesForKeys: nil) {
      for file in files where file.pathExtension == "json" {
        guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !remote.contains(id) else { continue }
        closeNoteEditors(id); notes.delete(id); changed = true
      }
    }
    if changed { app.easelsDidChange() }
    return warnings
  }

  /// A stable visit key for one synced history entry, so applying a record twice adds nothing.
  private static func visitKey(url: String, time: Double) -> Int64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in "\(url)|\(time)".utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
    return Int64(bitPattern: hash & 0x7fff_ffff_ffff_ffff)
  }

  private func applyHistory(_ bundle: SyncRemoteBundle, mode: SyncApplyMode) async -> [String] {
    var warnings: [String] = []
    for (profile, dto) in profileRecords(bundle, .historyProfile, as: SyncedHistoryProfileDTO.self, mode: mode,
                                         empty: { SyncedHistoryProfileDTO(profileID: $0.id.rawValue, entries: []) }, warnings: &warnings) {
      guard let dto, let store = app.stores.history(for: profile.id) else { continue }
      do {
        var known: [String: Double] = [:]
        if mode == .replaceLocal {
          try await store.deleteVisits(since: nil, through: .distantFuture)
        } else {
          // Visits this Mac already has (its own, or an earlier apply) are not added again.
          var offset = 0
          while offset < SyncLimits.maxHistoryEntriesPerProfile {
            let page = await store.recent(limit: 1_000, offset: offset)
            for row in page { known[row.url.absoluteString] = max(known[row.url.absoluteString] ?? 0, row.lastVisit.timeIntervalSince1970) }
            if page.count < 1_000 { break }
            offset += page.count
          }
        }
        let visits = dto.entries.compactMap { entry -> ImportedHistoryVisit? in
          guard URL(string: entry.url) != nil, entry.lastVisitedAt.isFinite else { return nil }
          if let local = known[entry.url], local >= entry.lastVisitedAt { return nil }
          return ImportedHistoryVisit(chromiumVisitID: Self.visitKey(url: entry.url, time: entry.lastVisitedAt), urlString: entry.url,
                                      title: entry.title, time: Date(timeIntervalSince1970: entry.lastVisitedAt),
                                      transition: entry.typedCount > 0 ? "typed" : "link", isTyped: entry.typedCount > 0)
        }
        let key = "sync:\(profile.id.rawValue.uuidString)"
        var start = 0
        while start < visits.count {
          let end = min(start + 5_000, visits.count)
          let result = await store.importHistoryBatch(Array(visits[start..<end]), sourceProfileKey: key)
          if !result.succeeded { warnings.append("History of the Profile “\(profile.name)” could not be updated."); break }
          start = end
        }
      } catch {
        warnings.append("History of the Profile “\(profile.name)” could not be replaced.")
      }
    }
    return warnings
  }

  private func applyExtensions(_ bundle: SyncRemoteBundle) async -> (pending: [SyncPendingExtension], warnings: [String]) {
    var warnings: [String] = []
    var pending: [SyncPendingExtension] = []
    for (profile, dto) in profileRecords(bundle, .extensionsProfile, as: SyncedExtensionsProfileDTO.self, warnings: &warnings) {
      guard let dto else { continue }
      guard let context = liveContext(for: profile), await waitUntilReady(context.extensions, seconds: 10) else {
        warnings.append("Extensions of the Profile “\(profile.name)” were not updated: the browser engine is not ready."); continue
      }
      let manager = context.extensions
      let browser = extensionBrowser(for: profile)
      let pinnedNow = Dictionary((browser?.extensionActions ?? []).filter(\.isPinned).map { ($0.extensionIdentifier, $0.pinnedIndex) },
                                 uniquingKeysWith: { first, _ in first })
      for item in dto.extensions where item.fromWebStore && Self.isWebStoreID(item.extensionID) {
        guard let installed = manager.extension(identifier: item.extensionID) else {
          pending.append(SyncPendingExtension(profileID: profile.id.rawValue, extensionID: item.extensionID, name: item.name,
                                              isEnabled: item.isEnabled, isPinned: item.isPinned, pinnedIndex: item.pinnedIndex))
          continue
        }
        if installed.isEnabled != item.isEnabled { manager.setEnabled(item.isEnabled, forExtension: item.extensionID) }
        guard let browser else { continue }
        if item.isPinned != (pinnedNow[item.extensionID] != nil) { browser.setExtensionAction(item.extensionID, pinned: item.isPinned) }
        if item.isPinned, item.pinnedIndex >= 0 { Self.movePinned(item.extensionID, to: item.pinnedIndex, in: browser) }
      }
      manager.reload()
    }
    return (pending, warnings)
  }

  /// Moves a pinned action within the current pinned range (as `EngineExtensionHost.movePinned`).
  private static func movePinned(_ id: String, to index: Int, in browser: OEBrowser) {
    let pinned = browser.extensionActions.filter(\.isPinned)
    guard let current = pinned.firstIndex(where: { $0.extensionIdentifier == id }) else { return }
    let destination = min(max(0, index), pinned.count - 1)
    guard current != destination else { return }
    browser.moveExtensionAction(id, toPinnedIndex: UInt(destination))
  }

  /// Installs Web Store extensions that another Mac synced, after the user agreed in Settings.
  /// Returns the pending IDs (`SyncPendingExtension.id`) that are now resolved.
  func installSyncedExtensions(_ extensions: [SyncPendingExtension], window: NSWindow?) async -> [String] {
    var resolved: [String] = []
    for item in extensions where Self.isWebStoreID(item.extensionID) {
      guard !app.terminationRequested, let profile = app.model.profile(id: ProfileID(rawValue: item.profileID)) else { continue }
      guard let context = liveContext(for: profile), await waitUntilReady(context.extensions, seconds: 10) else { continue }
      let manager = context.extensions
      if manager.extension(identifier: item.extensionID) == nil {
        let installed: Bool = await withCheckedContinuation { continuation in
          manager.install(fromWebStore: item.extensionID, window: window) { installed, _ in
            Task { @MainActor in
              manager.reload()
              continuation.resume(returning: installed && manager.extension(identifier: item.extensionID) != nil)
            }
          }
        }
        guard installed else { continue }
      }
      if !item.isEnabled { manager.setEnabled(false, forExtension: item.extensionID) }
      if item.isPinned, let browser = extensionBrowser(for: profile) {
        browser.setExtensionAction(item.extensionID, pinned: true)
        if item.pinnedIndex >= 0 { Self.movePinned(item.extensionID, to: item.pinnedIndex, in: browser) }
      }
      resolved.append(item.id)
    }
    // Settings passes the result to `SyncEngine.resolvePendingExtensionInstalls`.
    return resolved
  }

  private func applySitePermissions(_ bundle: SyncRemoteBundle, mode: SyncApplyMode) -> [String] {
    var warnings: [String] = []
    let removes = mode == .replaceLocal || !bundle.isFullSnapshot
    for (profile, dto) in profileRecords(bundle, .sitePermissionsProfile, as: SyncedSitePermissionsProfileDTO.self, mode: mode,
                                         empty: { SyncedSitePermissionsProfileDTO(profileID: $0.id.rawValue, permissions: [], siteSettings: []) },
                                         warnings: &warnings) {
      guard let dto else { continue }
      guard let context = liveContext(for: profile) else {
        warnings.append("Site permissions of the Profile “\(profile.name)” were not updated: the browser engine is not ready."); continue
      }
      let store = SitePermissionStore.forContext(context)
      var remoteKeys = Set<String>()
      for decision in dto.permissions {
        guard let origin = URL(string: decision.origin), ["http", "https"].contains(origin.scheme?.lowercased() ?? ""),
              let kind = Self.permissionKind(decision.permission), let state = Self.decisionState(decision.decision) else { continue }
        remoteKeys.insert("\(decision.origin)|\(decision.permission)")
        if store.currentState(origin: origin, kind: kind) != state {
          store.set(origin: origin, kind: kind, state: state, requestSystemAuthorization: false)
        }
      }
      if removes {
        for local in store.allDecisions() {
          guard let name = Self.permissionName(local.kind), !remoteKeys.contains("\(local.origin.absoluteString)|\(name)") else { continue }
          store.set(origin: local.origin, kind: local.kind, state: .ask, requestSystemAuthorization: false)
        }
      }
      for setting in dto.siteSettings {
        guard let origin = URL(string: setting.origin), ["http", "https"].contains(origin.scheme?.lowercased() ?? "") else { continue }
        let current = context.changedSiteSettings(origin: origin).first { $0.kind == setting.setting }?.state
        if current != setting.value, !context.setSiteSetting(setting.setting, state: setting.value, origin: origin) {
          warnings.append("A site setting (\(setting.setting)) could not be applied.")
        }
      }
    }
    return warnings
  }

  // MARK: Backup

  func prepareLocalBackup(root: URL) async throws {
    var relative = ["State/browser.json", "State/keybindings.json", "adblock-settings.json"]
    for profile in profiles {
      let base = "Profiles/\(profile.dataDirectoryName)/"
      relative += [base + "Boosts/boosts.json", base + "AdBlock/catalog-state.json", base + "AdBlock/exclusions.json"]
    }
    // During first run (for example right after an import) the snapshot is not written yet:
    // back up the live workspace instead, so a cloud replacement can be undone.
    var liveSnapshot: Data?
    if let model = app.model, !FileManager.default.fileExists(atPath: root.appendingPathComponent("State/browser.json").path) {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      liveSnapshot = try encoder.encode(SnapshotMapper.dto(from: model))
      relative.removeAll { $0 == "State/browser.json" }
    }
    let paths = relative, snapshot = liveSnapshot
    try await Task.detached(priority: .userInitiated) {
      var files: [(relativePath: String, data: Data)] = []
      if let snapshot { files.append(("State/browser.json", snapshot)) }
      for path in paths {
        let url = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path), let data = try? Data(contentsOf: url) else { continue }
        files.append((path, data))
      }
      guard !files.isEmpty else { return }
      try SyncStateStore.createLocalBackup(root: root, files: files)
    }.value
  }
}
