import Foundation
import CryptoKit
import Observation

// MARK: - Adapter contract

/// One plaintext record that the App collected from local state.
public struct SyncLocalRecord: Sendable {
    public var collection: SyncCollection
    public var recordId: String
    /// Deterministic JSON (`SyncPayloadCodec.encode`).
    public var payload: Data

    public init(collection: SyncCollection, recordId: String, payload: Data) {
        self.collection = collection; self.recordId = recordId; self.payload = payload
    }

    public init<T: Encodable>(collection: SyncCollection, recordId: String, value: T) throws {
        self.init(collection: collection, recordId: recordId, payload: try SyncPayloadCodec.encode(value))
    }
}

/// One plaintext Easel or Note asset that a record references by `blobId`.
public struct SyncLocalBlob: Sendable {
    public var blobId: String
    public var data: Data
    public init(blobId: String, data: Data) { self.blobId = blobId; self.data = data }
}

/// Everything the App holds for the enabled categories.
public struct SyncLocalBundle: Sendable {
    public var records: [SyncLocalRecord]
    public var blobs: [SyncLocalBlob]
    /// Collections whose records are all listed. A previously synced record of one of these
    /// that is missing here becomes a tombstone. Leave out a collection the App could not read.
    public var completeCollections: Set<SyncCollection>
    public var warnings: [String]

    public init(records: [SyncLocalRecord] = [], blobs: [SyncLocalBlob] = [], completeCollections: Set<SyncCollection>, warnings: [String] = []) {
        self.records = records; self.blobs = blobs; self.completeCollections = completeCollections; self.warnings = warnings
    }
}

/// Computes content-addressed blob IDs with the account's `blobIdKey`.
public struct SyncBlobHasher: Sendable {
    let keys: SyncCrypto.VaultKeys

    public func blobID(for data: Data) -> String { SyncCrypto.computeBlobID(data, keys: keys) }

    /// The reference to put in an Easel or Note payload, and the blob to put in the bundle.
    public func asset(filename: String, data: Data) -> (ref: SyncedAssetRef, blob: SyncLocalBlob) {
        let id = blobID(for: data)
        return (SyncedAssetRef(filename: filename, blobId: id, sha256: SyncCrypto.sha256Hex(data), byteLength: data.count),
                SyncLocalBlob(blobId: id, data: data))
    }
}

/// One decrypted record from the server.
public struct SyncRemoteRecord: Sendable {
    public var collection: SyncCollection
    public var recordId: String
    public var deleted: Bool
    /// Plaintext JSON; nil for tombstones.
    public var payload: Data?
    public var clientUpdatedAt: Int64
    public var revision: Int
    public var updatedByDeviceId: String?
    var payloadHash: String

    public func decode<T: Decodable>(_ type: T.Type) throws -> T? {
        guard !deleted, let payload else { return nil }
        if let version = SyncPayloadCodec.schemaVersion(of: payload), version > 1 {
            throw SyncError.decoding("\(collection.rawValue) \(recordId) uses schema \(version); update Open to read it.")
        }
        return try SyncPayloadCodec.decode(type, from: payload)
    }
}

public struct SyncRemoteBundle: Sendable {
    public var records: [SyncRemoteRecord]
    /// Plaintext assets by `blobId`, verified against their HMAC ID and SHA-256.
    public var blobs: [String: Data]
    /// True when `records` is the account's complete state (initial sync or a cloud reset).
    public var isFullSnapshot: Bool

    public init(records: [SyncRemoteRecord], blobs: [String: Data], isFullSnapshot: Bool) {
        self.records = records; self.blobs = blobs; self.isFullSnapshot = isFullSnapshot
    }

    public func records(in collection: SyncCollection) -> [SyncRemoteRecord] { records.filter { $0.collection == collection } }
    public func contains(_ collection: SyncCollection) -> Bool { records.contains { $0.collection == collection } }
    public var collections: Set<SyncCollection> { Set(records.map(\.collection)) }
}

public enum SyncApplyMode: String, Sendable {
    /// Replace local data with the bundle's records. With `isFullSnapshot` (always the case
    /// today), the bundle is the whole cloud: an enabled collection with no cloud records is
    /// cleared on every local Profile.
    case replaceLocal
    /// Upsert and delete the bundle's records over local data. With `isFullSnapshot`, this is
    /// the first-sign-in merge: keep local-only items.
    case mergeOrDelta
}

public struct SyncApplyOutcome: Sendable {
    public var pendingExtensionInstalls: [SyncPendingExtension]
    public var warnings: [String]

    public init(pendingExtensionInstalls: [SyncPendingExtension] = [], warnings: [String] = []) {
        self.pendingExtensionInstalls = pendingExtensionInstalls; self.warnings = warnings
    }
}

/// Implemented by the App (`App/Sync/AppSyncCoordinator.swift`).
@MainActor
public protocol SyncDataAdapter: AnyObject {
    /// Local records of the enabled categories. Use `blobHasher` for Easel and Note asset references.
    func collectLocalData(categories: SyncCategorySettings, blobHasher: SyncBlobHasher) async throws -> SyncLocalBundle
    /// Installs remote records. Called with `SyncEngine.isApplyingRemote == true`.
    func applyRemoteData(_ bundle: SyncRemoteBundle, mode: SyncApplyMode, categories: SyncCategorySettings) async throws -> SyncApplyOutcome
    /// Copies the files a destructive apply replaces (`SyncStateStore.createLocalBackup`).
    func prepareLocalBackup(root: URL) async throws
}

// MARK: - Engine

@MainActor
@Observable
public final class SyncEngine {
    /// Live account state for Settings, Onboarding, the sidebar banner, and automation.
    public private(set) var snapshot: SyncAccountSnapshot

    @ObservationIgnored public weak var dataAdapter: (any SyncDataAdapter)?
    /// True while `applyRemoteData` runs. Local change notifications are ignored meanwhile.
    @ObservationIgnored public private(set) var isApplyingRemote = false

    public let dataRoot: URL
    /// Called synchronously on the main actor right after `snapshot` changes.
    @ObservationIgnored public var onSnapshotDidChange: (@MainActor (SyncAccountSnapshot) -> Void)?
    private let stateStore: SyncStateStore
    private let credentialStore: any SyncCredentialStoring
    private let preferredDeviceName: String?
    private let stateWriter = SyncStateWriter()
    /// Serializes Keychain/file writes of the secrets off the main actor, in call order.
    private let credentialWriter = SyncCredentialWriter()

    @ObservationIgnored private var state: SyncPersistedState?
    @ObservationIgnored private var credentials: SyncCredentials?
    @ObservationIgnored private var client: SyncClient?
    @ObservationIgnored private var webSocket: SyncWebSocketClient?
    @ObservationIgnored private var vaultKeys: SyncCrypto.VaultKeys?
    @ObservationIgnored private var status: SyncStatus = .signedOut
    @ObservationIgnored private var warnings: [String] = []
    @ObservationIgnored private var devices: [SyncDeviceInfo] = []
    @ObservationIgnored private var lastReauthEmail: String?

    @ObservationIgnored private var started = false
    @ObservationIgnored private var sessionGeneration = 0
    @ObservationIgnored private var stateSequence = 0
    @ObservationIgnored private var credentialSequence = 0
    @ObservationIgnored private var currentSync: Task<Void, any Error>?
    @ObservationIgnored private var currentSyncID = 0
    @ObservationIgnored private var followUpRequested = false
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var pushBurstStartedAt: Date?

    /// - Parameters:
    ///   - dataRoot: The App data root; state lives in `State/sync-state.json`.
    ///   - useFileCredentialStore: Store secrets in a `0600` file instead of the Keychain
    ///     (mock Keychain, ad-hoc signing, isolated data roots).
    public init(dataRoot: URL, useFileCredentialStore: Bool = false, credentialStore: (any SyncCredentialStoring)? = nil, deviceName: String? = nil) {
        self.dataRoot = dataRoot
        self.stateStore = SyncStateStore(root: dataRoot)
        let store = credentialStore ?? SyncCredentialStore(dataRoot: dataRoot, useFileStore: useFileCredentialStore)
        self.credentialStore = store
        self.preferredDeviceName = deviceName
        self.snapshot = SyncAccountSnapshot(usesFileCredentialStore: store.usesFileBackend)
    }

    public var isSignedIn: Bool { state?.accountId != nil && client != nil && vaultKeys != nil }

    // MARK: Start

