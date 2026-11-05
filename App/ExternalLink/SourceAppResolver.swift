import AppKit
import Carbon
import OpenRouting

/// Only kAEGetURL carries sender identity. application(_:open:) is unknown-source,
/// so source-conditioned rules cannot match that delegate delivery path.
enum SourceAppResolver {
  static func source(from event: NSAppleEventDescriptor) -> RoutingSource {
    // Prefer the SDK's sender PID ('spid'). Do not infer identity from an address
    // descriptor or link libbsm for a speculative audit-token fallback.
    guard let attribute = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr)) else { return .unknown }
    let pid = attribute.int32Value
    guard pid > 0 else { return RoutingSource(pid: pid) }
    let sender = NSRunningApplication(processIdentifier: pid)
    return RoutingSource(bundleID: sender?.bundleIdentifier, pid: pid, displayName: sender?.localizedName)
  }
}
