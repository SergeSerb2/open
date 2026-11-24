import AppKit
import SwiftUI
import OpenDesign
import OpenSync

/// Settings ▸ Account & Sync. Open's own Settings cards and controls (SettingsStyle).
/// The page asks the App for its sync engine only while it is the selected section: the idle
/// pre-build of hidden pages and Settings' first open never create the engine.
struct AccountSyncPane: View {
    let root: SettingsViewModel
    @Bindable var model: AccountSyncViewModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(root: SettingsViewModel) { self.root = root; model = root.accountSync }

    private var snapshot: SyncAccountSnapshot { model.snapshot }
    private var accent: Color { Color(nsColor: SettingsStyle.accessibleAccent(root.settingsAccentSource, dark: scheme == .dark)) }
    private var motion: Animation? { (Motion.reduceMotionOverride ?? reduceMotion) ? nil : .easeOut(duration: SettingsStyle.searchDuration) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let key = model.recoveryKey { AccountSyncRecoveryKeyCard(model: model, key: key) }
            if snapshot.isSignedIn, let summary = snapshot.pendingInitialChoice {
                AccountSyncInitialChoiceCard(model: model, summary: summary)
            }
            if snapshot.isSignedIn {
                AccountSyncSignedIn(root: root, model: model, accent: accent, motion: motion)
            } else {
                AccountSyncSignedOut(root: root, model: model, accent: accent)
            }
        }
        .animation(motion, value: snapshot.isSignedIn)
        .animation(motion, value: model.recoveryKey)
        .onAppear { if root.selectedSection == .accountSync && root.searchQuery.isEmpty { model.pageDidAppear() } }
        .onChange(of: root.selectedSection) { _, section in if section == .accountSync { model.pageDidAppear() } }
    }
}

// MARK: - Shared pieces

/// Text and secure fields drawn as Open's controls (the Links test field style).
private struct AccountSyncField: View {
    let label: String
    @Binding var text: String
    var secure = false
    var monospaced = false
    var width: CGFloat = 260
    var identifier: String
    var submit: () -> Void = {}
    var body: some View {
        Group {
            if secure { SecureField(label, text: $text) } else { TextField(label, text: $text) }
        }
        .textFieldStyle(.plain).font(monospaced ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
        .autocorrectionDisabled(true)
        .accessibilityLabel(label).accessibilityIdentifier(identifier)
        .onSubmit(submit)
        .padding(.horizontal, 8).frame(width: width, height: 26)
        .background(Color(nsColor: SettingsStyle.control.nsColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: SettingsStyle.controlLine.nsColor), lineWidth: 1))
    }
}

/// A callout inside the page: errors, warnings, and notes.
struct AccountSyncCallout<Actions: View>: View {
    enum Kind { case error, warning, info, success }
    let kind: Kind
    let text: String
    @ViewBuilder var actions: Actions
    init(_ kind: Kind, _ text: String, @ViewBuilder actions: () -> Actions) { self.kind = kind; self.text = text; self.actions = actions() }
    private var symbol: String {
        switch kind {
        case .error: "exclamationmark.triangle.fill"
        case .warning: "exclamationmark.circle"
        case .info: "info.circle"
        case .success: "checkmark.circle"
        }
    }
    private var tint: Color {
        switch kind {
        case .error, .warning: Color(nsColor: SettingsStyle.attentionText.nsColor)
        case .info, .success: Color(nsColor: SettingsStyle.secondary.nsColor)
        }
    }
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(Color(nsColor: kind == .error ? SettingsStyle.attentionText.nsColor : SettingsStyle.text.nsColor))
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .font(.system(size: 11.5)).padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: SettingsStyle.control.nsColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: kind == .error ? SettingsStyle.sunEnd.nsColor.withAlphaComponent(0.45) : SettingsStyle.hairline.nsColor), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
extension AccountSyncCallout where Actions == EmptyView {
    init(_ kind: Kind, _ text: String) { self.init(kind, text) { EmptyView() } }
}

