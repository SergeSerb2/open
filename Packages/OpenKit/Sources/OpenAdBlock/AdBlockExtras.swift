import Foundation

/// Cosmetic rules the engine does not apply (docs/plans/adblock-fork.md lead ruling 6: the fork
/// keeps plain CSS hiding only), delivered by the App as document-start user scripts through
/// OpenEngine (PB2 row 1, LEAD 08:50):
/// - `example.com##selector:style(declarations)` — a style rule (sanitized as §8.5 designs it);
/// - `example.com##+js(name, args…)` — a scriptlet from Open's own library (`AdBlockScriptlets`);
/// - `example.com#@#+js(name, args…)` / `example.com#@#+js()` — scriptlet exceptions.
/// Plain `:has()` needs nothing here: the engine keeps it as a hide selector.
///
/// Every rule needs at least one plain domain (no generic scriptlets or styles, no entity
/// `name.*` domains). Limits: lines over 4 KiB are skipped; at most `maxRules` rules are kept;
/// each scriptlet takes at most 16 arguments of at most 1 KiB.
public struct AdBlockExtraRules: Sendable, Equatable {
    public static let maxRules = 20_000
    public static let maxLine = 4_096

    public struct Domains: Sendable, Equatable, Hashable {
        public var include: [String]
        public var exclude: [String]
        public func matches(_ host: String) -> Bool {
            func hit(_ d: String) -> Bool { host == d || host.hasSuffix("." + d) }
            return include.contains(where: hit) && !exclude.contains(where: hit)
        }
    }
    public struct Scriptlet: Sendable, Equatable, Hashable {
        public var name: String
        public var args: [String]
        public var key: String { ([name] + args).joined(separator: "\u{1}") }
    }
    public struct StyleRule: Sendable, Equatable, Hashable {
        public var selector: String
        public var declarations: String
        public var css: String { "\(selector){\(declarations)}" }
    }
    public var scriptlets: [(domains: Domains, scriptlet: Scriptlet)] = []
    public var styles: [(domains: Domains, rule: StyleRule)] = []
    /// Exceptions: an empty key disables every scriptlet on those domains.
    public var exceptions: [(domains: Domains, key: String)] = []
    public var skipped = 0

    public init() {}

    public static func == (a: AdBlockExtraRules, b: AdBlockExtraRules) -> Bool {
        a.scriptlets.map { "\($0.domains)\($0.scriptlet)" } == b.scriptlets.map { "\($0.domains)\($0.scriptlet)" }
            && a.styles.map { "\($0.domains)\($0.rule)" } == b.styles.map { "\($0.domains)\($0.rule)" }
            && a.exceptions.map { "\($0.domains)\($0.key)" } == b.exceptions.map { "\($0.domains)\($0.key)" }
    }

    var count: Int { scriptlets.count + styles.count + exceptions.count }

    /// Reads the live list files (call off the main thread). Unreadable files are skipped.
    public static func load(files: [URL]) -> AdBlockExtraRules {
        var rules = AdBlockExtraRules()
        for file in files {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
            // Most lines carry neither syntax: skip lists that have none at all.
            guard data.range(of: Data("+js(".utf8)) != nil || data.range(of: Data(":style(".utf8)) != nil else { continue }
            rules.add(listText: String(decoding: data, as: UTF8.self))
        }
        return rules
    }

