import Foundation
import OpenModel

/// Routes one model batch into each Profile's own SQLite archive. No store is opened eagerly.
@MainActor
public final class ProfileArchiveSink: ArchiveSink {
    private let directories: ProfileDirectories
    private let directoryNameFor: @MainActor (ProfileID?) -> String
    private var stores: [String: ArchiveStore] = [:]

    public init(directories: ProfileDirectories, directoryNameFor: @escaping @MainActor (ProfileID?) -> String) {
        self.directories = directories
        self.directoryNameFor = directoryNameFor
    }

    public func store(for profileID: ProfileID?) -> ArchiveStore {
        let name = directoryNameFor(profileID)
        if let store = stores[name] { return store }
        let store = ArchiveStore(fileURL: directories.archiveFileURL(dataDirectoryName: name))
        stores[name] = store
        return store
    }

    public func archive(_ entries: [ArchiveEntry]) {
        for (id, batch) in Dictionary(grouping: entries, by: \.profileID) { store(for: id).archive(batch) }
    }
    public func archiveFolder(_ entry: ArchiveFolderEntry) { store(for: entry.profileID).archiveFolder(entry) }
    public func archive(_ entries: [ArchiveEntry], folders: [ArchiveFolderEntry]) {
        let tabs = Dictionary(grouping: entries, by: \.profileID)
        let trees = Dictionary(grouping: folders, by: \.profileID)
        for id in Set(tabs.keys).union(trees.keys) { store(for: id).archive(tabs[id] ?? [], folders: trees[id] ?? []) }
    }
    public func archiveForProfileDeletion(_ entries: [ArchiveEntry], directoryName: String) throws {
        // A Profile delete contains only one Profile, so the archive is one transaction.
        try store(for: entries.first?.profileID).archiveForProfileDeletion(entries, directoryName: directoryName)
        try directories.retireDirectoryName(directoryName)
    }
    /// Profile deletion: close that folder's archive before the folder is removed.
    public func retire(directoryName: String) { stores.removeValue(forKey: directoryName)?.retire() }
    public func discardArchived(ids: [ItemID]) { for store in stores.values { store.discardArchived(ids: ids) } }
    public func flushAll() { for store in stores.values { store.flushQueue() } }
}