    /// Cheap when signed out (one `stat`). Otherwise loads state and secrets off the main
    /// thread, connects the wakeup socket, and runs one sync pass in the background.
    public func startIfSignedIn() {
        guard !started else { return }
        started = true
        guard SyncStateStore.hasSavedAccount(in: dataRoot) else { return }
        let store = stateStore, secrets = credentialStore
        let generation = sessionGeneration
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { () -> (SyncPersistedState?, SyncCredentials?, String?) in
                do {
                    let state = try store.load()
                    let credentials = try (state?.accountId == nil ? nil : secrets.load())
                    return (state, credentials, nil)
                } catch {
                    return (nil, nil, SyncError.wrap(error).localizedDescription)
                }
            }.value
            guard let self, self.sessionGeneration == generation, self.state == nil else { return }
            self.resume(state: loaded.0, credentials: loaded.1, loadError: loaded.2)
        }
    }

    private func resume(state loaded: SyncPersistedState?, credentials: SyncCredentials?, loadError: String?) {
        if let loadError { setStatus(.error(loadError)); return }
        guard let loaded, let accountId = loaded.accountId, !accountId.isEmpty else { return }
        var vaultKey = credentials.flatMap { Data(base64Encoded: $0.vaultKeyBase64) } ?? Data()
        defer { SyncCrypto.zeroData(&vaultKey) }
        guard let credentials, let keys = try? SyncCrypto.VaultKeys(vaultKey: vaultKey) else {
            lastReauthEmail = loaded.email
            state = loaded
            setStatus(.needsReauth("Sign in to Open Sync again to keep syncing."))
            return
        }
        guard let client = try? SyncClient(serverURL: loaded.serverURL, deviceId: loaded.deviceId, tokens: credentials.tokens) else {
            setStatus(.error(SyncError.invalidServerURL(loaded.serverURL).localizedDescription)); return
        }
        state = loaded
        installSession(client: client, keys: keys, credentials: credentials)
        if let summary = loaded.awaitingInitialChoice {
            setStatus(.awaitingInitialChoice(summary))
            return
        }
        setStatus(.idle)
        let handler = tokenUpdateHandler(), generation = sessionGeneration
        Task { [weak self] in
            await client.setTokenUpdateHandler(handler)
            guard let self, self.sessionGeneration == generation else { return }
            self.startWebSocket()
            self.requestSync()
        }
    }

    // MARK: Account

    /// Creates an account, uploads this Mac's data, and returns the formatted recovery key.
    /// Upload failures after the account exists do not throw: the key must reach the user.
    public func signUp(serverURL: String, email: String, password: String, displayName: String?) async throws -> String {
        let normalized = try validatedEmail(email)
        try validateNewPassword(password)
        if isSignedIn || state != nil { await clearLocalSession(status: .signedOut) }
        let deviceId = UUID().uuidString.lowercased()
        let client = try SyncClient(serverURL: serverURL, deviceId: deviceId)
        let deviceName = await resolvedDeviceName()
        setBusy("Creating your account…")
        defer { publish() }
        var material = try await Self.offMain { () -> SignUpMaterial in
            let params = try SyncKDFParams.generate()
            let vaultKey = try SyncCrypto.randomBytes(SyncCrypto.keyByteCount)
            var recovery = try SyncCrypto.generateRecoveryKey()
            defer { SyncCrypto.zeroData(&recovery.rawBytes) }
            let passwordKeys = try SyncCrypto.derivePasswordKeys(email: normalized, password: password, kdfParams: params)
            let recoveryKeys = SyncCrypto.deriveRecoveryKeys(recoveryKeyBytes: recovery.rawBytes)
            return SignUpMaterial(
                params: params, vaultKey: vaultKey, recoveryFormatted: recovery.formatted,
                authVerifier: passwordKeys.authVerifier, recoveryAuthVerifier: recoveryKeys.recoveryAuthVerifier,
                wrappedByPassword: try SyncCrypto.wrapVaultKey(vaultKey, wrapKey: passwordKeys.passwordWrapKey, kind: .password, email: normalized),
                wrappedByRecovery: try SyncCrypto.wrapVaultKey(vaultKey, wrapKey: recoveryKeys.recoveryWrapKey, kind: .recovery, email: normalized))
        }
        defer { material.zero() }
        let name = Self.truncated(displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", toScalars: SyncLimits.maxDisplayNameLength)
        let response: SyncAuthResponse
        do {
            response = try await client.register(SyncRegisterRequest(
                email: normalized, displayName: name,
                kdfParams: material.params, authVerifier: material.authVerifier.base64EncodedString(),
                recoveryAuthVerifier: material.recoveryAuthVerifier.base64EncodedString(),
                wrappedVaultKeyByPassword: material.wrappedByPassword.base64EncodedString(),
                wrappedVaultKeyByRecovery: material.wrappedByRecovery.base64EncodedString(),
                deviceId: deviceId, deviceName: deviceName, platform: SyncDefaults.platform))
        } catch {
            setStatus(.signedOut); throw SyncError.wrap(error)
        }
        try await establishSession(response: response, email: normalized, serverURL: serverURL, client: client,
                                   vaultKey: material.vaultKey, deviceName: deviceName)
        do { try await runSync() } catch { /* Status already shows the error. */ }
        startWebSocket()
        return material.recoveryFormatted
    }

    /// Signs in. Without cloud data this Mac's data is uploaded at once. With cloud data and no
    /// strategy, the account waits for `completeInitialSync(strategy:)`.
    public func signIn(serverURL: String, email: String, password: String, initialStrategy: FirstSyncStrategy? = nil) async throws -> SyncSignInOutcome {
        let normalized = try validatedEmail(email)
        guard !password.isEmpty else { throw SyncError.invalidCredentials }
        if isSignedIn || state != nil { await clearLocalSession(status: .signedOut) }
        let deviceId = UUID().uuidString.lowercased()
        let client = try SyncClient(serverURL: serverURL, deviceId: deviceId)
        let deviceName = await resolvedDeviceName()
        setBusy("Signing in…")
        defer { publish() }
        do {
            let params = try await client.kdfParams(email: normalized)
            var derived = try await Self.offMain { () -> DerivedPassword in
                let keys = try SyncCrypto.derivePasswordKeys(email: normalized, password: password, kdfParams: params)
                return DerivedPassword(authVerifier: keys.authVerifier, wrapKey: SyncCrypto.keyData(keys.passwordWrapKey))
            }
            defer { derived.zero() }
            let response = try await client.login(email: normalized, authVerifier: derived.authVerifier, deviceName: deviceName)
            var vaultKey = try Self.unwrap(response.wrappedVaultKeyByPassword, wrapKey: derived.wrapKey, kind: .password, email: normalized)
            defer { SyncCrypto.zeroData(&vaultKey) }
            try await establishSession(response: response, email: normalized, serverURL: serverURL, client: client,
                                       vaultKey: vaultKey, deviceName: deviceName)
            return try await finishSignIn(summary: response.cloudSummary, initialStrategy: initialStrategy)
        } catch {
            if !isSignedIn { setStatus(.signedOut) }
            throw SyncError.wrap(error)
        }
    }

    /// Resets the password with the recovery key. Returns the new recovery key: the old one stops working.
    public func recoverAccount(serverURL: String, email: String, recoveryKey: String, newPassword: String,
                               initialStrategy: FirstSyncStrategy? = nil) async throws -> (recoveryKey: String, outcome: SyncSignInOutcome) {
        let normalized = try validatedEmail(email)
        try validateNewPassword(newPassword)
        var recoveryBytes = try SyncCrypto.parseRecoveryKey(recoveryKey)
        defer { SyncCrypto.zeroData(&recoveryBytes) }
        if isSignedIn || state != nil { await clearLocalSession(status: .signedOut) }
        let deviceId = UUID().uuidString.lowercased()
        let client = try SyncClient(serverURL: serverURL, deviceId: deviceId)
        let deviceName = await resolvedDeviceName()
        setBusy("Recovering your account…")
        defer { publish() }
        do {
            let oldKeys = SyncCrypto.deriveRecoveryKeys(recoveryKeyBytes: recoveryBytes)
            var oldVerifier = oldKeys.recoveryAuthVerifier
            defer { SyncCrypto.zeroData(&oldVerifier) }
            let challenge = try await client.recoveryChallenge(email: normalized, recoveryAuthVerifier: oldVerifier)
            guard let wrapped = Data(base64Encoded: challenge.wrappedVaultKeyByRecovery) else { throw SyncError.invalidRecoveryKey }
            var vaultKey = try SyncCrypto.unwrapVaultKey(wrapped, wrapKey: oldKeys.recoveryWrapKey, kind: .recovery, email: normalized)
            defer { SyncCrypto.zeroData(&vaultKey) }
            let currentVaultKey = vaultKey
            var material = try await Self.offMain { () -> RecoveryMaterial in
                let vaultKey = currentVaultKey
                let params = try SyncKDFParams.generate()
                var recovery = try SyncCrypto.generateRecoveryKey()
                defer { SyncCrypto.zeroData(&recovery.rawBytes) }
                let passwordKeys = try SyncCrypto.derivePasswordKeys(email: normalized, password: newPassword, kdfParams: params)
                let recoveryKeys = SyncCrypto.deriveRecoveryKeys(recoveryKeyBytes: recovery.rawBytes)
                return RecoveryMaterial(
                    params: params, recoveryFormatted: recovery.formatted,
                    authVerifier: passwordKeys.authVerifier, recoveryAuthVerifier: recoveryKeys.recoveryAuthVerifier,
                    wrappedByPassword: try SyncCrypto.wrapVaultKey(vaultKey, wrapKey: passwordKeys.passwordWrapKey, kind: .password, email: normalized),
                    wrappedByRecovery: try SyncCrypto.wrapVaultKey(vaultKey, wrapKey: recoveryKeys.recoveryWrapKey, kind: .recovery, email: normalized))
            }
            defer { material.zero() }
            let response = try await client.recover(SyncRecoverRequest(
                email: normalized, recoveryTicket: challenge.recoveryTicket, newKdfParams: material.params,
                newAuthVerifier: material.authVerifier.base64EncodedString(),
                newRecoveryAuthVerifier: material.recoveryAuthVerifier.base64EncodedString(),
                newWrappedVaultKeyByPassword: material.wrappedByPassword.base64EncodedString(),
                newWrappedVaultKeyByRecovery: material.wrappedByRecovery.base64EncodedString(),
                deviceId: deviceId, deviceName: deviceName, platform: SyncDefaults.platform))
            guard response.accountId == challenge.accountId else { throw SyncError.decoding("The recovered account does not match.") }
            try await establishSession(response: response, email: normalized, serverURL: serverURL, client: client,
                                       vaultKey: vaultKey, deviceName: deviceName)
            // The password changed: the account exists with its new key even if the first sync fails.
            let outcome: SyncSignInOutcome
            do { outcome = try await finishSignIn(summary: response.cloudSummary, initialStrategy: initialStrategy) }
            catch { outcome = .synced }
            return (material.recoveryFormatted, outcome)
        } catch {
            if !isSignedIn { setStatus(.signedOut) }
            throw SyncError.wrap(error)
        }
    }

    private func finishSignIn(summary: SyncCloudSummary, initialStrategy: FirstSyncStrategy?) async throws -> SyncSignInOutcome {
        if !summary.hasCloudData {
            // Signed in either way; the status shows an upload failure and the next pass retries.
            do { try await runSync() } catch {}
            startWebSocket()
            return .synced
        }
        // The choice stays pending until an initial sync succeeds, also across relaunches.
        mutateState { $0.awaitingInitialChoice = summary }
        await flushState()
        if let initialStrategy {
            try await completeInitialSync(strategy: initialStrategy)
            return .synced
        }
        setStatus(.awaitingInitialChoice(summary))
        return .needsInitialChoice(summary)
    }

    /// Runs the first sync with the chosen strategy, then starts normal syncing.
    public func completeInitialSync(strategy: FirstSyncStrategy) async throws {
        guard isSignedIn else { throw SyncError.notSignedIn }
        if let running = currentSync { _ = try? await running.value }
        let generation = sessionGeneration
        currentSyncID &+= 1
        let syncID = currentSyncID
        let task = Task { @MainActor [weak self] () throws -> Void in
            guard let self else { return }
            defer { self.finishSyncTask(syncID) }
            do {
                try await self.runInitialPass(strategy: strategy, generation: generation)
            } catch {
                self.handleSyncFailure(error, generation: generation)
                throw error
            }
        }
        currentSync = task
        publish()
        try await task.value
        guard sessionGeneration == generation else { return }
        startWebSocket()
        // A sync requested while the first sync ran (or deferred attachments) runs now.
        if followUpRequested {
            followUpRequested = false
            requestSync()
        }
    }

    public func changePassword(currentPassword: String, newPassword: String, revokeOtherSessions: Bool) async throws {
        guard let client, let email = state?.email, let credentials,
              var vaultKey = Data(base64Encoded: credentials.vaultKeyBase64) else { throw SyncError.notSignedIn }
        defer { SyncCrypto.zeroData(&vaultKey) }
        try validateNewPassword(newPassword)
        let params = try await client.kdfParams(email: email)
        let currentVaultKey = vaultKey
        var material = try await Self.offMain { () -> PasswordChangeMaterial in
            let vaultKey = currentVaultKey
            let current = try SyncCrypto.derivePasswordKeys(email: email, password: currentPassword, kdfParams: params)
            let newParams = try SyncKDFParams.generate()
            let fresh = try SyncCrypto.derivePasswordKeys(email: email, password: newPassword, kdfParams: newParams)
            return PasswordChangeMaterial(currentAuthVerifier: current.authVerifier, params: newParams, authVerifier: fresh.authVerifier,
                                          wrapped: try SyncCrypto.wrapVaultKey(vaultKey, wrapKey: fresh.passwordWrapKey, kind: .password, email: email))
        }
        defer { material.zero() }
        _ = try await client.changePassword(SyncChangePasswordRequest(
            currentAuthVerifier: material.currentAuthVerifier.base64EncodedString(), newKdfParams: material.params,
            newAuthVerifier: material.authVerifier.base64EncodedString(),
            newWrappedVaultKeyByPassword: material.wrapped.base64EncodedString(), revokeOtherSessions: revokeOtherSessions))
        if revokeOtherSessions { _ = try? await refreshDevices() }
    }

    public func updateDisplayName(_ displayName: String) async throws {
        guard let client else { throw SyncError.notSignedIn }
        let trimmed = Self.truncated(displayName.trimmingCharacters(in: .whitespacesAndNewlines), toScalars: SyncLimits.maxDisplayNameLength)
        let saved = try await client.updateDisplayName(trimmed)
        mutateState { $0.displayName = saved }
        publish()
    }

    @discardableResult
    public func refreshDevices() async throws -> [SyncDeviceInfo] {
        guard let client else { throw SyncError.notSignedIn }
        let account: SyncAccountResponse
        do { account = try await client.getAccount() } catch { throw handleAuthError(error) }
        let ownId = state?.deviceId
        devices = account.devices.map { device in
            var info = device.info
            if device.isCurrent == nil { info.isCurrent = device.deviceId == ownId }
            return info
        }.sorted { ($0.isCurrent ? 0 : 1, $0.deviceName) < ($1.isCurrent ? 0 : 1, $1.deviceName) }
        mutateState { $0.displayName = account.displayName ?? $0.displayName }
        publish()
        return devices
    }

    public func revokeDevice(deviceId: String) async throws {
        guard let client else { throw SyncError.notSignedIn }
        if deviceId == state?.deviceId { await signOut(); return }
        do { try await client.revokeDevice(deviceId: deviceId) } catch { throw handleAuthError(error) }
        devices.removeAll { $0.deviceId == deviceId }
        publish()
        _ = try? await refreshDevices()
    }

    /// Ends the session on the server (best effort, 3 s) and forgets local secrets and state.
    /// Local browser data stays as it is.
    public func signOut() async {
        let client = self.client
        lastReauthEmail = nil
        sessionGeneration &+= 1
        cancelWork()
        if let client { await Self.withTimeout(seconds: 3) { _ = try? await client.logout() } }
        await clearLocalSession(status: .signedOut)
    }

    /// Deletes the account and every synced record on the server, then signs out locally.
    public func deleteAccount(password: String) async throws {
        guard let client, let email = state?.email else { throw SyncError.notSignedIn }
        let params = try await client.kdfParams(email: email)
        var auth = try await Self.offMain { () -> Data in
            try SyncCrypto.derivePasswordKeys(email: email, password: password, kdfParams: params).authVerifier
        }
        defer { SyncCrypto.zeroData(&auth) }
        try await client.deleteAccount(authVerifier: auth)
        sessionGeneration &+= 1
        cancelWork()
        await clearLocalSession(status: .signedOut)
    }

    // MARK: Sync control

    /// Pull, apply, collect, push. A call during a running pass waits for one follow-up pass.
    public func syncNow() async throws {
        guard isSignedIn else { throw SyncError.notSignedIn }
        guard state?.awaitingInitialChoice == nil else { throw SyncError.awaitingInitialChoice }
        try await runSync()
    }

    /// Debounced push after a local change: 2 s after the last change, at most 10 s after the first.
    public func schedulePush(reason: String) {
        guard isSignedIn, !isApplyingRemote, state?.awaitingInitialChoice == nil else { return }
        if case .needsReauth = status { return }
        let now = Date()
        let burstStart = pushBurstStartedAt ?? now
        pushBurstStartedAt = burstStart
        let elapsed = now.timeIntervalSince(burstStart)
        let delay = max(0, min(SyncDefaults.pushDebounceSeconds, SyncDefaults.pushMaxCoalesceSeconds - elapsed))
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.pushTask = nil
            self.pushBurstStartedAt = nil
            _ = try? await self.syncNow()
        }
    }

    /// Switches a category. Switching one on pulls its full cloud history on the next pass.
    public func setCategoryEnabled(_ enabled: Bool, for category: SyncCategory) {
        guard state != nil else {
            var categories = snapshot.categories
            categories.setEnabled(enabled, for: category)
            snapshot.categories = categories
            return
        }
        mutateState { state in
            state.categories.setEnabled(enabled, for: category)
            if enabled {
                if !state.pendingBackfillCategories.contains(category) { state.pendingBackfillCategories.append(category) }
            } else {
                state.pendingBackfillCategories.removeAll { $0 == category }
            }
        }
        saveStateInBackground()
        publish()
        if enabled { requestSync() }
    }

    /// Removes resolved entries (installed or declined) from the pending extension list.
    public func resolvePendingExtensionInstalls(ids: [String]) {
        let resolved = Set(ids)
        mutateState { $0.pendingExtensionInstalls.removeAll { resolved.contains($0.id) } }
        saveStateInBackground()
        publish()
    }

    /// For app termination: runs a pending debounced push (bounded by `timeoutSeconds`),
    /// closes the socket, and writes state.
    public func stopAndFlush(timeoutSeconds: Double = 3.0) async {
        let hadPendingPush = pushTask != nil
        pushTask?.cancel(); pushTask = nil; pushBurstStartedAt = nil
        if let webSocket { await webSocket.disconnect() }
        webSocket = nil
        if isSignedIn, state?.awaitingInitialChoice == nil, hadPendingPush || currentSync != nil {
            await Self.withTimeout(seconds: timeoutSeconds) { [weak self] in _ = try? await self?.syncNow() }
        }
        await flushState()
    }

    // MARK: Session plumbing

    private func establishSession(response: SyncAuthResponse, email: String, serverURL: String, client: SyncClient,
                                  vaultKey: Data, deviceName: String) async throws {
        let keys = try SyncCrypto.VaultKeys(vaultKey: vaultKey)
        let credentials = SyncCredentials(accessToken: response.accessToken, refreshToken: response.refreshToken,
                                          accessTokenExpiresAt: response.accessTokenExpiresAt, vaultKeyBase64: vaultKey.base64EncodedString())
        credentialSequence &+= 1
        try await credentialWriter.save(credentials, store: credentialStore, sequence: credentialSequence)
        let categories = state?.categories ?? snapshot.categories
        let normalizedURL = (try? SyncClient.validatedBaseURL(serverURL).absoluteString) ?? serverURL
        let fresh = SyncPersistedState(serverURL: normalizedURL, accountId: response.accountId, email: response.email.isEmpty ? email : response.email,
                                       displayName: response.displayName?.isEmpty == false ? response.displayName : nil,
                                       deviceId: client.deviceId, deviceName: deviceName,
                                       lastPulledRevision: 0, lastResetRevision: response.resetRevision, categories: categories)
        sessionGeneration &+= 1
        state = fresh
        warnings = []
        devices = []
        await client.setTokens(response.tokens)
        await client.setTokenUpdateHandler(tokenUpdateHandler())
        installSession(client: client, keys: keys, credentials: credentials)
        await flushState()
        setStatus(.idle)
    }

    private func installSession(client: SyncClient, keys: SyncCrypto.VaultKeys, credentials: SyncCredentials) {
        self.client = client
        self.vaultKeys = keys
        self.credentials = credentials
    }

    /// Bound to the current session: a refresh that ends after sign-out or an account switch
    /// never writes its tokens over the next session's secrets.
    private func tokenUpdateHandler() -> @Sendable (SyncTokens) async -> Void {
        let generation = sessionGeneration
        return { [weak self] tokens in await self?.persistRotatedTokens(tokens, generation: generation) }
    }

    /// Saves a rotated token pair before the client uses it: the old refresh token is spent.
    /// The Keychain write runs off the main actor, in order with every other secrets write.
    private func persistRotatedTokens(_ tokens: SyncTokens, generation: Int) async {
        guard generation == sessionGeneration, var credentials else { return }
        credentials.accessToken = tokens.accessToken
        credentials.refreshToken = tokens.refreshToken
        credentials.accessTokenExpiresAt = tokens.accessTokenExpiresAt
        self.credentials = credentials
        credentialSequence &+= 1
        do { try await credentialWriter.save(credentials, store: credentialStore, sequence: credentialSequence) }
        catch {
            guard generation == sessionGeneration else { return }
            appendWarning("Could not save the refreshed sync session: \(SyncError.wrap(error).localizedDescription)")
        }
    }

    private func startWebSocket() {
        guard webSocket == nil, isSignedIn, state?.awaitingInitialChoice == nil, let client, let state else { return }
        guard let base = try? SyncClient.validatedBaseURL(state.serverURL) else { return }
        let generation = sessionGeneration
        let socket = SyncWebSocketClient(
            serverURL: base, deviceId: state.deviceId,
            tokenProvider: { [weak client] force in
                guard let client else { throw SyncError.notSignedIn }
                return try await client.validAccessToken(forceRefresh: force)
            },
            handlers: SyncWebSocketClient.Handlers(
                onConnected: { [weak self] revision, reset in await self?.handleWakeup(revision: revision, resetRevision: reset, generation: generation) },
                onWakeup: { [weak self] revision, reset, _ in await self?.handleWakeup(revision: revision, resetRevision: reset, generation: generation) },
                onSessionRevoked: { [weak self] in await self?.handleSessionRevoked(generation: generation) }))
        webSocket = socket
        Task { await socket.connect() }
    }

    private func handleWakeup(revision: Int, resetRevision: Int, generation: Int) {
        guard generation == sessionGeneration, let state, state.awaitingInitialChoice == nil else { return }
        if revision > state.lastPulledRevision || resetRevision > state.lastResetRevision { requestSync() }
    }

    private func handleSessionRevoked(generation: Int) async {
        guard generation == sessionGeneration else { return }
        let email = state?.email
        sessionGeneration &+= 1
        cancelWork()
        await clearLocalSession(status: .needsReauth("This Mac was signed out of Open Sync. Sign in again to keep syncing."))
        lastReauthEmail = email
        publish()
    }

    private func requestSync() {
        guard isSignedIn, state?.awaitingInitialChoice == nil else { return }
        Task { [weak self] in _ = try? await self?.syncNow() }
    }

    private func cancelWork() {
        pushTask?.cancel(); pushTask = nil; pushBurstStartedAt = nil
        currentSync?.cancel(); currentSync = nil
        followUpRequested = false
        if let webSocket { Task { await webSocket.disconnect() } }
        webSocket = nil
    }

    private func clearLocalSession(status newStatus: SyncStatus) async {
        sessionGeneration &+= 1
        cancelWork()
        // Signed out: a refresh in flight must not save tokens or call back.
        if let oldClient = client { await oldClient.setTokens(nil) }
        credentialSequence &+= 1
        try? await credentialWriter.clear(store: credentialStore, sequence: credentialSequence)
        stateSequence &+= 1
        await stateWriter.delete(store: stateStore, sequence: stateSequence)
        let categories = state?.categories ?? snapshot.categories
        state = nil; credentials = nil; client = nil; vaultKeys = nil
        devices = []; warnings = []
        snapshot.categories = categories
        setStatus(newStatus)
    }

    // MARK: Pass orchestration

    private func runSync() async throws {
        if let running = currentSync {
            followUpRequested = true
            try await running.value
            return
        }
        let generation = sessionGeneration
        currentSyncID &+= 1
        let syncID = currentSyncID
        let task = Task { @MainActor [weak self] () throws -> Void in
            guard let self else { return }
            defer { self.finishSyncTask(syncID) }
            do {
                repeat {
                    self.followUpRequested = false
                    try await self.runPass(generation: generation)
                } while self.followUpRequested && self.sessionGeneration == generation
            } catch {
                self.handleSyncFailure(error, generation: generation)
                throw error
            }
        }
        currentSync = task
        publish()
        try await task.value
    }

    private func finishSyncTask(_ id: Int) {
        if currentSyncID == id { currentSync = nil }
        publish()
    }

    private func handleSyncFailure(_ error: any Error, generation: Int) {
        guard generation == sessionGeneration else { return }
        let wrapped = SyncError.wrap(error)
        switch wrapped {
        case .cancelled: setStatus(.idle)
        case .sessionExpired:
            lastReauthEmail = state?.email
            setStatus(.needsReauth(wrapped.localizedDescription))
        default: setStatus(.error(wrapped.localizedDescription))
        }
    }

    private func handleAuthError(_ error: any Error) -> SyncError {
        let wrapped = SyncError.wrap(error)
        if wrapped.requiresReauthentication {
            lastReauthEmail = state?.email
            setStatus(.needsReauth(wrapped.localizedDescription))
        }
        return wrapped
    }

    private struct Context {
        let client: SyncClient
        let keys: SyncCrypto.VaultKeys
        let accountId: String
        let adapter: any SyncDataAdapter
    }

    private func context(_ generation: Int) throws -> Context {
        guard generation == sessionGeneration else { throw SyncError.cancelled }
        guard let client, let vaultKeys, let accountId = state?.accountId else { throw SyncError.notSignedIn }
        guard let adapter = dataAdapter else { throw SyncError.noDataAdapter }
        return Context(client: client, keys: vaultKeys, accountId: accountId, adapter: adapter)
    }

    /// Pull from the cursor. A cloud reset since the last pull takes the whole account again.
    private func pullForPass(_ ctx: Context, current: SyncPersistedState) async throws -> (pull: PullResult, fullReset: Bool) {
        let pull = try await pullAll(ctx, since: current.lastPulledRevision, collections: nil)
        if !pull.fullResync, pull.resetRevision > current.lastResetRevision, current.lastPulledRevision > 0 {
            // The cloud was replaced since the last pull.
            return (try await pullAll(ctx, since: 0, collections: nil), true)
        }
        return (pull, pull.fullResync)
    }

    /// The newest revision of each record, in first-seen order.
    private static func mergeNewest(_ base: [SyncRemoteRecord], _ extra: [SyncRemoteRecord]) -> [SyncRemoteRecord] {
        guard !extra.isEmpty else { return base }
        var byKey: [String: SyncRemoteRecord] = [:]
        var order: [String] = []
        for record in base + extra {
            let key = SyncPersistedState.mirrorKey(record.collection, record.recordId)
            if let existing = byKey[key] {
                if existing.revision < record.revision { byKey[key] = record }
            } else {
                byKey[key] = record
                order.append(key)
            }
        }
        return order.compactMap { byKey[$0] }
    }

    /// Keys `pushDiff` would send for `local`: changed or new records, and tombstones for
    /// mirrored records that a complete collection no longer lists.
    private static func dirtyKeys(_ local: HashedBundle, mirror: [String: SyncRecordMirror]) -> Set<String> {
        var dirty = Set<String>()
        for (key, item) in local.records {
            if let known = mirror[key], !known.deleted, known.payloadHash == item.hash { continue }
            dirty.insert(key)
        }
        for (key, known) in mirror where !known.deleted && local.records[key] == nil {
            if let parsed = SyncPersistedState.parseMirrorKey(key), local.completeCollections.contains(parsed.collection) { dirty.insert(key) }
        }
        return dirty
    }

    /// Records left for later: the next pass pulls their collections again from revision 0
    /// (their mirror entries stay unset, so they count as changed).
    private func deferRecords(_ keys: Set<String>, warnings: inout [String]) {
        guard !keys.isEmpty else { return }
        let categories = Set(keys.compactMap { SyncPersistedState.parseMirrorKey($0)?.collection.category })
        mutateState { state in
            for category in categories.sorted(by: { $0.rawValue < $1.rawValue }) where !state.pendingBackfillCategories.contains(category) {
                state.pendingBackfillCategories.append(category)
            }
        }
        saveStateInBackground()
        followUpRequested = true
        warnings.append("Some attachments are still downloading; their Easels and Notes follow in the next sync pass.")
    }

    /// One normal pass. Local edits made since the last pass are pushed before remote changes
    /// are applied: the server keeps the copy with the newer `clientUpdatedAt` (last writer
    /// wins), so an older remote copy never overwrites a newer local edit. When this Mac has no
    /// local edits (an idle wakeup), the pass only pulls and applies. Up to two extra rounds run
    /// when the final push reports conflicts.
    private func runPass(generation: Int) async throws {
        var passWarnings: [String] = []
        for _ in 0..<3 {
            let ctx = try context(generation)
            guard var current = state else { throw SyncError.notSignedIn }
            let categories = current.categories
            let enabled = categories.enabledCollections

            setStatus(.syncing("Checking for changes…"))
            var (pull, fullReset) = try await pullForPass(ctx, current: current)
            _ = try context(generation)
            let backfill = current.pendingBackfillCategories.filter { categories.isEnabled($0) }
            let backfillCollections = Set(backfill.flatMap(\.collections))
            var backfillRecords: [SyncRemoteRecord] = []
            if !fullReset, !backfill.isEmpty {
                let extra = try await pullAll(ctx, since: 0, collections: backfill.flatMap(\.collections))
                passWarnings += extra.warnings
                backfillRecords = extra.records
                pull.records = Self.mergeNewest(pull.records, backfillRecords)
            }
            _ = try context(generation)
            passWarnings += pull.warnings

            // Local state before any remote record is applied.
            var preApplyLocal: HashedBundle?
            var dirtyBeforeApply = Set<String>()
            var pushedFirst = Set<String>()
            var cursorAfterPush: Int?
            if !fullReset {
                let local = try await collectHashed(ctx, categories: categories)
                _ = try context(generation)
                passWarnings += local.warnings
                preApplyLocal = local
                dirtyBeforeApply = Self.dirtyKeys(local, mirror: current.mirror)
                // A category switched on merges with its cloud copy first, so it is not pushed first.
                let first = local.excluding(backfillCollections)
                if !Self.dirtyKeys(first, mirror: current.mirror).isEmpty {
                    setStatus(.syncing("Uploading changes…"))
                    let early = try await pushDiff(ctx, local: first, mode: .delta, generation: generation,
                                                   cursorBase: pull.currentRevision, warnings: &passWarnings)
                    guard let afterPush = state else { throw SyncError.notSignedIn }
                    let stillDirty = Self.dirtyKeys(local, mirror: afterPush.mirror)
                    // Accepted: these keys now hold this Mac's copy, which supersedes the pulled one.
                    pushedFirst = dirtyBeforeApply.subtracting(stillDirty)
                    dirtyBeforeApply = stillDirty
                    current = afterPush
                    cursorAfterPush = early.cleanCursor
                    if early.hadConflicts {
                        // The server holds strictly newer copies of some records: pull them; they win.
                        setStatus(.syncing("Checking for changes…"))
                        let again = try await pullForPass(ctx, current: current)
                        _ = try context(generation)
                        passWarnings += again.pull.warnings
                        pull = again.pull
                        fullReset = again.fullReset
                        if !fullReset { pull.records = Self.mergeNewest(pull.records, backfillRecords) }
                        cursorAfterPush = nil
                    }
                }
            }
            if fullReset { preApplyLocal = nil; dirtyBeforeApply = []; pushedFirst = [] }

            let remote = pull.records.filter {
                enabled.contains($0.collection) && !pushedFirst.contains(SyncPersistedState.mirrorKey($0.collection, $0.recordId))
            }
            var changed: [SyncRemoteRecord] = []
            if fullReset {
                current.mirror = current.mirror.filter { key, _ in
                    SyncPersistedState.parseMirrorKey(key).map { !enabled.contains($0.collection) } ?? false
                }
                changed = remote.filter { !$0.deleted }
            } else {
                for record in remote {
                    let key = SyncPersistedState.mirrorKey(record.collection, record.recordId)
                    let known = current.mirror[key]
                    if known == nil, record.deleted { continue }
                    if let known, known.payloadHash == record.payloadHash, known.deleted == record.deleted { continue }
                    changed.append(record)
                }
            }

            var echoCandidates = Set<String>()
            var newPending: [SyncPendingExtension] = []
            var deferred = Set<String>()
            if !changed.isEmpty {
                setStatus(.syncing("Applying changes…"))
                let download = try await downloadBlobs(ctx, for: changed, warnings: &passWarnings)
                _ = try context(generation)
                deferred = download.deferredKeys
                changed.removeAll { deferred.contains(SyncPersistedState.mirrorKey($0.collection, $0.recordId)) }
                if fullReset { try await ctx.adapter.prepareLocalBackup(root: dataRoot) }
                let bundle = SyncRemoteBundle(records: changed, blobs: download.blobs, isFullSnapshot: fullReset)
                let outcome = try await applyRemote(ctx, bundle: bundle, mode: fullReset ? .replaceLocal : .mergeOrDelta, categories: categories)
                _ = try context(generation)
                passWarnings += outcome.warnings
                newPending = outcome.pendingExtensionInstalls
                for record in changed {
                    let key = SyncPersistedState.mirrorKey(record.collection, record.recordId)
                    current.mirror[key] = SyncRecordMirror(payloadHash: record.payloadHash, clientUpdatedAt: record.clientUpdatedAt, deleted: record.deleted)
                    // A local edit the server refused (it had a newer copy) or a backfill merge is
                    // pushed again after the apply when the merged result differs.
                    if !dirtyBeforeApply.contains(key) { echoCandidates.insert(key) }
                }
                for id in download.blobs.keys where !current.uploadedBlobIDs.contains(id) { current.uploadedBlobIDs.append(id) }
            }
            // Tombstones the server sent for records this device never had.
            for record in remote where record.deleted && current.mirror[SyncPersistedState.mirrorKey(record.collection, record.recordId)] == nil {
                current.mirror[SyncPersistedState.mirrorKey(record.collection, record.recordId)] =
                    SyncRecordMirror(payloadHash: record.payloadHash, clientUpdatedAt: record.clientUpdatedAt, deleted: true)
            }
            current.lastPulledRevision = max(pull.currentRevision, cursorAfterPush ?? 0)
            current.lastResetRevision = max(current.lastResetRevision, pull.resetRevision)
            if pull.truncated { followUpRequested = true }
            commitSyncFields(current, processedBackfill: backfill, newPending: newPending)
            deferRecords(deferred, warnings: &passWarnings)

            // Nothing arrived and the first push covered every collection: nothing is left to send.
            if changed.isEmpty, preApplyLocal != nil, backfillCollections.isEmpty { break }
            setStatus(.syncing("Uploading changes…"))
            let local: HashedBundle
            if changed.isEmpty, let preApplyLocal {
                local = preApplyLocal
            } else {
                local = try await collectHashed(ctx, categories: categories)
                _ = try context(generation)
                passWarnings += local.warnings
            }
            guard var afterApply = state else { throw SyncError.notSignedIn }
            suppressEchoes(echoCandidates, local: local, state: &afterApply)
            commitState(afterApply)
            let result = try await pushDiff(ctx, local: local, mode: .delta, generation: generation, warnings: &passWarnings)
            if !result.hadConflicts { break }
        }
        mutateState { $0.lastSyncAt = Date() }
        saveStateInBackground()
        warnings = Self.dedupe(passWarnings)
        setStatus(.idle)
    }

    private func runInitialPass(strategy: FirstSyncStrategy, generation: Int) async throws {
        var passWarnings: [String] = []
        let ctx = try context(generation)
        guard var current = state else { throw SyncError.notSignedIn }
        let categories = current.categories
        let enabled = categories.enabledCollections

        switch strategy {
        case .replaceLocalWithCloud, .mergeLocalAndCloud:
            setStatus(.syncing("Downloading your cloud data…"))
            current.mirror = [:]
            let pull = try await pullAll(ctx, since: 0, collections: nil)
            _ = try context(generation)
            passWarnings += pull.warnings
            var remote = pull.records.filter { enabled.contains($0.collection) && !$0.deleted }
            let download = try await downloadBlobs(ctx, for: remote, warnings: &passWarnings)
            _ = try context(generation)
            let deferred = download.deferredKeys
            remote.removeAll { deferred.contains(SyncPersistedState.mirrorKey($0.collection, $0.recordId)) }
            let replace = strategy == .replaceLocalWithCloud
            setStatus(.syncing(replace ? "Replacing this Mac's data…" : "Merging…"))
            if replace { try await ctx.adapter.prepareLocalBackup(root: dataRoot) }
            let outcome = try await applyRemote(ctx, bundle: SyncRemoteBundle(records: remote, blobs: download.blobs, isFullSnapshot: true),
                                                mode: replace ? .replaceLocal : .mergeOrDelta, categories: categories)
            _ = try context(generation)
            passWarnings += outcome.warnings
            var applied = Set<String>()
            for record in pull.records where enabled.contains(record.collection) {
                let key = SyncPersistedState.mirrorKey(record.collection, record.recordId)
                guard !deferred.contains(key) else { continue }
                current.mirror[key] = SyncRecordMirror(payloadHash: record.payloadHash, clientUpdatedAt: record.clientUpdatedAt, deleted: record.deleted)
                if !record.deleted { applied.insert(key) }
            }
            for id in download.blobs.keys where !current.uploadedBlobIDs.contains(id) { current.uploadedBlobIDs.append(id) }
            current.lastPulledRevision = pull.currentRevision
            current.lastResetRevision = pull.resetRevision
            commitSyncFields(current, processedBackfill: SyncCategory.allCases, newPending: outcome.pendingExtensionInstalls)
            deferRecords(deferred, warnings: &passWarnings)

            setStatus(.syncing(replace ? "Finishing…" : "Uploading this Mac's data…"))
            let local = try await collectHashed(ctx, categories: categories)
            _ = try context(generation)
            passWarnings += local.warnings
            guard var afterApply = state else { throw SyncError.notSignedIn }
            if replace {
                // This Mac now holds the cloud copy. Record the local form of what was applied and
                // upload nothing: local items the cloud did not have were meant to be replaced.
                suppressEchoes(applied, local: local, state: &afterApply)
                commitState(afterApply)
            } else {
                // Merge: push the merged result.
                commitState(afterApply)
                let result = try await pushDiff(ctx, local: local, mode: .delta, generation: generation, warnings: &passWarnings)
                if result.hadConflicts {
                    mutateState { $0.awaitingInitialChoice = nil }
                    try await runPass(generation: generation)
                }
            }

        case .replaceCloudWithLocal:
            setStatus(.syncing("Replacing your cloud data…"))
            let local = try await collectHashed(ctx, categories: categories)
            _ = try context(generation)
            passWarnings += local.warnings
            current.mirror = [:]
            commitSyncFields(current, processedBackfill: SyncCategory.allCases)
            let result = try await pushDiff(ctx, local: local, mode: .replaceCloud, generation: generation, warnings: &passWarnings)
            _ = try context(generation)
            // After the reset only this Mac's records exist: skip past them. If another device
            // pushed between batches, read again from the reset (own records match the mirror).
            mutateState { state in
                state.lastResetRevision = max(state.lastResetRevision, result.resetRevision)
                state.lastPulledRevision = result.cleanCursor ?? result.resetRevision
            }
            saveStateInBackground()
        }

        mutateState { state in
            state.awaitingInitialChoice = nil
            state.lastSyncAt = Date()
        }
        await flushState()
        warnings = Self.dedupe(passWarnings)
        setStatus(.idle)
    }

    // MARK: Pull

    private struct PullResult {
        var records: [SyncRemoteRecord]
        var currentRevision: Int
        var resetRevision: Int
        var fullResync: Bool
        var warnings: [String]
        /// A delta pull stopped at a cap; `currentRevision` is where the next pass continues.
        var truncated = false
    }

    /// Bounds on what one pull holds in memory.
    static let maxPulledRecords = 20_000
    static let maxPulledCiphertextBytes = 64 * 1024 * 1024
    /// Bounds on the attachments one pass downloads.
    static let maxBlobsPerPass = 256
    static let maxTotalBlobBytesPerPass = 64 * 1024 * 1024

    /// Pulls every page. A delta pull that reaches a cap stops after a whole page and continues
    /// in a follow-up pass; a full snapshot over a cap fails, because a partial snapshot would
    /// look like deletions.
    private func pullAll(_ ctx: Context, since start: Int, collections: [SyncCollection]?) async throws -> PullResult {
        var since = start
        var byKey: [String: SyncRemoteRecord] = [:]
        var order: [String] = []
        var result = PullResult(records: [], currentRevision: start, resetRevision: state?.lastResetRevision ?? 0, fullResync: false, warnings: [])
        var pages = 0
        var ciphertextBytes = 0
        while true {
            pages += 1
            if pages > 100_000 { throw SyncError.decoding("The server kept sending change pages.") }
            let page: SyncChangesResponse
            do { page = try await ctx.client.pullChanges(since: since, limit: SyncLimits.maxChangesLimit, collections: collections) }
            catch { throw handleAuthError(error) }
            try Task.checkCancellation()
            let restarted = page.fullResyncRequired && !result.fullResync
            if restarted {
                result.fullResync = true
                byKey.removeAll(); order.removeAll()
                ciphertextBytes = 0
            }
            ciphertextBytes += page.records.reduce(0) { $0 + $1.ciphertext.utf8.count }
            let keys = ctx.keys, accountId = ctx.accountId, wire = page.records
            let decrypted = try await Self.offMain { Self.decrypt(wire, keys: keys, accountId: accountId) }
            result.warnings += decrypted.warnings
            for record in decrypted.records {
                let key = SyncPersistedState.mirrorKey(record.collection, record.recordId)
                if let existing = byKey[key], existing.revision > record.revision { continue }
                if byKey[key] == nil { order.append(key) }
                byKey[key] = record
            }
            result.currentRevision = max(result.currentRevision, page.currentRevision)
            result.resetRevision = page.resetRevision
            if !page.hasMore { break }
            // A full resync restarts from revision 0 once; after that the cursor must advance.
            guard page.nextSince > since || restarted else {
                throw SyncError.decoding("The server's change cursor did not advance.")
            }
            since = page.nextSince
            if byKey.count >= Self.maxPulledRecords || ciphertextBytes >= Self.maxPulledCiphertextBytes {
                guard start > 0, !result.fullResync, collections == nil else {
                    throw SyncError.payloadTooLarge("The cloud data (more than \(Self.maxPulledRecords) records or 64 MB in one sync)")
                }
                // Everything up to `nextSince` is held; the rest arrives in the next pass.
                result.currentRevision = since
                result.truncated = true
                result.warnings.append("Open Sync received many changes at once; the rest follows in the next sync pass.")
                break
            }
        }
        result.records = order.compactMap { byKey[$0] }
        return result
    }

    private nonisolated static func decrypt(_ wire: [SyncWireRecord], keys: SyncCrypto.VaultKeys, accountId: String) -> (records: [SyncRemoteRecord], warnings: [String]) {
        var records: [SyncRemoteRecord] = []
        var warnings: [String] = []
        records.reserveCapacity(wire.count)
        let tombstoneHash = SyncCrypto.computePayloadHash(SyncCrypto.tombstonePayload, keys: keys)
        for item in wire {
            // Collections from a newer Open are skipped, not fatal.
            guard let collection = SyncCollection(rawValue: item.collection) else { continue }
            guard let combined = Data(base64Encoded: item.ciphertext) else {
                warnings.append("Skipped a damaged \(item.collection) record."); continue
            }
            do {
                let plaintext = try SyncCrypto.openRecord(combined, keys: keys, accountId: accountId, collection: item.collection,
                                                          recordId: item.recordId, deleted: item.deleted)
                records.append(SyncRemoteRecord(
                    collection: collection, recordId: item.recordId, deleted: item.deleted,
                    payload: item.deleted ? nil : plaintext, clientUpdatedAt: item.clientUpdatedAt, revision: item.revision,
                    updatedByDeviceId: item.updatedByDeviceId,
                    payloadHash: item.deleted ? tombstoneHash : SyncCrypto.computePayloadHash(plaintext, keys: keys)))
            } catch {
                warnings.append("Skipped a \(item.collection) record that failed to decrypt.")
            }
        }
        return (records, warnings)
    }

    /// Valid attachment references of one asset-carrying record.
    private static func assetRefs(_ record: SyncRemoteRecord) -> [SyncedAssetRef] {
        guard record.collection.carriesAssets, !record.deleted, let payload = record.payload,
              let probe = try? JSONDecoder().decode(SyncedAssetsProbe.self, from: payload) else { return [] }
        return (probe.assets ?? []).filter { SyncCrypto.isValidBlobID($0.blobId) }
    }

    /// Downloads and verifies the attachments `records` reference: at most `maxBlobsPerPass`
    /// files and about `maxTotalBlobBytesPerPass` bytes. It plans whole records, so a record is
    /// applied with all of its files or left for a later pass (`deferredKeys`). The first record
    /// with files always goes ahead, so every pass makes progress.
    private func downloadBlobs(_ ctx: Context, for records: [SyncRemoteRecord],
                               warnings: inout [String]) async throws -> (blobs: [String: Data], deferredKeys: Set<String>) {
        var planned: [[SyncedAssetRef]] = []
        var plannedIDs = Set<String>()
        var plannedBytes = 0
        var capSkippedIDs = Set<String>()
        for record in records {
            var fresh: [SyncedAssetRef] = []
            var freshIDs = Set<String>()
            for ref in Self.assetRefs(record) where !plannedIDs.contains(ref.blobId) && freshIDs.insert(ref.blobId).inserted { fresh.append(ref) }
            guard !fresh.isEmpty else { continue }
            let bytes = fresh.reduce(0) { $0 + max(0, $1.byteLength) + 28 }
            if !planned.isEmpty, plannedIDs.count + fresh.count > Self.maxBlobsPerPass || plannedBytes + bytes > Self.maxTotalBlobBytesPerPass {
                capSkippedIDs.formUnion(freshIDs); continue
            }
            planned.append(fresh); plannedIDs.formUnion(freshIDs); plannedBytes += bytes
        }
        guard !planned.isEmpty else { return ([:], []) }
        setStatus(.syncing("Downloading attachments…"))
        var blobs: [String: Data] = [:]
        var attemptedIDs = Set<String>()
        var totalBytes = 0
        for (index, refs) in planned.enumerated() {
            if index > 0, totalBytes >= Self.maxTotalBlobBytesPerPass {
                // The files were larger than their records said: leave the rest for later.
                for later in planned[index...] { capSkippedIDs.formUnion(later.map(\.blobId)) }
                break
            }
            for ref in refs {
                let blobId = ref.blobId
                try Task.checkCancellation()
                attemptedIDs.insert(blobId)
                let ciphertext: Data
                do { ciphertext = try await ctx.client.downloadBlob(blobId: blobId) }
                catch let error as SyncError {
                    if error.requiresReauthentication { throw handleAuthError(error) }
                    if case .cancelled = error { throw error }
                    warnings.append("Could not download \(ref.filename): \(error.localizedDescription)"); continue
                }
                totalBytes += ciphertext.count
                let keys = ctx.keys, accountId = ctx.accountId
                let plaintext = try await Self.offMain { () -> Data? in
                    guard let plain = try? SyncCrypto.openBlob(ciphertext, keys: keys, accountId: accountId, blobId: blobId),
                          SyncCrypto.computeBlobID(plain, keys: keys) == blobId,
                          SyncCrypto.sha256Hex(plain) == ref.sha256 else { return nil }
                    return plain
                }
                if let plaintext { blobs[blobId] = plaintext }
                else { warnings.append("Skipped \(ref.filename): the attachment failed verification.") }
            }
        }
        // A record waits when any of its files was left out by the cap (not when one failed).
        let missing = capSkippedIDs.subtracting(attemptedIDs)
        var deferredKeys = Set<String>()
        if !missing.isEmpty {
            for record in records where Self.assetRefs(record).contains(where: { missing.contains($0.blobId) }) {
                deferredKeys.insert(SyncPersistedState.mirrorKey(record.collection, record.recordId))
            }
        }
        return (blobs, deferredKeys)
    }

    private func applyRemote(_ ctx: Context, bundle: SyncRemoteBundle, mode: SyncApplyMode, categories: SyncCategorySettings) async throws -> SyncApplyOutcome {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        return try await ctx.adapter.applyRemoteData(bundle, mode: mode, categories: categories)
    }

    // MARK: Collect and push

    private struct HashedLocal: Sendable {
        let record: SyncLocalRecord
        let hash: String
    }

    private struct HashedBundle: Sendable {
        var records: [String: HashedLocal]
        var blobs: [SyncLocalBlob]
        var completeCollections: Set<SyncCollection>
        var warnings: [String]

        /// The bundle without `collections` (no records, no tombstones for them).
        func excluding(_ collections: Set<SyncCollection>) -> HashedBundle {
            guard !collections.isEmpty else { return self }
            return HashedBundle(records: records.filter { !collections.contains($0.value.record.collection) }, blobs: blobs,
                                completeCollections: completeCollections.subtracting(collections), warnings: warnings)
        }
    }

    private func collectHashed(_ ctx: Context, categories: SyncCategorySettings) async throws -> HashedBundle {
        let bundle = try await ctx.adapter.collectLocalData(categories: categories, blobHasher: SyncBlobHasher(keys: ctx.keys))
        let keys = ctx.keys
        let enabled = categories.enabledCollections
        return try await Self.offMain { () -> HashedBundle in
            var records: [String: HashedLocal] = [:]
            var warnings = bundle.warnings
            for record in bundle.records {
                guard enabled.contains(record.collection) else { continue }
                guard SyncLimits.isValidRecordID(record.recordId) else {
                    warnings.append("Skipped a \(record.collection.rawValue) item with an invalid ID."); continue
                }
                let key = SyncPersistedState.mirrorKey(record.collection, record.recordId)
                records[key] = HashedLocal(record: record, hash: SyncCrypto.computePayloadHash(record.payload, keys: keys))
            }
            return HashedBundle(records: records, blobs: bundle.blobs,
                                completeCollections: bundle.completeCollections.intersection(enabled), warnings: warnings)
        }
    }

    /// After applying remote records, local re-serialization of the same content is not a change.
    private func suppressEchoes(_ keys: Set<String>, local: HashedBundle, state: inout SyncPersistedState) {
        for key in keys {
            guard var entry = state.mirror[key] else { continue }
            if let localRecord = local.records[key] {
                entry.payloadHash = localRecord.hash
                entry.deleted = false
                state.mirror[key] = entry
            } else if !entry.deleted {
                // The App could not install it (for example a Profile this Mac lacks). Forget it
                // rather than push a tombstone that would delete it everywhere.
                state.mirror.removeValue(forKey: key)
            }
        }
    }

    private struct PlannedMutation: Sendable {
        let key: String
        let collection: SyncCollection
        let recordId: String
        let deleted: Bool
        let payload: Data
        let hash: String
        let clientUpdatedAt: Int64
    }

    private struct SealedMutation: Sendable {
        let plan: PlannedMutation
        let wire: SyncWireMutation
        var base64Bytes: Int { wire.ciphertext.utf8.count }
    }

    private struct PushResult {
        var hadConflicts: Bool
        /// The server revision after the last batch.
        var currentRevision: Int
        var resetRevision: Int
        var acceptedCount: Int
        /// The revision the pull cursor may move to: set only when every batch advanced the
        /// server by this Mac's own mutations alone (nothing from another device in between).
        var cleanCursor: Int?
    }

    /// Pushes what `local` changed against the mirror.
    /// - Parameter cursorBase: nil moves `state.lastPulledRevision` past clean batches (the
    ///   pass already applied everything up to it). Otherwise the cursor stays, and
    ///   `cleanCursor` is computed from this revision for the caller to commit after its apply.
    private func pushDiff(_ ctx: Context, local: HashedBundle, mode: SyncPushMode, generation: Int,
                          cursorBase: Int? = nil, warnings: inout [String]) async throws -> PushResult {
        guard let current = state else { throw SyncError.notSignedIn }
        let nothingSent = PushResult(hadConflicts: false, currentRevision: current.lastPulledRevision, resetRevision: current.lastResetRevision,
                                     acceptedCount: 0, cleanCursor: cursorBase ?? current.lastPulledRevision)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var plans: [PlannedMutation] = []
        for (key, item) in local.records.sorted(by: { $0.key < $1.key }) {
            let known = mode == .replaceCloud ? nil : current.mirror[key]
            if let known, !known.deleted, known.payloadHash == item.hash { continue }
            plans.append(PlannedMutation(key: key, collection: item.record.collection, recordId: item.record.recordId, deleted: false,
                                         payload: item.record.payload, hash: item.hash,
                                         clientUpdatedAt: max(now, (known?.clientUpdatedAt ?? 0) + 1)))
        }
        if mode == .delta {
            let tombstoneHash = SyncCrypto.computePayloadHash(SyncCrypto.tombstonePayload, keys: ctx.keys)
            for (key, known) in current.mirror.sorted(by: { $0.key < $1.key }) where !known.deleted && local.records[key] == nil {
                guard let parsed = SyncPersistedState.parseMirrorKey(key), local.completeCollections.contains(parsed.collection) else { continue }
                plans.append(PlannedMutation(key: key, collection: parsed.collection, recordId: parsed.recordId, deleted: true,
                                             payload: SyncCrypto.tombstonePayload, hash: tombstoneHash,
                                             clientUpdatedAt: max(now, known.clientUpdatedAt + 1)))
            }
        }
        guard !plans.isEmpty || mode == .replaceCloud else { return nothingSent }

        // Upload the blobs that dirty Easels and Notes reference.
        try await uploadBlobs(ctx, local: local, plans: plans, mode: mode, generation: generation, warnings: &warnings)

        let keys = ctx.keys, accountId = ctx.accountId, toSeal = plans
        let sealed = try await Self.offMain { () -> (mutations: [SealedMutation], skipped: [String]) in
            var out: [SealedMutation] = []
            var skipped: [String] = []
            for plan in toSeal {
                let combined = try SyncCrypto.sealRecord(plan.payload, keys: keys, accountId: accountId, collection: plan.collection.rawValue,
                                                         recordId: plan.recordId, deleted: plan.deleted)
                guard combined.count <= SyncLimits.maxRecordCiphertextBytes else { skipped.append("\(plan.collection.rawValue) \(plan.recordId)"); continue }
                out.append(SealedMutation(plan: plan, wire: SyncWireMutation(collection: plan.collection.rawValue, recordId: plan.recordId,
                                                                            deleted: plan.deleted, clientUpdatedAt: plan.clientUpdatedAt,
                                                                            ciphertext: combined.base64EncodedString())))
            }
            return (out, skipped)
        }
        for item in sealed.skipped { warnings.append("Skipped \(item): it is larger than 2 MB after encryption.") }

        var batches: [[SealedMutation]] = []
        var batch: [SealedMutation] = []
        var batchBytes = 0
        for mutation in sealed.mutations {
            let size = mutation.base64Bytes + 512
            if !batch.isEmpty, batch.count >= SyncLimits.pushBatchSize || batchBytes + size > SyncLimits.pushBatchBase64Bytes {
                batches.append(batch); batch = []; batchBytes = 0
            }
            batch.append(mutation); batchBytes += size
        }
        if !batch.isEmpty { batches.append(batch) }
        // A cloud replacement wipes the account even when this Mac has nothing to send.
        if batches.isEmpty, mode == .replaceCloud { batches.append([]) }
        guard !batches.isEmpty else { return nothingSent }

        var hadConflicts = false
        var nextMode = mode
        var chain: Int? = cursorBase ?? current.lastPulledRevision
        var lastRevision = current.lastPulledRevision, lastReset = current.lastResetRevision, accepted = 0
        for (index, batch) in batches.enumerated() {
            _ = try context(generation)
            if batches.count > 1 { setStatus(.syncing("Uploading changes (\(index + 1) of \(batches.count))…")) }
            let base = state?.lastPulledRevision ?? 0
            let knownReset = state?.lastResetRevision ?? 0
            let response: SyncPushResponse
            do { response = try await ctx.client.pushMutations(mode: nextMode, baseRevision: base, mutations: batch.map(\.wire)) }
            catch { throw handleAuthError(error) }
            _ = try context(generation)
            let conflicted = Set(response.conflicts.map { "\($0.collection)|\($0.recordId)" })
            if !conflicted.isEmpty { hadConflicts = true }
            lastRevision = response.currentRevision
            lastReset = response.resetRevision
            accepted += response.acceptedCount
            let wasReplace = nextMode == .replaceCloud
            // The cursor may pass this batch only when the server revision grew by our own
            // mutations alone (a reset counts from the new reset revision).
            let start: Int? = wasReplace ? Optional(response.resetRevision) : (response.resetRevision == knownReset ? chain : nil)
            if let start, conflicted.isEmpty, response.currentRevision >= start, response.currentRevision <= start + response.acceptedCount {
                chain = response.currentRevision
            } else {
                chain = nil
            }
            let advance = chain
            mutateState { state in
                for mutation in batch where !conflicted.contains(mutation.plan.key) {
                    state.mirror[mutation.plan.key] = SyncRecordMirror(payloadHash: mutation.plan.hash,
                                                                       clientUpdatedAt: mutation.plan.clientUpdatedAt,
                                                                       deleted: mutation.plan.deleted)
                }
                guard cursorBase == nil else { return }
                if wasReplace {
                    state.lastResetRevision = response.resetRevision
                    // Everything after the reset is read again unless only our records follow it.
                    state.lastPulledRevision = advance ?? response.resetRevision
                } else if let advance {
                    state.lastPulledRevision = max(state.lastPulledRevision, advance)
                }
            }
            saveStateInBackground()
            // A multi-batch cloud replacement wipes once, then continues as delta.
            nextMode = .delta
        }
        return PushResult(hadConflicts: hadConflicts, currentRevision: lastRevision, resetRevision: lastReset,
                          acceptedCount: accepted, cleanCursor: chain)
    }

    private func uploadBlobs(_ ctx: Context, local: HashedBundle, plans: [PlannedMutation], mode: SyncPushMode,
                             generation: Int, warnings: inout [String]) async throws {
        var needed = Set<String>()
        for plan in plans where plan.collection.carriesAssets && !plan.deleted {
            guard let probe = try? JSONDecoder().decode(SyncedAssetsProbe.self, from: plan.payload) else { continue }
            for ref in probe.assets ?? [] { needed.insert(ref.blobId) }
        }
        guard !needed.isEmpty else { return }
        let known = mode == .replaceCloud ? Set<String>() : Set(state?.uploadedBlobIDs ?? [])
        let candidates = local.blobs.filter { needed.contains($0.blobId) && !known.contains($0.blobId) }
        var seen = Set<String>()
        for blob in candidates where seen.insert(blob.blobId).inserted {
            _ = try context(generation)
            setStatus(.syncing("Uploading attachments…"))
            guard SyncCrypto.isValidBlobID(blob.blobId), blob.data.count + 28 <= SyncLimits.maxBlobBytes else {
                warnings.append("Skipped an attachment larger than 20 MB."); continue
            }
            do {
                if try await ctx.client.blobExists(blobId: blob.blobId) == false {
                    let keys = ctx.keys, accountId = ctx.accountId, data = blob.data, id = blob.blobId
                    let ciphertext = try await Self.offMain { try SyncCrypto.sealBlob(data, keys: keys, accountId: accountId, blobId: id) }
                    try await ctx.client.uploadBlob(blobId: blob.blobId, ciphertext: ciphertext)
                }
                mutateState { if !$0.uploadedBlobIDs.contains(blob.blobId) { $0.uploadedBlobIDs.append(blob.blobId) } }
            } catch let error as SyncError {
                if error.requiresReauthentication { throw handleAuthError(error) }
                if case .cancelled = error { throw error }
                warnings.append("Could not upload an attachment: \(error.localizedDescription)")
            }
        }
        for id in needed where !known.contains(id) && !local.blobs.contains(where: { $0.blobId == id }) {
            warnings.append("An Easel or Note references a missing attachment (\(id.prefix(8))).")
        }
    }

    // MARK: State helpers

    private func mergePending(_ incoming: [SyncPendingExtension], into state: inout SyncPersistedState) {
        for item in incoming where !state.pendingExtensionInstalls.contains(where: { $0.id == item.id }) {
            state.pendingExtensionInstalls.append(item)
        }
    }

    /// Writes the fields a pass owns onto the latest state, so a category switch or a resolved
    /// extension made while the pass awaited the network is kept.
    private func commitSyncFields(_ synced: SyncPersistedState, processedBackfill: [SyncCategory] = [], newPending: [SyncPendingExtension] = []) {
        guard var latest = state else { return }
        latest.mirror = synced.mirror
        latest.lastPulledRevision = synced.lastPulledRevision
        latest.lastResetRevision = synced.lastResetRevision
        for id in synced.uploadedBlobIDs where !latest.uploadedBlobIDs.contains(id) { latest.uploadedBlobIDs.append(id) }
        latest.pendingBackfillCategories.removeAll { processedBackfill.contains($0) }
        mergePending(newPending, into: &latest)
        commitState(latest)
    }

    private func mutateState(_ body: (inout SyncPersistedState) -> Void) {
        guard var current = state else { return }
        body(&current)
        state = current
    }

    private func commitState(_ next: SyncPersistedState) {
        state = next
        saveStateInBackground()
        publish()
    }

    private func saveStateInBackground() {
        guard let state else { return }
        stateSequence &+= 1
        let sequence = stateSequence, store = stateStore, writer = stateWriter
        Task.detached(priority: .utility) { await writer.write(state, store: store, sequence: sequence) }
    }

    private func flushState() async {
        guard let state else { return }
        stateSequence &+= 1
        await stateWriter.write(state, store: stateStore, sequence: stateSequence)
    }

    private func appendWarning(_ text: String) {
        if !warnings.contains(text) { warnings.append(text) }
        publish()
    }

    private func setBusy(_ step: String) { setStatus(.syncing(step)) }

    private func setStatus(_ next: SyncStatus) {
        status = next
        publish()
    }

    private func publish() {
        var notes = warnings
        if credentialStore.usesFileBackend {
            notes.append("Sync secrets are kept in a protected file in the data folder because the Keychain is not available to this build.")
        }
        let next = SyncAccountSnapshot(
            isSignedIn: isSignedIn,
            serverURL: state?.serverURL ?? snapshot.serverURL,
            accountId: state?.accountId,
            email: state?.email ?? lastReauthEmail,
            displayName: state?.displayName,
            deviceId: state?.deviceId,
            deviceName: state?.deviceName,
            status: status,
            categories: state?.categories ?? snapshot.categories,
            lastSyncAt: state?.lastSyncAt,
            lastPulledRevision: state?.lastPulledRevision ?? 0,
            devices: devices,
            pendingExtensionInstalls: state?.pendingExtensionInstalls ?? [],
            warnings: notes,
            usesFileCredentialStore: credentialStore.usesFileBackend,
            isBusy: currentSync != nil,
            pendingInitialChoice: state?.awaitingInitialChoice)
        if next != snapshot {
            snapshot = next
            onSnapshotDidChange?(next)
        }
    }

    // MARK: Validation

    private func validatedEmail(_ email: String) throws -> String {
        let normalized = SyncCrypto.normalizeEmail(email)
        guard SyncCrypto.isValidNormalizedEmail(normalized) else { throw SyncError.invalidEmail }
        return normalized
    }

    private func validateNewPassword(_ password: String) throws {
        guard password.count >= SyncDefaults.minimumPasswordLength else {
            throw SyncError.weakPassword("Use at least \(SyncDefaults.minimumPasswordLength) characters for your password.")
        }
    }

    /// `Host.current()` can block on name resolution, so it runs off the main actor.
    private func resolvedDeviceName() async -> String {
        let raw: String
        if let known = preferredDeviceName ?? state?.deviceName {
            raw = known
        } else {
            let hostName = try? await Self.offMain { () -> String? in Host.current().localizedName }
            raw = hostName ?? "Mac"
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.truncated(trimmed.isEmpty ? "Mac" : trimmed, toScalars: SyncLimits.maxDeviceNameLength)
    }

    /// The server counts length in Unicode code points.
    private static func truncated(_ text: String, toScalars limit: Int) -> String {
        guard text.unicodeScalars.count > limit else { return text }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: text.unicodeScalars.prefix(limit))
        return String(view)
    }

    // MARK: Concurrency helpers

    private nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    /// Waits for `operation` or `seconds`, whichever ends first. The operation keeps running.
    private static func withTimeout(seconds: Double, _ operation: @escaping @MainActor () async -> Void) async {
        let gate = TimeoutGate()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.continuation = continuation
            Task { @MainActor in await operation(); gate.finish() }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                gate.finish()
            }
        }
    }

    private static func unwrap(_ base64: String, wrapKey: Data, kind: SyncCrypto.WrapKind, email: String) throws -> Data {
        guard let wrapped = Data(base64Encoded: base64) else { throw SyncError.decoding("The wrapped vault key is not Base64.") }
        return try SyncCrypto.unwrapVaultKey(wrapped, wrapKey: .init(data: wrapKey), kind: kind, email: email)
    }

    private static func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}

