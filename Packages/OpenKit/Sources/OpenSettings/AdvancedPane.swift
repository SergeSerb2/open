import Foundation
import Observation
import SwiftUI
import AppKit
import OpenModel
import OpenStore
import OpenDesign
import OpenCommands

@MainActor @Observable public final class AdvancedViewModel {
    unowned let root: SettingsViewModel
    public var statusText = ""
    public init(root: SettingsViewModel) { self.root = root }
    public var sleepMode: TabSleepMode { get { TabSleepMode(rawValue: root.string("open.advanced.tabSleepMode")) ?? .automatic } set { root.set(newValue.rawValue, for: "open.advanced.tabSleepMode"); root.actions.setTabSleepMode(newValue) } }
    public func resetTranslate() { statusText = root.actions.resetTranslatePrompts(profileID: root.selectedProfileID) ?? "Done" }
    public func export(to url: URL) async {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let snapshotData = try encoder.encode(SnapshotMapper.dto(from: root.model))
            var archived: [[String: String]] = []
            for profile in root.model.profiles {
                let store = ArchiveStore(fileURL: ProfileDirectories(root: root.root).archiveFileURL(for: profile))
                for item in await store.recent(limit: Int(Int32.max)) { archived.append(["id": item.id.description, "host": item.url.host() ?? "", "title": item.title, "reason": item.reason.rawValue]) }
            }
            let data = try JSONSerialization.data(withJSONObject: ["snapshot": JSONSerialization.jsonObject(with: snapshotData), "archive": archived], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic); statusText = "Exported."
        } catch { statusText = "Export failed. \(error.localizedDescription)" }
    }
}
public struct AdvancedPane: View {
    @Bindable var model:AdvancedViewModel
    @State private var showsAdBlock=false
    public init(model:AdvancedViewModel) { self.model=model }
    public var body:some View {
        SettingsGroup {
            tile("Play Open sound effects",key:"playSoundEffects",symbol:"speaker.wave.2.fill",color:.blue)
            tile("Haptic feedback when reordering tabs",key:"hapticOnTabReorder",symbol:"hand.tap.fill",color:.blue,last:true)
        }
        SettingsGroup {
            tile("When opening Open, restore windows from previous session",key:"restoreWindowsOnLaunch",symbol:"macwindow",color:.green)
            tile("Allow window dragging from the top of webpages",key:"allowWindowDraggingFromWebTop",symbol:"rectangle.topthird.inset.filled",color:.green)
            tile("Show full URL when Toolbar is enabled",key:"showFullURLWithToolbar",symbol:"link",color:.red)
            tile("Enable Shared Quotes when highlighting text",key:"enableSharedQuotes",symbol:"quote.bubble.fill",color:.red,last:true,subtitle:"If disabled, you can still copy URL as a quote using \(quoteShortcut).")
        }
        SettingsGroup {
            tile("Enable Picture in Picture when you leave a video tab",key:"enablePictureInPictureOnLeave",symbol:"pip",color:.purple)
            tile("Allow websites to get your theme data",key:"allowSitesThemeData",symbol:"paintpalette.fill",color:.purple)
            tile("Enable Boosts on websites you visit",key:"enableBoosts",symbol:"paintbrush.pointed.fill",color:.purple,last:true)
        }
        dataButtons
        SettingsGroup {
            SettingsRow(height:44,divider:false) { HStack { Text("Search engine");Text("\(model.root.profiles.engines.first(where:{$0.id == model.root.profiles.searchEngineID})?.name ?? "Google") (\(model.root.profiles.profile?.name ?? "Profile"))").foregroundStyle(.secondary);Spacer();Button("Manage…") { model.root.showsSearchEngines=true } } }
        }
        if let ad=model.root.adBlock {
            SettingsGroup {
                SettingsRow(height:36) { SettingsSwitch("Block ads, trackers, and popups",isOn:Binding(get:{ad.enabled},set:{ad.setEnabled($0)})) }
                SettingsRow(height:44,divider:ad.hasOtherBlocker) { HStack { Text("Block lists");Text(ad.isReady ? ad.enabledIDs.joined(separator:", "):"Loading…").foregroundStyle(.secondary).lineLimit(1);Spacer();Button("Ad Block Settings…") { showsAdBlock=true } } }
                if ad.hasOtherBlocker { SettingsRow(height:44,divider:false) { Text("More than one ad blocker is on. Blocking may break sites.").foregroundStyle(.orange) } }
            }.id("advanced-adblock").sheet(isPresented:$showsAdBlock) { AdBlockSettingsSheet(model:ad,onDone:{showsAdBlock=false}) }
        }
        SettingsGroup {
            SettingsRow(height:64,divider:false) { VStack(alignment:.leading,spacing:5) {
                HStack { Text("Sleep inactive tabs");Spacer();SettingsPopUp("Sleep inactive tabs",selection:$model.sleepMode,width:150,entries:TabSleepMode.allCases.map{.option($0.rawValue.capitalized,$0)}) }
                Text(sleepDescription).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            } }
        }.id("advanced-sleep")
        if !model.statusText.isEmpty { Text(model.statusText).font(.system(size:11)).foregroundStyle(.secondary) }
    }
    private var dataButtons:some View { HStack(spacing:8) {
        Button("More Settings…") {model.root.actions.openMoreSettings()};Button("Reset Translated-site Prompts") {model.resetTranslate()};Spacer(minLength:0)
        Button("Export Data") {let panel=NSSavePanel();panel.nameFieldStringValue="Open-export.json";if panel.runModal() == .OK,let url=panel.url {Task {await model.export(to:url)}}}
        Menu {Button("Show Data Folder") {model.root.actions.revealOpenDataFolder()};Button("Copy Open Info") {model.root.actions.copyOpenInfoToPasteboard()}} label:{Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).fixedSize()
    }.controlSize(.mini).padding(.vertical,1) }
    private var quoteShortcut:String { CommandRegistry.byID["copy-url-quote"].flatMap {model.root.shortcutsStore.effectiveShortcuts(for:$0).first?.symbolDisplay} ?? "---" }
    private var sleepDescription:String { switch model.sleepMode {
    case .automatic:"Tabs you haven't viewed for 5 minutes (2 in Low Power Mode) sleep to save memory. Pinned tabs and Favorites sleep too unless they play audio or stay in use."
    case .conservative:"Tabs you haven't viewed for 15 minutes sleep to save memory. Pinned tabs and Favorites sleep too unless they play audio or stay in use."
    case .aggressive:"Tabs you haven't viewed for 2 minutes sleep to save memory. Pinned tabs and Favorites sleep too unless they play audio or stay in use."
    case .never:"Tabs stay awake until you close them. This uses more memory."
    } }
    private func tile(_ title:String,key:String,symbol:String,color:Color,last:Bool=false,subtitle:String?=nil)->some View {
        SettingsRow(height:subtitle == nil ? 40:50,divider:!last) { HStack(spacing:8) {
            Image(systemName:symbol).font(.system(size:12)).foregroundStyle(.white).frame(width:20,height:20).background(color,in:RoundedRectangle(cornerRadius:3))
            VStack(alignment:.leading,spacing:1) {Text(title).font(.system(size:13));if let subtitle {Text(subtitle).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}}
            Spacer(minLength:0);Toggle(title,isOn:Binding(get:{model.root.bool("open.advanced."+key)},set:{model.root.set($0,for:"open.advanced."+key)})).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        } }
    }
}
public struct AdBlockSettingsSheet:View {
    @Bindable var model:AdBlockSettingsModel
    let onDone:()->Void
    @State private var expanded:Set<String>=["generic"]
    public init(model:AdBlockSettingsModel,onDone:@escaping ()->Void={}) {self.model=model;self.onDone=onDone}
    public var body:some View { VStack(alignment:.leading,spacing:14) {
        Text("Ad Block Settings").font(.title2)
        Picker("Profile",selection:Binding(get:{model.root.selectedProfileID},set:{model.root.selectedProfileID=$0})){ForEach(model.root.model.profiles,id:\.id){Text($0.name).tag($0.id)}}.disabled(model.busy)
        Text("List choices and allowed sites belong to this Profile. The main switch applies to all Profiles.").font(.caption).foregroundStyle(.secondary)
        TextField("Search block lists",text:$model.query).textFieldStyle(.roundedBorder)
        ScrollView { VStack(alignment:.leading,spacing:12) {
            ForEach(["generic","cookies","privacy","regional"],id:\.self) {category in
                let lists=model.lists.filter{$0.category.lowercased() == category && !$0.urls.isEmpty}
                if !lists.isEmpty {DisclosureGroup(isExpanded:Binding(get:{expanded.contains(category) || !model.query.isEmpty},set:{if $0 {expanded.insert(category)} else {expanded.remove(category)}})) {
                    ForEach(lists){list in HStack {Toggle(list.displayName,isOn:Binding(get:{model.enabledIDs.contains(list.id)},set:{on in Task {await model.setList(list.id,enabled:on)}})).disabled(model.busy || !model.isReady);Spacer();Text(model.listStatus(list)).font(.caption).foregroundStyle(.secondary);Button {model.openInfo(list)} label:{Image(systemName:"info.circle")}.buttonStyle(.plain)}}
                } label:{Text(category.capitalized)} }
            }
            Divider();Text("Don't block on these sites")
            ForEach(model.domains,id:\.self){host in HStack {Text(host);Spacer();Button("Remove"){model.setExcluded(host,excluded:false)}.disabled(model.busy || !model.isReady)}}
            HStack {TextField("example.com",text:$model.hostDraft).disabled(model.busy || !model.isReady);Button("Add"){model.setExcluded(model.hostDraft,excluded:true)}.disabled(model.hostDraft.isEmpty || model.busy || !model.isReady)}
        }.frame(maxWidth:.infinity,alignment:.leading) }
        if model.busy || !model.isReady {ProgressView()};SettingsError(text:model.errorText);if let error=model.lastError {SettingsError(text:error)}
        HStack {Button("Copy Debug Info"){model.copyDebug()};Button("Reset List Choices"){Task {await model.reset()}}.disabled(model.busy || !model.isReady);Spacer();Button("Done",action:onDone).keyboardShortcut(.defaultAction).buttonStyle(SettingsButtonStyle(prominent:true))}
    }.padding(24).frame(width:600,height:560).task(id:model.profileID) {await model.openSelectedProfile()} }
}
