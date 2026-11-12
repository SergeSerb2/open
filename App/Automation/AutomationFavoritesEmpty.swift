#if OPEN_AUTOMATION
import AppKit
import OpenFeatures
import OpenModel
import OpenSidebar

/// Favorites empty-state card (A3): reads the real card and presses its real Dismiss button.
extension AutomationController {
  func runFavoritesEmptyCommand(_ a: [String: Any]) throws -> Any {
    guard let controller = app.frontWindowController else { throw Failure(message: "no browser window") }
    let context = controller.context
    switch a["action"] as? String ?? "state" {
    case "dismiss":
      guard let card = controller.sidebar.favoritesEmptyCard else { throw Failure(message: "no Favorites empty-state card") }
      return ["pressed": card.dismissButton.accessibilityPerformPress()]
    case "reset":
      // Test set-up only: shows the card again for the window's Profile.
      context.favoritesProfile?.favoritesEmptyStateDismissed = false
      return ["reset": true]
    case "state":
      controller.contentView.layoutSubtreeIfNeeded()
      let root = controller.contentView
      func rect(_ v: NSView) -> [Double] { let f = root.convert(v.bounds, from: v); return [f.minX, f.minY, f.width, f.height] }
      let card = controller.sidebar.favoritesEmptyCard
      return ["enabled": context.showsFavoritesEmptyState, "visible": context.favoritesEmptyStateVisible, "shown": card != nil,
        "dismissed": context.favoritesProfile?.favoritesEmptyStateDismissed ?? false,
        "profile": context.favoritesProfile?.id.description ?? "", "favorites": context.favoritesProfile?.favorites.count ?? 0,
        "card": card.map(rect) ?? [], "dismissButton": card.map { rect($0.dismissButton) } ?? [],
        "title": card == nil ? "" : FavoritesEmptyStateView.title, "body": card == nil ? "" : FavoritesEmptyStateView.body,
        "dropTarget": card?.isDropTarget ?? false, "sectionHeight": Double(controller.sidebar.favoritesHeight),
        "sidebarWidth": Double(context.sidebarWidth)] as [String: Any]
    default: throw Failure(message: "unknown favorites-empty-state action")
    }
  }
}
#endif
