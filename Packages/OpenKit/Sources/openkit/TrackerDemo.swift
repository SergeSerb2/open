import Foundation
import OpenModel

/// U1–U12 (Section 2 item 12): Copy URL without trackers, Arc's decoded rule (CC-31a), against
/// hand-written expected URLs.
@MainActor
func runTrackerDemo(check: (Bool, String) -> Void) {
    let cases: [(String, String, String, Bool)] = [
        ("U1 utm_ prefix and fbclid go; other parameters stay in order",
         "https://news.example.com/a?id=7&utm_source=x&utm_medium=y&fbclid=abc&page=2", "https://news.example.com/a?id=7&page=2", true),
        ("U2 nothing to remove: the same URL, not changed", "https://example.com/search?q=swift&page=2", "https://example.com/search?q=swift&page=2", false),
        ("U3 no query: unchanged", "https://example.com/path/", "https://example.com/path/", false),
        ("U4 every item removed: no query left", "https://example.com/p?gclid=1&_ga=2&mc_cid=3", "https://example.com/p", true),
        ("U5 names are case-sensitive", "https://example.com/p?UTM_source=1&Fbclid=2", "https://example.com/p?UTM_source=1&Fbclid=2", false),
        ("U6 prefixes match the start of a name (ref → referrer)", "https://example.com/p?referrer=a&q=1", "https://example.com/p?q=1", true),
        ("U7 a query with ; separators is left alone", "https://example.com/p?a=1;utm_source=2", "https://example.com/p?a=1;utm_source=2", false),
        ("U8 x.com and twitter.com subdomains drop t and s", "https://mobile.twitter.com/u/status/1?s=20&t=abc&lang=en", "https://mobile.twitter.com/u/status/1?lang=en", true),
        ("U9 t and s stay on other sites", "https://example.com/p?t=10&s=2", "https://example.com/p?t=10&s=2", false),
        ("U10 Amazon: ref= path segment, tag, pd_rd_ prefix and qid go; keywords too",
         "https://www.amazon.com/dp/B000/ref=sr_1_1?keywords=cable&qid=1&pd_rd_w=x&tag=aff-20&th=1&color=red",
         "https://www.amazon.com/dp/B000?color=red", true),
        ("U11 YouTube: feature and si go, v stays", "https://www.youtube.com/watch?v=abc&feature=share&si=xyz", "https://www.youtube.com/watch?v=abc", true),
        ("U12 eBay: _trksid and hash go", "https://www.ebay.com/itm/1?_trksid=p1&hash=item1&var=2", "https://www.ebay.com/itm/1?var=2", true),
    ]
    for (label, input, expected, changed) in cases {
        let (out, didChange) = TrackerStripping.clean(URL(string: input)!)
        check(out.absoluteString == expected && didChange == changed, "\(label): \(out.absoluteString) changed=\(didChange)")
    }
}
