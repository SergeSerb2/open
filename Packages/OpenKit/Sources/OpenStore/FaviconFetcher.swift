import Foundation

public struct FetchReport: Sendable {
    public let requested: Int
    public let alreadyCached: Int
    public let fetched: Int
    public let missing: Int
    public let failed: Int
    public let durationMs: Double
    /// Input-order identifiers only. Reports never contain URLs or hostnames.
    public let origins: [FaviconFetchResult]
}

public struct FaviconFetchResult: Sendable {
    public enum Status: String, Sendable { case ok, missing, failed }
    public let index: Int
    public let status: Status
    public let durationMs: Double
    public let alreadyCached: Bool
}

/// Fetches directly from a page and its declared icon locations. No favicon service.
public struct FaviconFetcher: Sendable {
    private let store: FaviconStore
    private let session: URLSession
    private let maxConcurrent: Int
    private let timeout: TimeInterval

    public init(store: FaviconStore, session: URLSession = .shared, maxConcurrent: Int = 6, timeout: TimeInterval = 5) {
        self.store = store
        self.session = session
        self.maxConcurrent = max(1, maxConcurrent)
        self.timeout = timeout.isFinite && timeout > 0 ? timeout : 5
    }

    public func prefetch(_ pageURLs: [URL]) async -> FetchReport {
        let start = ContinuousClock.now
        var seen = Set<String>(), pages: [URL] = []
        for page in pageURLs {
            guard let origin = FaviconOrigin.key(page), seen.insert(origin).inserted else { continue }
            pages.append(page)
        }
        var results: [FaviconFetchResult] = [], pending: [(Int, URL)] = []
        for (index, page) in pages.enumerated() {
            let originURL = URL(string: FaviconOrigin.key(page)!)!
            if !(await store.needsFetch(originURL)) {
                let status = await store.cachedStatus(for: originURL) ?? 2
                results.append(FaviconFetchResult(index: index + 1, status: Self.status(status), durationMs: 0, alreadyCached: true))
            } else {
                pending.append((index + 1, page))
            }
        }
        await withTaskGroup(of: FaviconFetchResult.self) { group in
            var next = 0
            func submit() {
                let (index, page) = pending[next]
                next += 1
                group.addTask {
                    let start = ContinuousClock.now
                    let status = await fetchOrigin(page)
                    return FaviconFetchResult(index: index, status: status, durationMs: Self.milliseconds(since: start), alreadyCached: false)
                }
            }
            for _ in 0..<min(maxConcurrent, pending.count) { submit() }
            while let result = await group.next() {
                results.append(result)
                if next < pending.count { submit() }
            }
        }
        results.sort { $0.index < $1.index }
        let fetchedResults = results.filter { !$0.alreadyCached }
        return FetchReport(requested: pages.count, alreadyCached: results.count - fetchedResults.count,
                           fetched: fetchedResults.filter { $0.status == .ok }.count,
                           missing: fetchedResults.filter { $0.status == .missing }.count,
                           failed: fetchedResults.filter { $0.status == .failed }.count,
                           durationMs: Self.milliseconds(since: start), origins: results)
    }

    public func fetchOne(_ pageURL: URL) async -> Bool {
        guard FaviconOrigin.key(pageURL) != nil else { return false }
        if !(await store.needsFetch(pageURL)) { return await store.icon(for: pageURL) != nil }
        return await fetchOrigin(pageURL) == .ok
    }

    private func fetchOrigin(_ pageURL: URL) async -> FaviconFetchResult.Status {
        guard let origin = FaviconOrigin.key(pageURL), let fallback = URL(string: origin + "/favicon.ico") else { return .failed }
        var candidates: [URL] = [], hadError = false
        do {
            let page = try await download(pageURL, limit: 256 * 1024, html: true)
            if (200..<300).contains(page.status) {
                candidates = FaviconHeadScanner.candidates(in: page.data, baseURL: page.url)
            } else if page.status != 404 && page.status != 410 { hadError = true }
        } catch {
            if Task.isCancelled { return .failed }
            hadError = true
        }
        if !candidates.contains(fallback) { candidates.append(fallback) }
        for candidate in candidates {
            if Task.isCancelled { return .failed }
            do {
                let data: Data
                let iconURL: URL?
                if candidate.scheme?.lowercased() == "data" {
                    guard let inline = Self.inlinePNG(candidate) else { continue }
                    data = inline
                    iconURL = nil // Do not duplicate embedded image bytes in icon_url.
                } else {
                    let icon = try await download(candidate, limit: 512 * 1024, html: false)
                    guard (200..<300).contains(icon.status) else {
                        if icon.status != 404 && icon.status != 410 { hadError = true }
                        continue
                    }
                    data = icon.data
                    iconURL = icon.url
                }
                do {
                    try await store.ingest(imageData: data, iconURL: iconURL, for: pageURL, pageSpecific: false)
                    return .ok
                } catch FaviconStoreError.invalidImage {
                    continue
                } catch {
                    hadError = true
                }
            } catch FaviconDownloadError.tooLarge {
                continue
            } catch {
                if Task.isCancelled { return .failed }
                hadError = true
            }
        }
        if Task.isCancelled { return .failed }
        if hadError { await store.markError(for: pageURL) } else { await store.markMissing(for: pageURL) }
        let status = await store.cachedStatus(for: URL(string: origin)!)
        return status.map(Self.status) ?? .failed
    }

