import Foundation
import OpenModel
import OpenStore

/// One document at a time. The main actor only captures values and queues work.
@MainActor
final class AppHistoryRecorder {
  private let stores: AppStores
  private let profileID: ProfileID
  private var typed = false
  private var visit: Task<Int64?, Never>?
  private var titleTask: Task<Void, Never>?
  private var latestTitle = ""
  private var savedTitle = ""
  private var revision = 0
  private var visitTime = Date.distantPast
  private var visitURL: URL?
  private var loading = false
  private var committedDuringLoad = false
  private var pendingURL: URL?
  private var pendingEphemeral = false

  init(stores: AppStores, profileID: ProfileID) { self.stores = stores; self.profileID = profileID }
  func markTyped() { typed = true }
  func navigationFailed() { typed = false; pendingURL = nil }

  func loadingChanged(_ isLoading: Bool) {
    loading = isLoading
    if isLoading { committedDuringLoad = false; pendingURL = nil }
    else if !committedDuringLoad, let url = pendingURL {
      // A committed address without OnLoadStart (such as a page-cache restore)
      // uses load completion as the fallback, once per load.
      committed(url: url, isReload: false, ephemeral: pendingEphemeral)
    }
    if !isLoading { pendingURL = nil }
  }

  func addressChanged(_ url: URL, isLoading: Bool, ephemeral: Bool, title: String) {
    if isLoading { pendingURL = url; pendingEphemeral = ephemeral }
    else {
      // Same-document commits have no OnLoadStart or load completion.
      committed(url: url, isReload: false, ephemeral: ephemeral)
      titleChanged(title)
    }
  }

  func committed(url: URL, isReload: Bool, ephemeral: Bool) {
    #if OPEN_AUTOMATION
    let start = ProcessInfo.processInfo.systemUptime
    defer { stores.noteHistoryEnqueue(milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1_000) }
    #endif
    committedDuringLoad = true; pendingURL = nil
    titleTask?.cancel(); titleTask = nil; revision += 1
    let wasTyped = typed; typed = false
    if isReload, !wasTyped, !ephemeral, visitURL == url { return }
    visit = nil; visitURL = nil; latestTitle = ""; savedTitle = ""
    guard !ephemeral, (!isReload || wasTyped), let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme), !url.absoluteString.isEmpty,
          let history = stores.history(for: profileID) else { return }
    // Guess (lead decision): back/forward, Peek and Little Open count like links.
    visitTime = Date()
    visitURL = url
    visit = stores.enqueueHistoryVisit(store: history, url: url, time: visitTime, typed: wasTyped)
  }

  /// A single deferred task coalesces a burst of title callbacks. A new commit
  /// cancels it. It never adds a visit or inserts a deleted URL.
  func titleChanged(_ title: String) {
    guard (!loading || committedDuringLoad), visit != nil, !title.isEmpty, title != savedTitle else { return }
    latestTitle = title
    guard titleTask == nil else { return }
    let token = revision
    titleTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, let id = await self.visit?.value, !Task.isCancelled, token == self.revision else { return }
      let title = self.latestTitle
      self.savedTitle = title; self.titleTask = nil
      guard let store = self.stores.history(for: self.profileID) else { return }
      let time = self.visitTime
      self.stores.enqueueHistoryWrite { await store.updateTitle(title, visitID: id, time: time) }
    }
  }

  func flush() async { await titleTask?.value }
  func close() { titleTask?.cancel(); titleTask = nil; revision += 1 }
}
