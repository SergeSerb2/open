import Foundation
import OpenSettings
import OpenModel
import OpenStore
import OpenImport

/// Preview action adapter uses the real importer and snapshot store. Secrets remain counts only.
@MainActor func applySyntheticImport(_ plan: ImportPlan, settings: SettingsViewModel) async -> ImportOutcome {
    do {
        let source = try ArcImporter(arcDirectory: plan.directory).importAll()
        let candidate = SnapshotMapper.model(from: SnapshotMapper.dto(from: settings.model))
        let beforeSpaces = candidate.spaces.count, beforeTabs = candidate.index.count
        var importedProfiles: [ProfileID: Profile] = [:]
        for profile in source.model.profiles {
            if let existing = candidate.profile(id: profile.id) { if plan.searchSettings { existing.settings.searchEngineID = profile.settings.searchEngineID }; importedProfiles[profile.id] = existing; continue }
            guard plan.spaces || plan.favorites || plan.archive else { continue }
            let original = profile.dataDirectoryName
            if candidate.profiles.contains(where: { $0.dataDirectoryName.caseInsensitiveCompare(original) == .orderedSame }) { profile.dataDirectoryName = "Imported-" + profile.id.description }
            var freshSettings = ProfileSettings(); if plan.searchSettings { freshSettings.searchEngineID = profile.settings.searchEngineID }
            let fresh = Profile(id: profile.id, name: profile.name, settings: freshSettings, dataDirectoryName: profile.dataDirectoryName)
            candidate.profiles.append(fresh); importedProfiles[profile.id] = fresh
        }
        candidate.rebuildIndex()
        var duplicates = 0
        func filter(_ nodes: [SidebarNode]) -> [SidebarNode] {
            nodes.compactMap { node in
                if candidate.node(id: node.id) != nil { duplicates += 1; return nil }
                switch node {
                case .tab: return plan.tabs ? node : nil
                case .split: return plan.tabs ? node : nil
                case .folder(let folder): guard plan.folders else { return nil }; folder.children = filter(folder.children); return .folder(folder)
                }
            }
        }
        for sourceSpace in source.model.spaces {
            if let existing = candidate.space(id: sourceSpace.id) { existing.pinned += filter(sourceSpace.pinned); existing.today += filter(sourceSpace.today) }
            else if plan.spaces {
                sourceSpace.pinned = filter(sourceSpace.pinned); sourceSpace.today = filter(sourceSpace.today)
                candidate.spaces.append(sourceSpace)
            } else if let target = candidate.spaces.first { target.today += filter(sourceSpace.pinned) + filter(sourceSpace.today) }
            candidate.rebuildIndex()
        }
        if plan.favorites {
            for profile in source.model.profiles {
                guard let target = importedProfiles[profile.id] else { continue }
                for tab in profile.favorites {
                    if candidate.node(id: tab.id) == nil { target.favorites.append(tab); candidate.rebuildIndex() } else { duplicates += 1 }
                }
            }
        }
        if plan.spaces {
            for rule in source.model.routingRules where !candidate.routingRules.contains(where: { $0.id == rule.id }) { candidate.routingRules.append(rule) }
        }
        // The durable snapshot commit precedes replacement of the live graph. A failed parse/save
        // leaves the old live graph and the old snapshot intact.
        try settings.snapshot.saveNow(model: candidate)
        settings.model.profiles = candidate.profiles; settings.model.spaces = candidate.spaces
        settings.model.routingRules = candidate.routingRules; settings.model.defaultDestination = candidate.defaultDestination
        settings.model.rebuildIndex()
        var archiveInserted = 0, archiveDuplicates = 0
        if plan.archive {
            for (profileID, rows) in Dictionary(grouping: source.archiveRecords, by: { $0.profileID }) {
                guard let profileID, let profile = settings.model.profile(id: profileID) else { continue }
                let store = ArchiveStore(fileURL: ProfileDirectories(root: settings.root).archiveFileURL(for: profile))
                let report = await store.importRecords(rows); archiveInserted += report.inserted; archiveDuplicates += report.duplicates
            }
        }
        // Phase 2 has no engine writer. Even explicit consent never reads Keychain here.
        return ImportOutcome(counts: ["Imported Spaces": candidate.spaces.count - beforeSpaces, "Imported items": candidate.index.count - beforeTabs,
                                      "Duplicates": duplicates + archiveDuplicates, "Imported Archive": archiveInserted,
                                      "Skipped easels": source.report.skippedEasels, "Skipped notes": source.report.skippedNotes,
                                      "Skipped unknown": source.report.skippedUnknown, "Archive accounted": source.report.archiveAccounted,
                                      "Archive total": source.report.archiveTotal, "Secret copies": 0])
    } catch { return ImportOutcome(errorText: "Import failed. The previous snapshot is unchanged.") }
}
