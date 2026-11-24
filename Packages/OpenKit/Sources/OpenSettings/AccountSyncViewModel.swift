import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import OpenSync

/// Settings ▸ Account & Sync. Form drafts, busy flags, and messages for the page.
/// The engine owns the account state; this model only reads `SyncEngine.snapshot` and calls its
/// methods. It starts no timer and no network request until the user acts or opens the page.
@MainActor @Observable public final class AccountSyncViewModel {
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case signIn, createAccount, recover
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .signIn: "Sign In"
            case .createAccount: "Create Account"
            case .recover: "Recover"
            }
        }
        public var actionTitle: String {
            switch self {
            case .signIn: "Sign In"
            case .createAccount: "Create Account"
            case .recover: "Recover Account"
            }
        }
    }

    unowned let root: SettingsViewModel

    // MARK: Signed-out form
    public var mode: Mode = .signIn {
        didSet { if mode != oldValue { errorText = ""; password = ""; newPassword = ""; confirmPassword = ""; recoveryKeyInput = "" } }
    }
    public var serverURL = SyncDefaults.serverURL { didSet { serverEdited = true } }
    public var email = ""
    public var password = ""
    public var displayName = ""
    public var recoveryKeyInput = ""
    public var newPassword = ""
    public var confirmPassword = ""
    public var errorText = ""
    public var noticeText = ""
    public private(set) var busy = false
    @ObservationIgnored private var serverEdited = false

    // MARK: Recovery key card
    /// The new recovery key after Create Account or Recover. Kept in memory until the user confirms
    /// they saved it; never written anywhere unless they choose Save to File….
    public var recoveryKey: String?
    public var recoveryKeyCopied = false
    public var recoveryKeyStatus = ""

    // MARK: Signed-in actions
    public var showsChangePassword = false
    public var currentPassword = ""
    public var changedPassword = ""
    public var changedPasswordConfirmation = ""
    public var revokeOtherDevices = true
    public var securityError = ""
    public var securityStatus = ""
    public private(set) var securityBusy = false
    public var showsDeleteAccount = false
    public var deletePassword = ""
    public private(set) var devicesBusy = false
    public var devicesError = ""
    public var disconnectingDeviceID: String?
    public private(set) var installingExtensions = false
    public var extensionsStatus = ""
    @ObservationIgnored private var lastDevicesRefresh: Date?

    public init(root: SettingsViewModel) { self.root = root }

    // MARK: State

    public var engine: SyncEngine? { root.syncEngine }
    public var snapshot: SyncAccountSnapshot { root.syncEngine?.snapshot ?? .signedOut }
    public var isSignedIn: Bool { snapshot.isSignedIn }
    public var isWorking: Bool { busy || snapshot.isBusy }

    /// Called when the page is on screen: the engine, the saved server, and the account email.
    public func pageDidAppear() {
        guard let engine = root.ensureSyncEngine() else { return }
        let current = engine.snapshot
        if !serverEdited, !current.serverURL.isEmpty, current.serverURL != serverURL {
            serverURL = current.serverURL; serverEdited = false
        }
        if email.isEmpty, let saved = current.email { email = saved }
        if current.isSignedIn { refreshDevicesIfStale() }
    }

    // MARK: Server URL

    public var trimmedServerURL: String { serverURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var serverIsDefault: Bool { trimmedServerURL == SyncDefaults.serverURL }
    public func resetServerURL() { serverURL = SyncDefaults.serverURL; serverEdited = false }

    /// A blocking problem with the address, or nil.
    public var serverURLIssue: String? {
        guard let url = URL(string: trimmedServerURL), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(), !host.isEmpty, url.user == nil, url.password == nil else {
            return "Enter a server address that starts with http:// or https://."
        }
        return nil
    }

    /// Plain HTTP to another machine: the data stays encrypted, the session does not.
    public var serverURLWarning: String? {
        guard serverURLIssue == nil, let url = URL(string: trimmedServerURL), url.scheme?.lowercased() == "http",
              let host = url.host()?.lowercased() else { return nil }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".localhost")
        return local ? nil : "This server does not use HTTPS. Your browser data stays end-to-end encrypted, but someone on your network could read your session and sign in as you."
    }

    // MARK: Form validation

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A mismatch the form shows under the confirmation field as soon as it has text.
    public var confirmationIssue: String? {
        guard mode != .signIn, !confirmPassword.isEmpty, confirmPassword != newPassword else { return nil }
        return "The passwords do not match."
    }

    public var passwordLengthHint: String { "Use at least \(SyncDefaults.minimumPasswordLength) characters." }

    public var canSubmit: Bool {
        guard !isWorking, serverURLIssue == nil, !trimmedEmail.isEmpty else { return false }
        switch mode {
        case .signIn: return !password.isEmpty
        case .createAccount: return !newPassword.isEmpty && !confirmPassword.isEmpty
        case .recover: return !recoveryKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !newPassword.isEmpty && !confirmPassword.isEmpty
        }
    }

    private func validationIssue() -> String? {
        if let serverURLIssue { return serverURLIssue }
        guard trimmedEmail.contains("@") else { return SyncError.invalidEmail.localizedDescription }
        guard mode != .signIn else { return nil }
        if newPassword.count < SyncDefaults.minimumPasswordLength { return passwordLengthHint }
        if newPassword != confirmPassword { return "The passwords do not match." }
        return nil
    }

    // MARK: Sign in, create, recover

    public func submit() {
        guard canSubmit else { return }
        if let issue = validationIssue() { errorText = issue; return }
        guard let engine = root.ensureSyncEngine() else { errorText = "Open Sync is not available right now. Try again in a moment."; return }
        let mode = mode, server = trimmedServerURL, email = trimmedEmail, password = password
        let name = displayName, recovery = recoveryKeyInput, fresh = newPassword
        busy = true; errorText = ""; noticeText = ""
        Task { [weak self] in
            do {
                switch mode {
                case .signIn:
                    _ = try await engine.signIn(serverURL: server, email: email, password: password)
                case .createAccount:
                    let key = try await engine.signUp(serverURL: server, email: email, password: fresh, displayName: name.isEmpty ? nil : name)
                    self?.presentRecoveryKey(key)
                case .recover:
                    let result = try await engine.recoverAccount(serverURL: server, email: email, recoveryKey: recovery, newPassword: fresh)
                    self?.presentRecoveryKey(result.recoveryKey)
                }
                self?.clearFormSecrets()
                self?.lastDevicesRefresh = nil
                self?.refreshDevicesIfStale()
            } catch {
                if let message = Self.message(for: error) { self?.errorText = message }
            }
            self?.busy = false
        }
    }

    private func clearFormSecrets() {
        password = ""; newPassword = ""; confirmPassword = ""; recoveryKeyInput = ""
    }

    /// The user-facing message for a failure, or nil for a cancellation (nothing to show).
    private static func message(for error: any Error) -> String? {
        if let sync = error as? SyncError, sync == .cancelled { return nil }
        if error is CancellationError { return nil }
        return error.localizedDescription
    }

    // MARK: Recovery key

    private func presentRecoveryKey(_ key: String) {
        recoveryKey = key; recoveryKeyCopied = false; recoveryKeyStatus = ""
    }

    public func copyRecoveryKey() {
        guard let recoveryKey else { return }
        root.actions.copyText(recoveryKey)
        recoveryKeyCopied = true; recoveryKeyStatus = "Copied to the clipboard."
    }

    public func saveRecoveryKey() {
        guard let recoveryKey else { return }
        let panel = NSSavePanel()
        panel.title = "Save Recovery Key"
        panel.nameFieldStringValue = "Open Recovery Key.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var lines = ["Open Sync recovery key", ""]
        if let email = snapshot.email ?? (trimmedEmail.isEmpty ? nil : trimmedEmail) { lines.append("Account: \(email)") }
        lines.append("Server: \(snapshot.isSignedIn ? snapshot.serverURL : trimmedServerURL)")
        lines += ["", recoveryKey, "",
                  "You need this key to reset your password. Without it, a forgotten password means your synced data cannot be decrypted.",
                  "Keep this file somewhere safe and private.", ""]
        do {
            try Self.writePrivateFile(Data(lines.joined(separator: "\n").utf8), to: url)
            recoveryKeyStatus = "Saved to “\(url.lastPathComponent)”."
        } catch {
            recoveryKeyStatus = "Could not save the file. \(error.localizedDescription)"
        }
    }

    public func dismissRecoveryKey() { recoveryKey = nil; recoveryKeyCopied = false; recoveryKeyStatus = "" }

    /// Writes `data` readable by the user only (0600) and replaces `url` atomically. The file
    /// never exists with wider permissions, not even briefly.
    private static func writePrivateFile(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            unlink(temp.path)
            throw error
        }
    }

    // MARK: First sync

    public func completeInitialSync(_ strategy: FirstSyncStrategy) {
        guard !isWorking, let engine else { return }
        busy = true; errorText = ""
        Task { [weak self] in
            do { try await engine.completeInitialSync(strategy: strategy) }
            catch { if let message = Self.message(for: error) { self?.errorText = message } }
            self?.busy = false
        }
    }

    // MARK: Signed in

    public func syncNow() {
        guard !isWorking, let engine else { return }
        busy = true; errorText = ""
        Task { [weak self] in
            do { try await engine.syncNow() }
            catch { if let message = Self.message(for: error) { self?.errorText = message } }
            self?.busy = false
        }
    }

    public func signOut() {
        guard !busy, let engine else { return }
        busy = true; errorText = ""
        Task { [weak self] in
            await engine.signOut()
            guard let self else { return }
            self.busy = false
            self.resetSignedInDrafts()
            self.noticeText = "You are signed out. Your Spaces, tabs, and settings stay on this Mac."
        }
    }

    public func setCategory(_ category: SyncCategory, enabled: Bool) {
        engine?.setCategoryEnabled(enabled, for: category)
    }

    private func resetSignedInDrafts() {
        showsChangePassword = false; showsDeleteAccount = false
        currentPassword = ""; changedPassword = ""; changedPasswordConfirmation = ""; deletePassword = ""
        securityError = ""; securityStatus = ""; devicesError = ""; extensionsStatus = ""
        lastDevicesRefresh = nil
        // The recovery key must not stay in memory or on screen for the next account.
        recoveryKey = nil; recoveryKeyCopied = false; recoveryKeyStatus = ""
    }

    // MARK: Devices

    /// One account read per visit at most every 60 s; never on a timer.
    func refreshDevicesIfStale() {
        if let lastDevicesRefresh, Date().timeIntervalSince(lastDevicesRefresh) < 60 { return }
        refreshDevices()
    }

    public func refreshDevices() {
        guard !devicesBusy, let engine, engine.snapshot.isSignedIn else { return }
        devicesBusy = true; devicesError = ""; lastDevicesRefresh = Date()
        Task { [weak self] in
            do { try await engine.refreshDevices() }
            catch { if let message = Self.message(for: error) { self?.devicesError = message } }
            self?.devicesBusy = false
        }
    }

    public func disconnect(_ device: SyncDeviceInfo) {
        guard !devicesBusy, !device.isCurrent, let engine else { return }
        devicesBusy = true; devicesError = ""; disconnectingDeviceID = device.deviceId
        Task { [weak self] in
            do { try await engine.revokeDevice(deviceId: device.deviceId) }
            catch { if let message = Self.message(for: error) { self?.devicesError = message } }
            self?.devicesBusy = false; self?.disconnectingDeviceID = nil
        }
    }

    // MARK: Extensions

    public func installPendingExtensions() {
        let pending = snapshot.pendingExtensionInstalls
        guard !installingExtensions, !pending.isEmpty, let engine else { return }
        installingExtensions = true; extensionsStatus = ""
        Task { [weak self] in
            guard let self else { return }
            let resolved = await self.root.actions.installSyncedExtensions(pending)
            if !resolved.isEmpty { engine.resolvePendingExtensionInstalls(ids: resolved) }
            let left = pending.count - Set(resolved).intersection(pending.map(\.id)).count
            self.extensionsStatus = left == 0 ? "" : "\(left) \(left == 1 ? "extension was" : "extensions were") not installed. Try again later."
            self.installingExtensions = false
        }
    }

    // MARK: Security

    public var changePasswordIssue: String? {
        guard !changedPasswordConfirmation.isEmpty, changedPassword != changedPasswordConfirmation else { return nil }
        return "The new passwords do not match."
    }

    public var canChangePassword: Bool {
        !securityBusy && !currentPassword.isEmpty && !changedPassword.isEmpty && changedPassword == changedPasswordConfirmation
    }

    public func changePassword() {
        guard canChangePassword, let engine else { return }
        guard changedPassword.count >= SyncDefaults.minimumPasswordLength else { securityError = passwordLengthHint; return }
        let current = currentPassword, fresh = changedPassword, revoke = revokeOtherDevices
        securityBusy = true; securityError = ""; securityStatus = ""
        Task { [weak self] in
            do {
                try await engine.changePassword(currentPassword: current, newPassword: fresh, revokeOtherSessions: revoke)
                guard let self else { return }
                self.currentPassword = ""; self.changedPassword = ""; self.changedPasswordConfirmation = ""
                self.showsChangePassword = false
                self.securityStatus = revoke ? "Password changed. Your other Macs must sign in again." : "Password changed."
            } catch {
                if let message = Self.message(for: error) { self?.securityError = message }
            }
            self?.securityBusy = false
        }
    }

    public func deleteAccount() {
        guard !securityBusy, !deletePassword.isEmpty, let engine else { return }
        let password = deletePassword
        securityBusy = true; securityError = ""
        Task { [weak self] in
            do {
                try await engine.deleteAccount(password: password)
                guard let self else { return }
                self.resetSignedInDrafts()
                self.noticeText = "Your cloud account and its synced data were deleted. Your browser data stays on this Mac."
            } catch {
                if let message = Self.message(for: error) { self?.securityError = message }
            }
            self?.securityBusy = false
        }
    }
}
