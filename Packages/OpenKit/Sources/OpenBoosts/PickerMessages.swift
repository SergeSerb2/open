import Foundation

public enum PickerMode: String, Sendable, Codable { case zap, select }

/// Validated native events. The App publishes these after coordinator.handle.
public enum BoostPickerEvent: Sendable {
    case committed(Boost), removed(Boost), exited, listResult([ZapListEntry])
    case selected(selector: String, matches: Int)
}

/// Capability created only by native. The adapter keeps page identity out of page JSON.
public struct PickerSession: Sendable, Equatable {
    public let boostID: BoostID
    public let mode: PickerMode
    public let sessionNonce: String
    fileprivate init(boostID: BoostID, sessionNonce: String, mode: PickerMode = .zap) {
        self.boostID = boostID; self.sessionNonce = sessionNonce; self.mode = mode
    }
}

public enum PickerInbound: Sendable {
    case zapCommitted(session: PickerSession, selector: String, label: String, matches: Int, inShadowRoot: Bool)
    case zapReplaced(session: PickerSession, oldSelector: String, newSelector: String, label: String, matches: Int)
    case zapRemoved(session: PickerSession, selector: String, via: String)
    case revealRequested(session: PickerSession, selector: String)
    case pickerSelected(session: PickerSession, selector: String, matches: Int)
    case zapListResult(session: PickerSession, entries: [ZapListEntry])
    case pickerReady(session: PickerSession)
    case pickerExited(session: PickerSession, reason: String)
    case pickerError(session: PickerSession, kind: String, selector: String?)
    case boostApplied(planID: String)
    case boostError(kind: String, selector: String?)
}

public struct ZapListEntry: Sendable, Decodable {
    public var selector: String
    public var label: String
    public var matchCount: Int
    public var truncated: Bool
    public init(selector: String, label: String = "", matchCount: Int, truncated: Bool = false) {
        self.selector = selector; self.label = label; self.matchCount = matchCount; self.truncated = truncated
    }
    private enum CodingKeys: String, CodingKey { case selector, label, matchCount, truncated }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selector = try c.decode(String.self, forKey: .selector)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        matchCount = try c.decode(Int.self, forKey: .matchCount)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

public enum PickerOutbound: Sendable {
    case enterZap(session: PickerSession)
    case exitZap(session: PickerSession)
    case undoZap(session: PickerSession)
    case listZaps(session: PickerSession, selectors: [String], labels: [String: String] = [:])
    case removeZap(session: PickerSession, selector: String)
    case applyBoosts(InjectionPlan)
    case clearBoosts
}

@MainActor
public final class BoostPickerCoordinator {
    private let store: BoostStore
    private var sessions: [String: PickerSession] = [:]
    public private(set) var lastEvent: BoostPickerEvent?
    public private(set) var lastListResult: [ZapListEntry] = []
    public init(store: BoostStore) { self.store = store }

    /// Call only for a native user request, then send the returned command to this
    /// exact document/frame in the ISOLATED WORLD. Re-entry keeps its capability.
    public func enterZap(boostID: BoostID, for pageID: String, mode: PickerMode = .zap) -> PickerOutbound? {
        guard store.boost(id: boostID) != nil, !pageID.isEmpty else { return nil }
        if let existing = sessions[pageID] {
            return existing.boostID == boostID && existing.mode == mode ? .enterZap(session: existing) : nil
        }
        let session = PickerSession(boostID: boostID, sessionNonce: UUID().uuidString, mode: mode)
        sessions[pageID] = session; lastListResult = []
        return .enterZap(session: session)
    }
    public func listZaps(for pageID: String) -> PickerOutbound? {
        guard let session = sessions[pageID], let boost = store.boost(id: session.boostID) else { return nil }
        return .listZaps(session: session, selectors: boost.zaps.map(\.selector), labels: Dictionary(uniqueKeysWithValues: boost.zaps.map { ($0.selector, $0.label) }))
    }
    public func undoZap(for pageID: String) -> PickerOutbound? {
        sessions[pageID].map { .undoZap(session: $0) }
    }
    public func removeZap(selector: String, for pageID: String) -> PickerOutbound? {
        sessions[pageID].map { .removeZap(session: $0, selector: selector) }
    }
    public func exitZap(for pageID: String) -> PickerOutbound? {
        sessions.removeValue(forKey: pageID).map { .exitZap(session: $0) }
    }
    /// Required on navigation, frame destruction, transport loss, or failed send.
    public func invalidate(pageID: String) { sessions.removeValue(forKey: pageID) }

