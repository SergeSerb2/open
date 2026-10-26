import Foundation
import OpenModel
import OpenStore
import OpenRouting

private let routeUsage = """
usage: openkit route DIR <url> [--source BUNDLE_ID] [--most-recent SPACE]
                        [--external-little-open on|off] [--json]
                        [--expect-destination space:<uuid>|littleOpen|mostRecentSpace]
"""

private enum ExpectedRoute {
    case space(SpaceID), littleOpen, mostRecentSpace
}

private func routeUsageError(_ message: String? = nil) -> Never {
    if let message { FileHandle.standardError.write(Data("error: \(message)\n".utf8)) }
    FileHandle.standardError.write(Data((routeUsage + "\n").utf8))
    exit(2)
}

@MainActor
func runRoute(args: [String]) throws {
    var positional: [String] = []
    var source: String?, mostRecent: String?
    var externalLittleOpen: Bool?
    var json = false
    var expected: ExpectedRoute?
    var i = 0
    func value() -> String {
        i += 1
        guard i < args.count, !args[i].hasPrefix("--") else { routeUsageError("missing option value") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--source": source = value()
        case "--most-recent": mostRecent = value()
        case "--external-little-open":
            switch value() {
            case "on": externalLittleOpen = true
            case "off": externalLittleOpen = false
            default: routeUsageError("--external-little-open needs on or off")
            }
        case "--json": json = true
        case "--expect-destination":
            let destination = value()
            if destination == "littleOpen" { expected = .littleOpen }
            else if destination == "mostRecentSpace" { expected = .mostRecentSpace }
            else if destination.hasPrefix("space:"), let uuid = UUID(uuidString: String(destination.dropFirst(6))) {
                expected = .space(SpaceID(rawValue: uuid))
            } else { routeUsageError("invalid expected destination") }
        default:
            guard !args[i].hasPrefix("--") else { routeUsageError("unknown option \(args[i])") }
            positional.append(args[i])
        }
        i += 1
    }
    guard positional.count == 2, let url = RoutingRequest.parseURL(positional[1]) else { routeUsageError() }
    let directory = positional[0]
    guard let model = try SnapshotStore(root: URL(fileURLWithPath: directory)).load() else {
        FileHandle.standardError.write(Data("error: no snapshot at \(directory)\n".utf8))
        exit(1)
    }
    let spaces = model.spaces.map { RoutingSpaceSnapshot(id: $0.id, title: $0.title, profileID: $0.profileID) }
    // Stored model order is not AppKit z-order. This CLI explicitly uses stored
    // standard-window order as its frontmost approximation, shown in the report.
    let windows = model.windows.filter { $0.style == .standard } + model.windows.filter { $0.style != .standard }
    var routingWindows = windows.map {
        RoutingWindowSnapshot(id: $0.id, kind: $0.style == .standard ? .standard : .littleOpen, focusedSpaceID: $0.focusedSpaceID)
    }
    var override: SpaceID?
    if let mostRecent {
        let selected = spaces.first {
            UUID(uuidString: mostRecent) == $0.id.rawValue || $0.title == mostRecent
        }
        guard let selected else { routeUsageError("unknown Space \(mostRecent)") }
        override = selected.id
        if let index = routingWindows.firstIndex(where: { $0.kind == .standard && $0.focusedSpaceID == selected.id }) {
            routingWindows.insert(routingWindows.remove(at: index), at: 0)
        } else {
            routingWindows.insert(RoutingWindowSnapshot(id: WindowID(), kind: .standard, focusedSpaceID: selected.id), at: 0)
        }
    }
    let toggle = externalLittleOpen ?? (UserDefaults.standard.object(forKey: "open.links.externalInLittleOpen") as? Bool ?? true)
    var snapshot = RoutingSnapshot(spaces: spaces, windows: routingWindows, rules: model.routingRules,
        defaultDestination: model.defaultDestination, externalLinksInLittleOpen: toggle, mostRecentOverride: override)
    let request = RoutingRequest(url: url, source: RoutingSource(bundleID: source))
    let decision = RoutingEvaluator().evaluate(request, in: snapshot)
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(decision)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } else { print(RoutingDecisionFormatter.report(decision, spaces: spaces)) }
    if let expected {
        let matches: Bool
        switch expected {
        case .littleOpen:
            if case .littleOpen = decision.resolved { matches = true } else { matches = false }
        case .space(let id):
            if case .space(let actual, _) = decision.resolved { matches = actual == id } else { matches = false }
        case .mostRecentSpace:
            // Use the same evaluator to resolve this expectation; no second routing
            // algorithm in the CLI that could drift from the real caller's behavior.
            snapshot.rules = []
            snapshot.defaultDestination = .mostRecentSpace
            let recent = RoutingEvaluator().evaluate(request, in: snapshot).resolved
            if case .space = recent { matches = decision.resolved == recent } else { matches = false }
        }
        if !matches {
            FileHandle.standardError.write(Data("error: destination did not match --expect-destination\n".utf8))
            exit(1)
        }
    }
}