// MARK: - Private support types

// Each holder of key material zeroes its buffers with `zero()` when the caller is done.

private struct DerivedPassword: Sendable {
    var authVerifier: Data
    var wrapKey: Data

    mutating func zero() {
        SyncCrypto.zeroData(&authVerifier); SyncCrypto.zeroData(&wrapKey)
    }
}

private struct SignUpMaterial: Sendable {
    let params: SyncKDFParams
    var vaultKey: Data
    let recoveryFormatted: String
    var authVerifier: Data
    var recoveryAuthVerifier: Data
    let wrappedByPassword: Data
    let wrappedByRecovery: Data

    mutating func zero() {
        SyncCrypto.zeroData(&vaultKey); SyncCrypto.zeroData(&authVerifier); SyncCrypto.zeroData(&recoveryAuthVerifier)
    }
}

private struct RecoveryMaterial: Sendable {
    let params: SyncKDFParams
    let recoveryFormatted: String
    var authVerifier: Data
    var recoveryAuthVerifier: Data
    let wrappedByPassword: Data
    let wrappedByRecovery: Data

    mutating func zero() {
        SyncCrypto.zeroData(&authVerifier); SyncCrypto.zeroData(&recoveryAuthVerifier)
    }
}

private struct PasswordChangeMaterial: Sendable {
    var currentAuthVerifier: Data
    let params: SyncKDFParams
    var authVerifier: Data
    let wrapped: Data

