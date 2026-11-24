import Foundation

// MARK: - Tokens

public struct SyncTokens: Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    /// Milliseconds since 1970; 0 when unknown.
    public var accessTokenExpiresAt: Int64

    public init(accessToken: String, refreshToken: String, accessTokenExpiresAt: Int64) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.accessTokenExpiresAt = accessTokenExpiresAt
    }
}

extension SyncTokens: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "SyncTokens(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

// MARK: - Wire responses (docs/sync-protocol.md §4)

public struct SyncHealthResponse: Decodable, Sendable {
    public var ok: Bool
    public var service: String
    public var version: Int
}

/// `/v1/auth/register`, `/v1/auth/login`, `/v1/auth/recover`.
public struct SyncAuthResponse: Decodable, Sendable {
    public var accountId: String
    public var email: String
    public var displayName: String?
    public var deviceId: String
    public var accessToken: String
    public var refreshToken: String
    public var accessTokenExpiresAt: Int64
    public var wrappedVaultKeyByPassword: String
    public var serverRevision: Int
    public var resetRevision: Int
    public var hasCloudData: Bool
    public var collectionCounts: [String: Int]

    public var tokens: SyncTokens { SyncTokens(accessToken: accessToken, refreshToken: refreshToken, accessTokenExpiresAt: accessTokenExpiresAt) }
    public var cloudSummary: SyncCloudSummary {
        SyncCloudSummary(serverRevision: serverRevision, resetRevision: resetRevision, hasCloudData: hasCloudData, collectionCounts: collectionCounts)
    }

    private enum CodingKeys: String, CodingKey {
        case accountId, email, displayName, deviceId, accessToken, refreshToken, accessTokenExpiresAt
        case wrappedVaultKeyByPassword, serverRevision, resetRevision, hasCloudData, collectionCounts
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try c.decode(String.self, forKey: .accountId)
        email = try c.decode(String.self, forKey: .email)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decode(String.self, forKey: .refreshToken)
        accessTokenExpiresAt = try c.decodeIfPresent(Int64.self, forKey: .accessTokenExpiresAt) ?? 0
        wrappedVaultKeyByPassword = try c.decode(String.self, forKey: .wrappedVaultKeyByPassword)
        serverRevision = try c.decodeIfPresent(Int.self, forKey: .serverRevision) ?? 0
        resetRevision = try c.decodeIfPresent(Int.self, forKey: .resetRevision) ?? 0
        hasCloudData = try c.decodeIfPresent(Bool.self, forKey: .hasCloudData) ?? false
        collectionCounts = try c.decodeIfPresent([String: Int].self, forKey: .collectionCounts) ?? [:]
    }
}

extension SyncAuthResponse: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "SyncAuthResponse(accountId: \(accountId), redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct SyncTokenRefreshResponse: Decodable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var accessTokenExpiresAt: Int64?
}

public struct SyncOKResponse: Decodable, Sendable {
    public var ok: Bool
}

public struct SyncChangePasswordResponse: Decodable, Sendable {
    public var ok: Bool
    public var revokedSessions: Int?
}

public struct SyncRecoveryChallengeResponse: Decodable, Sendable {
    public var accountId: String
    public var wrappedVaultKeyByRecovery: String
    public var recoveryTicket: String
}

public struct SyncAccountDevice: Decodable, Sendable {
    public var deviceId: String
    public var deviceName: String
    public var platform: String
    public var lastSeenAt: Int64?
    public var isCurrent: Bool?

    public var info: SyncDeviceInfo {
        SyncDeviceInfo(deviceId: deviceId, deviceName: deviceName, platform: platform,
                       lastSeenAt: lastSeenAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }, isCurrent: isCurrent ?? false)
    }
}

public struct SyncAccountResponse: Decodable, Sendable {
    public var accountId: String
    public var email: String
    public var displayName: String?
    public var createdAt: Int64?
    public var serverRevision: Int
    public var resetRevision: Int
    public var hasCloudData: Bool
    public var collectionCounts: [String: Int]?
    public var blobCount: Int?
    public var blobBytes: Int?
    public var devices: [SyncAccountDevice]
}

