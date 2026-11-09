import CoreFoundation
import Darwin
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
    public let elapsedMs: Double
    public let alreadyCached: Bool
    public let imageInfo: FaviconImageInfo?
}

/// The caller supplies its existing PSL implementation. OpenStore has no PSL
/// resource or dependency of its own; nil means the host has no accepted site.
public protocol FaviconSiteResolver: Sendable {
    func siteKey(for host: String) -> String?
}

/// Fetches directly from a page and its declared icon locations. No favicon service.
public actor FaviconFetcher {
    private let store: FaviconStore
    private let session: URLSession
    private let maxConcurrent: Int
    private let timeout: TimeInterval
    private let originTimeout: TimeInterval
    private let minimumDimension: Int
    private let fallbackMinimumDimension: Int?
    private var diagnostic: (@Sendable (String, String, String) -> Void)?
    private let siteResolver: (any FaviconSiteResolver)?
    private var inFlight: [String: Task<OriginResult, Never>] = [:]
    private var diagnosticPublicHost: String?

    private struct OriginResult: Sendable {
        let status: FaviconFetchResult.Status
        var alreadyCached = false
        var imageInfo: FaviconImageInfo?
        // Internal diagnostic only. Never attach destinations to reports or logs.
        var reason: FaviconDownloadError?
    }

    /// A site-key resolver can restrict each resource's redirects to its registrable
    /// site (including private PSL registries). Without one, redirects stay on the
    /// exact host. Declared CDN URLs remain explicit.
    public init(store: FaviconStore, session: URLSession? = nil, maxConcurrent: Int = 6, timeout: TimeInterval = 5,
                originTimeout: TimeInterval = 8, minimumDimension: Int = 1, fallbackMinimumDimension: Int? = nil,
                siteResolver: (any FaviconSiteResolver)? = nil) {
        self.store = store
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
        self.maxConcurrent = min(6, max(1, maxConcurrent))
        self.timeout = timeout.isFinite && timeout > 0 ? min(6, timeout) : 5
        self.originTimeout = originTimeout.isFinite && originTimeout > 0 ? min(8, originTimeout) : 8
        self.minimumDimension = min(1024, max(1, minimumDimension))
        self.fallbackMinimumDimension = fallbackMinimumDimension.map { min(min(1024, max(1, minimumDimension)), max(1, $0)) }
        self.siteResolver = siteResolver
    }

    @_spi(FaviconDiagnostics) public func setDiagnosticHandler(_ handler: @escaping @Sendable (String, String, String) -> Void) {
        diagnostic = handler
    }

    /// CLI fixture hook only. Not part of the application API or normal CLI help.
    /// Treat this page origin as public while checking all other destinations normally.
    @_spi(FaviconDiagnostics) public func treatAsPublic(host: String) throws {
        #if !DEBUG
        guard ProcessInfo.processInfo.environment["OPENKIT_FAVICON_DEBUG"] == "1" else {
            throw FaviconDownloadError.invalidResponse
        }
        #endif
        diagnosticPublicHost = FaviconDestinationPolicy.normalizedHost(host)
    }

    public nonisolated func prefetch(_ pageURLs: [URL], overallTimeout: TimeInterval? = nil,
        onResult: (@Sendable (FaviconFetchResult) async -> Void)? = nil) async -> FetchReport {
        let start = ContinuousClock.now
        let deadline = overallTimeout.flatMap { $0.isFinite && $0 > 0 ? start.advanced(by: .seconds($0)) : nil }
        var seen = Set<String>(), pages: [URL] = []
        for page in pageURLs {
            guard let origin = FaviconOrigin.key(page), seen.insert(origin).inserted else { continue }
            pages.append(page)
        }
        var results: [FaviconFetchResult] = []
        await withTaskGroup(of: FaviconFetchResult.self) { group in
            var next = 0
            func submit() {
                let index = next + 1, page = pages[next]
                next += 1
                group.addTask {
                    let siteStart = ContinuousClock.now
                    let result = await self.fetchShared(page, deadline: deadline)
                    return FaviconFetchResult(index: index, status: result.status,
                                              durationMs: result.alreadyCached ? 0 : Self.milliseconds(since: siteStart),
                                              elapsedMs: Self.milliseconds(since: start), alreadyCached: result.alreadyCached, imageInfo: result.imageInfo)
                }
            }
            for _ in 0..<min(maxConcurrent, pages.count) { submit() }
            while let result = await group.next() {
                results.append(result)
                await onResult?(result)
                if next < pages.count { submit() }
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

    public nonisolated func fetchOne(_ pageURL: URL) async -> Bool {
        await fetchShared(pageURL).status == .ok
    }

    private func fetchShared(_ pageURL: URL, deadline: ContinuousClock.Instant? = nil) async -> OriginResult {
        guard let origin = FaviconOrigin.key(pageURL) else { return OriginResult(status: .failed) }
        if let existing = inFlight[origin] { return await existing.value }
        // Register before the first suspension, including the cache lookup. A shared task
        // survives cancellation of one waiter so it can still serve the other callers.
        let task = Task { await fetchIfNeeded(pageURL, origin: origin, outerDeadline: deadline) }
        inFlight[origin] = task
        let result = await task.value
        inFlight[origin] = nil
        return result
    }

    private func fetchIfNeeded(_ pageURL: URL, origin: String, outerDeadline: ContinuousClock.Instant?) async -> OriginResult {
        if let stored = await store.cachedStatus(for: pageURL) {
            let icon = await store.icon(for: pageURL)
            if stored != 0 || (icon?.info.map { min($0.width, $0.height) >= (fallbackMinimumDimension ?? minimumDimension) } ?? (minimumDimension == 1)) {
                return OriginResult(status: Self.status(stored), alreadyCached: true, imageInfo: icon?.info)
            }
        }
        let deadline = min(outerDeadline ?? ContinuousClock.now.advanced(by: .seconds(originTimeout)), ContinuousClock.now.advanced(by: .seconds(originTimeout)))
        do {
            let policy = try await FaviconDestinationPolicy(pageURL: pageURL, origin: origin,
                                                           diagnosticPublicHost: diagnosticPublicHost, deadline: deadline)
            return await fetchOrigin(pageURL, origin: origin, policy: policy, deadline: deadline)
        } catch {
            return await failure(pageURL, reason: error as? FaviconDownloadError)
        }
    }

    private func failure(_ pageURL: URL, reason: FaviconDownloadError? = nil) async -> OriginResult {
        if !Task.isCancelled { await store.markError(for: pageURL) }
        return OriginResult(status: .failed, reason: reason)
    }

    private func fetchOrigin(_ pageURL: URL, origin: String, policy: FaviconDestinationPolicy,
                             deadline: ContinuousClock.Instant) async -> OriginResult {
        guard let fallback = URL(string: origin + "/favicon.ico") else { return OriginResult(status: .failed) }
        var candidates: [FaviconCandidate] = [], hadError = false
        var finalFallback = fallback
        do {
            let page = try await download(pageURL, limit: 256 * 1024, html: true, policy: policy, deadline: deadline)
            if (200..<300).contains(page.status) {
                let links = FaviconHeadScanner.candidates(in: page.data, baseURL: page.url, charset: page.charset)
                diagnostic?(origin, page.url.absoluteString, "discovered:\(links.count):head-bytes=\(page.data.count)")
                var manifests = 0
                candidates = links.filter { candidate in
                    guard candidate.manifestDocument else { return true }
                    manifests += 1; return manifests <= 2
                }
                if let finalOrigin = FaviconOrigin.key(page.url), let url = URL(string: finalOrigin + "/favicon.ico") { finalFallback = url }
            } else if page.status != 404 && page.status != 410 { hadError = true }
        } catch FaviconDownloadError.blockedPrivate {
            return await failure(pageURL, reason: .blockedPrivate)
        } catch {
            if Task.isCancelled { return OriginResult(status: .failed) }
            hadError = true
        }
        candidates.sort { $0.rank < $1.rank }
        var seen = Set<URL>()
        candidates = Array(candidates.filter { $0.url != fallback && $0.url != finalFallback && seen.insert($0.url).inserted }.prefix(14))
        candidates.append(FaviconCandidate(url: finalFallback, kind: .favicon))
        if finalFallback != fallback { candidates.append(FaviconCandidate(url: fallback, kind: .favicon)) }
        var attempts = 0, attempted = Set<URL>()
        var smallFallback: (Data, URL?, FaviconSourceKind, Int)?
        while !candidates.isEmpty && attempts < 16 {
            let candidate = candidates.removeFirst()
            guard attempted.insert(candidate.url).inserted else { continue }; attempts += 1
            if Task.isCancelled { return OriginResult(status: .failed) }
            if ContinuousClock.now >= deadline { hadError = true; break }
            do {
                if candidate.manifestDocument {
                    // Discover manifests only after apple-touch candidates. A slow
                    // manifest cannot spend the whole site's budget before links.
                    let response = try await download(candidate.url, limit: 64 * 1024, html: false, policy: policy,
                        deadline: min(deadline, ContinuousClock.now.advanced(by: .seconds(1.5))))
                    if (200..<300).contains(response.status) {
                        let icons = FaviconCandidate.manifest(response.data, baseURL: response.url).filter { !attempted.contains($0.url) }
                        let iconURLs = Set(icons.map(\.url))
                        candidates.removeAll { iconURLs.contains($0.url) }
                        let fallbacks = candidates.filter { $0.kind == .favicon }
                        let declared = (candidates.filter { $0.kind != .favicon } + icons).sorted { $0.rank < $1.rank }
                        candidates = Array(declared.prefix(max(0, 16-attempts-fallbacks.count))) + fallbacks
                    }
                    continue
                }
                let data: Data
                let iconURL: URL?
                if candidate.url.scheme?.lowercased() == "data" {
                    guard let inline = Self.inlinePNG(candidate.url) else { continue }
                    data = inline
                    iconURL = nil
                } else {
                    let icon = try await download(candidate.url, limit: 512 * 1024, html: false, policy: policy, deadline: deadline)
                    guard (200..<300).contains(icon.status) else {
                        if icon.status != 404 && icon.status != 410 { hadError = true }
                        continue
                    }
                    data = icon.data
                    iconURL = icon.url
                }
                if ContinuousClock.now >= deadline { hadError = true; break }
                do {
                    let minimum = candidate.kind == .appleTouch ? max(120, minimumDimension) : minimumDimension
                    let info = try await store.ingest(imageData: data, iconURL: iconURL, for: pageURL, pageSpecific: false,
                        minimumDimension: minimum, sourceKind: candidate.kind)
                    diagnostic?(origin, candidate.url.absoluteString, "accepted:\(candidate.kind.rawValue):\(info.width)x\(info.height)")
                    return OriginResult(status: .ok, imageInfo: info)
                } catch FaviconStoreError.invalidImage {
                    diagnostic?(origin, candidate.url.absoluteString, "rejected:image-or-size:minimum=\(minimumDimension):bytes=\(data.count)")
                    if let fallbackMinimumDimension,
                       let info = try? await store.inspect(imageData: data, minimumDimension: fallbackMinimumDimension),
                       min(info.width, info.height) > (smallFallback?.3 ?? 0) {
                        smallFallback = (data, iconURL, candidate.kind, min(info.width, info.height))
                        diagnostic?(origin, candidate.url.absoluteString, "deferred:small:\(info.width)x\(info.height):after-larger-candidates")
                    }
                    continue
                } catch {
                    hadError = true
                }
            } catch FaviconDownloadError.blockedPrivate {
                return await failure(pageURL, reason: .blockedPrivate)
            } catch FaviconDownloadError.tooLarge {
                continue
            } catch {
                if Task.isCancelled { return OriginResult(status: .failed) }
                hadError = true
            }
        }
        if Task.isCancelled { return OriginResult(status: .failed) }
        if let (data, url, kind, _) = smallFallback, let fallbackMinimumDimension,
           let info = try? await store.ingest(imageData: data, iconURL: url, for: pageURL, pageSpecific: false,
               minimumDimension: fallbackMinimumDimension, sourceKind: kind) {
            diagnostic?(origin, url?.absoluteString ?? "inline", "accepted:small-fallback:\(info.width)x\(info.height)")
            return OriginResult(status: .ok, imageInfo: info)
        }
        if hadError { await store.markError(for: pageURL) } else { await store.markMissing(for: pageURL) }
        let status = await store.cachedStatus(for: pageURL)
        return OriginResult(status: status.map(Self.status) ?? .failed)
    }

    private func download(_ url: URL, limit: Int, html: Bool, policy: FaviconDestinationPolicy,
                          deadline: ContinuousClock.Instant) async throws -> FaviconDownload {
        guard url.absoluteString.utf8.count <= 8192, url.user == nil, url.password == nil else { throw FaviconDownloadError.invalidResponse }
        let requestDeadline = min(deadline, ContinuousClock.now.advanced(by: .seconds(timeout)))
        try await policy.check(url, deadline: requestDeadline)
        let remaining = FaviconDestinationPolicy.remaining(requestDeadline)
        guard remaining > 0 else { throw FaviconDownloadError.timedOut }
        let requestTimeout = min(timeout, remaining)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        request.httpShouldHandleCookies = false
        request.setValue(html ? "text/html" : "image/*, application/manifest+json, application/json;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let requestToSend = request
        diagnostic?(policy.pageOrigin, url.absoluteString, "request")
        let redirectGuard = FaviconRedirectGuard(policy: policy, deadline: requestDeadline, timeout: requestTimeout, resourceURL: url, siteResolver: siteResolver, diagnostic: diagnostic)
        do {
            return try await withThrowingTaskGroup(of: FaviconDownload.self) { group in
                group.addTask {
                    let (bytes, response) = try await self.session.bytes(for: requestToSend, delegate: redirectGuard)
                    defer { bytes.task.cancel() }
                    if let error = redirectGuard.failure { throw error }
                    guard let response = response as? HTTPURLResponse, let finalURL = response.url,
                          FaviconOrigin.key(finalURL) != nil else { throw FaviconDownloadError.invalidResponse }
                    await self.trace(origin: policy.pageOrigin, url: finalURL, event: "http:\(response.statusCode)")
                    guard (200..<300).contains(response.statusCode) else {
                        return FaviconDownload(data: Data(), url: finalURL, status: response.statusCode, charset: response.textEncodingName)
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
                    return FaviconDownload(data: data, url: finalURL, status: response.statusCode, charset: response.textEncodingName)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(requestTimeout))
                    throw FaviconDownloadError.timedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw FaviconDownloadError.invalidResponse }
                return result
            }
        } catch {
            diagnostic?(policy.pageOrigin, url.absoluteString, "rejected:download:\(redirectGuard.failure ?? error)")
            throw redirectGuard.failure ?? error
        }
    }

    private func trace(origin: String, url: URL, event: String) { diagnostic?(origin, url.absoluteString, event) }

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
    let charset: String?
}

private enum FaviconDownloadError: String, Error { case tooLarge, timedOut, invalidResponse, blockedPrivate = "blocked-private" }

private struct FaviconDestinationPolicy: Sendable {
    let pageOrigin: String
    let pageIsPrivate: Bool
    let diagnosticPublicOrigin: Bool

    init(pageURL: URL, origin: String, diagnosticPublicHost: String?, deadline: ContinuousClock.Instant) async throws {
        pageOrigin = origin
        diagnosticPublicOrigin = diagnosticPublicHost != nil && Self.host(pageURL) == diagnosticPublicHost
        pageIsPrivate = diagnosticPublicOrigin ? false : try await Self.isPrivate(pageURL, deadline: deadline)
    }

    func check(_ url: URL, deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw FaviconDownloadError.timedOut }
        guard let origin = FaviconOrigin.key(url) else { throw FaviconDownloadError.invalidResponse }
        // The fixture override is scoped to the original page origin, not every port
        // or scheme on the same host. Cross-origin targets always use real addresses.
        if diagnosticPublicOrigin && origin == pageOrigin { return }
        if try await Self.isPrivate(url, deadline: deadline), !(pageIsPrivate && origin == pageOrigin) {
            throw FaviconDownloadError.blockedPrivate
        }
    }

    static func remaining(_ deadline: ContinuousClock.Instant) -> Double {
        let parts = ContinuousClock.now.duration(to: deadline).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    static func normalizedHost(_ host: String) -> String {
        var value = host.lowercased()
        if value.hasPrefix("[") && value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    private static func host(_ url: URL) -> String { normalizedHost(url.host(percentEncoded: false) ?? "") }

    private static func isPrivate(_ url: URL, deadline: ContinuousClock.Instant) async throws -> Bool {
        let host = host(url)
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        // getaddrinfo also normalizes non-dotted IPv4 and IPv4-mapped IPv6 forms.
        // Its blocking work runs on a utility queue, never the main thread or actor.
        return try await withCheckedThrowingContinuation { continuation in
            let lookup = FaviconDNSLookup(continuation)
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                hints.ai_protocol = IPPROTO_TCP
                var addresses: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &addresses) == 0, let first = addresses else {
                    lookup.finish(.failure(FaviconDownloadError.invalidResponse))
                    return
                }
                defer { freeaddrinfo(first) }
                var current: UnsafeMutablePointer<addrinfo>? = first
                var found = false
                while let address = current {
                    defer { current = address.pointee.ai_next }
                    guard let socket = address.pointee.ai_addr else { continue }
                    if socket.pointee.sa_family == sa_family_t(AF_INET) {
                        found = true
                        let ipv4 = UnsafeRawPointer(socket).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                        if withUnsafeBytes(of: ipv4, { privateIPv4(Array($0)) }) { lookup.finish(.success(true)); return }
                    } else if socket.pointee.sa_family == sa_family_t(AF_INET6) {
                        found = true
                        let ipv6 = UnsafeRawPointer(socket).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                        let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
                        let mapped = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255
                        if bytes == Array(repeating: 0, count: 15) + [1] || bytes[0] & 0xfe == 0xfc ||
                           (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) || (mapped && privateIPv4(Array(bytes.suffix(4)))) {
                            lookup.finish(.success(true)); return
                        }
                    }
                }
                lookup.finish(found ? .success(false) : .failure(FaviconDownloadError.invalidResponse))
            }
            // A slow resolver must not extend the origin's configured budget. Late
            // getaddrinfo completion is discarded; no connection starts after expiry.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, remaining(deadline))) {
                lookup.finish(.failure(FaviconDownloadError.timedOut))
            }
        }
    }

    private static func privateIPv4(_ bytes: [UInt8]) -> Bool {
        let a = bytes[0], b = bytes[1]
        return a == 0 || a == 10 || a == 127 || (a == 172 && (16...31).contains(b)) ||
            (a == 192 && b == 168) || (a == 169 && b == 254) || (a == 100 && (64...127).contains(b))
    }
}

/// Exactly one resolver result or deadline resumes the continuation.
private final class FaviconDNSLookup: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, any Error>?
    init(_ continuation: CheckedContinuation<Bool, any Error>) { self.continuation = continuation }
    func finish(_ result: Result<Bool, any Error>) {
        let saved = lock.withLock { let saved = continuation; continuation = nil; return saved }
        saved?.resume(with: result)
    }
}

private final class FaviconRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let policy: FaviconDestinationPolicy
    private let deadline: ContinuousClock.Instant
    private let timeout: TimeInterval
    private let resourceURL: URL
    private let siteResolver: (any FaviconSiteResolver)?
    private let diagnostic: (@Sendable (String, String, String) -> Void)?
    private let lock = NSLock()
    private var storedFailure: (any Error)?
    var failure: (any Error)? { lock.withLock { storedFailure } }

    init(policy: FaviconDestinationPolicy, deadline: ContinuousClock.Instant, timeout: TimeInterval,
         resourceURL: URL, siteResolver: (any FaviconSiteResolver)?, diagnostic: (@Sendable (String, String, String) -> Void)?) {
        self.policy = policy; self.deadline = deadline; self.timeout = timeout
        self.resourceURL = resourceURL; self.siteResolver = siteResolver
        self.diagnostic = diagnostic
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        do {
            guard let url = request.url, url.absoluteString.utf8.count <= 8192,
                  url.user == nil, url.password == nil else { throw FaviconDownloadError.invalidResponse }
            if let siteResolver {
                guard let original = resourceURL.host.flatMap({ siteResolver.siteKey(for: $0) }),
                      let next = url.host.flatMap({ siteResolver.siteKey(for: $0) }), original == next else { throw FaviconDownloadError.invalidResponse }
            } else {
                guard resourceURL.host == url.host else { throw FaviconDownloadError.invalidResponse }
            }
            guard resourceURL.scheme != "https" || url.scheme == "https" else { throw FaviconDownloadError.invalidResponse }
            try await policy.check(url, deadline: deadline)
            let remaining = FaviconDestinationPolicy.remaining(deadline)
            guard remaining > 0 else { throw FaviconDownloadError.timedOut }
            var request = request
            request.timeoutInterval = min(timeout, remaining)
            request.httpShouldHandleCookies = false
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            request.setValue(nil, forHTTPHeaderField: "Cookie")
            diagnostic?(policy.pageOrigin, url.absoluteString, "redirect:\(response.statusCode):from=\(response.url?.absoluteString ?? "")")
            return request
        } catch {
            diagnostic?(policy.pageOrigin, request.url?.absoluteString ?? "", "redirect-refused:\(response.statusCode):\(error)")
            lock.withLock { storedFailure = error }
            task.cancel()
            return nil
        }
    }
}

