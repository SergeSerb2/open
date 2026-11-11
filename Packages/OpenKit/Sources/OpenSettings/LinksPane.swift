import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OpenModel
import OpenRouting
import OpenCommands
import OpenDesign

public struct LinksPane:View {
    let root:SettingsViewModel
    private var links: LinksSettingsModel { root.links }
    @State private var editing:RuleDraft?
    @State private var tested = false
    @Environment(\.colorScheme) private var scheme
    public init(root:SettingsViewModel) {self.root=root}
    public var body: some View {
        @Bindable var links = root.links
        OpenSettingsGroup("Little Open") {
            linkToggle("little-open-hotkey", title: "Open Little Open in any app", help: "Press \(hotkey) from any app.", key: \.littleOpenHotkeyEnabled, defaultValue: true)
            linkToggle("option-command-click", title: "Open Little Open with Option-Command-click", key: \.optionCommandClickLittleOpen, defaultValue: true)
            linkToggle("external-links", title: "Links from other apps open in Little Open", key: \.externalLinksInLittleOpen, defaultValue: true, last: true)
        }
        OpenSettingsGroup("Peek") {
            OpenPreferenceRow(root: root, id: "links/peek-shift-click", title: "Open Peek with Shift-click", key: "open.links.openPeekShiftClick")
            OpenPreferenceRow(root: root, id: "links/peek-other-sites", title: "Open Peek for links to other sites", key: "open.links.openPeekOtherSites", help: "Applies to Favorites and Pinned tabs.", last: true)
        }
        OpenSettingsGroup("Air Traffic Control") {
            OpenSettingsRow(root: root, id: "links/destination", title: "Default destination", help: "Choose where links open when no rule matches.", changed: links.defaultRoutingDestination != .littleOpen(profile: nil), reset: { links.defaultRoutingDestination = .littleOpen(profile: nil); root.commitLinks() }) { RouteDestinationPicker(links: links, selection: Binding(get: { links.defaultRoutingDestination }, set: { links.defaultRoutingDestination = $0; root.commitLinks() })) }
            LinkIssues(issues: links.issues().filter { $0.ruleID == LinksSettingsModel.defaultDestinationIssueID }, defaultDestination: true).padding(.horizontal, 14)
            ForEach(Array(links.drafts.enumerated()), id: \.element.id) { index, draft in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        Button { editing = draft } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(draft.pattern.isEmpty ? "New rule" : draft.pattern).font(.system(size: 13)).lineLimit(1)
                                    Text(matchTitle(draft.matchKind)).font(.system(size: 11.5)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor))
                                }
                                Spacer()
                                Text(links.destinationLabel(draft.destination)).font(.system(size: 12)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor)).lineLimit(1)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button { links.deleteRule(id: draft.id); root.commitLinks() } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).accessibilityLabel("Delete rule " + draft.pattern)
                    }
                    .draggable(draft.id.description).dropDestination(for: String.self) { values, _ in
                        guard let value = values.first, let from = links.drafts.firstIndex(where: { $0.id.description == value }) else { return false }
                        links.moveRule(from: from, to: index); root.commitLinks(); return true
                    }
                    LinkIssues(issues: links.issues().filter { $0.ruleID == draft.id })
                }.padding(14)
                    .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: SettingsStyle.hairline.nsColor)).frame(height: 1).padding(.leading, 14) }
                    .contextMenu {
                        Button("Edit Rule…") { editing = draft }
                        Button("Move Up") { links.moveRule(from: index, to: index - 1); root.commitLinks() }.disabled(index == 0)
                        Button("Move Down") { links.moveRule(from: index, to: index + 1); root.commitLinks() }.disabled(index == links.drafts.count - 1)
                    }
            }
            OpenSettingsRow(root: root, id: "links/rules", title: links.drafts.isEmpty ? "No routing rules yet" : "First matching rule wins", help: "Send a site to a Space or to Little Open.", last: true) {
                Button("Add rule…") { editing = RuleDraft(from: RoutingRule(match: .hostEquals(""), destination: .littleOpen(profile: nil))) }
            }
        }
        .sheet(item: $editing) { draft in LinkRuleSheet(root: root, draft: draft, onDone: { editing = nil }) }
        LinkTestArea(root: root, tested: $tested).id("links/test")
        let notice = !root.linksError.isEmpty ? root.linksError : tested && !links.testInputIsValid ? "Enter a valid URL." : root.linkTestSummary ?? ""
        SettingsInlineMessage(text: notice)
        if let decision = links.testDecision {
            DisclosureGroup("Details") { Text(RoutingDecisionFormatter.report(decision, spaces: root.routingSpaces)).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private func linkToggle(_ id: String, title: String, help: String = "", key: ReferenceWritableKeyPath<LinksSettingsModel, Bool>, defaultValue: Bool, last: Bool = false) -> some View {
        OpenSettingsRow(root: root, id: "links/" + id, title: title, help: help, changed: links[keyPath: key] != defaultValue, last: last, reset: { links[keyPath: key] = defaultValue; root.commitLinks() }) {
            Toggle(title, isOn: toggle(key)).toggleStyle(OpenSettingsSwitchStyle(accent: Color(nsColor: SettingsStyle.accessibleAccent(root.settingsAccentSource, dark: scheme == .dark)), label: title))
        }
    }
    private func matchTitle(_ kind:RuleDraft.MatchKind)->String {switch kind {case .hostContains:"Host contains";case .hostEquals:"Host equals";case .urlPrefix:"URL starts with"}}
    private var hotkey:String {CommandRegistry.byID["little-open-global"].flatMap{root.shortcutsStore.effectiveShortcuts(for:$0).first?.symbolDisplay} ?? "---"}
    private func toggle(_ key:ReferenceWritableKeyPath<LinksSettingsModel,Bool>)->Binding<Bool> {Binding(get:{links[keyPath:key]},set:{links[keyPath:key]=$0;root.commitLinks()})}

}
private struct LinkTestArea: View {
    let root: SettingsViewModel
    @Binding var tested: Bool
    @Environment(\.settingsPage) private var page
    @State private var pulse = false
    @State private var expanded = false
    var body: some View {
        @Bindable var links = root.links
        OpenSettingsGroup("Test a Link") {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .medium)).frame(width: 10)
                    Text("Try a URL or host").font(.system(size: 13))
                    Spacer()
                }.padding(.horizontal, 14).frame(height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Expand link test").accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                HStack(spacing: 10) { TextField("URL or host", text: $links.testURLString).textFieldStyle(.plain).accessibilityLabel("URL or host"); Button("Test") { tested = true; links.runTest() } }.padding(14)
                AppPicker(bundleID: $links.testSourceBundleID).padding(.horizontal, 14).padding(.bottom, 10)
                OpenSettingsRow(root: root, id: "links/test-space", title: "Most Recent Space", last: true) {
                    OpenSettingsPop(title: "Most Recent Space", value: $links.testMostRecentSpaceID, options: [("Automatic", nil)] + links.spaces.map { ($0.title, Optional($0.id)) })
                }
            }
        }
        .background(pulse ? Color(nsColor: SettingsStyle.sunStart.nsColor).opacity(0.24) : Color.clear)
        .task(id: page?.revision ?? root.arrivalRevision) {
            guard (page == nil ? root.arrivalID : page?.target) == "links/test" else { return }
            expanded = true
            pulse = true
            withAnimation(.easeOut(duration: SettingsStyle.arrivalDuration)) { pulse = false }
        }
    }
}
public struct LinkRuleSheet:View {
    let root:SettingsViewModel
    @State private var draft:RuleDraft
    let onDone:()->Void
    public init(root:SettingsViewModel,draft:RuleDraft,onDone:@escaping ()->Void={}){self.root=root;_draft=State(initialValue:draft);self.onDone=onDone}
    public var body:some View {VStack(alignment:.leading,spacing:18) {
        Text("Link Routing").font(.title2)
        HStack {Text("Match");Spacer();SettingsPopUp("Match",selection:$draft.matchKind,width:185,entries:[.option("Host contains",.hostContains),.option("Host equals",.hostEquals),.option("URL starts with",.urlPrefix)])}
        TextField("Pattern",text:$draft.pattern).accessibilityLabel("Pattern")
        HStack {Text("Open in");Spacer();RouteDestinationPicker(links:root.links,selection:$draft.destination)}
        AppPicker(bundleID:$draft.sourceBundleID)
        LinkIssues(issues:root.links.issues(replacing:draft).filter{$0.ruleID == draft.id})
        SettingsError(text:root.linksError)
        Spacer();HStack {Button("Cancel",action:onDone).keyboardShortcut(.cancelAction);Spacer();Button("Save rule") {if root.saveLinkRule(draft) {onDone()}}.keyboardShortcut(.defaultAction).disabled(root.links.issues(replacing:draft).contains(where:\.isError))}
    }.padding(24).frame(width:520,height:380).settingsSheet()}
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