public struct SyncDisplayNameResponse: Decodable, Sendable {
    public var ok: Bool
    public var displayName: String
}

public struct SyncRevokeDeviceResponse: Decodable, Sendable {
    public var ok: Bool
    public var removed: Bool?
}

public struct SyncStatusResponse: Decodable, Sendable {
    public var serverRevision: Int
    public var resetRevision: Int
    public var hasCloudData: Bool
    public var collectionCounts: [String: Int]?
    public var lastModifiedAt: Int64?

    public var cloudSummary: SyncCloudSummary {
        SyncCloudSummary(serverRevision: serverRevision, resetRevision: resetRevision, hasCloudData: hasCloudData, collectionCounts: collectionCounts ?? [:])
    }
}

public struct SyncWireRecord: Decodable, Sendable {
    public var collection: String
    public var recordId: String
    public var revision: Int
    public var deleted: Bool
    public var clientUpdatedAt: Int64
    public var ciphertext: String
    public var updatedByDeviceId: String?
}

public struct SyncChangesResponse: Decodable, Sendable {
    public var currentRevision: Int
    public var resetRevision: Int
    public var fullResyncRequired: Bool
    public var hasMore: Bool
    public var nextSince: Int
    public var records: [SyncWireRecord]
}

public struct SyncWireMutation: Encodable, Sendable {
    public var collection: String
    public var recordId: String
    public var deleted: Bool
    public var clientUpdatedAt: Int64
    public var ciphertext: String

    public init(collection: String, recordId: String, deleted: Bool, clientUpdatedAt: Int64, ciphertext: String) {
        self.collection = collection; self.recordId = recordId; self.deleted = deleted
        self.clientUpdatedAt = clientUpdatedAt; self.ciphertext = ciphertext
    }
}

public enum SyncPushMode: String, Encodable, Sendable {
    case delta
    case replaceCloud
}

public struct SyncPushConflict: Decodable, Sendable {
    public var collection: String
    public var recordId: String
    public var serverRevision: Int
    public var serverClientUpdatedAt: Int64
}

public struct SyncPushResponse: Decodable, Sendable {
    public var currentRevision: Int
    public var resetRevision: Int
    public var acceptedCount: Int
    public var conflicts: [SyncPushConflict]

    private enum CodingKeys: String, CodingKey { case currentRevision, resetRevision, acceptedCount, conflicts }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentRevision = try c.decode(Int.self, forKey: .currentRevision)
        resetRevision = try c.decode(Int.self, forKey: .resetRevision)
        acceptedCount = try c.decodeIfPresent(Int.self, forKey: .acceptedCount) ?? 0
        conflicts = try c.decodeIfPresent([SyncPushConflict].self, forKey: .conflicts) ?? []
    }
}

public struct SyncBlobUploadResponse: Decodable, Sendable {
    public var ok: Bool
    public var blobId: String
    public var sizeBytes: Int?
    public var created: Bool?
}

struct SyncServerErrorEnvelope: Decodable {
    struct Body: Decodable { var code: String; var message: String? }
    var error: Body
}

// MARK: - Wire requests

struct SyncRegisterRequest: Encodable {
    var email: String
    /// Required by the server; empty when the user gave none.
    var displayName: String
    var kdfParams: SyncKDFParams
    var authVerifier: String
    var recoveryAuthVerifier: String
    var wrappedVaultKeyByPassword: String
    var wrappedVaultKeyByRecovery: String
    var deviceId: String
    var deviceName: String
    var platform: String
}

struct SyncEmailRequest: Encodable { var email: String }
struct SyncKDFParamsResponse: Decodable, Sendable { var kdfParams: SyncKDFParams }

struct SyncLoginRequest: Encodable {
    var email: String
    var authVerifier: String
    var deviceId: String
    var deviceName: String
    var platform: String
}

