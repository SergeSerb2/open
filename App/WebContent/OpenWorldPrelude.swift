import OpenEngine

/// The App's transport prelude for the applier and picker. User Boost code
/// keeps the page world; only Open's runtimes receive this prelude.
enum OpenWorldPrelude {
  static func unwrapped(_ source: String, world: OEScriptWorld) -> String {
    let prefix = Self.source + "\n"
    return world == .open && source.hasPrefix(prefix) ? String(source.dropFirst(prefix.count)) : source
  }
  static let source = """
  window.__open = window.__open || {};
  window.__open.postMessage = (type, payload) =>
    __openNative.postMessage(type, JSON.stringify(payload));
  """
}
