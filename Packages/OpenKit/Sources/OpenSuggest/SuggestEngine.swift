import Foundation
import Observation
import OpenModel
import OpenStore

/// Engine-agnostic, UI-free backend of the command bar (Cmd+T, Cmd+L, tab search).
///
/// `query(_:context:)` returns a stream. Its first snapshot holds every synchronous provider and is
/// already buffered when `query` returns. Each async provider (history, then the network) adds one
/// snapshot as it finishes; the last one has `isFinal == true`. A new `query` call cancels the
/// previous stream, which also cancels its pending network request.
@MainActor
public final class SuggestEngine {
    public var model: BrowserModel? {
        get { indexer.model }
        set { indexer.model = newValue }
    }
    public var providers: [any SuggestProvider]
    public var searchEngines: [SearchEngine]
    public var siteSearches: [SiteSearch] {
        didSet { siteIndex = SiteSearchIndex(siteSearches) }
    }
    /// Rows in a snapshot, top hit included.
    public var maxResults = 12

    private let indexer: TabIndexer
    private var siteIndex: SiteSearchIndex
    private let classifier = InputClassifier()
    private var activeTask: Task<Void, Never>?

    /// Default providers: what you typed, tabs, calculator, actions, Site Search, history (when a
    /// store is given), and remote suggestions (when a fetcher is given).
    public init(
        model: BrowserModel?,
        historyStore: (@MainActor (ProfileID?) -> HistoryStore?)? = nil,
        fetcher: (any SuggestionFetcher)? = HTTPSuggestionFetcher(),
        actions: ActionRegistry = .arcDefaults,
        searchEngines: [SearchEngine] = SearchEngines.all,
        siteSearches: [SiteSearch]? = nil
    ) {
        let sites = siteSearches ?? SiteSearches.defaults(engines: searchEngines)
        self.indexer = TabIndexer(model: model)
        self.searchEngines = searchEngines
        self.siteSearches = sites
        self.siteIndex = SiteSearchIndex(sites)
        var list: [any SuggestProvider] = [
            WhatYouTypedProvider(), TabsProvider(), CalculatorProvider(),
            ActionsProvider(registry: actions), SiteSearchProvider(sites: sites),
        ]
        if let historyStore { list.append(HistoryProvider(store: historyStore)) }
        if let fetcher { list.append(RemoteSuggestionsProvider(fetcher: fetcher, engines: searchEngines)) }
        self.providers = list
    }

    /// Convenience: one history database for every Profile.
    public convenience init(model: BrowserModel?, history: HistoryStore?, fetcher: (any SuggestionFetcher)? = HTTPSuggestionFetcher()) {
        var resolver: (@MainActor (ProfileID?) -> HistoryStore?)?
        if let history { resolver = { _ in history } }
        self.init(model: model, historyStore: resolver, fetcher: fetcher)
    }

    /// Builds the tab index now and loads the Public Suffix List off the main actor. Call when the
    /// command bar is about to open so the first keystroke pays neither cost.
    public func prewarm() {
        _ = indexer.current()
        Task.detached(priority: .utility) { _ = PublicSuffixList.shared.ruleCount }
    }

    /// The Site Search target for the Tab key ("you" + Tab → YouTube), or nil.
    public func siteSearchTrigger(for text: String) -> SiteSearch? {
        siteIndex.tabTrigger(for: TextMatching.fold(text.trimmingCharacters(in: .whitespaces)))
    }

    public func siteSearch(id: String) -> SiteSearch? { siteIndex.byID[id] }

    /// Time the last tab index build or patch took, for diagnostics.
    public var lastIndexBuildMilliseconds: Double { indexer.lastBuildMilliseconds }
    /// How many times the tab index was rebuilt. It grows only after a structural model change.
    public var indexBuildCount: Int { indexer.buildCount }
    /// Tabs read and folded from scratch in the last build or patch.
    public var lastIndexFoldedCount: Int { indexer.lastFoldedCount }
    public var indexedTabCount: Int { indexer.index?.entries.count ?? 0 }

    // MARK: Query