struct SyncRefreshRequest: Encodable { var refreshToken: String; var deviceId: String }
struct SyncEmptyRequest: Encodable {}

struct SyncChangePasswordRequest: Encodable {
    var currentAuthVerifier: String
    var newKdfParams: SyncKDFParams
    var newAuthVerifier: String
    var newWrappedVaultKeyByPassword: String
    var revokeOtherSessions: Bool
}

struct SyncRecoveryChallengeRequest: Encodable { var email: String; var recoveryAuthVerifier: String }

struct SyncRecoverRequest: Encodable {
    var email: String
    var recoveryTicket: String
    var newKdfParams: SyncKDFParams
    var newAuthVerifier: String
    var newRecoveryAuthVerifier: String
    var newWrappedVaultKeyByPassword: String
    var newWrappedVaultKeyByRecovery: String
    var deviceId: String
    var deviceName: String
    var platform: String
}

struct SyncDisplayNameRequest: Encodable { var displayName: String }
struct SyncDeleteAccountRequest: Encodable { var authVerifier: String }

struct SyncPushRequest: Encodable {
    var deviceId: String
    var mode: SyncPushMode
    var baseRevision: Int
    var mutations: [SyncWireMutation]
}

// MARK: - HTTP client

/// HTTP client for every `/v1` endpoint. Refreshes the access token once on `401`,
/// with one refresh in flight at a time, and reports rotated tokens through `onTokensUpdated`.
public actor SyncClient {
    public nonisolated let baseURL: URL
    public nonisolated let deviceId: String
    private let session: URLSession
    private var tokens: SyncTokens?
    private var refreshTask: Task<SyncTokens, any Error>?
    private var onTokensUpdated: (@Sendable (SyncTokens) async -> Void)?

    public init(serverURL: String, deviceId: String, tokens: SyncTokens? = nil, session: URLSession? = nil) throws {
        self.baseURL = try Self.validatedBaseURL(serverURL)
        self.deviceId = deviceId
        self.tokens = tokens
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 300
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    /// `http(s)://host[:port][/path]` without query or fragment; trailing `/` removed.
    public static func validatedBaseURL(_ text: String) throws -> URL {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil, components.user == nil, components.password == nil,
              let url = components.url
        else { throw SyncError.invalidServerURL(text) }
        return url
    }

    public func setTokens(_ tokens: SyncTokens?) { self.tokens = tokens }
    public func currentTokens() -> SyncTokens? { tokens }
    public func setTokenUpdateHandler(_ handler: (@Sendable (SyncTokens) async -> Void)?) { onTokensUpdated = handler }

    /// A usable access token, refreshed first when it expires within a minute or when forced.
    public func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = tokens else { throw SyncError.notSignedIn }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if forceRefresh || (current.accessTokenExpiresAt > 0 && current.accessTokenExpiresAt - nowMs < 60_000) {
            return try await refreshTokens(replacing: current.accessToken).accessToken
        }
        return current.accessToken
    }

    // MARK: Endpoints

    public func health() async throws -> SyncHealthResponse {
        try await send(method: "GET", path: "/health", body: Optional<SyncEmptyRequest>.none, authenticated: false)
    }

    func register(_ request: SyncRegisterRequest) async throws -> SyncAuthResponse {
        try await send(method: "POST", path: "/v1/auth/register", body: request, authenticated: false)
    }

    public func kdfParams(email: String) async throws -> SyncKDFParams {
        let response: SyncKDFParamsResponse = try await send(method: "POST", path: "/v1/auth/kdf-params",
                                                             body: SyncEmailRequest(email: email), authenticated: false)
        return response.kdfParams
    }

    public func login(email: String, authVerifier: Data, deviceName: String) async throws -> SyncAuthResponse {
        try await send(method: "POST", path: "/v1/auth/login",
                       body: SyncLoginRequest(email: email, authVerifier: authVerifier.base64EncodedString(), deviceId: deviceId,
                                              deviceName: deviceName, platform: SyncDefaults.platform),
                       authenticated: false)
    }

    /// Rotates the refresh token. Concurrent callers share one request.
    @discardableResult
    public func refresh() async throws -> SyncTokens {
        try await refreshTokens(replacing: tokens?.accessToken ?? "")
    }

    public func logout() async throws {
        let _: SyncOKResponse = try await send(method: "POST", path: "/v1/auth/logout", body: SyncEmptyRequest(), authenticated: true)
    }

    func changePassword(_ request: SyncChangePasswordRequest) async throws -> SyncChangePasswordResponse {
        try await send(method: "POST", path: "/v1/auth/change-password", body: request, authenticated: true)
    }

    public func recoveryChallenge(email: String, recoveryAuthVerifier: Data) async throws -> SyncRecoveryChallengeResponse {
        try await send(method: "POST", path: "/v1/auth/recovery-challenge",
                       body: SyncRecoveryChallengeRequest(email: email, recoveryAuthVerifier: recoveryAuthVerifier.base64EncodedString()),
                       authenticated: false)
    }

    func recover(_ request: SyncRecoverRequest) async throws -> SyncAuthResponse {
        try await send(method: "POST", path: "/v1/auth/recover", body: request, authenticated: false)
    }

    public func getAccount() async throws -> SyncAccountResponse {
        try await send(method: "GET", path: "/v1/account", body: Optional<SyncEmptyRequest>.none, authenticated: true)
    }

    public func updateDisplayName(_ displayName: String) async throws -> String {
        let response: SyncDisplayNameResponse = try await send(method: "PATCH", path: "/v1/account",
                                                               body: SyncDisplayNameRequest(displayName: displayName), authenticated: true)
        return response.displayName
    }

    @discardableResult
    public func revokeDevice(deviceId target: String) async throws -> Bool {
        guard let escaped = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._"))) else {
            throw SyncError.transport("Invalid device ID.")
        }
        let response: SyncRevokeDeviceResponse = try await send(method: "DELETE", path: "/v1/account/devices/\(escaped)",
                                                                body: Optional<SyncEmptyRequest>.none, authenticated: true)
        return response.removed ?? response.ok
    }

    public func deleteAccount(authVerifier: Data) async throws {
        let _: SyncOKResponse = try await send(method: "DELETE", path: "/v1/account",
                                               body: SyncDeleteAccountRequest(authVerifier: authVerifier.base64EncodedString()), authenticated: true)
    }

    public func syncStatus() async throws -> SyncStatusResponse {
        try await send(method: "GET", path: "/v1/sync/status", body: Optional<SyncEmptyRequest>.none, authenticated: true)
    }

    public func pullChanges(since: Int, limit: Int = SyncLimits.maxChangesLimit, collections: [SyncCollection]? = nil) async throws -> SyncChangesResponse {
        var query = [URLQueryItem(name: "since", value: String(max(0, since))),
                     URLQueryItem(name: "limit", value: String(min(max(1, limit), SyncLimits.maxChangesLimit)))]
        if let collections, !collections.isEmpty {
            query.append(URLQueryItem(name: "collections", value: collections.map(\.rawValue).joined(separator: ",")))
        }
        return try await send(method: "GET", path: "/v1/sync/changes", query: query, body: Optional<SyncEmptyRequest>.none, authenticated: true)
    }

    public func pushMutations(mode: SyncPushMode, baseRevision: Int, mutations: [SyncWireMutation]) async throws -> SyncPushResponse {
        guard mutations.count <= SyncLimits.maxMutationsPerPush else { throw SyncError.payloadTooLarge("A push batch") }
        return try await send(method: "POST", path: "/v1/sync/push",
                              body: SyncPushRequest(deviceId: deviceId, mode: mode, baseRevision: baseRevision, mutations: mutations),
                              authenticated: true)
    }

    @discardableResult
    public func uploadBlob(blobId: String, ciphertext: Data) async throws -> SyncBlobUploadResponse {
        guard SyncCrypto.isValidBlobID(blobId) else { throw SyncError.transport("Invalid blob ID.") }
        guard ciphertext.count <= SyncLimits.maxBlobBytes else { throw SyncError.payloadTooLarge("An attachment") }
        return try await perform(authenticated: true) { token in
            var request = try self.request(method: "PUT", path: "/v1/blobs/\(blobId)", query: [], token: token)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(String(ciphertext.count), forHTTPHeaderField: "Content-Length")
            let (data, response) = try await self.session.upload(for: request, from: ciphertext)
            return try Self.decodeJSON(data: data, response: response, limit: SyncLimits.maxJSONResponseBytes)
        }
    }

    /// Raw ciphertext, or `SyncError.server(404, "BLOB_NOT_FOUND", …)`.
    public func downloadBlob(blobId: String) async throws -> Data {
        guard SyncCrypto.isValidBlobID(blobId) else { throw SyncError.transport("Invalid blob ID.") }
        return try await perform(authenticated: true) { token in
            let request = try self.request(method: "GET", path: "/v1/blobs/\(blobId)", query: [], token: token)
            let (data, response) = try await self.limitedData(for: request, limit: SyncLimits.maxBlobResponseBytes)
            try Self.checkStatus(data: data, response: response)
            return data
        }
    }

    public func blobExists(blobId: String) async throws -> Bool {
        guard SyncCrypto.isValidBlobID(blobId) else { throw SyncError.transport("Invalid blob ID.") }
        return try await perform(authenticated: true) { token in
            let request = try self.request(method: "HEAD", path: "/v1/blobs/\(blobId)", query: [], token: token)
            let (data, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SyncError.transport("No HTTP response.") }
            if http.statusCode == 404 { return false }
            try Self.checkStatus(data: data, response: response)
            return true
        }
    }

    // MARK: Plumbing

    private func send<Body: Encodable, Response: Decodable>(method: String, path: String, query: [URLQueryItem] = [],
                                                            body: Body?, authenticated: Bool) async throws -> Response {
        var bodyData: Data?
        if let body {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            bodyData = try encoder.encode(body)
            if let bodyData, bodyData.count > SyncLimits.maxJSONRequestBytes { throw SyncError.payloadTooLarge("The request") }
        }
        let payload = bodyData
        return try await perform(authenticated: authenticated) { token in
            var request = try self.request(method: method, path: path, query: query, token: token)
            if let payload {
                request.httpBody = payload
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await self.limitedData(for: request, limit: SyncLimits.maxJSONResponseBytes)
            return try Self.decodeJSON(data: data, response: response, limit: SyncLimits.maxJSONResponseBytes)
        }
    }

    /// Runs `operation`; on `401` from an authenticated call, refreshes once and retries.
    private func perform<T>(authenticated: Bool, _ operation: (String?) async throws -> T) async throws -> T {
        guard authenticated else {
            do { return try await operation(nil) } catch { throw SyncError.wrap(error) }
        }
        let token = try await validAccessToken()
        do {
            return try await operation(token)
        } catch let error as SyncError {
            guard case .server(401, let code, _) = error, code != "INVALID_CREDENTIALS" else { throw error }
            let refreshed = try await refreshTokens(replacing: token)
            do { return try await operation(refreshed.accessToken) }
            catch let retry as SyncError {
                if case .server(401, _, let message) = retry { throw SyncError.sessionExpired(message) }
                throw retry
            } catch { throw SyncError.wrap(error) }
        } catch {
            throw SyncError.wrap(error)
        }
    }

    /// One refresh at a time. A caller whose token was already replaced reuses the new one.
    private func refreshTokens(replacing usedAccessToken: String) async throws -> SyncTokens {
        if let current = tokens, current.accessToken != usedAccessToken, !usedAccessToken.isEmpty { return current }
        if let refreshTask { return try await refreshTask.value }
        guard let current = tokens else { throw SyncError.notSignedIn }
        let session = self.session, base = baseURL, device = deviceId
        let task = Task<SyncTokens, any Error> {
            var request = URLRequest(url: base.appendingPathComponent("v1/auth/refresh"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONEncoder().encode(SyncRefreshRequest(refreshToken: current.refreshToken, deviceId: device))
            let (data, response) = try await session.data(for: request)
            let decoded: SyncTokenRefreshResponse
            do {
                decoded = try Self.decodeJSON(data: data, response: response, limit: SyncLimits.maxJSONResponseBytes)
            } catch let error as SyncError {
                if case .server(let status, _, let message) = error, status == 401 || status == 403 { throw SyncError.sessionExpired(message) }
                throw error
            }
            return SyncTokens(accessToken: decoded.accessToken, refreshToken: decoded.refreshToken,
                              accessTokenExpiresAt: decoded.accessTokenExpiresAt ?? 0)
        }
        refreshTask = task
        defer { refreshTask = nil }
        let fresh: SyncTokens
        do { fresh = try await task.value } catch { throw SyncError.wrap(error) }
        tokens = fresh
        // Save the rotated refresh token before anything else can fail: the old one is now spent.
        await onTokensUpdated?(fresh)
        return fresh
    }

    private func request(method: String, path: String, query: [URLQueryItem], token: String?) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw SyncError.invalidServerURL(baseURL.absoluteString) }
        components.path = components.path + path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw SyncError.invalidServerURL(baseURL.absoluteString) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(deviceId, forHTTPHeaderField: "X-Open-Device-Id")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// Reads at most `limit` bytes; larger responses are cancelled.
    private func limitedData(for request: URLRequest, limit: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > Int64(limit) {
            bytes.task.cancel()
            throw SyncError.responseTooLarge(limit)
        }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        var chunk = [UInt8]()
        chunk.reserveCapacity(65_536)
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count == 65_536 {
                data.append(contentsOf: chunk); chunk.removeAll(keepingCapacity: true)
                if data.count > limit { bytes.task.cancel(); throw SyncError.responseTooLarge(limit) }
            }
        }
        data.append(contentsOf: chunk)
        if data.count > limit { throw SyncError.responseTooLarge(limit) }
        return (data, response)
    }

    static func checkStatus(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw SyncError.transport("No HTTP response.") }
        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? JSONDecoder().decode(SyncServerErrorEnvelope.self, from: data) {
                let code = envelope.error.code
                let message = envelope.error.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                switch code {
                case "INVALID_CREDENTIALS": throw SyncError.invalidCredentials
                case "INVALID_RECOVERY_KEY": throw SyncError.invalidRecoveryKey
                case "EMAIL_TAKEN": throw SyncError.emailTaken
                default: throw SyncError.server(status: http.statusCode, code: code, message: message)
                }
            }
            throw SyncError.server(status: http.statusCode, code: "HTTP_\(http.statusCode)",
                                   message: "The sync server returned \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode)).")
        }
    }

    static func decodeJSON<T: Decodable>(data: Data, response: URLResponse, limit: Int) throws -> T {
        try checkStatus(data: data, response: response)
        guard data.count <= limit else { throw SyncError.responseTooLarge(limit) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw SyncError.decoding("\(T.self): \(error.localizedDescription)") }
    }
}