/// The account's sync state as a small coloured badge.
private struct AccountSyncStatusBadge: View {
    let status: SyncStatus
    let busy: Bool
    let accent: Color
    private var label: String {
        switch status {
        case .signedOut: "Signed out"
        case .idle: busy ? "Syncing…" : "Up to date"
        case .syncing: "Syncing…"
        case .awaitingInitialChoice: "Setup needed"
        case .error: "Sync paused"
        case .needsReauth: "Sign in needed"
        }
    }
    private var color: Color {
        switch status {
        case .idle: busy ? accent : Color(nsColor: NSColor.systemGreen)
        case .syncing: accent
        case .awaitingInitialChoice, .error, .needsReauth: Color(nsColor: SettingsStyle.sunEnd.nsColor)
        case .signedOut: Color(nsColor: SettingsStyle.secondary.nsColor)
        }
    }
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(label).font(.system(size: 11.5, weight: .medium))
        }
        .padding(.horizontal, 9).frame(height: 22)
        .background(Color(nsColor: SettingsStyle.control.nsColor), in: Capsule())
        .overlay(Capsule().stroke(Color(nsColor: SettingsStyle.controlLine.nsColor), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .ignore).accessibilityLabel("Sync status: " + label)
        .accessibilityIdentifier("account-sync-status")
    }
}

/// A group header with a trailing control (the Profiles list header style).
private struct AccountSyncGroupHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .semibold)).tracking(0.22)
                .foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
        }.padding(.leading, 4)
    }
}

private let accountSyncE2EENote = "End-to-end encrypted before leaving your Mac. Your sync server cannot read your browser setup or passwords."

// MARK: - Signed out

private struct AccountSyncSignedOut: View {
    let root: SettingsViewModel
    @Bindable var model: AccountSyncViewModel
    let accent: Color
    private var snapshot: SyncAccountSnapshot { model.snapshot }
    var body: some View {
        if case .needsReauth(let message) = snapshot.status {
            AccountSyncCallout(.warning, message).padding(.top, 18)
        } else if case .error(let message) = snapshot.status {
            AccountSyncCallout(.error, message).padding(.top, 18)
        }
        if !model.noticeText.isEmpty { AccountSyncCallout(.success, model.noticeText).padding(.top, 18) }
        VStack(alignment: .leading, spacing: 8) {
            AccountSyncGroupHeader(title: "Open Account") {
                OpenSettingsSegments(title: "Account", selection: Binding(get: { model.mode.rawValue }, set: { model.mode = AccountSyncViewModel.Mode(rawValue: $0) ?? .signIn }),
                                     options: AccountSyncViewModel.Mode.allCases.map { ($0.title, $0.rawValue) })
                    .disabled(model.isWorking)
            }
            OpenSettingsCard {
                OpenSettingsRow(root: root, id: "account-sync/server", title: "Sync server",
                                help: model.serverIsDefault ? "Open Sync on this Mac. Change it to use your own server." : "Your self-hosted or custom Open Sync server.",
                                changed: !model.serverIsDefault, reset: { model.resetServerURL() }) {
                    HStack(spacing: 6) {
                        AccountSyncField(label: "Server URL", text: $model.serverURL, width: 230, identifier: "account-sync-server-url")
                        if !model.serverIsDefault {
                            Button("Reset") { model.resetServerURL() }.accessibilityLabel("Reset Server URL")
                        }
                    }
                }
                OpenSettingsRow(root: root, id: "account-sync/form-email", title: "Email") {
                    AccountSyncField(label: "Email", text: $model.email, identifier: "account-sync-email", submit: { model.submit() })
                }
                switch model.mode {
                case .signIn:
                    OpenSettingsRow(root: root, id: "account-sync/form-password", title: "Password", last: true) {
                        AccountSyncField(label: "Password", text: $model.password, secure: true, identifier: "account-sync-password", submit: { model.submit() })
                    }
                case .createAccount:
                    OpenSettingsRow(root: root, id: "account-sync/form-name", title: "Display name", help: "Optional. Shown only to you.") {
                        AccountSyncField(label: "Display Name", text: $model.displayName, identifier: "account-sync-display-name", submit: { model.submit() })
                    }
                    newPasswordRows(title: "Password")
                case .recover:
                    OpenSettingsRow(root: root, id: "account-sync/form-recovery-key", title: "Recovery key", help: "The OPEN-… key you saved when you created the account.") {
                        AccountSyncField(label: "Recovery Key", text: $model.recoveryKeyInput, monospaced: true, identifier: "account-sync-recovery-key", submit: { model.submit() })
                    }
                    newPasswordRows(title: "New password")
                }
            }
        }.padding(.top, 24).id("account-sync/account")
        if let issue = model.serverURLIssue, !model.trimmedServerURL.isEmpty {
            AccountSyncCallout(.error, issue).padding(.top, 10)
        } else if let warning = model.serverURLWarning {
            AccountSyncCallout(.warning, warning).padding(.top, 10)
        }
        if !model.errorText.isEmpty {
            AccountSyncCallout(.error, model.errorText).padding(.top, 10).accessibilityIdentifier("account-sync-error")
        }
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(accent).accessibilityHidden(true)
            Text(accountSyncE2EENote).font(.system(size: 11.5)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if model.isWorking { ProgressView().controlSize(.small).accessibilityLabel(snapshot.status.label) }
            Button(model.mode.actionTitle) { model.submit() }
                .buttonStyle(OpenSettingsButtonStyle(attention: true))
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("account-sync-submit")
        }.padding(.top, 14)
    }
    @ViewBuilder private func newPasswordRows(title: String) -> some View {
        OpenSettingsRow(root: root, id: "account-sync/form-new-password", title: title, help: model.passwordLengthHint) {
            AccountSyncField(label: title, text: $model.newPassword, secure: true, identifier: "account-sync-new-password", submit: { model.submit() })
        }
        OpenSettingsRow(root: root, id: "account-sync/form-confirm-password", title: "Confirm password", help: model.confirmationIssue ?? "", last: true) {
            AccountSyncField(label: "Confirm Password", text: $model.confirmPassword, secure: true, identifier: "account-sync-confirm-password", submit: { model.submit() })
        }
    }
}

