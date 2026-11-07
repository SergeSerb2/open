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
    @State private var tested = false
    public init(root:SettingsViewModel) {self.root=root;links=root.links}
    public var body:some View {
        Text("Little Open is a smaller, simpler Open window for quick lookups and reading links.").fixedSize(horizontal:false,vertical:true).padding(.bottom,4)
        SettingsGroup {
            SettingsRow(height:36) {SettingsSwitch("Open Little Open when I press \(hotkey) in any app",isOn:toggle(\.littleOpenHotkeyEnabled))}
            SettingsRow(height:36) {SettingsSwitch("Open Little Open when clicking on links with ⌥⌘ held",isOn:toggle(\.optionCommandClickLittleOpen))}
            SettingsRow(height:36) {SettingsSwitch("Links from other apps open in Little Open",isOn:toggle(\.externalLinksInLittleOpen))}
            SettingsRow(height:44,divider:false) {HStack {Text("Archive Little Open windows after");Spacer();SettingsPopUp("Archive Little Open windows after",selection:Binding(get:{links.littleOpenAutoArchiveAfter},set:{links.littleOpenAutoArchiveAfter=$0;root.commitLinks()}),width:155,entries:AutoArchiveInterval.allCases.map{.option($0.settingsTitle + ($0 == .sixHours ? " (default)":""),$0)})}}
        }
        Rectangle().fill(Color(nsColor:SettingsTokens.divider.nsColor)).frame(height:1).padding(.vertical,10)
        Text("Peek is a way to preview a link without opening a new tab. It's perfect for quickly looking at a link from an email, news article, or tweet.").fixedSize(horizontal:false,vertical:true).padding(.bottom,4)
        SettingsGroup {
            SettingsRow(height:36) {PreferenceToggle(title:"Open a Peek window when clicking on links with Shift held",key:"open.links.openPeekShiftClick",root:root)}
            SettingsRow(height:49,divider:false) {VStack(alignment:.leading,spacing:3) {PreferenceToggle(title:"Open a Peek window when clicking on links to other sites",key:"open.links.openPeekOtherSites",root:root);Text("This only affects Favorites and Pinned tabs").font(.system(size:11)).italic().foregroundStyle(.secondary)}}
        }
        Rectangle().fill(Color(nsColor:SettingsTokens.divider.nsColor)).frame(height:1).padding(.vertical,10)
        VStack(alignment:.leading,spacing:10) {
        Text("Air Traffic Control").font(Font(SettingsTokens.section.font)).foregroundStyle(Color(nsColor:SettingsTokens.secondary.nsColor)).padding(.leading,10)
        Text("Routes let you choose where specific sites open inside Open. First match wins.").fixedSize(horizontal:false,vertical:true)
        SettingsError(text:root.linksError)
        SettingsGroup {
            SettingsRow(minimumHeight:SettingsTokens.controlRowHeight) {VStack(alignment:.leading,spacing:3) {
                HStack {Text("Default destination");Spacer();RouteDestinationPicker(links:links,selection:Binding(get:{links.defaultRoutingDestination},set:{links.defaultRoutingDestination=$0;root.commitLinks()}))}
                LinkIssues(issues:links.issues().filter{$0.ruleID == LinksSettingsModel.defaultDestinationIssueID},defaultDestination:true)
            }}
            ForEach(Array(links.drafts.enumerated()),id:\.element.id) {index,draft in
                SettingsRow(divider:index < links.drafts.count-1,minimumHeight:44) {VStack(alignment:.leading,spacing:3) {HStack(spacing:8) {
                    Button {editing=draft} label:{HStack {VStack(alignment:.leading,spacing:2){Text(draft.pattern.isEmpty ? "New rule":draft.pattern).lineLimit(1);Text("\(matchTitle(draft.matchKind)) · \(draft.pattern)").font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)};Spacer();Text(links.destinationLabel(draft.destination)).foregroundStyle(.secondary).lineLimit(1)}}.buttonStyle(.plain)
                    Button {links.deleteRule(id:draft.id);root.commitLinks()} label:{Image(systemName:"minus.circle.fill").font(.system(size:16)).foregroundStyle(.secondary)}.buttonStyle(.plain).help("Delete rule")
                }.draggable(draft.id.description).dropDestination(for:String.self) {values,_ in guard let value=values.first,let from=links.drafts.firstIndex(where:{$0.id.description == value}) else {return false};links.moveRule(from:from,to:index);root.commitLinks();return true}
                LinkIssues(issues:links.issues().filter{$0.ruleID == draft.id})
                }}
                .contextMenu {Button("Edit Rule…"){editing=draft};Button("Move Up"){links.moveRule(from:index,to:index-1);root.commitLinks()}.disabled(index == 0);Button("Move Down"){links.moveRule(from:index,to:index+1);root.commitLinks()}.disabled(index == links.drafts.count-1)}
            }
        }
        Button("Add Rule…") {let rule=RoutingRule(match:.hostEquals(""),destination:.littleOpen(profile: nil));editing=RuleDraft(from:rule)}
        .sheet(item:$editing){draft in LinkRuleSheet(root:root,draft:draft,onDone:{editing=nil})}
        }.id("links-rules")
        VStack(alignment:.leading,spacing:10) {
        Text("Test a Link")
        SettingsGroup {
            SettingsRow {HStack {TextField("URL or host",text:$links.testURLString);Button("Test"){tested=true;links.runTest()}}}
            SettingsRow {AppPicker(bundleID:$links.testSourceBundleID)}
            SettingsRow(divider:false) {HStack {Text("Most Recent Space");Spacer();SettingsPopUp("Most Recent Space",selection:$links.testMostRecentSpaceID,width:185,entries:[.option("Automatic",nil)]+links.spaces.map{.option($0.title,Optional($0.id))})}}
        }
        if tested && !links.testInputIsValid {SettingsError(text:"Enter a valid URL.")}
        if let decision=links.testDecision {
            if let summary=root.linkTestSummary {Text(summary).fixedSize(horizontal:false,vertical:true)}
            DisclosureGroup("Details") {Text(RoutingDecisionFormatter.report(decision,spaces:root.routingSpaces)).font(.system(.caption,design:.monospaced)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}
        }
        }.id("links-test")
    }
    private func matchTitle(_ kind:RuleDraft.MatchKind)->String {switch kind {case .hostContains:"Host contains";case .hostEquals:"Host equals";case .urlPrefix:"URL starts with"}}
    private var hotkey:String {CommandRegistry.byID["little-open-global"].flatMap{root.shortcutsStore.effectiveShortcuts(for:$0).first?.symbolDisplay} ?? "---"}
    private func toggle(_ key:ReferenceWritableKeyPath<LinksSettingsModel,Bool>)->Binding<Bool> {Binding(get:{links[keyPath:key]},set:{links[keyPath:key]=$0;root.commitLinks()})}

}
public struct LinkRuleSheet:View {
    let root:SettingsViewModel
    @State private var draft:RuleDraft
    let onDone:()->Void
    public init(root:SettingsViewModel,draft:RuleDraft,onDone:@escaping ()->Void={}){self.root=root;_draft=State(initialValue:draft);self.onDone=onDone}
    public var body:some View {VStack(alignment:.leading,spacing:18) {
        Text("Link Routing").font(.title2)
        HStack {Text("Match");Spacer();SettingsPopUp("Match",selection:$draft.matchKind,width:185,entries:[.option("Host contains",.hostContains),.option("Host equals",.hostEquals),.option("URL starts with",.urlPrefix)])}
        TextField("Pattern",text:$draft.pattern)
        HStack {Text("Open in");Spacer();RouteDestinationPicker(links:root.links,selection:$draft.destination)}
        AppPicker(bundleID:$draft.sourceBundleID)
        LinkIssues(issues:root.links.issues(replacing:draft).filter{$0.ruleID == draft.id})
        SettingsError(text:root.linksError)
        Spacer();HStack {Button("Cancel",action:onDone).keyboardShortcut(.cancelAction);Spacer();Button("Save Rule") {if root.saveLinkRule(draft) {onDone()}}.keyboardShortcut(.defaultAction).buttonStyle(SettingsButtonStyle(prominent:true)).disabled(root.links.issues(replacing:draft).contains(where:\.isError))}
    }.padding(24).frame(width:520,height:380).buttonStyle(SettingsButtonStyle())}
}
private struct LinkIssues: View {
    let issues: [RuleIssue]
    var defaultDestination = false
    var body: some View {
        ForEach(Array(issues.enumerated()),id:\.offset) { _, issue in
            if issue.isError { SettingsError(text:message(issue)).font(.caption) }
            else { Text(message(issue)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
        }
    }
    private func message(_ issue: RuleIssue) -> String {
        switch issue {
        case .emptyPattern: "Enter a site to match."
        case .patternHasSpaces: "Patterns cannot contain spaces."
        case .prefixNotParseable: "Enter a valid URL prefix."
        case .missingSpace: defaultDestination ? "This Space is no longer available. Links use the Most Recent Space until you choose another destination." : "Choose an existing Space."
        case .missingProfile(_, let hasNoSpaces): hasNoSpaces ? "This Profile has no Spaces." : "This Profile is no longer available."
        case .duplicateOf(_, let index): "This duplicates rule \(index + 1). The first matching rule wins."
        case .containsIsSubstring: "Host contains also matches unrelated hosts that contain this text."
        }
    }
}
struct RouteDestinationPicker:View {
    let links:LinksSettingsModel
    @Binding var selection:RoutingDestination?
    var body:some View {
        SettingsPopUp("Destination",selection:$selection,width:185,entries:links.destinationEntries.map { entry in
            switch entry {
            case .destination(let title,let destination): .option(title,Optional(destination))
            case .section(let title): .section(title)
            case .separator: .separator
            }
        })
    }
}
private struct AppPicker:View {
    @Binding var bundleID:String
    private var appURL:URL? {bundleID.isEmpty ? nil:NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundleID)}
    var body:some View {HStack {Text("From app");Spacer();SettingsPopUp("From app",selection:Binding(get:{bundleID},set:{value in
        if value == "__choose__" {let panel=NSOpenPanel();panel.allowedContentTypes=[.applicationBundle];panel.directoryURL=URL(fileURLWithPath:"/Applications");if panel.runModal() == .OK,let url=panel.url,let id=Bundle(url:url)?.bundleIdentifier {bundleID=id}}
        else {bundleID=value}
    }),width:185,entries:appEntries)}}
    private var appEntries:[SettingsPopUpEntry<String>] {
        var entries:[SettingsPopUpEntry<String>]=[.option("Any app","")]
        if let appURL {entries.append(.imageOption(FileManager.default.displayName(atPath:appURL.path),bundleID,NSWorkspace.shared.icon(forFile:appURL.path)))} else if !bundleID.isEmpty {entries.append(.option("Selected app",bundleID,symbol:"app"))}
        entries += [.separator,.option("Choose App…","__choose__")];return entries
    }
}
