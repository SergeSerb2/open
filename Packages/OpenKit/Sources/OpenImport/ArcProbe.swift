import Foundation

/// Count estimates only. No URLs, titles, secret values, or live model objects cross tasks.
public struct ArcProbeResult: Sendable, Codable {
    public var arcDirectoryExists = false
    public var sidebarFound = false
    public var spaces: Int?
    public var sidebarItems: Int?
    public var archiveItems: Int?
    public var historyVisits: Int?
    /// Login and cookie rows. The extra Settings counts include addresses and cards too.
    public var secretRows: Int?
    public var savedItems: Int?
    public var arcIsRunning = false
    public var settingsCounts: [String: Int] = [:]
    public var historyFound = false
    public var secretsFound = false
    public var archiveFound = false
    public init() {}
}

/// Best-effort estimates. Every SQLite read goes through the phase-2 readers' private-copy path.
public struct ArcProbe:Sendable {
    public let arcDirectory:URL
    public init(arcDirectory:URL?=nil) {
        self.arcDirectory=arcDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Arc")
    }
    public func run() async -> ArcProbeResult {
        let work=Task.detached(priority:.utility) {await self.count()}
        return await withTaskCancellationHandler {await work.value} onCancel:{work.cancel()}
    }
    private func count() async -> ArcProbeResult {
        var result=ArcProbeResult()
        let fm=FileManager.default
        var directory:ObjCBool=false
        result.arcDirectoryExists=fm.fileExists(atPath:arcDirectory.path,isDirectory:&directory) && directory.boolValue
        result.sidebarFound=result.arcDirectoryExists && fm.fileExists(atPath:arcDirectory.appendingPathComponent("StorableSidebar.json").path)
        guard result.sidebarFound,!Task.isCancelled else {return result}
        // Read the importer's immutable parse, never a BrowserModel. The walk stays on this worker.
        if let parsed=try? ArcImporter(arcDirectory:arcDirectory).readSidebar(),
           let sidebar=parsed.root["sidebar"] as? [String:Any],let containers=sidebar["containers"] as? [Any],containers.count>1,
           let holder=containers[1] as? [String:Any],let rawItems=holder["items"] as? [Any],let rawSpaces=holder["spaces"] as? [Any] {
            let items=entries(rawItems),spaces=entries(rawSpaces)
            result.spaces=spaces.count
            let content=items.filter {kind($0.1) != "itemContainer"}
            result.sidebarItems=content.count
            var counts:[String:Int]=["Spaces":spaces.count,"Pinned and Today tabs":0,"Favorites":0,"Folders":0,"Skipped easels":0,"Skipped notes":0,"Skipped unknown":0,"Welcome items":0]
            let itemMap=Dictionary(items,uniquingKeysWith: {first,_ in first})
            let topApps=holder["topAppsContainerIDs"] as? [Any] ?? []
            var favoriteIDs:Set<String>=[]
            for index in stride(from:1,to:topApps.count,by:2) {
                if let id=topApps[index] as? String,let children=itemMap[id]?["childrenIds"] as? [String] {favoriteIDs.formUnion(children)}
            }
            for (id,item) in content {
                switch kind(item) {
                case "tab","welcomeToArc":
                    counts[favoriteIDs.contains(id) ? "Favorites":"Pinned and Today tabs",default:0] += 1
                    if kind(item) == "welcomeToArc" {counts["Welcome items",default:0] += 1}
                case "list":counts["Folders",default:0] += 1
                case "easel":counts["Skipped easels",default:0] += 1
                case "note":counts["Skipped notes",default:0] += 1
                case "splitView":break
                default:counts["Skipped unknown",default:0] += 1
                }
            }
            let profiles=Set(spaces.map {ArcImporter.profileReferenceKey($0.1["profile"])})
            counts["Profiles"]=max(1,profiles.count);counts["Search settings"]=max(1,profiles.count)
            if let routes=json("StorableLinkRouting.json") as? [String:Any],let rules=routes["rules"] as? [Any] {counts["Routing rules"]=rules.count}
            else {counts["Routing rules"]=0}
            result.settingsCounts=counts
        }
        guard !Task.isCancelled else {return result}
        let archiveURL=arcDirectory.appendingPathComponent("StorableArchiveItems.json")
        result.archiveFound=fm.fileExists(atPath:archiveURL.path)
        if let object=json("StorableArchiveItems.json") as? [String:Any],let items=object["items"] as? [Any] {result.archiveItems=items.count/2;result.settingsCounts["Archive"]=result.archiveItems}
        var history=0,secrets=0,saved=0,historyFailed=false,secretsFailed=false
        for name in profileDirectories() {
            guard !Task.isCancelled else {return result}
            let profile=arcDirectory.appendingPathComponent("User Data").appendingPathComponent(name)
            let historyURL=profile.appendingPathComponent("History")
            if fm.fileExists(atPath:historyURL.path) {
                result.historyFound=true
                do {
                    // Kept rows, not the unfiltered visits table. This shares the reader's
                    // schema, scheme, transition and timestamp rules (§10 F2).
                    let report=try await ArcHistoryReader(historyFileURL:historyURL).readBatches(consume:{_ in})
                    history += report.keptVisits
                } catch {historyFailed=true}
            }
            guard !Task.isCancelled else {return result}
            if ["Login Data","Cookies","Web Data"].contains(where:{fm.fileExists(atPath:profile.appendingPathComponent($0).path)}) {
                result.secretsFound=true
                do {
                    let report=try ArcSecretsReader(profileDirectory:profile).countOnly()
                    secrets += report.loginRows+report.cookieRows
                    saved += report.loginRows+report.cookieRows+report.addressRows+report.cardRows
                } catch {secretsFailed=true}
            }
        }
        if result.historyFound && !historyFailed {result.historyVisits=history;result.settingsCounts["History"]=history}
        if result.secretsFound && !secretsFailed {result.secretRows=secrets;result.savedItems=saved;result.settingsCounts["Passwords and cookies"]=saved}
        return result
    }
    private func json(_ path:String)->Any? {
        guard let data=try? Data(contentsOf:arcDirectory.appendingPathComponent(path)) else {return nil}
        return try? JSONSerialization.jsonObject(with:data)
    }
    private func entries(_ array:[Any])->[(String,[String:Any])] {
        stride(from:0,to:max(0,array.count-1),by:2).compactMap {index in
            guard let id=array[index] as? String,let value=array[index+1] as? [String:Any] else {return nil};return (id,value)
        }
    }
    private func kind(_ item:[String:Any])->String {(item["data"] as? [String:Any])?.keys.first ?? "unknown"}
    private func profileDirectories()->[String] {
        // Named metadata only; no scan of unrelated user files or profile directories.
        var names:Set<String>=["Default"]
        if let root=json("User Data/Local State") as? [String:Any],let profile=root["profile"] as? [String:Any],let cache=profile["info_cache"] as? [String:Any] {names.formUnion(cache.keys)}
        for file in ["StorableProfiles.json","StorableProfileContainers.json"] {
            func visit(_ raw:Any) {
                if let array=raw as? [Any] {for value in array {if value is [String:Any] {visit(value)}}}
                else if let object=raw as? [String:Any] {
                    for key in ["profileDirectoryBasename","directoryBasename","directory"] {if let name=object[key] as? String {names.insert(name)}}
                    for value in object.values where value is [String:Any] || value is [Any] {visit(value)}
                }
            }
            if let root=json(file) {visit(root)}
        }
        return names.filter {!$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\") && !$0.contains(":")}.sorted()
    }
}
