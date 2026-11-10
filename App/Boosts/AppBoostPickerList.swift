import Foundation
import OpenBoosts

/// A counts snapshot is bounded by stored-entry limits, not by one IPC message.
/// Each message is at most 64 KiB; at most 1,024 decoded entries (a few MiB)
/// remain live across replies. No unbounded page-supplied list is accumulated.
@MainActor
final class AppBoostPickerList {
  static let wireLimit = 65_536
  let id = UUID().uuidString
  private let selectors: Set<String>
  private var entries: [String: ZapListEntry] = [:]
  enum Result { case partial, complete([ZapListEntry]) }
  private struct Reply: Decodable { let listID: String; let complete: Bool }
  private struct Payload: Encodable {
    let boostID: String
    let sessionNonce: String
    let listID: String
    var reset: Bool
    var complete: Bool
    var selectors: [String]
    var labels: [String: String]
  }
  init(selectors: [String]) { self.selectors = Set(selectors) }

  func commands(session: PickerSession, selectors: [String], labels: [String: String]) -> [String]? {
    let encoder = JSONEncoder()
    func encode(_ payload: Payload) -> String? {
      guard let data = try? encoder.encode(payload), data.count + "zap:list".utf8.count <= Self.wireLimit else { return nil }
      return String(decoding: data, as: UTF8.self)
    }
    var payload = Payload(boostID: session.boostID.description, sessionNonce: session.sessionNonce,
      listID: id, reset: true, complete: false, selectors: [], labels: [:])
    var commands: [String] = []
    for selector in selectors {
      var next = payload
      next.selectors.append(selector); next.labels[selector] = labels[selector] ?? ""
      if encode(next) == nil {
        guard !payload.selectors.isEmpty, let wire = encode(payload) else { return nil }
        commands.append(wire)
        payload.reset = false; payload.selectors = [selector]; payload.labels = [selector: labels[selector] ?? ""]
        guard encode(payload) != nil else { return nil }
      } else { payload = next }
    }
    // A final empty marker avoids changing the size of a full data chunk.
    if !payload.selectors.isEmpty {
      guard let wire = encode(payload) else { return nil }; commands.append(wire)
      payload.reset = false; payload.selectors = []; payload.labels = [:]
    }
    payload.complete = true
    guard let wire = encode(payload) else { return nil }; commands.append(wire)
    return commands
  }

  /// Only a complete snapshot is published; partial and stale replies cannot
  /// replace the editor's previous counts.
  func receive(payloadJSON: String, chunk: [ZapListEntry]) -> Result? {
    guard let data = payloadJSON.data(using: .utf8),
      let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.listID == id,
      entries.count + chunk.count <= selectors.count,
      chunk.allSatisfy({ selectors.contains($0.selector) && entries[$0.selector] == nil }) else { return nil }
    for entry in chunk { entries[entry.selector] = entry }
    guard reply.complete else { return .partial }
    guard entries.count == selectors.count else { return nil }
    return .complete(entries.values.sorted { $0.selector < $1.selector })
  }
}
