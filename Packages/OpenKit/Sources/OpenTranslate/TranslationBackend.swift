import AppKit
import Foundation
import SwiftUI
import Translation

public enum TranslationPairStatus: Sendable, Equatable {
    /// Language assets are on this Mac; translation needs no prompt and no network.
    case installed
    /// The pair works after macOS downloads its assets (it asks the user first, on a user action).
    case supported
    case unsupported
}

/// Translates batches of text units. Open's backends run on device (D-2): no Google service, no key.
@MainActor
public protocol TranslationBackend: AnyObject {
    func status(from source: Locale.Language, to target: Locale.Language) async -> TranslationPairStatus
    /// Every language a page can be translated into, for "Choose Another Language".
    func supportedLanguages() async -> [Locale.Language]
    /// One result per input, in order.
    func translate(_ texts: [String], from source: Locale.Language, to target: Locale.Language) async throws -> [String]
}

public struct TranslationFailure: LocalizedError, Sendable, Equatable {
    public var reason: String
    public init(_ reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }

    /// The "<reason>" of the toast "Translation error (<reason>)" (PG-1.11).
    public static func reason(for error: any Error) -> String {
        if let failure = error as? TranslationFailure { return failure.reason }
        if let localized = error as? LocalizedError {
            if let reason = localized.failureReason, !reason.isEmpty { return reason }
            if let description = localized.errorDescription, !description.isEmpty { return description }
        }
        return error.localizedDescription
    }
}

/// Apple's `Translation` framework (§4.7.5). One session per (source, target) pair, reused.
@MainActor
public final class AppleTranslationBackend: TranslationBackend {
    private var sessions: [String: TranslationSession] = [:]
    private var cachedSupported: [Locale.Language]?
    private var preparing: [NSView] = []

    public init() {}

    private static func key(_ s: Locale.Language, _ t: Locale.Language) -> String { "\(s.maximalIdentifier)>\(t.maximalIdentifier)" }

    public func status(from source: Locale.Language, to target: Locale.Language) async -> TranslationPairStatus {
        switch await Self.pairStatus(source, target) {
        case .installed: return .installed
        case .supported: return .supported
        default: return .unsupported
        }
    }

    public func supportedLanguages() async -> [Locale.Language] {
        if let cachedSupported { return cachedSupported }
        let list = await Self.languages()
        cachedSupported = list
        return list
    }

    public func translate(_ texts: [String], from source: Locale.Language, to target: Locale.Language) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        let key = Self.key(source, target)
        let session = sessions[key] ?? TranslationSession(installedSource: source, target: target)
        sessions[key] = session
        do {
            let responses = try await Self.run(SessionBox(session: session), texts)
            var out = texts
            for response in responses {
                if let id = response.clientIdentifier.flatMap(Int.init), out.indices.contains(id) { out[id] = response.targetText }
            }
            return out
        } catch {
            // A failed session (assets removed, cancelled) is not reused.
            sessions[key] = nil
            throw error
        }
    }

    // `LanguageAvailability` is not `Sendable`: each query makes its own, off the main actor.
    nonisolated private static func pairStatus(_ s: Locale.Language, _ t: Locale.Language) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: s, to: t)
    }
    nonisolated private static func languages() async -> [Locale.Language] { await LanguageAvailability().supportedLanguages }

    /// `TranslationSession` is not `Sendable`; Apple documents it as safe to call from any task.
    /// It is only touched here and on the main actor, one call at a time per pair.
    private struct SessionBox: @unchecked Sendable { let session: TranslationSession }
    nonisolated private static func run(_ box: SessionBox, _ texts: [String]) async throws -> [TranslationSession.Response] {
        let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        return try await box.session.translations(from: requests)
    }

    /// The pair is `.supported` but not installed (§4.7.5): a zero-size SwiftUI host with
    /// `.translationTask` in `container` (the popover) calls `prepareTranslation()`, which shows
    /// macOS's download prompt. Only ever called from a user action. This is the only SwiftUI
    /// in the feature.
    public func prepare(from source: Locale.Language, to target: Locale.Language, in container: NSView) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = PrepareResult(continuation)
            let host = NSHostingView(rootView: PrepareView(configuration: .init(source: source, target: target), done: once))
            host.frame = .zero
            container.addSubview(host)
            preparing.append(host)
            once.cleanup = { [weak self, weak host] in
                host?.removeFromSuperview()
                self?.preparing.removeAll { $0 === host }
            }
        }
    }
}