    /// pageID comes from the engine's document/frame identity, never from payload.
    /// An absent, foreign, or expired native capability cannot mutate the store.
    public func handle(_ message: PickerInbound, from pageID: String) -> Bool {
        lastEvent = nil
        if let session = message.session {
            guard let armed = sessions[pageID], armed.boostID == session.boostID,
                  armed.sessionNonce == session.sessionNonce, store.boost(id: session.boostID) != nil else { return false }
            if armed.mode == .select {
                switch message {
                case let .pickerSelected(_, selector, matches):
                    guard !selector.isEmpty, matches > 0 else { return false }
                    lastEvent = .selected(selector: selector, matches: matches); return false
                case .pickerReady, .pickerExited, .pickerError: break
                default: return false
                }
            } else if case .pickerSelected = message { return false }
        }
        switch message {
        case let .zapCommitted(session, selector, label, _, _):
            let changed = store.appendZap(boostID: session.boostID, zap: ZappedElement(selector: selector, label: label))
            if changed, let boost = store.boost(id: session.boostID) { lastEvent = .committed(boost) }; return changed
        case let .zapReplaced(session, old, new, label, _):
            let old = old.trimmingCharacters(in: .whitespacesAndNewlines), new = new.trimmingCharacters(in: .whitespacesAndNewlines)
            guard old != new, !new.isEmpty else { return false }
            let removed = store.removeZap(boostID: session.boostID, selector: old)
            let appended = store.appendZap(boostID: session.boostID, zap: ZappedElement(selector: new, label: label))
            if removed || appended, let boost = store.boost(id: session.boostID) { lastEvent = .committed(boost) }; return removed || appended
        case let .zapRemoved(session, selector, via):
            let changed = via == "undo" ? store.removeZap(boostID: session.boostID, selector: selector) : false
            if changed, let boost = store.boost(id: session.boostID) { lastEvent = .removed(boost) }; return changed
        case let .revealRequested(session, selector):
            let changed = store.removeZap(boostID: session.boostID, selector: selector)
            if changed, let boost = store.boost(id: session.boostID) { lastEvent = .removed(boost) }; return changed
        case .pickerSelected: return false
        case let .zapListResult(_, entries): lastListResult = entries; lastEvent = .listResult(entries); return false
        case .pickerExited: invalidate(pageID: pageID); lastEvent = .exited; return false
        case let .pickerError(_, kind, selector), let .boostError(kind, selector):
            debugLog("\(kind) \(selector ?? "")"); return false
        case .pickerReady, .boostApplied: return false
        }
    }
    private func debugLog(_ message: String) {
        #if DEBUG
        FileHandle.standardError.write(Data("BoostPicker: \(message)\n".utf8))
        #endif
    }
}

private extension PickerInbound {
    var session: PickerSession? {
        switch self {
        case let .zapCommitted(s, _, _, _, _), let .zapReplaced(s, _, _, _, _),
             let .zapRemoved(s, _, _), let .revealRequested(s, _), let .pickerSelected(s, _, _), let .zapListResult(s, _), let .pickerReady(s),
             let .pickerExited(s, _), let .pickerError(s, _, _): return s
        case .boostApplied, .boostError: return nil
        }
    }
}

/// The App transport checks envelope v == 1 before passing (type, payloadJSON).
/// Native -> page: wrap the returned pair in {v:1,type,payload} for __open.receive.
public enum BridgeDecode {
    private struct Inbound: Decodable {
        var boostID: BoostID?
        var sessionNonce: String?
        var selector: String?
        var label: String?
        var matches: Int?
        var inShadowRoot: Bool?
        var oldSelector: String?
        var newSelector: String?
        var via: String?
        var entries: [ZapListEntry]?
        var reason: String?
        var kind: String?
        var planID: String?
    }
    public static func decode(type: String, payloadJSON: String) -> PickerInbound? {
        guard let data = payloadJSON.data(using: .utf8), let p = try? JSONDecoder().decode(Inbound.self, from: data) else { return nil }
        let session = p.boostID.flatMap { id in
            p.sessionNonce.flatMap { $0.isEmpty ? nil : PickerSession(boostID: id, sessionNonce: $0) }
        }
        if type.hasPrefix("zap:") || type.hasPrefix("picker:") { guard session != nil else { return nil } }
        switch type {
        case "zap:committed":
            guard let session, let s = p.selector, let m = p.matches else { return nil }
            return .zapCommitted(session: session, selector: s, label: p.label ?? "", matches: m, inShadowRoot: p.inShadowRoot ?? false)
        case "zap:replaced":
            guard let session, let old = p.oldSelector, let new = p.newSelector, let m = p.matches else { return nil }
            return .zapReplaced(session: session, oldSelector: old, newSelector: new, label: p.label ?? "", matches: m)
        case "zap:removed":
            guard let session, let s = p.selector, let via = p.via else { return nil }
            return .zapRemoved(session: session, selector: s, via: via)
        case "zap:revealRequested":
            guard let session, let selector = p.selector else { return nil }
            return .revealRequested(session: session, selector: selector)
        case "picker:selected":
            guard let session, let selector = p.selector, let matches = p.matches else { return nil }
            return .pickerSelected(session: session, selector: selector, matches: matches)
        case "zap:list-result":
            guard let session, let entries = p.entries else { return nil }
            return .zapListResult(session: session, entries: entries)
        case "picker:ready":
            guard let session else { return nil }; return .pickerReady(session: session)
        case "picker:exited":
            guard let session, let reason = p.reason else { return nil }; return .pickerExited(session: session, reason: reason)
        case "picker:error":
            guard let session, let kind = p.kind else { return nil }; return .pickerError(session: session, kind: kind, selector: p.selector)
        case "boost:applied":
            guard let id = p.planID else { return nil }; return .boostApplied(planID: id)
        case "boost:error":
            guard let kind = p.kind else { return nil }; return .boostError(kind: kind, selector: p.selector)
        default: return nil
        }
    }

