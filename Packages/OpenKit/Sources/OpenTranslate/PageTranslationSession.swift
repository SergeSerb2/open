import Foundation
import OpenWeb

/// One batch from the page runtime (§4.7.4). The page controls this value: the init refuses any
/// shape or size the runtime itself never sends (checklist §1). Worst single allocation on this
/// path: one unit string of 20,000 UTF-16 units (40 KB) or a batch of at most 24,000 (48 KB),
/// and its JSON for `apply` (results may be up to twice as long, about 100 KB): far under every
/// allocator ceiling.
public struct TranslationBatch: Sendable, Equatable {
    public static let maxUnits = 40
    /// The runtime caps a batch at 4,000 characters unless one unit alone is longer, and a unit at
    /// 20,000 (UTF-16 units, the page's own string length).
    public static let maxCharacters = 4_000
    public static let maxUnitCharacters = 20_000

    public var id: Int
    public var texts: [String]

    public init?(json: Any) {
        guard let object = json as? [String: Any], object.count == 2,
              let id = (object["id"] as? NSNumber)?.intValue, id > 0, id < Int(Int32.max),
              let units = object["units"] as? [Any], units.count <= Self.maxUnits else { return nil }
        var texts: [String] = []
        var total = 0
        for unit in units {
            guard let u = unit as? [String: Any], u.count == 2, u["id"] is NSNumber,
                  let text = u["text"] as? String else { return nil }
            let length = text.utf16.count
            guard length <= Self.maxUnitCharacters else { return nil }
            total += length
            texts.append(text)
        }
        guard texts.count <= 1 || total <= Self.maxCharacters else { return nil }
        self.id = id; self.texts = texts
    }
}

/// One page's translation state machine (§4.7.2–§4.7.7). Lives as long as its tab's web content;
/// the App creates it lazily for the focused tab and closes it with the page.
@MainActor
public final class PageTranslationSession {
    public struct Offer: Sendable, Equatable {
        public var source: Locale.Language
        public var target: Locale.Language
        public var host: String
        public init(source: Locale.Language, target: Locale.Language, host: String) { self.source = source; self.target = target; self.host = host }
    }

    public enum State: Sendable, Equatable {
        /// No offer: not detected yet, same language, unsupported, off, or a never-translate host.
        case idle
        case offered(Offer)
        case translating(Offer)
        case translated(Offer)
        case failed(Offer, reason: String)

        public var offer: Offer? {
            switch self {
            case .idle: nil
            case .offered(let o), .translating(let o), .translated(let o), .failed(let o, _): o
            }
        }
    }

    /// What the App turns into toasts and undo entries (§4.1.4, §4.7.6).
    public enum Event: Sendable, Equatable {
        /// `userAction` is false for the same-host automatic translation of a new page (Q12).
        case translated(to: Locale.Language, userAction: Bool)
        case reverted(to: Locale.Language, userAction: Bool)
        case failed(reason: String)
    }

    public private(set) var state: State = .idle { didSet { if state != oldValue { onStateChange?(state) } } }
    public var onStateChange: ((State) -> Void)?
    public var onEvent: ((Event) -> Void)?
    /// Called when the pair is `.supported` but not installed, before translating: shows macOS's
    /// download prompt (`AppleTranslationBackend.prepare`). Nil refuses those pairs.
    public var prepareLanguages: ((Locale.Language, Locale.Language) async throws -> Void)?

    public weak private(set) var page: (any WebContent)?
    private let backend: any TranslationBackend
    private let preferences: TranslatePreferences
    private let runtimeSource: String
    private let preferredLanguages: () -> [String]
    /// Every new document, revert and close starts a new generation; late answers of older
    /// generations are dropped.
    private var generation = 0
    private var loop: Task<Void, Never>?
    private var detection: Task<Void, Never>?
    /// The document this session last probed (the App's load counter for this page).
    public private(set) var probedDocument: Int?
    /// Q12: after the user translated this host in this tab, new pages of the host translate to
    /// the same target until Show Original.
    public private(set) var stickyTarget: (host: String, target: Locale.Language)?
    public private(set) var batchesApplied = 0
    /// Every answer of `nextBatch()` (also empty ones): proves the shell does not poll while idle.
    public private(set) var batchesPulled = 0
    public private(set) var unitsFallback = 0
    private var closed = false

