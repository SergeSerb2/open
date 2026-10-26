import Foundation
import OpenModel
import OpenStore

private let profilesUsage = """
usage: openkit profiles DIR list [--show-titles] [--json]
       openkit profiles DIR create --name NAME [--icon emoji:TEXT|symbol:NAME] [--json]
       openkit profiles DIR rename PROFILE --name NAME
       openkit profiles DIR set-icon PROFILE [--icon emoji:TEXT|symbol:NAME|none]
       openkit profiles DIR assign-space SPACE --to PROFILE
       openkit profiles DIR create-space --title TITLE --profile PROFILE
       openkit profiles DIR delete PROFILE
       openkit profiles DIR show PROFILE [--show-titles]
"""

func profileCLIError(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}

@MainActor
func resolveProfile(_ ref: String, in model: BrowserModel) -> Profile? {
    if let uuid = UUID(uuidString: ref), let profile = model.profile(id: ProfileID(rawValue: uuid)) { return profile }
    if ref.count == 8 {
        let matches = model.profiles.filter { $0.id.description.prefix(8).caseInsensitiveCompare(ref) == .orderedSame }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { return nil }
    }
    let exact = model.profiles.filter { $0.name == ref }
    if exact.count == 1 { return exact[0] }
    if exact.count > 1 { return nil }
    let matches = model.profiles.filter { $0.name.caseInsensitiveCompare(ref) == .orderedSame }
    return matches.count == 1 ? matches[0] : nil
}

@MainActor
func resolveProfileSpace(_ ref: String, in model: BrowserModel) -> Space? {
    if let uuid = UUID(uuidString: ref) { return model.space(id: SpaceID(rawValue: uuid)) }
    let matches = model.spaces.filter { $0.title == ref }
    return matches.count == 1 ? matches[0] : nil
}

/// Load maintenance precedes all per-Profile stores. JSON callers keep stdout machine-readable.
@MainActor
@discardableResult
func prepareProfiles(_ model: BrowserModel, root: URL, json: Bool = false) throws -> [SpaceID] {
    func notice(_ line: String) {
        if json { FileHandle.standardError.write(Data((line + "\n").utf8)) } else { print(line) }
    }
    let report = try OpenDataRoot.prepare(root: root, model: model)
    for line in report.moved { notice("migration moved \(line)") }
    for line in report.skipped { notice("migration skipped \(line)") }
    let repaired = model.repairMissingProfileReferences()
    for id in repaired { notice("repaired space \(id.description.prefix(8)) -> default profile") }
    let directories = ProfileDirectories(root: root)
    for profile in model.profiles { try directories.ensureProfileDirectories(for: profile) }
    return repaired
}

@MainActor
func profileArchiveSink(model: BrowserModel, directories: ProfileDirectories) -> ProfileArchiveSink {
    ProfileArchiveSink(directories: directories) { [weak model] id in
        id.flatMap { model?.profile(id: $0)?.dataDirectoryName } ?? model?.defaultProfile?.dataDirectoryName ?? "Default"
    }
}

