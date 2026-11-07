import Foundation
import SQLite3

public struct ArcProfileProbeCounts:Sendable,Codable {
    public var historyFound=false, savedItemsFound=false
    public var historyVisits:Int?,secretRows:Int?,savedItems:Int?
    public var historyFailed=false,savedItemsFailed=false
    public init() {}
}

/// Count estimates only. No URLs, titles, secret values, or live model objects cross tasks.
public struct ArcProbeResult: Sendable, Codable {
    public var arcDirectoryExists = false
    public var sidebarFound = false
    public var spaces: Int?
    public var sidebarItems: Int?
    public var archiveItems: Int?
    public var rawArchiveItems:Int?
    public var profileCounts:[String:ArcProfileProbeCounts]=[:]
    public var historyPartial=false,savedItemsPartial=false,cancelled=false
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
        let observer=ArcCopyAudit.observer
        let work=Task.detached(priority:.utility) {await ArcCopyAudit.$observer.withValue(observer) {await self.count()}}
        var result=await withTaskCancellationHandler {await work.value} onCancel:{work.cancel()}
        result.cancelled=work.isCancelled;return result
    }
    private func count() async -> ArcProbeResult {
        var result=ArcProbeResult()
        let fm=FileManager.default
        var directory:ObjCBool=false
        result.arcDirectoryExists=fm.fileExists(atPath:arcDirectory.path,isDirectory:&directory) && directory.boolValue
        result.sidebarFound=result.arcDirectoryExists && fm.fileExists(atPath:arcDirectory.appendingPathComponent("StorableSidebar.json").path)
        guard result.sidebarFound,!Task.isCancelled else {return result}
        var sourceDirectories:[(id:String,directory:String)]=[]
        var liveArcIDs:Set<String>=[]
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
            var profileReport=ImportReport()
            let layout=ArcImporter(arcDirectory:arcDirectory).sourceProfiles(spacesRaw:spaces,holder:holder,itemsByID:itemMap,report:&profileReport)
            counts["Profiles"]=layout.profiles.count;counts["Search settings"]=layout.profiles.count
            sourceDirectories=layout.profiles.map {($0.id.description,$0.sourceDirectory)}
            liveArcIDs=Set(items.filter {ArcImporter.buildsSidebarNode($0.1)}.map(\.0))
            if let routes=json("StorableLinkRouting.json") as? [String:Any],let rules=routes["rules"] as? [Any] {counts["Routing rules"]=rules.count}
            else {counts["Routing rules"]=0}
            result.settingsCounts=counts
            result.settingsCounts["Boosts"] = parsed.boosts.report.imported
        }
        guard !Task.isCancelled else {return result}
        let archiveURL=arcDirectory.appendingPathComponent("StorableArchiveItems.json")
        result.archiveFound=fm.fileExists(atPath:archiveURL.path)
        if let object=json("StorableArchiveItems.json") as? [String:Any],let items=object["items"] as? [Any] {
            var report=ImportReport()
            result.rawArchiveItems=items.count/2
            result.archiveItems=ArcImporter.archiveCandidates(items,liveArcIDs:liveArcIDs,report:&report).count
            result.settingsCounts["Archive"]=result.archiveItems
        }
        // A malformed sidebar still permits counts from named source metadata.
        if sourceDirectories.isEmpty {
            var report=ImportReport()
            let layout=ArcImporter(arcDirectory:arcDirectory).sourceProfiles(spacesRaw:[],holder:[:],itemsByID:[:],report:&report)
            sourceDirectories=layout.profiles.map {($0.id.description,$0.sourceDirectory)}
        }
        var seenDirectories:Set<String>=[]
        for source in sourceDirectories {
            guard !Task.isCancelled else {return result}
            let name=source.directory
            guard !name.isEmpty,name != ".",name != "..",!name.contains("/"),!name.contains("\\"),!name.contains(":"),seenDirectories.insert(name).inserted else {continue}
            var counts=ArcProfileProbeCounts()
            let profile=arcDirectory.appendingPathComponent("User Data").appendingPathComponent(name)
            let historyURL=profile.appendingPathComponent("History")
            if fm.fileExists(atPath:historyURL.path) {
                counts.historyFound=true;result.historyFound=true
                do {counts.historyVisits=try await ArcHistoryReader(historyFileURL:historyURL).readBatches(consume:{_ in}).keptVisits}
                catch {counts.historyFailed=true}
            }
            if !Task.isCancelled && ["Login Data","Cookies","Web Data"].contains(where:{fm.fileExists(atPath:profile.appendingPathComponent($0).path)}) {
                counts.savedItemsFound=true;result.secretsFound=true
                do {
                    let report=try ArcSecretsReader(profileDirectory:profile).countOnly()
                    counts.secretRows=report.loginRows+report.cookieRows
                    counts.savedItems=report.loginRows+report.cookieRows+report.addressRows+report.cardRows
                } catch {counts.savedItemsFailed=true}
            }
            result.profileCounts[source.id]=counts
        }
        let histories=result.profileCounts.values.compactMap(\.historyVisits)
        let secrets=result.profileCounts.values.compactMap(\.secretRows)
        let saved=result.profileCounts.values.compactMap(\.savedItems)
        if !histories.isEmpty {result.historyVisits=histories.reduce(0,+);result.settingsCounts["History"]=result.historyVisits}
        if !saved.isEmpty {result.secretRows=secrets.reduce(0,+);result.savedItems=saved.reduce(0,+);result.settingsCounts["Passwords and cookies"]=result.savedItems}
        result.historyPartial = !histories.isEmpty && result.profileCounts.values.contains{ $0.historyFailed }
        result.savedItemsPartial = !saved.isEmpty && result.profileCounts.values.contains{ $0.savedItemsFailed }
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
}

