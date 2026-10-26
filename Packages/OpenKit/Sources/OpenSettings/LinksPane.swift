import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OpenModel
import OpenRouting
import OpenCommands
import OpenDesign

public struct LinksPane:View {
    let root:SettingsViewModel
    @Bindable var links:LinksSettingsModel
    @State private var editing:RuleDraft?
    public init(root:SettingsViewModel) {self.root=root;links=root.links}
    public var body:some View {
        Text("Little Open is a smaller, simpler Open window for quick lookups and reading links.").fixedSize(horizontal:false,vertical:true).padding(.bottom,4)
        SettingsGroup {
            SettingsRow(height:36) {SettingsSwitch("Open Little Open when I press \(hotkey) in any app",isOn:toggle(\.littleOpenHotkeyEnabled))}
            SettingsRow(height:36) {SettingsSwitch("Open Little Open when clicking on links with ⌥⌘ held",isOn:toggle(\.optionCommandClickLittleOpen))}
            SettingsRow(height:36) {SettingsSwitch("Links from other apps open in Little Open",isOn:toggle(\.externalLinksInLittleOpen))}
            SettingsRow(height:44,divider:false) {HStack {Text("Archive Little Open windows after");Spacer();Picker("Archive Little Open windows after",selection:Binding(get:{links.littleOpenAutoArchiveAfter},set:{links.littleOpenAutoArchiveAfter=$0;root.commitLinks()})){ForEach(AutoArchiveInterval.allCases,id:\.self){Text($0.settingsTitle + ($0 == .sixHours ? " (default)":"")).tag($0)}}.labelsHidden().frame(width:155)}}
        }
        Rectangle().fill(Color(nsColor:SettingsTokens.divider.nsColor)).frame(height:1).padding(.vertical,10)
        Text("Peek is a way to preview a link without opening a new tab. It's perfect for quickly looking at a link from an email, news article, or tweet.").fixedSize(horizontal:false,vertical:true).padding(.bottom,4)
        SettingsGroup {
            SettingsRow(height:36) {PreferenceToggle(title:"Open a Peek window when clicking on links with Shift held",key:"open.links.openPeekShiftClick",root:root)}
            SettingsRow(height:49,divider:false) {VStack(alignment:.leading,spacing:3) {PreferenceToggle(title:"Open a Peek window when clicking on links to other sites",key:"open.links.openPeekOtherSites",root:root);Text("This only affects Favorites and Pinned tabs").font(.system(size:11)).italic().foregroundStyle(.secondary)}}
        }
        SettingsGroup {
            SettingsRow {HStack {Text("Default destination");Spacer();RouteDestinationPicker(spaces:links.spaces,kind:Binding(get:{links.defaultDestinationKind},set:{links.defaultDestinationKind=$0;root.commitLinks()}),space:Binding(get:{links.defaultSpaceID},set:{links.defaultSpaceID=$0;root.commitLinks()}))}}
            ForEach(Array(links.drafts.enumerated()),id:\.element.id) {index,draft in
                SettingsRow(height:44,divider:index < links.drafts.count-1) {HStack(spacing:8) {
                    Button {editing=draft} label:{HStack {Text(draft.pattern.isEmpty ? "New rule":draft.pattern).lineLimit(1);Spacer();Text(destinationLabel(draft)).foregroundStyle(.secondary).lineLimit(1)}}.buttonStyle(.plain)
                    Button {links.deleteRule(id:draft.id);root.commitLinks()} label:{Image(systemName:"minus.circle.fill").font(.system(size:16)).foregroundStyle(.secondary)}.buttonStyle(.plain).help("Delete rule")
                }.draggable(draft.id.description).dropDestination(for:String.self) {values,_ in guard let value=values.first,let from=links.drafts.firstIndex(where:{$0.id.description == value}) else {return false};links.moveRule(from:from,to:index);root.commitLinks();return true}}
                .contextMenu {Button("Edit Rule…"){editing=draft};Button("Move Up"){links.moveRule(from:index,to:index-1);root.commitLinks()}.disabled(index == 0);Button("Move Down"){links.moveRule(from:index,to:index+1);root.commitLinks()}.disabled(index == links.drafts.count-1)}
            }
        }.id("links-rules")
        Button("Add Rule…") {let rule=RoutingRule(match:.hostEquals(""),destination:.littleOpen);editing=RuleDraft(from:rule)}
        .sheet(item:$editing){draft in LinkRuleSheet(root:root,draft:draft,onDone:{editing=nil})}
        SettingsGroup {
            SettingsRow {HStack {TextField("URL or host",text:$links.testURLString);Button("Test"){links.runTest()}}}
            SettingsRow {AppPicker(bundleID:$links.testSourceBundleID)}
            SettingsRow(divider:false) {Picker("Most Recent Space",selection:$links.testMostRecentSpaceID){Text("Automatic").tag(Optional<SpaceID>.none);ForEach(links.spaces){Text($0.title).tag(Optional($0.id))}}}
        }.id("links-test")
        if let decision=links.testDecision {Text(RoutingDecisionFormatter.report(decision,spaces:root.routingSpaces)).font(.system(.caption,design:.monospaced)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}
    }
    private var hotkey:String {CommandRegistry.byID["little-open-global"].flatMap{root.shortcutsStore.effectiveShortcuts(for:$0).first?.symbolDisplay} ?? "---"}
    private func toggle(_ key:ReferenceWritableKeyPath<LinksSettingsModel,Bool>)->Binding<Bool> {Binding(get:{links[keyPath:key]},set:{links[keyPath:key]=$0;root.commitLinks()})}
    private func destinationLabel(_ draft:RuleDraft)->String {switch draft.destinationKind {case .littleOpen:"Little Open";case .mostRecentSpace:"Most Recent Space";case .space:links.spaces.first{$0.id == draft.spaceID}?.title ?? "Choose Space"}}
}
public struct LinkRuleSheet:View {
    let root:SettingsViewModel
    @State private var draft:RuleDraft
    let onDone:()->Void
    public init(root:SettingsViewModel,draft:RuleDraft,onDone:@escaping ()->Void={}){self.root=root;_draft=State(initialValue:draft);self.onDone=onDone}
    public var body:some View {VStack(alignment:.leading,spacing:18) {
        Text("Link Routing").font(.title2)
        Picker("Match",selection:$draft.matchKind){Text("Host contains").tag(RuleDraft.MatchKind.hostContains);Text("Host equals").tag(RuleDraft.MatchKind.hostEquals);Text("URL starts with").tag(RuleDraft.MatchKind.urlPrefix)}
        TextField("Pattern",text:$draft.pattern)
        if draft.matchKind == .hostContains {Text("Host contains matches any host containing “\(draft.pattern)”, including unrelated hosts.").font(.caption).foregroundStyle(.secondary)}
        HStack {Text("Open in");Spacer();RouteDestinationPicker(spaces:root.links.spaces,kind:$draft.destinationKind,space:$draft.spaceID)}
        AppPicker(bundleID:$draft.sourceBundleID)
        if draft.makeRule() == nil {SettingsError(text:"Enter a valid pattern and destination.")}
        Spacer();HStack {Button("Cancel",action:onDone).keyboardShortcut(.cancelAction);Spacer();Button("Save Rule") {if let index=root.links.drafts.firstIndex(where:{$0.id == draft.id}){root.links.drafts[index]=draft}else{root.links.drafts.append(draft)};root.commitLinks();onDone()}.keyboardShortcut(.defaultAction).disabled(draft.makeRule() == nil || (draft.destinationKind == .space && !root.links.spaces.contains{$0.id == draft.spaceID}))}
    }.padding(24).frame(width:520,height:340)}
}
private struct RouteDestinationPicker:View {
    let spaces:[SpaceOption];@Binding var kind:RuleDraft.DestinationKind;@Binding var space:SpaceID?
    private var selection:Binding<String> {Binding(get:{kind == .space ? space.map{$0.description} ?? "missing":kind.rawValue},set:{value in if let selected=spaces.first(where:{$0.id.description == value}) {space=selected.id;kind = .space} else if let selected=RuleDraft.DestinationKind(rawValue:value){kind=selected;space=nil}})}
    var body:some View {Picker("Destination",selection:selection){Text("Little Open").tag(RuleDraft.DestinationKind.littleOpen.rawValue);Text("Most Recent Space").tag(RuleDraft.DestinationKind.mostRecentSpace.rawValue);Divider();ForEach(spaces){Text($0.title).tag($0.id.description)}}.labelsHidden().frame(width:185)}
}
private struct AppPicker:View {
    @Binding var bundleID:String
    private var appURL:URL? {bundleID.isEmpty ? nil:NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundleID)}
    var body:some View {HStack {Text("From app");Spacer();Menu {
        Button("Any app"){bundleID=""}
        Button("Choose App…"){let panel=NSOpenPanel();panel.allowedContentTypes=[.applicationBundle];panel.directoryURL=URL(fileURLWithPath:"/Applications");if panel.runModal() == .OK,let url=panel.url,let id=Bundle(url:url)?.bundleIdentifier {bundleID=id}}
    } label:{HStack(spacing:5){if let appURL {Image(nsImage:NSWorkspace.shared.icon(forFile:appURL.path)).resizable().frame(width:16,height:16)};Text(appURL.map{FileManager.default.displayName(atPath:$0.path)} ?? (bundleID.isEmpty ? "Any app":"Selected app"))}}.frame(width:185)}}
}
