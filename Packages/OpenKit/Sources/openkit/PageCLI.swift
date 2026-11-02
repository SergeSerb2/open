import Foundation
import OpenModel

/// `openkit url-clean [URL]` (page-platform §8.2): with a URL, prints the cleaned URL and the removed
/// names; without one, runs 30 fixed rows over `URLCleaner` (Arc's decoded rule, RE CC-31a) and prints
/// PASS/FAIL per row. Rows follow the decoded rule's real behavior: names match case-sensitively.
@MainActor
func runURLClean(args: [String]) throws {
    if let raw = args.first {
        guard let url = URL(string: raw) else { throw CLIFailure("not a URL: \(raw)") }
        let (clean, removed) = URLCleaner.clean(url)
        print(clean.absoluteString)
        print("removed: \(removed.isEmpty ? "-" : removed.joined(separator: " "))")
        print("toast: \(URLCleaner.toastTitle(removed: removed))")
        return
    }
    // (label, input, expected output, expected removed names)
    let rows: [(String, String, String, [String])] = [
        ("global prefix utm_ goes, other items stay", "https://news.example.com/a?id=7&utm_source=x&utm_medium=y",
         "https://news.example.com/a?id=7", ["utm_source", "utm_medium"]),
        ("global name fbclid", "https://example.com/p?fbclid=abc&q=1", "https://example.com/p?q=1", ["fbclid"]),
        ("only tracking items: the ? goes too", "https://shop.example.com/?gclid=1&gad_source=2", "https://shop.example.com/", ["gclid", "gad_source"]),
        ("msclkid", "https://example.com/?msclkid=9&x=1", "https://example.com/?x=1", ["msclkid"]),
        ("HubSpot _hsenc, _hsmi, hsa_ prefix", "https://blog.example.com/post?_hsenc=a&_hsmi=b&hsa_cam=c",
         "https://blog.example.com/post", ["_hsenc", "_hsmi", "hsa_cam"]),
        ("Matomo and Piwik prefixes", "https://example.com/?pk_campaign=a&mtm_source=b&matomo_kwd=c&piwik_x=d&page=3",
         "https://example.com/?page=3", ["pk_campaign", "mtm_source", "matomo_kwd", "piwik_x"]),
        ("Mailchimp mc_ prefix", "https://example.com/?mc_cid=1&mc_eid=2", "https://example.com/", ["mc_cid", "mc_eid"]),
        ("Instagram igsh prefix (igshid too)", "https://www.instagram.com/p/abc/?igsh=xyz&igshid=1",
         "https://www.instagram.com/p/abc/", ["igsh", "igshid"]),
        ("_ga goes; _gl is not in the rule and stays", "https://example.com/?_ga=2.1&_gl=1", "https://example.com/?_gl=1", ["_ga"]),
        ("Google Shopping srsltid", "https://example.com/item?srsltid=AfmBO&id=1", "https://example.com/item?id=1", ["srsltid"]),
        ("fragment kept", "https://example.com/doc?utm_campaign=x&id=2#section-3", "https://example.com/doc?id=2#section-3", ["utm_campaign"]),
        ("order of kept items kept", "https://example.com/?b=2&utm_term=x&a=1&c=3", "https://example.com/?b=2&a=1&c=3", ["utm_term"]),
        ("names are case-sensitive (mixed case stays)", "https://example.com/?UTM_Source=x&FBCLID=y", "https://example.com/?UTM_Source=x&FBCLID=y", []),
        ("nothing to remove: unchanged", "https://example.com/search?q=swift&page=2", "https://example.com/search?q=swift&page=2", []),
        ("no query: unchanged", "https://example.com/path/", "https://example.com/path/", []),
        ("a query with ; separators is left alone", "https://example.com/p?a=1;utm_source=2", "https://example.com/p?a=1;utm_source=2", []),
        ("file URL unchanged (http(s) only)", "file:///tmp/page.html?utm_source=x", "file:///tmp/page.html?utm_source=x", []),
        ("plain http is cleaned too", "http://example.com/?utm_source=x&a=1", "http://example.com/?a=1", ["utm_source"]),
        ("kept values keep their encoding (%2B stays)", "https://example.com/s?q=a%2Bb&utm_source=x", "https://example.com/s?q=a%2Bb", ["utm_source"]),
        ("encoded names compare decoded", "https://example.com/?utm%5Fsource=x&q=1", "https://example.com/?q=1", ["utm_source"]),
        ("prefix ref matches referrer", "https://example.com/p?referrer=a&q=1", "https://example.com/p?q=1", ["referrer"]),
        ("x.com drops t and s", "https://x.com/u/status/1?s=20&t=abc", "https://x.com/u/status/1", ["s", "t"]),
        ("twitter.com subdomain drops s, keeps lang", "https://mobile.twitter.com/u/status/1?s=20&lang=en",
         "https://mobile.twitter.com/u/status/1?lang=en", ["s"]),
        ("t and s stay on other sites", "https://example.com/p?t=10&s=2", "https://example.com/p?t=10&s=2", []),
        ("Amazon: site names and prefixes, ref= path segment",
         "https://www.amazon.com/dp/B000/ref=sr_1_1?keywords=cable&qid=1&pd_rd_w=x&tag=aff-20&color=red",
         "https://www.amazon.com/dp/B000?color=red", ["keywords", "qid", "pd_rd_w", "tag", "ref=sr_1_1"]),
        ("Amazon ref= path segment without a query", "https://www.amazon.com/dp/B000/ref=cm_sw", "https://www.amazon.com/dp/B000", ["ref=cm_sw"]),
        ("Amazon names stay on other sites", "https://example.com/p?tag=x&th=1&keywords=a", "https://example.com/p?tag=x&th=1&keywords=a", []),
        ("YouTube feature and si go, v stays", "https://www.youtube.com/watch?v=abc&feature=share&si=xyz",
         "https://www.youtube.com/watch?v=abc", ["feature", "si"]),
        ("youtu.be si goes, the t timestamp stays", "https://youtu.be/abc?si=xyz&t=42", "https://youtu.be/abc?t=42", ["si"]),
        ("eBay _trksid and hash", "https://www.ebay.com/itm/1?_trksid=p1&hash=item1&var=2", "https://www.ebay.com/itm/1?var=2", ["_trksid", "hash"]),
    ]
    var passed = 0, failed = 0
    for (index, row) in rows.enumerated() {
        let (label, input, expected, removedNames) = row
        guard let url = URL(string: input) else { failed += 1; print("FAIL UC\(index + 1) \(label): bad input"); continue }
        let (out, removed) = URLCleaner.clean(url)
        let ok = out.absoluteString == expected && removed == removedNames
        if ok { passed += 1 } else { failed += 1 }
        print("\(ok ? "PASS" : "FAIL") UC\(index + 1) \(label): \(out.absoluteString) removed=[\(removed.joined(separator: ","))]")
    }
    print("url-clean: \(passed) passed, \(failed) failed")
    if failed > 0 || rows.count != 30 { throw CLIFailure("url-clean rows failed") }
}

struct CLIFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