@MainActor
func runProfiles(args: [String]) throws {
    func usage() -> Never { FileHandle.standardError.write(Data((profilesUsage + "\n").utf8)); exit(2) }
    guard args.count >= 2 else { usage() }
    let root = URL(fileURLWithPath: args[0]), command = args[1]
    let allowed: Set<String>
    let flags: Set<String>
    let positionalCount: Int
    switch command {
    case "list": allowed = []; flags = ["--show-titles", "--json"]; positionalCount = 0
    case "create": allowed = ["--name", "--icon"]; flags = ["--json"]; positionalCount = 0
    case "rename": allowed = ["--name"]; flags = []; positionalCount = 1
    case "set-icon": allowed = ["--icon"]; flags = []; positionalCount = 1
    case "assign-space": allowed = ["--to"]; flags = []; positionalCount = 1
    case "create-space": allowed = ["--title", "--profile"]; flags = []; positionalCount = 0
    case "delete": allowed = []; flags = []; positionalCount = 1
    case "show": allowed = []; flags = ["--show-titles"]; positionalCount = 1
    default: usage()
    }
    var options: [String: String] = [:], enabled: Set<String> = [], positional: [String] = []
    var i = 2
    while i < args.count {
        let arg = args[i]
        if flags.contains(arg) {
            guard enabled.insert(arg).inserted else { usage() }
        } else if allowed.contains(arg) {
            guard options[arg] == nil, i + 1 < args.count, !args[i + 1].hasPrefix("--") else { usage() }
            i += 1; options[arg] = args[i]
        } else if arg.hasPrefix("--") { usage() }
        else { positional.append(arg) }
        i += 1
    }
    guard positional.count == positionalCount else { usage() }
    for key in allowed where key != "--icon" { guard options[key] != nil else { usage() } }
    var icon: SpaceIcon?
    if let raw = options["--icon"] {
        if raw == "none", command == "set-icon" { icon = nil }
        else if raw.hasPrefix("emoji:"), raw.count > 6 { icon = .emoji(String(raw.dropFirst(6))) }
        else if raw.hasPrefix("symbol:"), raw.count > 7 { icon = .symbol(String(raw.dropFirst(7))) }
        else { usage() }
    }
    let snapshot = SnapshotStore(root: root)
    let model: BrowserModel
    if let loaded = try snapshot.load() { model = loaded }
    else if command == "list" { print("no snapshot at \(args[0])"); return }
    else if command == "create" { model = BrowserModel() }
    else { profileCLIError("no snapshot at \(args[0])") }
    let json = enabled.contains("--json")
    let mutating = command != "list" && command != "show"
    let repaired = try prepareProfiles(model, root: root, json: json)
    if mutating && command != "delete" && !repaired.isEmpty { try snapshot.saveNow(model: model) }
    let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
    let directories = ProfileDirectories(root: root)
    let sink = profileArchiveSink(model: model, directories: directories)
    model.archiveSink = sink
    func profile(_ ref: String) -> Profile {
        guard let profile = resolveProfile(ref, in: model) else { profileCLIError("unknown profile \(ref)", code: 2) }
        return profile
    }
    func space(_ ref: String) -> Space {
        guard let space = resolveProfileSpace(ref, in: model) else { profileCLIError("unknown space \(ref)", code: 2) }
        return space
    }
    func line(_ profile: Profile) {
        print("profile \(profile.id.description.prefix(8)) dir=\(profile.dataDirectoryName) spaces=\(model.spaces(using: profile.id).count) favorites=\(profile.favorites.count) default=\(profile.id == model.defaultProfile?.id) name=\(enabled.contains("--show-titles") ? profile.name : "•••")")
    }
    func jsonRow(_ profile: Profile) -> [String: Any] {
        ["id": profile.id.description, "name": profile.name, "dataDirectoryName": profile.dataDirectoryName,
         "spaceIDs": model.spaces(using: profile.id).map { $0.id.description }, "favoriteCount": profile.favorites.count,
         "isDefault": profile.id == model.defaultProfile?.id]
    }
    func printJSON(_ value: Any) throws { print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)) }
    switch command {
    case "list":
        if json { try printJSON(model.profiles.map(jsonRow)) }
        else { model.profiles.forEach(line); print("profiles=\(model.profiles.count) spaces=\(model.spaces.count)") }
    case "show":
        let p = profile(positional[0]); line(p)
        for s in model.spaces(using: p.id) { print("space \(s.id.description.prefix(8)) title=\(enabled.contains("--show-titles") ? s.title : "•••")") }
    case "create":
        let name = options["--name"]!
        guard let p = model.createProfile(name: name, icon: icon) else {
            profileCLIError("profile name \(BrowserModel.profileNameIssue(name, in: model.profiles)!.rawValue)")
        }
        try directories.ensureProfileDirectories(for: p)
        try snapshot.saveNow(model: model)
        if json { try printJSON(jsonRow(p)) } else { print("created profile \(p.id.description.prefix(8)) dir=\(p.dataDirectoryName)") }
    case "rename":
        let p = profile(positional[0]), name = options["--name"]!
        guard model.renameProfile(id: p.id, to: name) else {
            profileCLIError("profile name \(BrowserModel.profileNameIssue(name, in: model.profiles, excluding: p.id)!.rawValue)")
        }
        try snapshot.saveNow(model: model); print("updated profile \(p.id.description.prefix(8))")
    case "set-icon":
        let p = profile(positional[0]); model.setProfileIcon(id: p.id, icon: icon)
        try snapshot.saveNow(model: model); print("updated profile \(p.id.description.prefix(8))")
    case "assign-space":
        let s = space(positional[0]), p = profile(options["--to"]!)
        guard model.moveSpace(id: s.id, toProfile: p.id) else { profileCLIError("cannot assign space") }
        try snapshot.saveNow(model: model); print("assigned space \(s.id.description.prefix(8)) -> profile \(p.id.description.prefix(8))")
    case "create-space":
        let p = profile(options["--profile"]!)
        let s = model.createSpace(title: options["--title"]!, profileID: p.id)
        try snapshot.saveNow(model: model); print("created space \(s.id.description.prefix(8)) profile=\(p.id.description.prefix(8))")
    case "delete":
        let p = profile(positional[0]), favoriteCount = p.favorites.count
        if let reason = model.deleteBlockReason(for: p.id) {
            switch reason {
            case .isDefault: profileCLIError("profile is default")
            case .spacesAssigned(let count): profileCLIError("profile has \(count) space(s)")
            }
        }
        guard try model.deleteProfile(id: p.id) else { profileCLIError("cannot delete profile") }
        sink.flushAll(); try snapshot.saveNow(model: model)
        print("deleted profile \(p.id.description.prefix(8)) archivedFavorites=\(favoriteCount)")
    default: usage()
    }
}