@MainActor
private final class PrepareResult {
    private var continuation: CheckedContinuation<Void, any Error>?
    var cleanup: (() -> Void)?
    init(_ continuation: CheckedContinuation<Void, any Error>) { self.continuation = continuation }
    func finish(_ error: (any Error)?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        // The SwiftUI task ends with this call; remove its host on the next turn.
        let cleanup = cleanup; self.cleanup = nil
        DispatchQueue.main.async { cleanup?() }
    }
}

private struct PrepareView: View {
    let configuration: TranslationSession.Configuration
    let done: PrepareResult
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .translationTask(configuration) { session in
                let box = PrepareBox(session: session)
                do { try await Self.prepare(box); done.finish(nil) } catch { done.finish(error) }
            }
            .onDisappear { done.finish(TranslationFailure("Cancelled")) }
    }
    /// See `AppleTranslationBackend.SessionBox`.
    struct PrepareBox: @unchecked Sendable { let session: TranslationSession }
    nonisolated static func prepare(_ box: PrepareBox) async throws { try await box.session.prepareTranslation() }
}

/// A deterministic backend for the automation build and the offscreen harnesses only: French to
/// English with a fixed word list that covers `tools/e2e/fixtures/page-platform/fr*.html`.
/// It lets the e2e suite run the whole pipeline (runtime, batches, revert, undo) on a Mac without
/// Apple's language assets, where `AppleTranslationBackend` would need macOS's download prompt
/// (page-platform §8.4 U-X1). It never touches the network. Units whose text has the word
/// "parfois" come back without their inline markers, like a translator that drops them (R-3),
/// so the per-node fallback runs too.
@MainActor
public final class FixtureTranslationBackend: TranslationBackend {
    public static let words: [String: String] = [
        "bonjour": "hello", "le": "the", "la": "the", "les": "the", "un": "a", "une": "a", "des": "some",
        "de": "of", "du": "of the", "et": "and", "est": "is", "sont": "are", "ce": "this", "cette": "this",
        "ceci": "this", "page": "page", "texte": "text", "en": "in", "français": "French", "monde": "world",
        "nous": "we", "vous": "you", "il": "he", "elle": "she", "avec": "with", "pour": "for", "dans": "in",
        "sur": "on", "très": "very", "important": "important", "importante": "important", "phrase": "sentence",
        "première": "first", "deuxième": "second", "troisième": "third", "paragraphe": "paragraph",
        "envoyer": "send", "rechercher": "search", "votre": "your", "adresse": "address", "nom": "name",
        "nouveau": "new", "nouvelle": "new", "ajouté": "added", "après": "after", "seconde": "second",
        "parfois": "sometimes", "mot": "word", "mots": "words", "gras": "bold", "italique": "italic",
        "lire": "read", "plus": "more", "chat": "cat", "chien": "dog", "maison": "house", "jardin": "garden",
        "petit": "small", "petite": "small", "grand": "big", "grande": "big", "aujourd'hui": "today",
        "beau": "nice", "temps": "weather", "fait": "makes",
        "ne": "not", "pas": "not", "traduire": "translate", "jamais": "never", "titre": "title",
        "bouton": "button", "image": "picture", "lien": "link", "contenu": "content", "dynamique": "dynamic",
    ]
    public static let source = Locale.Language(identifier: "fr")
    public static let target = Locale.Language(identifier: "en")
    public private(set) var translatedUnits = 0
    public private(set) var batches = 0

    public init() {}

    public func status(from source: Locale.Language, to target: Locale.Language) async -> TranslationPairStatus {
        PageLanguageDetector.sameLanguage(source, Self.source) && PageLanguageDetector.sameLanguage(target, Self.target) ? .installed : .unsupported
    }
    public func supportedLanguages() async -> [Locale.Language] { [Self.source, Self.target] }

    public func translate(_ texts: [String], from source: Locale.Language, to target: Locale.Language) async throws -> [String] {
        guard await status(from: source, to: target) == .installed else { throw TranslationFailure("Unsupported language pair") }
        batches += 1; translatedUnits += texts.count
        return texts.map(Self.translateText)
    }

    static func translateText(_ text: String) -> String {
        var out = ""
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            let lower = word.lowercased()
            var mapped = words[lower] ?? word
            if word.first?.isUppercase == true, let first = mapped.first { mapped = first.uppercased() + mapped.dropFirst() }
            out += mapped; word = ""
        }
        for ch in text {
            if ch.isLetter || ch == "'" { word.append(ch) } else { flush(); out.append(ch) }
        }
        flush()
        if text.lowercased().contains("parfois"), out.contains("⟦") {
            out = out.replacingOccurrences(of: "⟦[^⟧]*⟧", with: "", options: .regularExpression)
        }
        return out
    }
}
