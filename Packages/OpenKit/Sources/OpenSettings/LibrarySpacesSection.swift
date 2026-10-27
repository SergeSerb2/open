import AppKit
import SwiftUI

/// OpenSettings hosts the caller's native Space Manager without importing OpenSidebar.
public struct LibrarySpacesSection: View {
    let model: LibraryViewModel
    public init(model: LibraryViewModel) { self.model = model }
    public var body: some View {
        if let manager = model.spaceManagerView {
            InjectedSpaceManager(manager: manager).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LibraryEmptyState(title: "Spaces", message: "Space Manager is unavailable.", symbol: "rectangle.split.3x1")
        }
    }
}

private struct InjectedSpaceManager: NSViewRepresentable {
    let manager: NSView
    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        install(in: host)
        return host
    }
    private func install(in host: NSView) {
        guard host.subviews.first !== manager else { return }
        for view in host.subviews { view.removeFromSuperview() }
        manager.removeFromSuperview()
        manager.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(manager)
        NSLayoutConstraint.activate([
            manager.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            manager.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            manager.topAnchor.constraint(equalTo: host.topAnchor),
            manager.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }
    func updateNSView(_ host: NSView, context: Context) { install(in: host) }
    static func dismantleNSView(_ host: NSView, coordinator: ()) {
        for view in host.subviews { view.removeFromSuperview() }
    }
}