// MARK: - Recovery key

private struct AccountSyncRecoveryKeyCard: View {
    @Bindable var model: AccountSyncViewModel
    let key: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AccountSyncGroupHeader(title: "Your Recovery Key") { EmptyView() }
            OpenSettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Save this key now. It is the only way to reset your password. Open cannot show it again, and nobody can recover your synced data without it.")
                        .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                    Text(key).font(.system(size: 15, weight: .medium, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12).padding(.horizontal, 10)
                        .background(Color(nsColor: SettingsStyle.control.nsColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: SettingsStyle.controlLine.nsColor), lineWidth: 1))
                        .accessibilityLabel("Recovery key").accessibilityValue(key).accessibilityIdentifier("account-sync-recovery-key-text")
                    HStack(spacing: 8) {
                        Button(model.recoveryKeyCopied ? "Copied" : "Copy Recovery Key") { model.copyRecoveryKey() }
                            .accessibilityLabel("Copy Recovery Key")
                        Button("Save to File…") { model.saveRecoveryKey() }
                        Spacer(minLength: 8)
                        Button("I've Saved My Recovery Key") { model.dismissRecoveryKey() }
                            .buttonStyle(OpenSettingsButtonStyle(attention: true))
                            .accessibilityIdentifier("account-sync-recovery-key-done")
                    }
                    if !model.recoveryKeyStatus.isEmpty {
                        Text(model.recoveryKeyStatus).font(.system(size: 11.5)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor))
                    }
                }.padding(14)
            }
        }.padding(.top, 24).id("account-sync/recovery-key")
    }
}

// MARK: - First sync choice

private struct AccountSyncInitialChoiceCard: View {
    @Bindable var model: AccountSyncViewModel
    let summary: SyncCloudSummary
    @State private var confirmsReplaceCloud = false
    private var lines: [(String, String)] {
        var rows: [(String, String)] = []
        if summary.spaceCount > 0 { rows.append(("Spaces", summary.spaceCount.formatted())) }
        if summary.profileCount > 0 { rows.append(("Profiles", summary.profileCount.formatted())) }
        for category in SyncCategory.allCases where category != .workspace {
            let count = category.collections.reduce(0) { $0 + summary.count($1) }
            if count > 0 { rows.append((category.title, count.formatted())) }
        }
        return rows
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AccountSyncGroupHeader(title: "Finish Setting Up Sync") { EmptyView() }
            OpenSettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your account already has a browser setup from another Mac. Choose what this Mac should use.")
                        .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(lines, id: \.0) { title, value in
                            HStack { Text(title); Spacer(); Text(value).monospacedDigit() }
                                .font(.system(size: 11.5)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor))
                                .accessibilityElement(children: .combine)
                        }
                        Text("Cloud revision \(summary.serverRevision.formatted()) · \(summary.totalRecords.formatted()) synced items")
                            .font(.system(size: 11)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor))
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: SettingsStyle.control.nsColor), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .contain).accessibilityLabel("Cloud summary")
                    VStack(alignment: .leading, spacing: 4) {
                        Button("Use Cloud Setup (Replace This Mac)") { model.completeInitialSync(.replaceLocalWithCloud) }
                            .buttonStyle(OpenSettingsButtonStyle(attention: true)).disabled(model.isWorking)
                            .accessibilityIdentifier("account-sync-choice-cloud")
                        Text("Recommended. Open saves a safety backup of this Mac’s setup first.")
                            .font(.system(size: 11.5)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor))
                    }
                    HStack(spacing: 8) {
                        Button("Merge Local & Cloud") { model.completeInitialSync(.mergeLocalAndCloud) }
                            .disabled(model.isWorking).help(FirstSyncStrategy.mergeLocalAndCloud.subtitle)
                            .accessibilityIdentifier("account-sync-choice-merge")
                        Button("Keep This Mac (Replace Cloud)") { confirmsReplaceCloud = true }
                            .disabled(model.isWorking).help(FirstSyncStrategy.replaceCloudWithLocal.subtitle)
                            .accessibilityIdentifier("account-sync-choice-local")
                        Spacer(minLength: 8)
                        if model.isWorking { ProgressView().controlSize(.small).accessibilityLabel(model.snapshot.status.label) }
                    }
                }.padding(14)
            }
            if !model.errorText.isEmpty { AccountSyncCallout(.error, model.errorText).padding(.top, 2) }
        }
        .padding(.top, 24).id("account-sync/initial-choice")
        .confirmationDialog("Replace the cloud with this Mac?", isPresented: $confirmsReplaceCloud, titleVisibility: .visible) {
            Button("Replace Cloud", role: .destructive) { model.completeInitialSync(.replaceCloudWithLocal) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The synced setup in your account is replaced with this Mac’s. Your other Macs then follow this Mac.")
        }
    }
}