// MARK: - WebSocket wakeups (§4.6)

/// Holds `/v1/sync/ws` open and reports wakeups. Reconnects with 1 s…60 s exponential backoff.
public actor SyncWebSocketClient {
    public struct Handlers: Sendable {
        public var onConnected: @Sendable (_ serverRevision: Int, _ resetRevision: Int) async -> Void
        public var onWakeup: @Sendable (_ revision: Int, _ resetRevision: Int, _ sourceDeviceId: String?) async -> Void
        public var onSessionRevoked: @Sendable () async -> Void

        public init(onConnected: @escaping @Sendable (Int, Int) async -> Void = { _, _ in },
                    onWakeup: @escaping @Sendable (Int, Int, String?) async -> Void,
                    onSessionRevoked: @escaping @Sendable () async -> Void) {
            self.onConnected = onConnected; self.onWakeup = onWakeup; self.onSessionRevoked = onSessionRevoked
        }
    }

    public static let sessionRevokedCloseCode = 4001
    public static let minimumBackoff = 1.0
    public static let maximumBackoff = 60.0

    private let url: URL
    private let deviceId: String
    private let tokenProvider: @Sendable (_ forceRefresh: Bool) async throws -> String
    private let handlers: Handlers
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var generation = 0

    public init(serverURL: URL, deviceId: String, tokenProvider: @escaping @Sendable (Bool) async throws -> String, handlers: Handlers) {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = components.scheme?.lowercased() == "https" ? "wss" : "ws"
        components.path += "/v1/sync/ws"
        self.url = components.url ?? serverURL
        self.deviceId = deviceId
        self.tokenProvider = tokenProvider
        self.handlers = handlers
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    public var isRunning: Bool { loop != nil }

    public func connect() {
        guard loop == nil else { return }
        generation &+= 1
        let current = generation
        loop = Task { await self.run(generation: current) }
    }

    public func disconnect() {
        generation &+= 1
        loop?.cancel(); loop = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
    }

    private func run(generation current: Int) async {
        var backoff = Self.minimumBackoff
        var forceRefresh = false
        while !Task.isCancelled, generation == current {
            let token: String
            do { token = try await tokenProvider(forceRefresh) }
            catch let error as SyncError where error.requiresReauthentication || error == .notSignedIn {
                if generation == current { await handlers.onSessionRevoked() }
                break
            } catch {
                guard await sleep(seconds: backoff) else { break }
                backoff = min(backoff * 2, Self.maximumBackoff); continue
            }
            forceRefresh = false
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(deviceId, forHTTPHeaderField: "X-Open-Device-Id")
            let socket = session.webSocketTask(with: request)
            task = socket
            socket.resume()
            let pinger = Task { [weak socket] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 25_000_000_000)
                    guard let socket, !Task.isCancelled else { return }
                    try? await socket.send(.string(#"{"type":"ping"}"#))
                }
            }
            var receivedAny = false
            do {
                while !Task.isCancelled, generation == current {
                    let message = try await socket.receive()
                    if !receivedAny { receivedAny = true; backoff = Self.minimumBackoff }
                    await handle(message)
                }
            } catch {
                // Falls through to the close handling below.
            }
            pinger.cancel()
            if task === socket { task = nil }
            socket.cancel(with: .goingAway, reason: nil)
            guard !Task.isCancelled, generation == current else { break }
            let reason = socket.closeReason.map { String(decoding: $0, as: UTF8.self) }
            if socket.closeCode.rawValue == Self.sessionRevokedCloseCode || reason == "session_revoked" {
                await handlers.onSessionRevoked()
                break
            }
            if let http = socket.response as? HTTPURLResponse, http.statusCode == 401 { forceRefresh = true }
            // Jitter keeps many devices from reconnecting in step after a server restart.
            guard await sleep(seconds: backoff * Double.random(in: 0.8...1.2)) else { break }
            backoff = min(backoff * 2, Self.maximumBackoff)
        }
        if generation == current { loop = nil }
    }

    /// False when cancelled.
    private func sleep(seconds: Double) async -> Bool {
        do { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)); return true }
        catch { return false }
    }

    private struct Frame: Decodable {
        var type: String
        var serverRevision: Int?
        var revision: Int?
        var resetRevision: Int?
        var sourceDeviceId: String?
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) async {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return
        }
        guard data.count <= 65_536, let frame = try? JSONDecoder().decode(Frame.self, from: data) else { return }
        switch frame.type {
        case "connected":
            await handlers.onConnected(frame.serverRevision ?? 0, frame.resetRevision ?? 0)
        case "sync_available":
            guard frame.sourceDeviceId != deviceId else { return }
            await handlers.onWakeup(frame.revision ?? 0, frame.resetRevision ?? 0, frame.sourceDeviceId)
        default:
            break
        }
    }
}