    public init(page: any WebContent, backend: any TranslationBackend, preferences: TranslatePreferences = .init(),
                runtimeSource: String = TranslateResources.runtimeJS,
                preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages }) {
        self.page = page; self.backend = backend; self.preferences = preferences
        self.runtimeSource = runtimeSource; self.preferredLanguages = preferredLanguages
    }

    // MARK: Detection (§4.7.2)

    /// A main-frame document finished loading in this page (`document` is the App's per-page load
    /// counter). Detects and offers, or translates again for the sticky host.
    public func documentDidLoad(url: URL?, status: Int, document: Int) {
        guard !closed else { return }
        stop()
        state = .idle
        probedDocument = document
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), (200..<300).contains(status),
              let host = TranslatePreferences.normalizedHost(url.host), preferences.isEnabled,
              !preferences.neverTranslates(host: host) else { return }
        let token = generation
        detection = Task { [weak self] in
            guard let self, let page = self.page else { return }
            let raw = try? await Self.evaluate(page, PageLanguageDetector.probeScript)
            guard !Task.isCancelled, !self.closed, self.generation == token,
                  let raw, let probe = PageLanguageProbe(json: raw),
                  let detected = PageLanguageDetector.detect(probe) else { return }
            let sticky = self.stickyTarget?.host == host ? self.stickyTarget?.target : nil
            let target: Locale.Language?
            if let sticky, !PageLanguageDetector.sameLanguage(detected.language, sticky) { target = sticky }
            else { target = await PageLanguageDetector.target(for: detected.language, preferred: self.preferredLanguages(), backend: self.backend) }
            guard !Task.isCancelled, !self.closed, self.generation == token, let target else { return }
            let offer = Offer(source: detected.language, target: target, host: host)
            self.state = .offered(offer)
            // Its own task: `translate` stops this detection task first.
            if sticky != nil { Task { await self.translate(to: target, userAction: false) } }
        }
    }

    // MARK: Translate, revert (§4.7.3–§4.7.6)

    /// Translates the offered page to `target` (default: the offer's). A translated page is
    /// restored first, so this also serves "Choose Another Language".
    public func translate(to target: Locale.Language? = nil, userAction: Bool = true) async {
        guard !closed, let page, var offer = state.offer else { return }
        let active: Bool
        switch state { case .translating, .translated: active = true; default: active = false }
        if active, target == nil || target == offer.target { return }
        stop()
        // Taken before the restore suspends: a load, revert or other action during it starts a
        // newer generation, and this action must then give way.
        let token = generation
        if active {
            _ = try? await Self.evaluate(page, "window.__openTranslate ? window.__openTranslate.restore() : false")
            guard generation == token, !closed else { return }
        }
        if let target { offer.target = target }
        state = .translating(offer)
        do {
            switch await backend.status(from: offer.source, to: offer.target) {
            case .installed: break
            case .supported:
                guard let prepareLanguages else { throw TranslationFailure("Language not installed") }
                try await prepareLanguages(offer.source, offer.target)
            case .unsupported: throw TranslationFailure("Unsupported language pair")
            }
            guard generation == token, !closed else { return }
            // Open's isolated world (engine P7, PB4 row 5): the page cannot see or call
            // `window.__openTranslate`; the runtime shares only the DOM with it.
            _ = try await Self.evaluate(page, runtimeSource)
            let started = try await Self.evaluate(page, "window.__openTranslate.start()") as? [String: Any]
            guard generation == token, !closed else { return }
            if userAction || stickyTarget?.host == offer.host { stickyTarget = (offer.host, offer.target) }
            let units = (started?["units"] as? NSNumber)?.intValue ?? 0
            if units == 0 { finishFirstRound(offer, userAction: userAction) }
            runLoop(offer, token: token, userAction: userAction, announced: units == 0)
        } catch {
            guard generation == token, !closed else { return }
            fail(offer, error)
        }
    }

    /// Runs in Open's isolated world; a backend without one (render fakes) uses the page world.
    static func evaluate(_ page: any WebContent, _ script: String) async throws -> Any {
        do { return try await page.evaluateJavaScript(script, in: .open) }
        catch ScriptWorldError.unsupported { return try await page.evaluateJavaScript(script) }
    }

    private func finishFirstRound(_ offer: Offer, userAction: Bool) {
        state = .translated(offer)
        onEvent?(.translated(to: offer.target, userAction: userAction))
    }

    private func runLoop(_ offer: Offer, token: Int, userAction: Bool, announced: Bool) {
        loop = Task { [weak self] in
            // Every exit (the runtime ended, a failure, a newer generation) ends this loop; only
            // the current generation's loop clears the handle, so `isLoopRunning` reads false.
            defer { if let self, self.generation == token { self.loop = nil } }
            var announced = announced
            while let self, !Task.isCancelled, self.generation == token, !self.closed, let page = self.page {
                let raw: Any
                do { raw = try await Self.evaluate(page, "window.__openTranslate ? window.__openTranslate.nextBatch() : null") }
                catch {
                    // The document went away (a new page, a crash, or close): nothing to restore.
                    if self.generation == token, !self.closed { self.loop = nil; self.state = .idle }
                    return
                }
                guard self.generation == token, !self.closed else { return }
                self.batchesPulled += 1
                if raw is NSNull { return }   // restore() ended the runtime
                guard let batch = TranslationBatch(json: raw) else {
                    self.fail(offer, TranslationFailure("Invalid page data")); return
                }
                if !batch.texts.isEmpty {
                    do {
                        let results = try await self.backend.translate(batch.texts, from: offer.source, to: offer.target)
                        guard self.generation == token, !self.closed else { return }
                        guard results.count == batch.texts.count else { throw TranslationFailure("Invalid translation result") }
                        let json = String(decoding: try JSONSerialization.data(withJSONObject: results), as: UTF8.self)
                        let applied = try await Self.evaluate(page, "window.__openTranslate.apply(\(batch.id), \(json))") as? [String: Any]
                        guard self.generation == token, !self.closed else { return }
                        self.batchesApplied += 1
                        self.unitsFallback += (applied?["fallback"] as? NSNumber)?.intValue ?? 0
                    } catch {
                        guard self.generation == token, !self.closed else { return }
                        self.fail(offer, error); return
                    }
                }
                if !announced { announced = true; self.finishFirstRound(offer, userAction: userAction) }
            }
        }
    }

    private func fail(_ offer: Offer, _ error: any Error) {
        let reason = TranslationFailure.reason(for: error)
        stop()
        if let page { Task { _ = try? await Self.evaluate(page, "window.__openTranslate ? window.__openTranslate.restore() : false") } }
        state = .failed(offer, reason: reason)
        onEvent?(.failed(reason: reason))
    }

    /// Show Original: restores the page and ends the same-host automatic translation.
    public func revert(userAction: Bool = true) async {
        guard !closed, let page, let offer = state.offer else { return }
        switch state { case .translating, .translated: break; default: return }
        stop()
        if userAction { stickyTarget = nil }
        state = .offered(offer)
        _ = try? await Self.evaluate(page, "window.__openTranslate ? window.__openTranslate.restore() : false")
        onEvent?(.reverted(to: offer.source, userAction: userAction))
    }

    /// "Never Translate This Site" (§4.7.7): remembers the host, reverts a translated page
    /// without a toast, and hides the offer.
    public func neverTranslateThisSite() async {
        guard !closed, let offer = state.offer else { return }
        preferences.addNeverTranslate(host: offer.host)
        if stickyTarget?.host == offer.host { stickyTarget = nil }
        let wasTranslated: Bool
        switch state { case .translating, .translated: wasTranslated = true; default: wasTranslated = false }
        stop()
        state = .idle
        if wasTranslated, let page { _ = try? await Self.evaluate(page, "window.__openTranslate ? window.__openTranslate.restore() : false") }
    }

    /// The preferences changed (Reset Translated-site Prompts): nothing to do until the next load.
    public func close() {
        guard !closed else { return }
        stop(); closed = true; state = .idle
        onStateChange = nil; onEvent = nil; prepareLanguages = nil
    }

    private func stop() {
        generation += 1
        loop?.cancel(); loop = nil
        detection?.cancel(); detection = nil
    }

    public var isLoopRunning: Bool { loop != nil }
}

public enum TranslateResources {
    public static let runtimeJS: String = load("translate-runtime")

    private final class ResourceAnchor {}
    private static let resourceBundle: Bundle? = {
        // SwiftPM's generated Bundle.module traps if the entire bundle is missing.
        // Preflight its normal locations so a packaging error stays a recoverable error.
        var roots = [Bundle.main.resourceURL, Bundle(for: ResourceAnchor.self).resourceURL, Bundle.main.bundleURL]
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"] ?? ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
            roots.insert(URL(fileURLWithPath: path), at: 0)
        }
        #endif
        guard roots.compactMap({ $0 }).contains(where: { Bundle(url: $0.appendingPathComponent("OpenKit_OpenTranslate.bundle")) != nil }) else { return nil }
        return Bundle.module
    }()

    private static func load(_ name: String) -> String {
        do {
            guard let url = resourceBundle?.url(forResource: name, withExtension: "js") else { throw CocoaError(.fileNoSuchFile) }
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("OpenTranslate: missing resource \(name): \(error)\n".utf8))
            return ""
        }
    }
}
