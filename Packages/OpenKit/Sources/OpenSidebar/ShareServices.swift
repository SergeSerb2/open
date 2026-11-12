import AppKit

/// The system share services for some items, in the system's order (AirDrop, Mail, Messages, …).
/// Arc's "Share ▸" submenu lists exactly these (capture session 8 item 1). AppKit's only API for
/// the list, `NSSharingService.sharingServices(forItems:)`, is deprecated since macOS 13 in favour
/// of `standardShareMenuItem`, which is a single "Share…" item that opens the picker (no submenu).
/// The call lives here, behind a protocol witness, so the deprecation stays in one place.
private protocol ShareServiceListing {
    static func services(for items: [Any]) -> [NSSharingService]
}
private enum SystemShareServices: ShareServiceListing {
    @available(macOS, deprecated: 13.0)
    static func services(for items: [Any]) -> [NSSharingService] { NSSharingService.sharingServices(forItems: items) }
}
public enum ShareServices {
    public static func list(for items: [Any]) -> [NSSharingService] {
        // Arc's submenu has no "Add to Reading List" (Safari's own service): AirDrop · Mail · Messages ·
        // Notes · Open in News · Freeform · Journal · Reminders on the capture Mac (session 8 item 1).
        let readingList = NSSharingService(named: .addToSafariReadingList)?.title
        return (SystemShareServices.self as ShareServiceListing.Type).services(for: items).filter { $0.title != readingList }
    }
}