public struct ArcProbeCancellationReceipt:Sendable {
    public let cancelled:Bool,copyStarted:Bool,copyWasPartial:Bool,privateModes:Bool,temporaryCopyRemoved:Bool,sourceUnchanged:Bool
}

private final class ProbeCopyReceipt:@unchecked Sendable {
    let lock=NSLock();var directory:URL?;var bytes=0;var modes=false
    func observe(_ directory:URL,_ bytes:Int) {
        lock.lock();defer {lock.unlock()}
        self.directory=directory;self.bytes=bytes
        let fm=FileManager.default
        let dir=(try? fm.attributesOfItem(atPath:directory.path)[.posixPermissions] as? NSNumber)?.intValue
        let file=(try? fm.attributesOfItem(atPath:directory.appendingPathComponent("History").path)[.posixPermissions] as? NSNumber)?.intValue
        modes=dir == 0o700 && file == 0o600
        withUnsafeCurrentTask {$0?.cancel()}
    }
}

public extension ArcProbe {
    /// Real copy/cancellation/cleanup through the public probe. The caller cannot supply user data.
    static func verifyCopyCancellation() async throws -> ArcProbeCancellationReceipt {
        let work=Task.detached(priority:.utility) {() async throws -> ArcProbeCancellationReceipt in
            let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("open-probe-cancel-"+UUID().uuidString)
            try fm.createDirectory(at:root.appendingPathComponent("User Data/Default"),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            defer {try? fm.removeItem(at:root)}
            try JSONSerialization.data(withJSONObject:["sidebar":["containers":["fixture",["items":[],"spaces":[]]]]]).write(to:root.appendingPathComponent("StorableSidebar.json"))
            let history=root.appendingPathComponent("User Data/Default/History")
            var db:OpaquePointer?
            guard sqlite3_open(history.path,&db) == SQLITE_OK else {sqlite3_close(db);throw ArcHistoryImportError.openFailed}
            let status=sqlite3_exec(db,"CREATE TABLE payload(value BLOB); INSERT INTO payload VALUES(zeroblob(8*1024*1024));",nil,nil,nil)
            sqlite3_close(db);guard status == SQLITE_OK else {throw ArcHistoryImportError.copyFailed}
            let before=try Data(contentsOf:history),audit=ProbeCopyReceipt()
            let result=await ArcCopyAudit.$observer.withValue({audit.observe($0,$1)}) {await ArcProbe(arcDirectory:root).run()}
            let directory=audit.directory
            return ArcProbeCancellationReceipt(cancelled:result.cancelled,copyStarted:audit.bytes>0,copyWasPartial:audit.bytes<before.count,privateModes:audit.modes,temporaryCopyRemoved:directory.map{!fm.fileExists(atPath:$0.path)} ?? false,sourceUnchanged:try Data(contentsOf:history) == before)
        }
        return try await work.value
    }
}
