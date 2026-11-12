import Foundation
import OpenEasel

/// Link-card metadata (og:title, og:description / description, og:image, <title>) for a
/// pasted or dropped address. An ephemeral session (no cookies, no cache on disk); the page is
/// read up to 1 MiB and the picture up to `EaselStore.maxImageBytes`; 10 s timeout each.
enum EaselLinkFetcher {
  static let maxPageBytes = 1 << 20
  struct Metadata: Sendable { var title: String?; var summary: String?; var image: URL? }

  static func fetch(_ url: URL) async -> (Metadata, Data?) {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 10
    config.httpAdditionalHeaders = ["Accept": "text/html,application/xhtml+xml"]
    let session = URLSession(configuration: config)
    defer { session.finishTasksAndInvalidate() }
    guard let html = await read(url, session: session, limit: maxPageBytes) else { return (Metadata(), nil) }
    let page = String(decoding: html, as: UTF8.self)
    var meta = parse(page, base: url)
    var picture: Data?
    if let image = meta.image, ["http", "https"].contains(image.scheme?.lowercased() ?? "") {
      picture = await read(image, session: session, limit: EaselStore.maxImageBytes)
    } else { meta.image = nil }
    return (meta, picture)
  }

  private static func read(_ url: URL, session: URLSession, limit: Int) async -> Data? {
    guard let (bytes, response) = try? await session.bytes(from: url),
          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
          http.expectedContentLength <= Int64(limit) else { return nil }
    var data = Data()
    do {
      for try await byte in bytes {
        data.append(byte)
        if data.count > limit { return limit == maxPageBytes ? data : nil }  // a long page: its head is enough
      }
    } catch { return data.isEmpty ? nil : data }
    return data
  }

  /// Reads `<meta property|name="…" content="…">` in either attribute order, and `<title>`.
  static func parse(_ html: String, base: URL) -> Metadata {
    var values: [String: String] = [:]
    let tag = try! NSRegularExpression(pattern: "<meta\\s[^>]*>", options: [.caseInsensitive])
    let attr = try! NSRegularExpression(pattern: "(property|name|content)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')", options: [.caseInsensitive])
    let ns = html as NSString
    for m in tag.matches(in: html, range: NSRange(location: 0, length: min(ns.length, maxPageBytes))).prefix(400) {
      let t = ns.substring(with: m.range)
      var key: String?, content: String?
      for a in attr.matches(in: t, range: NSRange(location: 0, length: (t as NSString).length)) {
        let name = (t as NSString).substring(with: a.range(at: 1)).lowercased()
        let r = a.range(at: 3).location != NSNotFound ? a.range(at: 3) : a.range(at: 4)
        let value = (t as NSString).substring(with: r)
        if name == "content" { content = value } else { key = value.lowercased() }
      }
      if let key, let content, values[key] == nil { values[key] = decode(content) }
    }
    var title = values["og:title"] ?? values["twitter:title"]
    if title == nil, let r = html.range(of: "<title[^>]*>([^<]{1,500})</title>", options: [.regularExpression, .caseInsensitive]) {
      title = decode(String(html[r]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
    }
    let summary = values["og:description"] ?? values["description"] ?? values["twitter:description"]
    let image = (values["og:image"] ?? values["og:image:url"] ?? values["twitter:image"]).flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
    func clip(_ s: String?) -> String? {
      guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
      return String(s.prefix(500))
    }
    return Metadata(title: clip(title), summary: clip(summary), image: image)
  }

  private static func decode(_ s: String) -> String {
    var out = s
    for (k, v) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
      out = out.replacingOccurrences(of: k, with: v)
    }
    return out
  }
}
