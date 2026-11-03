import Foundation
import OpenTranslate

/// `openkit lang-detect [--dir DIR]` (page-platform §8.2): runs the real `PageLanguageDetector` over the
/// fixture pages in `tools/e2e/fixtures/page-platform/lang/` and prints the detected language, its
/// confidence and source per page, then the input limits of the page probe and the batch channel
/// (checklist §1: at the limit accepted, one over refused). PASS/FAIL per row.
@MainActor
func runLangDetect(args: [String]) throws {
    var dir = "tools/e2e/fixtures/page-platform/lang"
    if let i = args.firstIndex(of: "--dir"), args.indices.contains(i + 1) { dir = args[i + 1] }
    var passed = 0, failed = 0
    func check(_ ok: Bool, _ label: String) {
        if ok { passed += 1 } else { failed += 1 }
        print("\(ok ? "PASS" : "FAIL") \(label)")
    }
    // file, expected language code, expected source
    let cases: [(String, String, DetectedLanguage.Source)] = [
        ("fr.html", "fr", .recognizer), ("de.html", "de", .recognizer), ("ja.html", "ja", .recognizer),
        ("en.html", "en", .recognizer),
        // 39 characters of menu words: the recognizer stays under 0.80, so the lang attribute decides.
        ("short-fr.html", "fr", .langAttribute),
    ]
    for (file, code, source) in cases {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(file)
        guard let html = try? String(contentsOf: url, encoding: .utf8) else { check(false, "\(file): unreadable at \(url.path)"); continue }
        let probe = langDetectProbe(html: html)
        let result = PageLanguageDetector.detect(probe)
        let shown = result.map { "\($0.code) \(String(format: "%.3f", $0.confidence)) \($0.source.rawValue)" } ?? "none"
        check(result?.code == code && result?.source == source,
              "\(file) (\(probe.text.count) chars, lang=\"\(probe.langAttribute)\"): \(shown); expected \(code) \(source.rawValue)")
    }
    let noLang = PageLanguageDetector.detect(PageLanguageProbe(langAttribute: "", text: "OK · Menu · Login · Info · 2024 · Email"))
    check(noLang == nil, "short text without a lang attribute: no offer (\(noLang?.code ?? "none"))")
    check(PageLanguageDetector.detect(PageLanguageProbe(langAttribute: "x-<script>", text: "")) == nil, "malformed lang attribute refused")

    // Probe limits.
    let maxText = String(repeating: "a", count: PageLanguageDetector.maxProbeCharacters)
    let maxLang = String(repeating: "a", count: PageLanguageDetector.maxLangAttributeLength)
    check(PageLanguageProbe(json: ["lang": maxLang, "text": maxText]) != nil, "probe at the limits (2,000 text, 35 lang) accepted")
    check(PageLanguageProbe(json: ["lang": "fr", "text": maxText + "a"]) == nil, "probe text 2,001 refused")
    check(PageLanguageProbe(json: ["lang": maxLang + "a", "text": ""]) == nil, "probe lang 36 refused")
    check(PageLanguageProbe(json: ["lang": "fr", "text": "", "extra": 1]) == nil, "probe with unknown data refused")

    // Batch limits.
    func batch(_ texts: [String], extra: Bool = false) -> Any {
        var o: [String: Any] = ["id": 1, "units": texts.enumerated().map { ["id": $0.offset + 1, "text": $0.element] }]
        if extra { o["x"] = 1 }
        return o
    }
    let unit = String(repeating: "b", count: 100)
    check(TranslationBatch(json: batch(Array(repeating: unit, count: 40))) != nil, "batch of 40 units, 4,000 characters accepted")
    check(TranslationBatch(json: batch(Array(repeating: "b", count: 41))) == nil, "batch of 41 units refused")
    check(TranslationBatch(json: batch(Array(repeating: unit, count: 39) + [unit + "b"])) == nil, "batch of 4,001 characters refused")
    let long = String(repeating: "c", count: TranslationBatch.maxUnitCharacters)
    check(TranslationBatch(json: batch([long])) != nil, "one unit of 20,000 characters accepted alone")
    check(TranslationBatch(json: batch([long + "c"])) == nil, "one unit of 20,001 characters refused")
    check(TranslationBatch(json: batch(["a"], extra: true)) == nil, "batch with unknown data refused")
    print("lang-detect: \(passed) passed, \(failed) failed")
    if failed > 0 { throw LangDetectFailure() }
}

private struct LangDetectFailure: Error, CustomStringConvertible { var description: String { "lang-detect checks failed" } }

/// The fixture's `lang` attribute and visible text, like the page probe: no script or style text,
/// tags removed, white space collapsed, at most 2,000 characters.
func langDetectProbe(html: String) -> PageLanguageProbe {
    var lang = ""
    if let r = html.range(of: #"<html[^>]*\blang="([^"]*)""#, options: .regularExpression) {
        let tag = String(html[r])
        if let q = tag.range(of: #"lang="[^"]*""#, options: .regularExpression) { lang = String(tag[q].dropFirst(6).dropLast()) }
    }
    var body = html
    if let start = body.range(of: "<body")?.lowerBound { body = String(body[start...]) }
    for pattern in [#"<script[\s\S]*?</script>"#, #"<style[\s\S]*?</style>"#, #"<[^>]+>"#] {
        body = body.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
    }
    body = body.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    let text = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return PageLanguageProbe(langAttribute: lang, text: String(text.prefix(PageLanguageDetector.maxProbeCharacters)))
}