// MARK: - Signed in

private struct AccountSyncSignedIn: View {
    let root: SettingsViewModel
    @Bindable var model: AccountSyncViewModel
    let accent: Color
    let motion: Animation?
    @State private var pendingDisconnect: SyncDeviceInfo?
    @State private var confirmsDelete = false
    private var snapshot: SyncAccountSnapshot { model.snapshot }

    private var accountTitle: String {
        if let name = snapshot.displayName, !name.isEmpty { return name }
        return snapshot.email ?? "Open Account"
    }
    private var accountHelp: String {
        if let email = snapshot.email, email != accountTitle { return email }
        return "Signed in to Open Sync"
    }
    private var lastSyncText: String {
        guard let date = snapshot.lastSyncAt else { return "Not synced yet" }
        return "Last synced \(date.formatted(date: .abbreviated, time: .shortened)) · revision \(snapshot.lastPulledRevision.formatted())"
    }
    private var statusDetail: String {
        switch snapshot.status {
        case .syncing(let step): step
        case .error(let message), .needsReauth(let message): message
        case .awaitingInitialChoice: "Choose how to combine this Mac with your cloud setup above."
        default: lastSyncText
        }
    }

    var body: some View {
        if !model.errorText.isEmpty && snapshot.pendingInitialChoice == nil {
            AccountSyncCallout(.error, model.errorText).padding(.top, 18).accessibilityIdentifier("account-sync-error")
        }
        OpenSettingsGroup("Account") {
            OpenSettingsRow(root: root, id: "account-sync/account", title: accountTitle, help: accountHelp) {
                AccountSyncStatusBadge(status: snapshot.status, busy: snapshot.isBusy, accent: accent)
            }
            OpenSettingsRow(root: root, id: "account-sync/server", title: "Sync server", help: snapshot.serverURL) {
                if snapshot.serverURL.lowercased().hasPrefix("https://") {
                    Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor))
                        .accessibilityLabel("Secure connection")
                }
            }
            OpenSettingsRow(root: root, id: "account-sync/this-mac", title: snapshot.deviceName ?? "This Mac", help: lastSyncText) {
                Text("This Mac").font(.system(size: 10.5, weight: .semibold)).padding(.horizontal, 6).frame(height: 17)
                    .foregroundStyle(accent).background(accent.opacity(0.14), in: Capsule())
            }
            OpenSettingsRow(root: root, id: "account-sync/sync-now", title: "Sync", help: statusDetail, last: true) {
                HStack(spacing: 8) {
                    if model.isWorking { ProgressView().controlSize(.small).accessibilityLabel(snapshot.status.label) }
                    Button("Sync Now") { model.syncNow() }
                        .disabled(model.isWorking || snapshot.pendingInitialChoice != nil)
                        .accessibilityIdentifier("account-sync-sync-now")
                    Button("Sign Out") { model.signOut() }
                        .disabled(model.busy)
                        .accessibilityIdentifier("account-sync-sign-out")
                }
            }
        }
        if !snapshot.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(snapshot.warnings.enumerated()), id: \.offset) { _, warning in AccountSyncCallout(.warning, warning) }
            }.padding(.top, 12)
        }
        if !snapshot.pendingExtensionInstalls.isEmpty {
            let count = snapshot.pendingExtensionInstalls.count
            AccountSyncCallout(.info, "\(count) synced \(count == 1 ? "extension is" : "extensions are") not on this Mac yet: \(snapshot.pendingExtensionInstalls.prefix(3).map(\.name).joined(separator: ", "))\(count > 3 ? ", and more" : "").") {
                if model.installingExtensions { ProgressView().controlSize(.small).accessibilityLabel("Installing extensions") }
                Button("Install Synced Extensions") { model.installPendingExtensions() }
                    .disabled(model.installingExtensions).fixedSize()
                    .accessibilityIdentifier("account-sync-install-extensions")
            }.padding(.top, 12)
        }
        if !model.extensionsStatus.isEmpty { AccountSyncCallout(.warning, model.extensionsStatus).padding(.top, 6) }
        OpenSettingsGroup("What to Sync") {
            ForEach(Array(SyncCategory.allCases.enumerated()), id: \.element) { index, category in
                OpenSettingsRow(root: root, id: "account-sync/category-" + category.rawValue, title: category.title, help: category.subtitle,
                                last: index == SyncCategory.allCases.count - 1) {
                    Toggle(category.title, isOn: Binding(get: { snapshot.categories.isEnabled(category) }, set: { model.setCategory(category, enabled: $0) }))
                        .toggleStyle(OpenSettingsSwitchStyle(accent: accent, label: category.title))
                }
            }
        }.id("account-sync/categories")
        devices
        security
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").foregroundStyle(accent).accessibilityHidden(true)
            Text(accountSyncE2EENote).font(.system(size: 11.5)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor))
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 14)
    }

    // MARK: Devices

    private var devices: some View {
        VStack(alignment: .leading, spacing: 8) {
            AccountSyncGroupHeader(title: "Connected Devices") {
                if model.devicesBusy { ProgressView().controlSize(.small).accessibilityLabel("Refreshing devices") }
                Button("Refresh") { model.refreshDevices() }.disabled(model.devicesBusy)
                    .accessibilityLabel("Refresh Connected Devices").accessibilityIdentifier("account-sync-refresh-devices")
            }
            OpenSettingsCard {
                if snapshot.devices.isEmpty {
                    Text(model.devicesBusy ? "Loading devices…" : "No devices yet. Click Refresh to load them.")
                        .font(.system(size: 12)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 14)
                }
                ForEach(Array(snapshot.devices.enumerated()), id: \.element.id) { index, device in
                    deviceRow(device, last: index == snapshot.devices.count - 1)
                }
            }
            if !model.devicesError.isEmpty { AccountSyncCallout(.error, model.devicesError).padding(.top, 2) }
        }
        .padding(.top, 24).id("account-sync/devices")
        .confirmationDialog("Disconnect “\(pendingDisconnect?.deviceName ?? "")”?", isPresented: Binding(get: { pendingDisconnect != nil }, set: { if !$0 { pendingDisconnect = nil } }), titleVisibility: .visible, presenting: pendingDisconnect) { device in
            Button("Disconnect", role: .destructive) { model.disconnect(device) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("That Mac stops syncing and must sign in again. Its browser data stays on it.")
        }
    }

    private func deviceRow(_ device: SyncDeviceInfo, last: Bool) -> some View {
        let platform = device.platform.lowercased() == "macos" ? "macOS" : device.platform
        let seen = device.lastSeenAt.map { "Last seen \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Never seen"
        return HStack(spacing: 10) {
            Image(systemName: "laptopcomputer").font(.system(size: 14)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor))
                .frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.deviceName).font(.system(size: 13))
                    if device.isCurrent {
                        Text("This Mac").font(.system(size: 10.5, weight: .semibold)).padding(.horizontal, 6).frame(height: 17)
                            .foregroundStyle(accent).background(accent.opacity(0.14), in: Capsule())
                    }
                }
                Text(platform + " · " + seen).font(.system(size: 11.5)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor))
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !device.isCurrent {
                if model.disconnectingDeviceID == device.deviceId { ProgressView().controlSize(.small).accessibilityLabel("Disconnecting") }
                Button("Disconnect") { pendingDisconnect = device }.disabled(model.devicesBusy)
                    .accessibilityLabel("Disconnect " + device.deviceName)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 52)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Color(nsColor: SettingsStyle.hairline.nsColor)).frame(height: 1).padding(.leading, 14) } }
        .accessibilityElement(children: .contain).accessibilityLabel(device.deviceName + (device.isCurrent ? ", This Mac" : ""))
        .accessibilityIdentifier("account-sync-device-" + device.deviceId)
    }

    // MARK: Security

    private var security: some View {
        VStack(alignment: .leading, spacing: 8) {
            AccountSyncGroupHeader(title: "Account Security") { EmptyView() }
            OpenSettingsCard {
                disclosure("Change Password", expanded: $model.showsChangePassword)
                if model.showsChangePassword {
                    VStack(alignment: .leading, spacing: 8) {
                        securityField("Current password", text: $model.currentPassword, identifier: "account-sync-current-password", submit: { model.changePassword() })
                        securityField("New password", text: $model.changedPassword, identifier: "account-sync-changed-password", submit: { model.changePassword() })
                        securityField("Confirm new password", text: $model.changedPasswordConfirmation, identifier: "account-sync-changed-password-confirm", submit: { model.changePassword() })
                        if let issue = model.changePasswordIssue {
                            Text(issue).font(.system(size: 11.5)).foregroundStyle(Color(nsColor: SettingsStyle.attentionText.nsColor))
                        } else {
                            Text(model.passwordLengthHint + " Your recovery key keeps working.").font(.system(size: 11.5)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor))
                        }
                        Toggle("Sign out my other Macs", isOn: $model.revokeOtherDevices).toggleStyle(.checkbox).font(.system(size: 12.5))
                        HStack {
                            Spacer()
                            if model.securityBusy { ProgressView().controlSize(.small).accessibilityLabel("Changing password") }
                            Button("Cancel") { model.showsChangePassword = false; model.currentPassword = ""; model.changedPassword = ""; model.changedPasswordConfirmation = "" }
                            Button("Change Password") { model.changePassword() }.buttonStyle(OpenSettingsButtonStyle(attention: true))
                                .disabled(!model.canChangePassword).accessibilityIdentifier("account-sync-change-password")
                        }
                    }.padding(.horizontal, 14).padding(.bottom, 12)
                }
                Rectangle().fill(Color(nsColor: SettingsStyle.hairline.nsColor)).frame(height: 1).padding(.leading, 14)
                disclosure("Delete Cloud Account", expanded: $model.showsDeleteAccount)
                if model.showsDeleteAccount {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This deletes your account and every synced item on the server. Your Spaces, tabs, and settings stay on this Mac. Other Macs stop syncing.")
                            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        securityField("Password", text: $model.deletePassword, identifier: "account-sync-delete-password", submit: { if !model.deletePassword.isEmpty { confirmsDelete = true } })
                        HStack {
                            Spacer()
                            if model.securityBusy { ProgressView().controlSize(.small).accessibilityLabel("Deleting account") }
                            Button("Cancel") { model.showsDeleteAccount = false; model.deletePassword = "" }
                            Button("Delete Cloud Account…", role: .destructive) { confirmsDelete = true }
                                .disabled(model.deletePassword.isEmpty || model.securityBusy)
                                .accessibilityIdentifier("account-sync-delete-account")
                        }
                    }.padding(.horizontal, 14).padding(.bottom, 12)
                }
            }
            if !model.securityError.isEmpty { AccountSyncCallout(.error, model.securityError).padding(.top, 2) }
            if !model.securityStatus.isEmpty { AccountSyncCallout(.success, model.securityStatus).padding(.top, 2) }
        }
        .padding(.top, 24).id("account-sync/security")
        .animation(motion, value: model.showsChangePassword)
        .animation(motion, value: model.showsDeleteAccount)
        .confirmationDialog("Delete your Open cloud account?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Cloud Account", role: .destructive) { model.deleteAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can’t be undone. Your synced data is removed from the server. Local browser data stays on this Mac.")
        }
    }

    private func disclosure(_ title: String, expanded: Binding<Bool>) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .medium)).frame(width: 10)
                Text(title).font(.system(size: 13))
                Spacer()
            }.padding(.horizontal, 14).frame(height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
    }

    private func securityField(_ label: String, text: Binding<String>, identifier: String, submit: @escaping () -> Void) -> some View {
        HStack {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor))
            Spacer(minLength: 8)
            AccountSyncField(label: label, text: text, secure: true, identifier: identifier, submit: submit)
        }
    }
}
