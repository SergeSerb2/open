import Foundation

public struct AdBlockDownloadPolicy: Sendable {
    public var maximumSourceBytes = 16 * 1024 * 1024
    public var maximumListBytes = 64 * 1024 * 1024
    public var requestTimeout: TimeInterval = 30
    public var resourceTimeout: TimeInterval = 90
    public var attempts = 3
    public var initialBackoff: TimeInterval = 1
    public init() {}

    func validate() throws {
        guard maximumSourceBytes > 0, maximumListBytes >= maximumSourceBytes,
              requestTimeout > 0, resourceTimeout > 0, attempts > 0, attempts <= 5,
              initialBackoff >= 0, resourceTimeout.isFinite, requestTimeout.isFinite,
              initialBackoff.isFinite, initialBackoff <= 30 else { throw AdBlockError("invalid download policy") }
    }
}

struct DownloadResponse: Sendable {
    let status: Int
    let data: Data
    let etag: String?
    let modified: String?
}

struct DownloadFailure: Error {
    let message: String
    let retryable: Bool
}

/// Cancellation may arrive before URLSession's continuation has installed its task.
/// Do not invalidate the session in that gap: creating a task on it would be invalid.
private final class TransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDataTask?
    func start(_ task: URLSessionDataTask) {
        lock.lock(); defer { lock.unlock() }
        self.task = task
        if cancelled { task.cancel() }
        task.resume()
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        task?.cancel()
    }
}

/// One transfer owns one serial delegate queue. Mutable fields are accessed only before resume,
/// then on that queue. No URLSession cache: 304 evidence comes from the server, not local caching.
private final class BoundedTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let maximumBytes: Int
    let allowedHosts: Set<String>
    let debugLoopbackHTTP: Bool
    var data = Data()
    var response: HTTPURLResponse?
    var failure: DownloadFailure?
    var continuation: CheckedContinuation<DownloadResponse, any Error>?

    init(maximumBytes: Int, allowedHosts: Set<String>, debugLoopbackHTTP: Bool) {
        self.maximumBytes = maximumBytes; self.allowedHosts = allowedHosts
        self.debugLoopbackHTTP = debugLoopbackHTTP
    }

    static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        // URLSession delivers the rejected redirect response after completionHandler(nil).
        // Preserve the policy error instead of replacing it with a generic HTTP 30x error.
        guard failure == nil else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse else {
            failure = DownloadFailure(message: "invalid HTTP response", retryable: false)
            completionHandler(.cancel); return
        }
        self.response = http
        if http.statusCode != 200 && http.statusCode != 304 {
            failure = DownloadFailure(message: "HTTP \(http.statusCode)",
                                      retryable: http.statusCode == 408 || http.statusCode == 429 || http.statusCode >= 500)
            completionHandler(.cancel)
        } else if response.expectedContentLength > Int64(maximumBytes) {
            failure = DownloadFailure(message: "source size limit exceeded", retryable: false)
            completionHandler(.cancel)
        } else { completionHandler(.allow) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard failure == nil else { return }
        guard data.count <= maximumBytes - chunk.count else {
            failure = DownloadFailure(message: "source size limit exceeded", retryable: false)
            dataTask.cancel(); return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let host = request.url?.host()?.lowercased(), allowedHosts.contains(host) else {
            failure = DownloadFailure(message: "cross-host redirect rejected (host is not in this list's CDN allowlist)", retryable: false)
            completionHandler(nil); return
        }
        guard request.url?.scheme == "https" ||
                (debugLoopbackHTTP && request.url?.scheme == "http" && Self.isLoopback(host)) else {
            failure = DownloadFailure(message: "non-HTTPS redirect rejected", retryable: false)
            completionHandler(nil); return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        defer { continuation = nil; session.finishTasksAndInvalidate() }
        if let failure { continuation?.resume(throwing: failure) }
        else if let error {
            let code = (error as NSError).code
            continuation?.resume(throwing: DownloadFailure(message: "network error (\(code))", retryable: true))
        } else if let response {
            continuation?.resume(returning: DownloadResponse(status: response.statusCode, data: data,
                etag: response.value(forHTTPHeaderField: "ETag"),
                modified: response.value(forHTTPHeaderField: "Last-Modified")))
        } else { continuation?.resume(throwing: DownloadFailure(message: "missing HTTP response", retryable: true)) }
    }
}

struct ListDownloader: Sendable {
    let policy: AdBlockDownloadPolicy
    /// A real HTTPS proxy can be supplied for diagnostics, including an unreachable-host check.
    let proxy: URL?

    func fetch(url: URL, etag: String?, modified: String?, redirectHosts: [String] = []) async throws -> (DownloadResponse, Int) {
        var source = url
        var debugLoopbackHTTP = false
        if let raw = ProcessInfo.processInfo.environment["OPEN_ADBLOCK_DEBUG_SOURCE_ROOT"] {
            guard let root = URL(string: raw), root.scheme == "http", let host = root.host(),
                  BoundedTransfer.isLoopback(host), root.port != nil, root.user == nil, root.password == nil else {
                throw AdBlockError("debug source root must be an explicit loopback HTTP server with a port")
            }
            source = root.appendingPathComponent(url.path)
            debugLoopbackHTTP = true
        }
        for attempt in 1...policy.attempts {
            try Task.checkCancellation()
            do {
                let response = try await transfer(url: source, etag: etag, modified: modified, redirectHosts: redirectHosts, debugLoopbackHTTP: debugLoopbackHTTP)
                try Task.checkCancellation()
                return (response, attempt)
            }
            catch let failure as DownloadFailure {
                try Task.checkCancellation()
                if !failure.retryable || attempt == policy.attempts {
                    throw AdBlockError("\(failure.message); attempts=\(attempt)")
                }
                let seconds = policy.initialBackoff * pow(2, Double(attempt - 1))
                try await Task.sleep(for: .seconds(seconds))
            }
        }
        throw AdBlockError("download failed")
    }

    private func transfer(url: URL, etag: String?, modified: String?, redirectHosts: [String], debugLoopbackHTTP: Bool) async throws -> DownloadResponse {
        guard url.scheme == "https" || debugLoopbackHTTP else { throw AdBlockError("HTTPS is required") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = policy.requestTimeout
        configuration.timeoutIntervalForResource = policy.resourceTimeout
        if let proxy {
            guard proxy.scheme == "http", let host = proxy.host(), let port = proxy.port else {
                throw AdBlockError("proxy must be an HTTP host with a port")
            }
            configuration.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
                                                       "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port]
        }
        let allowedHosts = Set(redirectHosts.map { $0.lowercased() } + [url.host()?.lowercased() ?? ""])
        let delegate = BoundedTransfer(maximumBytes: policy.maximumSourceBytes, allowedHosts: allowedHosts, debugLoopbackHTTP: debugLoopbackHTTP)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        let cancellation = TransferCancellation()
        var request = URLRequest(url: url)
        request.setValue("Open/1 AdBlock", forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        else if let modified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                cancellation.start(session.dataTask(with: request))
            }
        } onCancel: { cancellation.cancel() }
    }
}
