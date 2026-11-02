import Foundation

/// Copy URL without trackers (Section 2 item 12). Arc's rule, decoded from its main binary (CC-31a in
/// `docs/re/commandbar-completion.md`): the parameter names below are facts read from Arc's static arrays;
/// the logic follows its cleaner (`FUN_100826084` in the shared Ghidra project).
public enum TrackerStripping {
    /// Arc's toasts after Copy URL (main binary strings): something removed, or the URL as it was.
    public static let cleanToast = "Copied a clean link without trackers"
    public static let plainToast = "Copied Current URL"

    /// Query item names that start with any of these are removed (case-sensitive).
    static let prefixes: [String] = [
        "_bta_c", "_bta_tid", "_ga", "_hsenc", "_hsmi", "_ke", "_openstat", "dm_i", "ef_id", "epik", "gclsrc",
        "gdffi", "gdfms", "gdftrk", "hsa_", "igsh", "matomo_", "mc_", "mkwid", "msclkid", "mtm_", "ns_",
        "oly_anon_id", "oly_enc_id", "otc", "pcrid", "piwik_", "pk_", "rb_clickid", "redirect_log_mongo_id",
        "redirect_mongo_id", "ref", "s_kwcid", "sb_referer_host", "soc_src", "soc_trk", "spm", "sr_", "stm_",
        "trk_", "utm_", "vero_",
    ]
    /// Query item names removed when equal (case-sensitive).
    static let names: Set<String> = [
        "cm_mmc", "fbclid", "gad_source", "gclid", "ref", "pla", "spm", "si", "trackingId", "mt", "mcid",
        "linkCode", "srsltid", "ocid", "trk", "ncid", "mtc", "srcid", "nr_email_referer", "_pos", "_sid", "_ss",
        "share_id",
    ]
    struct Site: Sendable {
        let domains: [String]
        let prefixes: [String]
        let names: Set<String>
        let dropsRefPathSegment: Bool
    }
    /// Site rules run before the general lists, in Arc's order.
    static let sites: [Site] = [
        Site(domains: ["twitter.com", "x.com"], prefixes: [], names: ["t", "s"], dropsRefPathSegment: false),
        Site(domains: ["amazon.com"], prefixes: ["_encoding", "ascsubtag", "pd_rd_", "pf", "pf_rd_", "psc", "tag", "ie", "hv"],
             names: ["content-id", "crid", "dib", "dib_tag", "keywords", "qid", "rnid", "s", "sprefix", "th"], dropsRefPathSegment: true),
        Site(domains: ["youtube.com"], prefixes: [], names: ["feature", "app", "embeds_referring_euri", "source_ve_path"], dropsRefPathSegment: false),
        Site(domains: ["ebay.com"], prefixes: [], names: ["_trkparms", "_trksid", "_from", "hash", "_skw", "itmmeta", "itmprp"], dropsRefPathSegment: false),
    ]

    /// The host is `domain` or one of its subdomains.
    static func host(of url: URL, matches domain: String) -> Bool {
        guard let host = url.host() else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }

    /// The URL without tracking parameters, and whether anything was removed. A query that uses `;`
    /// separators is left alone, as is a URL with no query (except an Amazon `/ref=…` path segment).
    public static func clean(_ url: URL) -> (url: URL, changed: Bool) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return (url, false) }
        var items = components.queryItems ?? []
        let rules = sites.filter { site in site.domains.contains { host(of: url, matches: $0) } }
        if items.isEmpty && !rules.contains(where: \.dropsRefPathSegment) { return (url, false) }
        if components.percentEncodedQuery?.contains(";") == true { return (url, false) }
        for site in rules {
            items.removeAll { item in site.names.contains(item.name) || site.prefixes.contains { item.name.hasPrefix($0) } }
            if site.dropsRefPathSegment, let last = url.pathComponents.last, last.hasPrefix("ref=") {
                var path = url.deletingLastPathComponent().path(percentEncoded: true)
                if path.hasSuffix("/") && path.count > 1 { path.removeLast() }
                components.percentEncodedPath = path
            }
        }
        items.removeAll { item in prefixes.contains { item.name.hasPrefix($0) } || names.contains(item.name) }
        components.queryItems = items.isEmpty ? nil : items
        guard let cleaned = components.url else { return (url, false) }
        return (cleaned, cleaned.absoluteString != url.absoluteString)
    }
}
