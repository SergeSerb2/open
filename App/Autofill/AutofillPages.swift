import Foundation
import OpenModel

/// Mirrors OEAutofillPage's cases and raw values, without requiring the later
/// engine bridge. Dropdown callbacks can pass the source page's Space here.
enum AutofillPage: Int, CaseIterable {
  case passwords = 0, paymentMethods, addresses

  var url: URL {
    switch self {
    case .passwords: URL(string: "chrome://password-manager/passwords")!
    case .paymentMethods: URL(string: "chrome://settings/payments")!
    case .addresses: URL(string: "chrome://settings/addresses")!
    }
  }

  func matches(_ url: URL) -> Bool {
    let destination = self.url
    return url.scheme == destination.scheme && url.host() == destination.host()
      && url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        == destination.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }
}

extension EngineWebContentHostFactory {
  /// A singleton within this Space, including pinned tabs, folders and splits.
  /// The Space selects the Profile; never route a footer through the front Space.
  @discardableResult
  func openAutofillPage(_ page: AutofillPage, in space: Space) -> Bool {
    guard !isIncognito, model.space(id: space.id) === space else { return false }
    if let tab = flattened(space.pinned + space.today).first(where: { page.matches($0.url) }) {
      selectTabForCommand(tab.id, spaceID: space.id)
      return true
    }
    focus(space: space)
    return openNewTab(url: page.url, background: false) != nil
  }
}