    mutating func zero() {
        SyncCrypto.zeroData(&currentAuthVerifier); SyncCrypto.zeroData(&authVerifier)
    }
}

@MainActor
private final class TimeoutGate {
    var continuation: CheckedContinuation<Void, Never>?
    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

/// Serializes secrets writes off the main actor; an older write never lands after a newer
/// one (for example a rotated token pair after sign-out cleared the store).
actor SyncCredentialWriter {
    private var lastSequence = 0

    func save(_ credentials: SyncCredentials, store: any SyncCredentialStoring, sequence: Int) throws {
        guard sequence > lastSequence else { return }
        lastSequence = sequence
        try store.save(credentials)
    }

    func clear(store: any SyncCredentialStoring, sequence: Int) throws {
        guard sequence > lastSequence else { return }
        lastSequence = sequence
        try store.clear()
    }
}

/// Serializes state file writes; an older snapshot never overwrites a newer one.
actor SyncStateWriter {
    private var lastSequence = 0

    func write(_ state: SyncPersistedState, store: SyncStateStore, sequence: Int) {
        guard sequence > lastSequence else { return }
        lastSequence = sequence
        try? store.save(state)
    }

    func delete(store: SyncStateStore, sequence: Int) {
        guard sequence > lastSequence else { return }
        lastSequence = sequence
        try? store.delete()
    }
}