private struct FaviconCandidate {
    let url: URL
    let kind: FaviconSourceKind
    var size: Int? = nil
    var manifestDocument = false
    var rank: (Int, Int) {
        let category: Int = switch kind {
        case .appleTouch: size.map { $0 >= 120 ? 0 : 3 } ?? 0
        case .manifest: 1
        case .link: 2
        case .favicon: 4
        }
        return (category, manifestDocument ? Int.min : -(size ?? 0))
    }
    static func size(_ sizes: String, maximum: Int) -> Int? {
        sizes.lowercased().split(whereSeparator: { $0.isWhitespace }).compactMap { token -> Int? in
            let sides = token.split(separator: "x")
            guard sides.count == 2, let w = Int(sides[0]), let h = Int(sides[1]), min(w,h) > 0, max(w,h) <= maximum else { return nil }
            return min(w,h)
        }.max()
    }
    static func manifest(_ data: Data, baseURL: URL) -> [Self] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let icons = object["icons"] as? [[String: Any]], icons.count <= 64 else { return [] }
        return icons.compactMap { icon in
            guard let src = icon["src"] as? String, src.utf8.count <= 8192,
                  let url = URL(string: src, relativeTo: baseURL)?.absoluteURL, FaviconOrigin.key(url) != nil,
                  let size = size(icon["sizes"] as? String ?? "", maximum: 512) else { return nil }
            let purpose = (icon["purpose"] as? String ?? "any").split(separator: " ")
            guard purpose.contains("any") || purpose.contains("maskable") else { return nil }
            return Self(url: url, kind: .manifest, size: size)
        }
    }
}