    /// Reads one list's text and adds its extra rules.
    public mutating func add(listText text: String) {
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            if count >= Self.maxRules { return }
            // Cheap prefilter: only lines with either syntax reach the parser.
            guard line.contains("+js(") || line.contains(":style(") else { continue }
            addLine(String(line))
        }
    }

    mutating func addLine(_ raw: String) {
        guard raw.utf8.count <= Self.maxLine else { skipped += 1; return }
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[") else { return }
        if let r = line.range(of: "#@#+js(") {
            guard let domains = Self.domains(String(line[..<r.lowerBound])), line.hasSuffix(")") else { skipped += 1; return }
            let body = String(line[r.upperBound..<line.index(before: line.endIndex)])
            if body.trimmingCharacters(in: .whitespaces).isEmpty { exceptions.append((domains, "")); return }
            guard let call = Self.scriptlet(body) else { skipped += 1; return }
            exceptions.append((domains, call.key)); return
        }
        if let r = line.range(of: "##+js(") {
            guard let domains = Self.domains(String(line[..<r.lowerBound])), line.hasSuffix(")"),
                  let call = Self.scriptlet(String(line[r.upperBound..<line.index(before: line.endIndex)])),
                  AdBlockScriptlets.canonical(call.name) != nil else { skipped += 1; return }
            scriptlets.append((domains, call)); return
        }
        guard let r = line.range(of: "##"), line.hasSuffix(")"), let style = line.range(of: ":style(", options: .backwards),
              style.lowerBound > r.upperBound else { return }
        guard let domains = Self.domains(String(line[..<r.lowerBound])) else { skipped += 1; return }
        let selector = String(line[r.upperBound..<style.lowerBound]).trimmingCharacters(in: .whitespaces)
        let declarations = String(line[style.upperBound..<line.index(before: line.endIndex)])
        guard let s = Self.safeSelector(selector), let d = Self.safeDeclarations(declarations) else { skipped += 1; return }
        styles.append((domains, StyleRule(selector: s, declarations: d)))
    }

    /// `a.com,~b.a.com` → include/exclude. Entity (`name.*`), wildcard or non-ASCII domains are
    /// skipped; a rule with no plain include domain is refused (no generic rules).
    static func domains(_ text: String) -> Domains? {
        var include: [String] = [], exclude: [String] = []
        for part in text.split(separator: ",") {
            var d = part.trimmingCharacters(in: .whitespaces).lowercased()
            let negated = d.hasPrefix("~")
            if negated { d.removeFirst() }
            guard !d.isEmpty, d.count <= 253, !d.hasSuffix(".*"), !d.contains("*"), !d.contains("/"),
                  d.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-") }) else { continue }
            if negated { exclude.append(d) } else { include.append(d) }
        }
        return include.isEmpty ? nil : Domains(include: include, exclude: exclude)
    }

    /// `name, arg1, 'arg, 2'` → name and arguments (commas escape with `\,`; one level of
    /// matching quotes is removed).
    static func scriptlet(_ body: String) -> Scriptlet? {
        var parts: [String] = [], current = "", escaped = false
        for ch in body {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "," { parts.append(current); current = ""; continue }
            current.append(ch)
        }
        parts.append(current)
        let cleaned = parts.map { p -> String in
            let t = p.trimmingCharacters(in: .whitespaces)
            if t.count >= 2, let f = t.first, f == t.last, f == "'" || f == "\"" { return String(t.dropFirst().dropLast()) }
            return t
        }
        guard let name = cleaned.first, !name.isEmpty, cleaned.count <= 17, cleaned.allSatisfy({ $0.utf8.count <= 1_024 }) else { return nil }
        return Scriptlet(name: name, args: Array(cleaned.dropFirst()))
    }

    /// A selector that cannot leave its rule: no braces, `<`, `@`, comments, newlines, unbalanced
    /// brackets or quotes, and none of the procedural operators the engine also refuses.
    static func safeSelector(_ s: String) -> String? {
        guard !s.isEmpty, s.utf8.count <= 1_024 else { return nil }
        for bad in ["{", "}", "<", "@", "/*", "*/", "\n", "\r", "\\", ":has-text(", ":xpath(", ":upward(", ":matches-",
                    ":min-text-length(", ":watch-attr(", ":others(", ":remove(", ":-abp-", ":-ext-", ":contains("] where s.contains(bad) { return nil }
        var depth = 0, bracket = 0, quote: Character? = nil
        for ch in s {
            if let q = quote { if ch == q { quote = nil }; continue }
            switch ch {
            case "\"", "'": quote = ch
            case "(": depth += 1
            case ")": depth -= 1; if depth < 0 { return nil }
            case "[": bracket += 1
            case "]": bracket -= 1; if bracket < 0 { return nil }
            default: break
            }
        }
        return depth == 0 && bracket == 0 && quote == nil ? s : nil
    }

    /// §8.5: refuse `url(`, `image(`, `image-set(`, `cross-fade(`, `element(`, `attr(`,
    /// `expression(`, `\`, comments, braces, `@`, `<` and quotes; then every declaration gets
    /// `!important` so it wins over the page.
    static func safeDeclarations(_ d: String) -> String? {
        let lower = d.lowercased()
        guard !d.isEmpty, d.utf8.count <= 1_024 else { return nil }
        for bad in ["url(", "image(", "image-set(", "cross-fade(", "element(", "attr(", "expression(", "\\", "/*",
                    "{", "}", "@", "<", "\"", "'"] where lower.contains(bad) { return nil }
        let parts = d.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty, parts.allSatisfy({ $0.contains(":") }) else { return nil }
        return parts.map { $0.lowercased().hasSuffix("!important") ? $0 : $0 + " !important" }.joined(separator: ";")
    }

    // MARK: Delivery plan

    /// One user script per include domain: the rules that name it, minus excluded sites.
    public struct Plan: Sendable, Equatable {
        public var domain: String
        public var patterns: [String]
        /// Main world, document start: the scriptlets (with their exceptions applied in the page).
        public var scriptletSource: String?
        /// A user stylesheet: the `:style()` rules with no `~domain` exception.
        public var styleSheet: String?
        /// Open's isolated world, document start: `:style()` rules that need a host check.
        public var styleSource: String?
    }

    /// `excludedSites`: sites (registrable domains) where blocking is off; their rules go.
    /// Caps: at most 5,000 domains and 8 MiB of script source in total.
    public func plans(excludedSites: Set<String>) -> [Plan] {
        func excluded(_ d: String) -> Bool { excludedSites.contains { d == $0 || d.hasSuffix("." + $0) } }
        func related(_ a: String, _ b: String) -> Bool { a == b || a.hasSuffix("." + b) || b.hasSuffix("." + a) }
        // A rule goes into the scripts of its top-most include domains only (`*://*.a.com/*` also
        // covers `b.a.com`), so it never runs twice on one page; the page re-checks the host.
        func roots(_ d: Domains) -> [String] { d.include.filter { i in !d.include.contains { i.hasSuffix("." + $0) } } }
        var calls: [String: [(domains: Domains, scriptlet: Scriptlet)]] = [:]
        var sheets: [String: [(domains: Domains, rule: StyleRule)]] = [:]
        for s in scriptlets { for d in roots(s.domains) { calls[d, default: []].append(s) } }
        for s in styles { for d in roots(s.domains) { sheets[d, default: []].append(s) } }
        var out: [Plan] = [], bytes = 0
        for domain in Set(calls.keys).union(sheets.keys).sorted() where !excluded(domain) {
            guard out.count < 5_000, bytes < 8 << 20 else { break }
            var plan = Plan(domain: domain, patterns: ["*://*.\(domain)/*"])
            if let c = calls[domain] {
                let ex = exceptions.filter { $0.domains.include.contains { related($0, domain) } }
                plan.scriptletSource = AdBlockScriptlets.source(calls: c, exceptions: ex)
            }
            if let sheet = sheets[domain] {
                let plain = sheet.filter { $0.domains.exclude.isEmpty }, gated = sheet.filter { !$0.domains.exclude.isEmpty }
                if !plain.isEmpty { plan.styleSheet = plain.map { $0.rule.css }.joined(separator: "\n") }
                if !gated.isEmpty { plan.styleSource = AdBlockScriptlets.styleSource(gated) }
            }
            bytes += (plan.scriptletSource?.utf8.count ?? 0) + (plan.styleSource?.utf8.count ?? 0) + (plan.styleSheet?.utf8.count ?? 0)
            out.append(plan)
        }
        return out
    }
}
