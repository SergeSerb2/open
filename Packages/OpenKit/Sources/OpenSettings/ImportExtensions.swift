import AppKit
import Observation
import OpenModel
import SwiftUI

public struct ImportExtensionCandidate: Sendable, Identifiable {
    public let extensionID: String
    public let name: String
    public let profileID: ProfileID
    public let profileName: String
    public var id: String { profileID.description + ":" + extensionID }
    public init(extensionID: String, name: String, profileID: ProfileID, profileName: String) {
        self.extensionID = extensionID; self.name = name; self.profileID = profileID; self.profileName = profileName
    }
}

public enum ImportExtensionInstallResult: Sendable, Equatable {
    case installed, skipped(String), failed(String)
    public var text: String {
        switch self {
        case .installed: "Installed"
        case .skipped(let reason): "Skipped (\(reason))"
        case .failed(let error): "Failed: \(error)"
        }
    }
}

@MainActor @Observable public final class ImportExtensionsViewModel {
    public struct Row: Identifiable {
        public let candidate: ImportExtensionCandidate
        public var selected = true
        public var result: ImportExtensionInstallResult?
        public var id: String { candidate.id }
    }
    public private(set) var rows: [Row] = []
    public private(set) var isInstalling = false
    public private(set) var finished = false
    public private(set) var showsProfiles = false
    public private(set) var activeID: String?
    public init() {}
    public var canInstall: Bool { !isInstalling && rows.contains { $0.selected && $0.result == nil } }
    public var summary: String? {
        guard finished else { return nil }
        let installed = rows.filter { $0.result == .installed }.count
        let skipped = rows.filter { if case .skipped = $0.result { true } else { false } }.count
        let failed = rows.filter { if case .failed = $0.result { true } else { false } }.count
        return "Installed \(installed) · Skipped \(skipped) · Failed \(failed)"
    }
    public func reset(candidates: [ImportExtensionCandidate], profileCount: Int) {
        guard !isInstalling else { return }
        rows = candidates.map { Row(candidate: $0) }; showsProfiles = profileCount > 1
        finished = false; activeID = nil
    }
    public func select(id: String, on: Bool) {
        guard !isInstalling, let index = rows.firstIndex(where: { $0.id == id }), rows[index].result == nil else { return }
        rows[index].selected = on
    }
    public func install(using actions: any ImportActions) async {
        guard canInstall else { return }
        isInstalling = true; finished = false
        defer { isInstalling = false; activeID = nil; finished = true }
        // Freeze the selection before the first consent sheet. Each await is
        // the real engine operation, so there is never a second pending install.
        for index in rows.indices where rows[index].selected && rows[index].result == nil {
            guard !Task.isCancelled else { break }
            activeID = rows[index].id
            rows[index].result = await actions.installImportedExtension(rows[index].candidate)
        }
    }
}

/// Both report surfaces use Section 7's existing group and row styles.
public struct ImportExtensionsSection: View {
    @Bindable var model: ImportExtensionsViewModel
    let install: () -> Void
    public init(model: ImportExtensionsViewModel, install: @escaping () -> Void) {
        self.model = model; self.install = install
    }
    public var body: some View {
        if !model.rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Extensions").font(.headline)
                SettingsGroup {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        SettingsRow(divider: index != model.rows.count - 1, minimumHeight: 38) {
                            HStack {
                                Toggle(isOn: Binding(get: { model.rows.first(where: { $0.id == row.id })?.selected ?? false }, set: { model.select(id: row.id, on: $0) })) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(row.candidate.name)
                                        if model.showsProfiles { Text(row.candidate.profileName).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }.toggleStyle(.checkbox).disabled(model.isInstalling || row.result != nil)
                                Spacer()
                                if let result = row.result { Text(result.text).font(.caption).foregroundStyle(.secondary) }
                                else if model.activeID == row.id { ProgressView().controlSize(.small) }
                            }
                        }
                    }
                }
                Text("Settings and data from extensions don't move. Open installs each one from the Chrome Web Store.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Install Extensions", action: install).disabled(!model.canInstall)
                if let summary = model.summary { Text(summary).monospacedDigit() }
            }
        }
    }
}
