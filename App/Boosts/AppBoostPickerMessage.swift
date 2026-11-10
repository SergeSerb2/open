import Foundation
import OpenBoosts

/// Refuse oversized and unknown fields before decoding the typed bridge value.
/// The 64 KiB wire cap and 1,024-entry cap bound decoded storage to a few MiB;
/// no single allocation is remotely near PartitionAlloc's 2 GiB ceiling.
enum AppBoostPickerMessage {
  static let maxEntries = 1_024
  static func validSelector(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 4_096 && !value.contains("\0")
  }
  static func validLabel(_ value: String) -> Bool { value.utf8.count <= 1_024 && !value.contains("\0") }
  static func supports(_ boost: Boost) -> Bool {
    boost.zaps.count <= maxEntries && boost.zaps.allSatisfy { validSelector($0.selector) && validLabel($0.label) }
  }
  static func decode(type: String, payloadJSON: String, session: PickerSession, selectors: [String]) -> PickerInbound? {
    guard type.utf8.count <= 64, payloadJSON.utf8.count + type.utf8.count <= 65_536,
      let data = payloadJSON.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["boostID"] as? String == session.boostID.description,
      object["sessionNonce"] as? String == session.sessionNonce else { return nil }
    let fields: Set<String>
    switch type {
    case "zap:committed": fields = ["selector", "label", "matches", "inShadowRoot"]
    case "zap:replaced": fields = ["oldSelector", "newSelector", "label", "matches"]
    case "zap:removed": fields = ["selector", "via"]
    case "zap:revealRequested": fields = ["selector"]
    case "picker:selected": fields = ["selector", "matches"]
    case "zap:list-result": fields = ["entries", "listID", "complete"]
    case "picker:ready": fields = []
    case "picker:exited": fields = ["reason"]
    case "picker:error": fields = ["kind", "selector"]
    default: return nil
    }
    guard Set(object.keys).isSubset(of: fields.union(["boostID", "sessionNonce"])) else { return nil }
    if let entries = object["entries"] {
      guard let entries = entries as? [[String: Any]], entries.count <= maxEntries,
        entries.allSatisfy({ Set($0.keys).isSubset(of: ["selector", "label", "matchCount", "truncated"]) }) else { return nil }
    }
    guard let message = BridgeDecode.decode(type: type, payloadJSON: payloadJSON) else { return nil }
    switch message {
    case let .zapCommitted(_, selector, label, matches, _):
      guard validSelector(selector), validLabel(label), (1...Int(Int32.max)).contains(matches),
        selectors.count < maxEntries else { return nil }
    case let .zapReplaced(_, old, new, label, matches):
      guard validSelector(old), validSelector(new), selectors.contains(old), validLabel(label),
        (1...Int(Int32.max)).contains(matches) else { return nil }
    case let .zapRemoved(_, selector, via):
      guard validSelector(selector), selectors.contains(selector), ["undo", "native"].contains(via) else { return nil }
    case let .revealRequested(_, selector): guard validSelector(selector), selectors.contains(selector) else { return nil }
    case let .pickerSelected(_, selector, matches):
      guard validSelector(selector), (1...Int(Int32.max)).contains(matches) else { return nil }
    case let .zapListResult(_, entries):
      let known = Set(selectors)
      guard Set(entries.map(\.selector)).count == entries.count,
        entries.allSatisfy({ validSelector($0.selector) && validLabel($0.label) && known.contains($0.selector) && (0...Int(Int32.max)).contains($0.matchCount) }) else { return nil }
    case let .pickerExited(_, reason): guard ["done", "esc", "bridge", "navigation"].contains(reason) else { return nil }
    case let .pickerError(_, kind, selector):
      guard ["no-candidate", "already-active"].contains(kind), selector.map(validSelector) ?? true else { return nil }
    case .pickerReady: break
    case .boostApplied, .boostError: return nil
    }
    return message
  }
}
