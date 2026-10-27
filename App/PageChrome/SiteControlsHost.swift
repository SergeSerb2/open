import AppKit
import OpenEngine
import OpenModel

/// Host-side inputs for OpenSiteControl's URL-field anchor. The library is not
/// on main yet (#69/#96); no replacement panel is drawn here.
@MainActor
final class SiteControlsHost {
  weak var owner: EngineWebContentHostFactory?
  private(set) var requests = 0
  private(set) var lastRequest: [String: Any] = [:]
  init(owner: EngineWebContentHostFactory) { self.owner = owner }
  @discardableResult func present() -> Bool {
    guard let owner, owner.app.engineReady, !owner.isClosing, let page = owner.selectedContent,
          let tab = owner.selectedTab, let url = page.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          let controller = owner.controller else { return false }
    let anchor = controller.sidebar.siteControlsAnchorView
    let rect = controller.contentView.convert(anchor.bounds, from: anchor)
    var origin = URLComponents(url: url, resolvingAgainstBaseURL: false)
    origin?.path = ""; origin?.query = nil; origin?.fragment = nil
    let permissions = PermissionPromptPresenter.kinds.map { kind, name in
      ["kind": kind.rawValue, "name": name, "state": PermissionPromptPresenter.canPersist(kind) ? page.context.permissionState(for: kind, origin: origin?.url ?? url).rawValue : OEPermissionState.ask.rawValue, "persistent": PermissionPromptPresenter.canPersist(kind)] as [String: Any]
    }
    requests += 1
    lastRequest = ["tab": tab.id.description, "profile": owner.profile(for: tab.id)?.id.description ?? "",
      "origin": origin?.url?.absoluteString ?? "", "anchor": [rect.minX, rect.minY, rect.width, rect.height],
      "permissions": permissions]
    owner.record("siteControlsPending", page, ["dependency": "#69", "anchor": "urlField"])
    return false // Pending #69: SiteControlController.toggle(anchor: .urlField, tabID:).
  }
  var state: [String: Any] { ["available": false, "pending": "#69", "requests": requests, "request": lastRequest] }
}
