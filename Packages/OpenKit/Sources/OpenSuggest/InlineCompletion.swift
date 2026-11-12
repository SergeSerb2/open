import Foundation

/// Inline autocomplete: the rest of row 1's host (or URL) appended to the typed text in the field
/// (docs/plans/commandbar-completion.md §4.1; Arc CC-1…CC-7, CC-40). OpenSuggest decides which row
/// completes and the text; the command bar owns the field, the selection, and the key rules.
public struct InlineCompletion: Sendable, Hashable {
    /// The row that completes. Always row 1, the top hit (CC-4, D2).
    public var rowID: String
    /// The whole field text: the typed lead (scheme, "www.") plus the candidate, in the candidate's
    /// letter case (CC-6).
    public var fieldText: String
    /// UTF-16 length of the typed part of `fieldText`. The completion is `[typedLength, end)`.
    public var typedLength: Int

    public init(rowID: String, fieldText: String, typedLength: Int) {
        self.rowID = rowID; self.fieldText = fieldText; self.typedLength = typedLength
    }

    /// Longest field text a completion may write, in UTF-16 units: the field's own cap.
    public static let maxFieldLength = 2_048

    /// The completion of `typed` toward `url` (§4.1.2), or nil.
    ///
    /// - Only http and https pages complete.
    /// - A leading `https://` or `http://`, then `www.`, is the lead; it stays as typed.
    /// - Text without `/`, `?`, or `#` completes only to the host (plus a non-default port): a whole
    ///   host never completes to a deeper path (CC-7). guess: host-only (CC-1, CC-7 show root hosts).
    ///   Text with one of them completes to the URL without scheme, "www.", fragment, or a root "/".
    /// - The candidate must start with the typed body (folded: case and diacritics) and be longer.
    /// - Whitespace anywhere means no completion.
    /// - The field text stays within `maxFieldLength`.
    public static func text(typed: String, url: URL) -> (fieldText: String, typedLength: Int)? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              !typed.contains(where: \.isWhitespace) else { return nil }
        var rest = Substring(typed)
        var lead = ""
        for prefix in ["https://", "http://"] where rest.lowercased().hasPrefix(prefix) {
            lead += rest.prefix(prefix.count); rest = rest.dropFirst(prefix.count)
            break
        }
        if rest.lowercased().hasPrefix("www.") { lead += rest.prefix(4); rest = rest.dropFirst(4) }
        let body = String(rest)
        guard !body.isEmpty else { return nil }
        var candidate: String
        if body.contains(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            candidate = TextMatching.matchableURL(url)
            if candidate.hasSuffix("/"), candidate.dropLast().firstIndex(of: "/") == nil { candidate.removeLast() }
        } else {
            candidate = TextMatching.displayHost(url)
            if let port = url.port, port != (scheme == "https" ? 443 : 80) { candidate += ":\(port)" }
        }
        // The field caps text at 2,048 characters (CommandBarFieldEditor.normalized); a longer URL never completes.
        guard candidate.count > body.count, lead.utf16.count + candidate.utf16.count <= maxFieldLength else { return nil }
        let typedPart = candidate.prefix(body.count)
        guard TextMatching.fold(typedPart) == TextMatching.fold(body) else { return nil }
        return (lead + candidate, (lead + typedPart).utf16.count)
    }

    /// Row kinds that may complete: open tabs (split panes included) and history (§4.1.2 rule 1).
    static func canComplete(_ s: Suggestion) -> Bool {
        s.kind == .switchToTab || s.kind == .history
    }

    /// The completion for `row`, when the input allows one.
    static func make(for row: Suggestion, input: SuggestInput) -> InlineCompletion? {
        guard allowed(input), canComplete(row), let url = row.url,
              let (fieldText, typedLength) = text(typed: input.rawText, url: url) else { return nil }
        return InlineCompletion(rowID: row.id, fieldText: fieldText, typedLength: typedLength)
    }

    /// §4.1.1 rules 1, 2 (`allowsInlineCompletion`, from the bar) and 4: new tab or edit mode with no
    /// scope, and typed text that is not empty and has no whitespace.
    static func allowed(_ input: SuggestInput) -> Bool {
        input.context.allowsInlineCompletion && input.siteSearch == nil && input.context.extensionScopeID == nil
            && (input.context.mode == .newTab || input.context.mode == .editCurrentURL)
            && !input.rawText.isEmpty && !input.rawText.contains(where: \.isWhitespace)
    }
}