    public func query(_ text: String, context: SuggestContext) -> AsyncStream<SuggestionSnapshot> {
        activeTask?.cancel()
        activeTask = nil
        let run = QueryRun(text: text, input: makeInput(text, context: context), maxResults: maxResults)
        var operations: [(id: String, run: @Sendable () async -> [Suggestion]?)] = []
        for provider in providers {
            let t0 = ContinuousClock.now
            let rows = provider.localSuggestions(for: run.input)
            if let op = provider.asyncOperation(for: run.input) { operations.append((provider.id, op)) }
            run.add(provider.id, rows, milliseconds: (ContinuousClock.now - t0).milliseconds, isAsync: false)
        }
        run.pending = operations.map(\.id)

        let (stream, continuation) = AsyncStream.makeStream(of: SuggestionSnapshot.self, bufferingPolicy: .unbounded)
        continuation.yield(run.snapshot())
        guard !operations.isEmpty else {
            continuation.finish()
            return stream
        }
        let task = Task { @MainActor in
            await withTaskGroup(of: (String, [Suggestion]?, Double).self) { group in
                for op in operations {
                    group.addTask {
                        let t0 = ContinuousClock.now
                        let rows = await op.run()
                        return (op.id, rows, (ContinuousClock.now - t0).milliseconds)
                    }
                }
                for await (id, rows, ms) in group {
                    if Task.isCancelled { break }
                    run.finish(id, rows, milliseconds: ms)
                    continuation.yield(run.snapshot())
                }
                group.cancelAll()
            }
            continuation.finish()
        }
        activeTask = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Stops the running query (for example when the command bar closes).
    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
    }

    // MARK: Input

    private func makeInput(_ raw: String, context: SuggestContext) -> SuggestInput {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = indexer.current()
        let profileID = context.profileID ?? context.spaceID.flatMap { model?.space(id: $0)?.profileID }
        return SuggestInput(
            rawText: raw, text: text, query: FoldedQuery(text), typed: classifier.classify(text),
            context: context, searchEngine: SearchEngines.engine(id: context.searchEngineID, in: searchEngines),
            siteSearch: context.siteSearchID.flatMap { siteIndex.byID[$0] },
            currentTab: currentTabState(context), profileID: profileID, now: Date(),
            tabs: index, profileOrdinal: index.ordinal(of: profileID))
    }

    private func currentTabState(_ context: SuggestContext) -> CurrentTabState? {
        guard let model, let id = context.currentTabID, let tab = model.tab(id: id) else { return nil }
        var isPinned = false, isFavorite = false, isInSplit = false
        var parent = model.parent(of: id)
        if case .splitPane = parent { isInSplit = true }
        var hops = 0
        while let p = parent, hops < 64 {
            hops += 1
            switch p {
            case .spacePinned: isPinned = true; parent = nil
            case .spaceToday: parent = nil
            case .favorites: isFavorite = true; parent = nil
            case .folder(let fid), .splitPane(let fid): parent = model.parent(of: fid)
            }
        }
        return CurrentTabState(tabID: id, url: context.currentTabURL ?? tab.url,
                               isPinned: isPinned, isFavorite: isFavorite, isInSplit: isInSplit)
    }
}

/// State of one query: rows per provider (in provider order), timings, and pending async work.
@MainActor
private final class QueryRun {
    let text: String
    let input: SuggestInput
    let maxResults: Int
    let start = ContinuousClock.now
    private var rows: [(id: String, rows: [Suggestion])] = []
    private var timings: [ProviderTiming] = []
    var pending: [String] = []
    private var sequence = 0

    init(text: String, input: SuggestInput, maxResults: Int) {
        self.text = text; self.input = input; self.maxResults = maxResults
    }

    func add(_ id: String, _ list: [Suggestion], milliseconds: Double, isAsync: Bool) {
        rows.append((id, list))
        timings.append(ProviderTiming(provider: id, milliseconds: milliseconds, isAsync: isAsync))
    }

    /// Async rows replace the provider's local rows; nil keeps them.
    func finish(_ id: String, _ list: [Suggestion]?, milliseconds: Double) {
        if let list, let i = rows.firstIndex(where: { $0.id == id }) { rows[i].rows = list }
        pending.removeAll { $0 == id }
        timings.append(ProviderTiming(provider: id, milliseconds: milliseconds, isAsync: true))
        sequence += 1
    }

    func snapshot() -> SuggestionSnapshot {
        let ranked = Ranking.rank(rows.flatMap(\.rows), input: input, maxResults: maxResults)
        return SuggestionSnapshot(
            query: text, sequence: sequence, isFinal: pending.isEmpty, input: input.typed,
            suggestions: ranked.rows, hasTopHit: ranked.hasTopHit, topHitRule: ranked.rule,
            elapsedMilliseconds: (ContinuousClock.now - start).milliseconds,
            timings: timings, pendingProviders: pending)
    }
}
