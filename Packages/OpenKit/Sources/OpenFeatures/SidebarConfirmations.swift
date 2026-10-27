import AppKit
import OpenModel

/// Delete Space and delete folder confirmations (completion §3.3, Arc's copy in §2.6 with
/// "Arc" → "Open"). System `NSAlert` sheets, warning style, the destructive button first, then
/// Cancel (Esc). AppKit gives a `hasDestructiveAction` button no Return equivalent, so Return
/// never deletes (Section 1 decision; capture C3 confirms Arc's default button).
/// While a sheet is open on the window, another request is ignored.
@MainActor
public enum SidebarConfirmations {
    /// Title "Delete your <Space display title> Space?" (`strings:132842–132844`).
    public static func deleteSpaceAlert(model: BrowserModel, spaceID: SpaceID) -> NSAlert? {
        guard let space = model.space(id: spaceID) else { return nil }
        return alert(title: "Delete your \(model.displayTitle(for: space)) Space?",
                     text: "This will archive all the tabs and folders inside it.", destructive: "Delete")
    }

    /// One titled folder: "Delete your <title> folder?"; an untitled folder or several folders:
    /// "Are you sure?" (Arc's fallback, `FUN_102a75b50`; plural is lead decision Q15).
    public static func deleteFoldersAlert(model: BrowserModel, ids: [ItemID]) -> NSAlert? {
        let folders = ids.compactMap { model.node(id: $0)?.folder }
        guard !folders.isEmpty else { return nil }
        let title = folders.count == 1 && !(folders[0].title.trimmingCharacters(in: .whitespaces).isEmpty)
            ? "Delete your \(folders[0].title) folder?" : "Are you sure?"
        return alert(title: title, text: "Deleting this folder will archive the tabs inside it.", destructive: "Delete Folder")
    }

    /// "Folder deleted" / "Folders deleted" (`FUN_102a76ff0`).
    public static func folderToast(count: Int) -> String { count == 1 ? "Folder deleted" : "Folders deleted" }

    /// Shows the alert as a sheet on `window` and calls `completion` once with the answer.
    /// Returns false (and shows nothing) when the window already has a sheet.
    @discardableResult
    public static func present(_ alert: NSAlert, on window: NSWindow, completion: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard window.attachedSheet == nil else { return false }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { completion(response == .alertFirstButtonReturn) }
        }
        return true
    }

    private static func alert(title: String, text: String, destructive: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        let delete = alert.addButton(withTitle: destructive)
        delete.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        return alert
    }
}