    private func download(_ url: URL, limit: Int, html: Bool) async throws -> FaviconDownload {
        guard FaviconOrigin.key(url) != nil else { throw FaviconDownloadError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        request.setValue(html ? "text/html" : "image/*", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let requestToSend = request
        return try await withThrowingTaskGroup(of: FaviconDownload.self) { group in
            group.addTask {
                let (bytes, response) = try await session.bytes(for: requestToSend)
                defer { bytes.task.cancel() }
                guard let response = response as? HTTPURLResponse, let finalURL = response.url,
                      FaviconOrigin.key(finalURL) != nil else { throw FaviconDownloadError.invalidResponse }
                guard (200..<300).contains(response.statusCode) else {
                    return FaviconDownload(data: Data(), url: finalURL, status: response.statusCode)
                }
                if !html && response.expectedContentLength > limit { throw FaviconDownloadError.tooLarge }
                var data = Data()
                data.reserveCapacity(min(limit, max(0, Int(response.expectedContentLength))))
                for try await byte in bytes {
                    if data.count == limit {
                        if html { break }
                        throw FaviconDownloadError.tooLarge
                    }
                    data.append(byte)
                    if html && data.count == limit { break }
                }
                return FaviconDownload(data: data, url: finalURL, status: response.statusCode)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw FaviconDownloadError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw FaviconDownloadError.invalidResponse }
            return result
        }
    }

    fileprivate static func inlinePNG(_ url: URL) -> Data? {
        let text = url.absoluteString
        let prefix = "data:image/png;base64,"
        guard text.count <= 44 * 1024, text.lowercased().hasPrefix(prefix),
              let data = Data(base64Encoded: String(text.dropFirst(prefix.count))), data.count <= 32 * 1024 else { return nil }
        return data
    }

    private static func status(_ stored: Int) -> FaviconFetchResult.Status {
        stored == 0 ? .ok : (stored == 1 ? .missing : .failed)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }
}

private struct FaviconDownload: Sendable {
    let data: Data
    let url: URL
    let status: Int
}

private enum FaviconDownloadError: Error { case tooLarge, timedOut, invalidResponse }

/// A bounded byte scanner, not a document-wide regular expression or a DOM.
private struct FaviconHeadScanner {
    private let bytes: [UInt8]
    private var cursor = 0

    private struct Candidate {
        let url: URL
        let size: Int?
        let apple: Bool
        let order: Int
    }

    static func candidates(in data: Data, baseURL: URL) -> [URL] {
        var scanner = FaviconHeadScanner(bytes: Array(data))
        var found: [Candidate] = []
        while let tag = scanner.nextTag() {
            if tag.name == "body" || tag.name == "/head" { break }
            if ["script", "style", "title", "textarea"].contains(tag.name) { scanner.skipRawText(tag.name); continue }
            guard tag.name == "link", let rel = tag.attributes["rel"], let href = tag.attributes["href"] else { continue }
            let tokens = Set(rel.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init))
            let apple = tokens.contains("apple-touch-icon") || tokens.contains("apple-touch-icon-precomposed")
            guard !tokens.contains("mask-icon"), apple || tokens.contains("icon"),
                  let url = URL(string: entities(href).trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: baseURL)?.absoluteURL else { continue }
            if url.scheme?.lowercased() == "data" {
                guard FaviconFetcher.inlinePNG(url) != nil else { continue }
            } else if FaviconOrigin.key(url) == nil { continue }
            let sizes = (tag.attributes["sizes"] ?? "").lowercased().split(whereSeparator: { $0.isWhitespace }).compactMap { token -> Int? in
                let sides = token.split(separator: "x")
                guard sides.count == 2, let width = Int(sides[0]), let height = Int(sides[1]), min(width, height) >= 64 else { return nil }
                return max(width, height)
            }
            found.append(Candidate(url: url, size: sizes.min(), apple: apple, order: found.count))
        }
        found.sort {
            let lhs = ($0.size == nil ? ($0.apple ? 1 : 2) : 0, $0.size ?? 0, $0.order)
            let rhs = ($1.size == nil ? ($1.apple ? 1 : 2) : 0, $1.size ?? 0, $1.order)
            return lhs < rhs
        }
        var seen = Set<URL>()
        return found.map(\.url).filter { seen.insert($0).inserted }
    }

    private mutating func nextTag() -> (name: String, attributes: [String: String])? {
        while cursor < bytes.count {
            guard bytes[cursor] == 60 else { cursor += 1; continue }
            if matches("<!--", at: cursor) {
                cursor += 4
                while cursor < bytes.count && !matches("-->", at: cursor) { cursor += 1 }
                cursor = min(bytes.count, cursor + 3)
                continue
            }
            cursor += 1
            let start = cursor
            if cursor < bytes.count && bytes[cursor] == 47 { cursor += 1 }
            while cursor < bytes.count && isName(bytes[cursor]) { cursor += 1 }
            let name = String(decoding: bytes[start..<cursor], as: UTF8.self).lowercased()
            var attributes: [String: String] = [:]
            while cursor < bytes.count {
                skipSpace()
                if cursor == bytes.count { return nil }
                if bytes[cursor] == 62 { cursor += 1; return (name, attributes) }
                if bytes[cursor] == 47 { cursor += 1; continue }
                let attrStart = cursor
                while cursor < bytes.count && !isSpace(bytes[cursor]) && ![61, 62, 47].contains(bytes[cursor]) { cursor += 1 }
                if attrStart == cursor { cursor += 1; continue }
                let key = String(decoding: bytes[attrStart..<cursor], as: UTF8.self).lowercased()
                skipSpace()
                var value = ""
                if cursor < bytes.count && bytes[cursor] == 61 {
                    cursor += 1
                    skipSpace()
                    if cursor == bytes.count { return nil }
                    let quote = bytes[cursor]
                    if quote == 34 || quote == 39 {
                        cursor += 1
                        let valueStart = cursor
                        while cursor < bytes.count && bytes[cursor] != quote { cursor += 1 }
                        value = String(decoding: bytes[valueStart..<cursor], as: UTF8.self)
                        if cursor < bytes.count { cursor += 1 }
                    } else {
                        let valueStart = cursor
                        while cursor < bytes.count && !isSpace(bytes[cursor]) && bytes[cursor] != 62 { cursor += 1 }
                        value = String(decoding: bytes[valueStart..<cursor], as: UTF8.self)
                    }
                }
                if attributes[key] == nil { attributes[key] = value }
            }
        }
        return nil
    }

    private mutating func skipRawText(_ tag: String) {
        while cursor < bytes.count {
            if matches("</" + tag, at: cursor) {
                let end = cursor + tag.utf8.count + 2
                if end == bytes.count || isSpace(bytes[end]) || bytes[end] == 62 { return }
            }
            cursor += 1
        }
    }

    private func matches(_ text: String, at start: Int) -> Bool {
        let expected = Array(text.utf8)
        guard start + expected.count <= bytes.count else { return false }
        return expected.enumerated().allSatisfy { offset, byte in
            let actual = bytes[start + offset]
            return (65...90).contains(actual) ? actual + 32 == byte : actual == byte
        }
    }

    private mutating func skipSpace() { while cursor < bytes.count && isSpace(bytes[cursor]) { cursor += 1 } }
    private func isSpace(_ byte: UInt8) -> Bool { [9, 10, 12, 13, 32].contains(byte) }
    private func isName(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 58 }

    private static func entities(_ text: String) -> String {
        var result = "", cursor = text.startIndex
        let named = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">"]
        while cursor < text.endIndex {
            if text[cursor] == "&", let end = text[cursor...].prefix(12).firstIndex(of: ";") {
                let token = String(text[text.index(after: cursor)..<end])
                var replacement = named[token]
                if token.hasPrefix("#") {
                    let hex = token.lowercased().hasPrefix("#x")
                    if let value = UInt32(token.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let scalar = UnicodeScalar(value) { replacement = String(scalar) }
                }
                if let replacement { result += replacement; cursor = text.index(after: end); continue }
            }
            result.append(text[cursor])
            cursor = text.index(after: cursor)
        }
        return result
    }
}