    private struct Command: Encodable {
        var boostID: BoostID
        var sessionNonce: String
        var selector: String?
        var selectors: [String]?
        var mode: PickerMode?
        var labels: [String: String]?
        init(_ session: PickerSession, selector: String? = nil, selectors: [String]? = nil, mode: PickerMode? = nil, labels: [String: String]? = nil) {
            boostID = session.boostID; sessionNonce = session.sessionNonce
            self.selector = selector; self.selectors = selectors; self.mode = mode; self.labels = labels
        }
    }
    private struct WireBoost: Encodable { var boostID: BoostID; var css: String; var zaps: [String] }
    private struct WirePlan: Encodable {
        var planID: String
        var boosts: [WireBoost]
        var colorAdjustment: ColorAdjustment?
        var fontFamily: String?
        var textZoom: Double?
        var textTransform: String?
        var js: String
        private enum CodingKeys: String, CodingKey { case planID, boosts, colorAdjustment, fontFamily, textZoom, textTransform, js }
        // Unlike file DTOs, wire optional components are explicit null per §9.3.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(planID, forKey: .planID); try c.encode(boosts, forKey: .boosts)
            try c.encode(colorAdjustment, forKey: .colorAdjustment); try c.encode(fontFamily, forKey: .fontFamily)
            try c.encode(textZoom, forKey: .textZoom); try c.encode(textTransform, forKey: .textTransform)
            try c.encode(js, forKey: .js)
        }
    }
    public static func encode(_ message: PickerOutbound) -> (type: String, payloadJSON: String) {
        switch message {
        case let .enterZap(s): return ("zap:enter", json(Command(s, mode: s.mode)))
        case let .exitZap(s): return ("zap:exit", json(Command(s)))
        case let .undoZap(s): return ("zap:undo", json(Command(s)))
        case let .listZaps(s, selectors, labels): return ("zap:list", json(Command(s, selectors: selectors, labels: labels)))
        case let .removeZap(s, selector): return ("zap:remove", json(Command(s, selector: selector)))
        case let .applyBoosts(plan):
            let wire = WirePlan(planID: plan.planID, boosts: plan.boosts.map { WireBoost(boostID: $0.boostID, css: $0.css, zaps: $0.zaps) },
                                colorAdjustment: plan.colorAdjustment?.clamped(), fontFamily: plan.fontFamily,
                                textZoom: plan.textZoom, textTransform: plan.textTransform, js: plan.combinedJS)
            return ("boost:apply", json(wire))
        case .clearBoosts: return ("boost:clear", "{}")
        }
    }
    private static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        do { return String(decoding: try encoder.encode(value), as: UTF8.self) }
        catch {
            #if DEBUG
            FileHandle.standardError.write(Data("BoostPicker: bridge encode failed: \(error)\n".utf8))
            #endif
            return "{}"
        }
    }
}
