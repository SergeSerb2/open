import Foundation

public enum PickerInbound: Sendable {
    case zapCommitted(boostID: BoostID, selector: String, label: String, matches: Int, inShadowRoot: Bool)
    case zapReplaced(boostID: BoostID, oldSelector: String, newSelector: String, label: String, matches: Int)
    case zapRemoved(boostID: BoostID, selector: String, via: String)
    case zapListResult(boostID: BoostID, entries: [ZapListEntry])
    case pickerReady(boostID: BoostID)
    case pickerExited(boostID: BoostID?, reason: String)
    case pickerError(kind: String, selector: String?)
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
    case enterZap(boostID: BoostID)
    case exitZap
    case undoZap
    case listZaps(boostID: BoostID)
    case removeZap(boostID: BoostID, selector: String)
    case applyBoosts(InjectionPlan)
    case clearBoosts
}

@MainActor
public final class BoostPickerCoordinator {
    private let store: BoostStore
    public private(set) var lastListResult: [ZapListEntry] = []
    public init(store: BoostStore) { self.store = store }

    public func handle(_ message: PickerInbound) -> Bool {
        switch message {
        case let .zapCommitted(id, selector, label, _, _):
            guard store.boost(id: id) != nil else { debugLog("unknown boost \(id)"); return false }
            return store.appendZap(boostID: id, zap: ZappedElement(selector: selector, label: label))
        case let .zapReplaced(id, old, new, label, _):
            guard store.boost(id: id) != nil else { debugLog("unknown boost \(id)"); return false }
            let old = old.trimmingCharacters(in: .whitespacesAndNewlines), new = new.trimmingCharacters(in: .whitespacesAndNewlines)
            guard old != new, !new.isEmpty else { return false }
            let removed = store.removeZap(boostID: id, selector: old)
            let appended = store.appendZap(boostID: id, zap: ZappedElement(selector: new, label: label))
            return removed || appended
        case let .zapRemoved(id, selector, via):
            return via == "undo" ? store.removeZap(boostID: id, selector: selector) : false
        case let .zapListResult(_, entries): lastListResult = entries; return false
        case let .pickerError(kind, selector), let .boostError(kind, selector):
            debugLog("\(kind) \(selector ?? "")"); return false
        case .pickerReady, .pickerExited, .boostApplied: return false
        }
    }
    private func debugLog(_ message: String) {
        #if DEBUG
        FileHandle.standardError.write(Data("BoostPicker: \(message)\n".utf8))
        #endif
    }
}

/// The App transport checks envelope v == 1 before passing (type, payloadJSON).
/// Native -> page: wrap the returned pair in {v:1,type,payload} for __open.receive.
public enum BridgeDecode {
    private struct Inbound: Decodable {
        var boostID: BoostID?
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
        switch type {
        case "zap:committed":
            guard let id = p.boostID, let s = p.selector, let m = p.matches else { return nil }
            return .zapCommitted(boostID: id, selector: s, label: p.label ?? "", matches: m, inShadowRoot: p.inShadowRoot ?? false)
        case "zap:replaced":
            guard let id = p.boostID, let old = p.oldSelector, let new = p.newSelector, let m = p.matches else { return nil }
            return .zapReplaced(boostID: id, oldSelector: old, newSelector: new, label: p.label ?? "", matches: m)
        case "zap:removed":
            guard let id = p.boostID, let s = p.selector, let via = p.via else { return nil }
            return .zapRemoved(boostID: id, selector: s, via: via)
        case "zap:list-result":
            guard let id = p.boostID, let entries = p.entries else { return nil }
            return .zapListResult(boostID: id, entries: entries)
        case "picker:ready":
            guard let id = p.boostID else { return nil }; return .pickerReady(boostID: id)
        case "picker:exited":
            guard let reason = p.reason else { return nil }; return .pickerExited(boostID: p.boostID, reason: reason)
        case "picker:error":
            guard let kind = p.kind else { return nil }; return .pickerError(kind: kind, selector: p.selector)
        case "boost:applied":
            guard let id = p.planID else { return nil }; return .boostApplied(planID: id)
        case "boost:error":
            guard let kind = p.kind else { return nil }; return .boostError(kind: kind, selector: p.selector)
        default: return nil
        }
    }

    private struct Command: Encodable {
        var boostID: BoostID?
        var selector: String?
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
        case let .enterZap(id): return ("zap:enter", json(Command(boostID: id)))
        case .exitZap: return ("zap:exit", "{}")
        case .undoZap: return ("zap:undo", "{}")
        case let .listZaps(id): return ("zap:list", json(Command(boostID: id)))
        case let .removeZap(id, selector): return ("zap:remove", json(Command(boostID: id, selector: selector)))
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