/// A bounded byte scanner, not a document-wide regular expression or a DOM.
private struct FaviconHeadScanner {
    private let bytes: [UInt8]
    private var encoding: String.Encoding?
    private var cursor = 0

    static func candidates(in data: Data, baseURL: URL, charset: String?) -> [FaviconCandidate] {
        let encoding = charset.flatMap(stringEncoding) ?? metaEncoding(in: data)
        var scanner = FaviconHeadScanner(bytes: Array(data), encoding: encoding)
        var found: [FaviconCandidate] = []
        while let tag = scanner.nextTag() {
            if tag.name == "body" || tag.name == "/head" { break }
            if ["script", "style", "title", "textarea"].contains(tag.name) { scanner.skipRawText(tag.name); continue }
            guard tag.name == "link", let rel = tag.attributes["rel"], let href = tag.attributes["href"] else { continue }
            let tokens = Set(rel.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init))
            let apple = tokens.contains("apple-touch-icon") || tokens.contains("apple-touch-icon-precomposed")
            let manifest = tokens.contains("manifest")
            guard !tokens.contains("mask-icon"), apple || manifest || tokens.contains("icon"),
                  let url = URL(string: asciiURL(entities(href).trimmingCharacters(in: .whitespacesAndNewlines)), relativeTo: baseURL)?.absoluteURL else { continue }
            if url.scheme?.lowercased() == "data" {
                guard !manifest, FaviconFetcher.inlinePNG(url) != nil else { continue }
            } else if FaviconOrigin.key(url) == nil { continue }
            let size = FaviconCandidate.size(tag.attributes["sizes"] ?? "", maximum: 1024)
            found.append(FaviconCandidate(url: url, kind: apple ? .appleTouch : manifest ? .manifest : .link, size: size, manifestDocument: manifest))
            if found.count == 64 { break }
        }
        return found
    }

    private mutating func nextTag() -> (name: String, attributes: [String: String])? {
        while cursor < bytes.count {
            guard bytes[cursor] == 60 else { cursor += 1; continue }
            if matches("<!--", at: cursor) {
                cursor += 4
                // HTML5 abrupt-closing-of-empty-comment forms.
                if matches(">", at: cursor) { cursor += 1; continue }
                if matches("->", at: cursor) { cursor += 2; continue }
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
                        value = attributeValue(bytes[valueStart..<cursor])
                        if cursor < bytes.count { cursor += 1 }
                    } else {
                        let valueStart = cursor
                        while cursor < bytes.count && !isSpace(bytes[cursor]) && bytes[cursor] != 62 { cursor += 1 }
                        value = attributeValue(bytes[valueStart..<cursor])
                    }
                }
                if attributes[key] == nil { attributes[key] = value }
            }
        }
        return nil
    }

    private func attributeValue(_ bytes: ArraySlice<UInt8>) -> String {
        let data = Data(bytes)
        return encoding.flatMap { String(data: data, encoding: $0) } ??
            String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func stringEncoding(_ charset: String) -> String.Encoding? {
        let value = charset.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoding = CFStringConvertIANACharSetNameToEncoding(value as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }

    private static func metaEncoding(in data: Data) -> String.Encoding? {
        var scanner = FaviconHeadScanner(bytes: Array(data.prefix(1024)))
        while let tag = scanner.nextTag() {
            if tag.name == "body" || tag.name == "/head" { break }
            if ["script", "style", "title", "textarea"].contains(tag.name) { scanner.skipRawText(tag.name); continue }
            guard tag.name == "meta" else { continue }
            if let charset = tag.attributes["charset"], let encoding = stringEncoding(charset) { return encoding }
            if tag.attributes["http-equiv"]?.lowercased() == "content-type", let content = tag.attributes["content"] {
                for part in content.split(separator: ";").dropFirst() {
                    let pair = part.split(separator: "=", maxSplits: 1)
                    if pair.count == 2, pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "charset",
                       let encoding = stringEncoding(pair[1].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))) {
                        return encoding
                    }
                }
            }
        }
        return nil
    }

    private static func asciiURL(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            scalar.isASCII ? String(scalar) : String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
        }.joined()
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
