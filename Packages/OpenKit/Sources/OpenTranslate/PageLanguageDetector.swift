import Foundation
import NaturalLanguage

/// What the page probe returns (§4.7.2 step 2): the `lang` attribute and the first
/// 2,000 characters of the body text.
public struct PageLanguageProbe: Sendable, Equatable {
    public var langAttribute: String
    public var text: String
    public init(langAttribute: String, text: String) { self.langAttribute = langAttribute; self.text = text }

    /// Parses the probe script's result. Refuses anything but `{lang: String, text: String}` within the
    /// limits (the page controls both values); the script itself already cuts them.
    public init?(json: Any) {
        guard let object = json as? [String: Any], object.count == 2,
              let lang = object["lang"] as? String, let text = object["text"] as? String,
              lang.utf16.count <= PageLanguageDetector.maxLangAttributeLength,
              text.utf16.count <= PageLanguageDetector.maxProbeCharacters else { return nil }
        self.init(langAttribute: lang, text: text)
    }
}

public struct DetectedLanguage: Sendable, Equatable {
    public enum Source: String, Sendable { case recognizer, langAttribute }
    public var language: Locale.Language
    /// The recognizer's probability for `language`; 0 when the `lang` attribute decided.
    public var confidence: Double
    public var source: Source
    public var code: String { language.languageCode?.identifier ?? language.minimalIdentifier }
}

/// Detects a page's language on device (§4.7.2, D-2): `NLLanguageRecognizer` over the probe text,
/// else the page's `lang` attribute.
public enum PageLanguageDetector {
    public static let maxProbeCharacters = 2_000
    /// BCP 47 tags are short; anything longer is not a language tag.
    public static let maxLangAttributeLength = 35
    /// guess (§4.7.2 step 3): below this the `lang` attribute decides.
    public static let minimumConfidence = 0.80

    /// Runs in the page's main world. A text walk, not `innerText`: it stops after
    /// `maxProbeCharacters` and forces no layout, so a huge page costs the same as a small one.
    public static let probeScript = """
    (() => {
      const max = \(maxProbeCharacters), skip = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','TEXTAREA','CODE','PRE']);
      let text = '';
      const root = document.body;
      if (root) {
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, { acceptNode(n) {
          for (let e = n.parentElement; e && e !== root; e = e.parentElement) { if (skip.has(e.tagName)) return NodeFilter.FILTER_REJECT; }
          return /\\S/.test(n.data) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT; } });
        for (let n = walker.nextNode(); n && text.length < max; n = walker.nextNode()) text += n.data.replace(/\\s+/g, ' ').trim() + ' ';
      }
      const lang = (document.documentElement.getAttribute('lang') || '').trim();
      return { lang: lang.length <= \(maxLangAttributeLength) ? lang : '', text: text.slice(0, max) };
    })()
    """

    public static func detect(_ probe: PageLanguageProbe) -> DetectedLanguage? {
        let text = String(probe.text.prefix(maxProbeCharacters))
        if !text.isEmpty {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            if let top = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
               top.value >= minimumConfidence, top.key != .undetermined {
                return DetectedLanguage(language: Locale.Language(identifier: top.key.rawValue), confidence: top.value, source: .recognizer)
            }
        }
        let tag = probe.langAttribute.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty, tag.utf16.count <= maxLangAttributeLength,
              tag.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        let language = Locale.Language(identifier: tag)
        guard let code = language.languageCode?.identifier, code.count >= 2, code.count <= 3, code != "und" else { return nil }
        return DetectedLanguage(language: language, confidence: 0, source: .langAttribute)
    }

    /// Same language for translation purposes: the language code, plus the script when both
    /// name one (Simplified and Traditional Chinese differ).
    public static func sameLanguage(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        guard a.languageCode == b.languageCode else { return false }
        guard let sa = a.script, let sb = b.script else { return true }
        return sa == sb
    }

    /// §4.7.2 step 4: the first preferred language the backend can translate into from `source`.
    /// Nil when that language is the source language, or nothing is supported.
    @MainActor
    public static func target(for source: Locale.Language, preferred: [String], backend: any TranslationBackend) async -> Locale.Language? {
        for identifier in preferred.prefix(8) {
            let target = Locale.Language(identifier: identifier)
            if sameLanguage(source, target) { return nil }
            switch await backend.status(from: source, to: target) {
            case .installed, .supported: return target
            case .unsupported: continue
            }
        }
        return nil
    }

    /// Display name in the user's locale ("English", "French").
    public static func displayName(_ language: Locale.Language, locale: Locale = .current) -> String {
        // The script names a different written language only for Chinese ("Chinese, Simplified");
        // "en-CA" is "English", not "English (Latin)".
        if let code = language.languageCode, code.identifier == "zh", let script = language.script,
           let name = locale.localizedString(forIdentifier: "zh-\(script.identifier)") { return name }
        if let code = language.languageCode, let name = locale.localizedString(forLanguageCode: code.identifier) { return name }
        return language.minimalIdentifier
    }
}
