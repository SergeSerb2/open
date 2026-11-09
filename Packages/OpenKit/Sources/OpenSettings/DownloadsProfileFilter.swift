import AppKit
import SwiftUI
import OpenModel

/// Profile section of Filter Downloads (features-advanced DL-1). The native
/// menu is also the e2e surface; automation selects its items and sends its action.
struct DownloadsProfileFilter: NSViewRepresentable {
    @Bindable var model: LibraryViewModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton()
        button.identifier = .init("download-profile-filter")
        button.setAccessibilityLabel("Filter Downloads")
        button.target = context.coordinator; button.action = #selector(Coordinator.selectProfile(_:))
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        button.removeAllItems(); button.addItem(withTitle: "All Profiles")
        for profile in model.model.profiles {
            // NSMenu.addItem keeps duplicate Profile names as separate items.
            let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
            item.representedObject = profile.id.description; button.menu?.addItem(item)
        }
        let index = model.downloadProfileFilter.flatMap { id in model.model.profiles.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0
        button.selectItem(at: index)
    }
    @MainActor final class Coordinator: NSObject {
        let model: LibraryViewModel
        init(_ model: LibraryViewModel) { self.model = model }
        @objc func selectProfile(_ button: NSPopUpButton) {
            model.downloadProfileFilter = (button.selectedItem?.representedObject as? String)
                .flatMap { UUID(uuidString: $0) }.map { ProfileID(rawValue: $0) }
            model.selectedIDs = []
        }
    }
}
