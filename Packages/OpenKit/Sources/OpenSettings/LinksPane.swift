import SwiftUI
import OpenModel
import OpenRouting
import OpenCommands

/// Binds the routing owner's drafts directly. The root only commits validated copies.
public struct LinksPane: View {
    let root: SettingsViewModel
    @Bindable var links: LinksSettingsModel
    @FocusState private var focusedField: String?
    @State private var tested = false
    public init(root: SettingsViewModel) { self.root = root; links = root.links }
    public var body: some View {
        SettingsGroup("Little Open") {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "macwindow.on.rectangle").font(.largeTitle).foregroundStyle(.secondary)
                Text("Little Open is a smaller, simpler window for quick lookups and reading links.").foregroundStyle(.secondary)
            }.padding(.bottom, 8)
            SettingsSwitch("Open Little Open when I press \(hotkey) in any app", isOn: toggle(\.littleOpenHotkeyEnabled))
            SettingsSwitch("Open Little Open when clicking links with Option+Command held", isOn: toggle(\.optionCommandClickLittleOpen))
            SettingsSwitch("Links from other apps open in Little Open", isOn: toggle(\.externalLinksInLittleOpen))
                .help("Only links from other apps need Open as your default browser. Links inside Open work either way.")
            HStack { Text("Archive Little Open windows after"); Spacer(); Picker("Archive Little Open windows after", selection: Binding(get: { links.littleOpenAutoArchiveAfter }, set: { links.littleOpenAutoArchiveAfter = $0; root.commitLinks() })) {
                ForEach(AutoArchiveInterval.allCases, id: \.self) { Text($0.settingsTitle + ($0 == .sixHours ? " (default)" : "")).tag($0) }
            }.labelsHidden().fixedSize() }
        }
        SettingsGroup("Peek") {
            PreferenceToggle(title: "Open a Peek window when clicking links to other sites", key: "open.links.openPeekOtherSites", root: root).help("This only affects Favorites and Pinned tabs.")
            PreferenceToggle(title: "Open a Peek window when clicking links with Shift held", key: "open.links.openPeekShiftClick", root: root)
        }
        SettingsGroup("Air Traffic Control") {
            Text("Routes let you choose where specific sites open inside Open. First match wins.").foregroundStyle(.secondary)
            HStack { Text("Default link destination"); Spacer(); destination(kind: Binding(get: { links.defaultDestinationKind }, set: { links.defaultDestinationKind = $0; root.commitLinks() }), space: Binding(get: { links.defaultSpaceID }, set: { links.defaultSpaceID = $0; root.commitLinks() })) }
            ForEach(Array(links.drafts.enumerated()), id: \.element.id) { index, draft in
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    HStack {
                        Text("\(index + 1).").foregroundStyle(.secondary)
                        Picker("Match", selection: draftBinding(draft.id, \.matchKind)) { Text("Host contains").tag(RuleDraft.MatchKind.hostContains); Text("Host equals").tag(RuleDraft.MatchKind.hostEquals); Text("URL starts with").tag(RuleDraft.MatchKind.urlPrefix) }.labelsHidden()
                        TextField("Pattern", text: textBinding(draft.id, \.pattern)).focused($focusedField, equals: "pattern-\(draft.id)").onSubmit { root.commitLinks() }
                    }
                    HStack { Text("Opens in").foregroundStyle(.secondary); destination(kind: draftBinding(draft.id, \.destinationKind), space: draftBinding(draft.id, \.spaceID)) }
                    HStack {
                        TextField("From app bundle ID (optional)", text: textBinding(draft.id, \.sourceBundleID)).focused($focusedField, equals: "source-\(draft.id)").onSubmit { root.commitLinks() }
                        Button { links.moveRule(from: index, to: index - 1); root.commitLinks() } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("Move rule up")
                        Button { links.moveRule(from: index, to: index + 1); root.commitLinks() } label: { Image(systemName: "arrow.down") }.disabled(index == links.drafts.count - 1).help("Move rule down")
                        Button { links.deleteRule(id: draft.id); root.commitLinks() } label: { Image(systemName: "minus") }.help("Delete rule")
                    }
                    ForEach(issues(for: draft.id), id: \.self) { issue in Text(issue.message).font(.caption).foregroundStyle(issue.isError ? .red : .secondary) }
                }.draggable(draft.id.description)
                .dropDestination(for: String.self) { values, _ in
                    guard let id = values.first, let from = links.drafts.firstIndex(where: { $0.id.description == id }) else { return false }
                    links.moveRule(from: from, to: index); root.commitLinks(); return true
                }
            }
            Button("Add Rule") { links.addRule() }
            ForEach(issues(for: LinksSettingsModel.defaultDestinationIssueID), id: \.self) { Text($0.message).foregroundStyle(.red) }
            if links.issues().contains(where: \.isError) { SettingsError(text: "Fix the route errors to save. Your last saved routes are unchanged.") }
        }
        SettingsGroup("Test a Link") {
            TextField("URL or host", text: $links.testURLString)
            TextField("From app bundle ID (optional)", text: $links.testSourceBundleID)
            Picker("Most Recent Space", selection: $links.testMostRecentSpaceID) { Text("Automatic").tag(Optional<SpaceID>.none); ForEach(links.spaces) { Text($0.title).tag(Optional($0.id)) } }
            Button("Test") { tested = true; links.runTest() }
            if tested && !links.testInputIsValid { SettingsError(text: "Enter a valid URL.") }
            if let decision = links.testDecision { Text(RoutingDecisionFormatter.report(decision, spaces: root.routingSpaces)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        }
        .onChange(of: focusedField) { old, _ in if old != nil { root.commitLinks() } }
    }
    private var hotkey: String { (root.shortcutsStore.effectiveShortcuts(for: CommandRegistry.byID["little-open-global"]!).first?.symbolDisplay) ?? "the shortcut" }
    private func issues(for id: RuleID) -> [RuleIssue] { links.issues().filter { $0.ruleID == id } }
    private func toggle(_ key: ReferenceWritableKeyPath<LinksSettingsModel, Bool>) -> Binding<Bool> { Binding(get: { links[keyPath: key] }, set: { links[keyPath: key] = $0; root.commitLinks() }) }
    private func draftBinding<T>(_ id: RuleID, _ key: WritableKeyPath<RuleDraft, T>) -> Binding<T> { Binding(get: { links.drafts.first(where: { $0.id == id })![keyPath: key] }, set: { value in if let i = links.drafts.firstIndex(where: { $0.id == id }) { links.drafts[i][keyPath: key] = value; root.commitLinks() } }) }
    private func textBinding(_ id: RuleID, _ key: WritableKeyPath<RuleDraft, String>) -> Binding<String> { Binding(get: { links.drafts.first(where: { $0.id == id })?[keyPath: key] ?? "" }, set: { value in if let i = links.drafts.firstIndex(where: { $0.id == id }) { links.drafts[i][keyPath: key] = value } }) }
    private func destination(kind: Binding<RuleDraft.DestinationKind>, space: Binding<SpaceID?>) -> some View {
        HStack {
            Picker("Destination", selection: kind) { Text("Little Open").tag(RuleDraft.DestinationKind.littleOpen); Text("Most Recent Space").tag(RuleDraft.DestinationKind.mostRecentSpace); Text("Space").tag(RuleDraft.DestinationKind.space) }.labelsHidden()
            if kind.wrappedValue == .space { Picker("Space", selection: space) { Text("Choose Space").tag(Optional<SpaceID>.none); ForEach(links.spaces) { Text($0.title).tag(Optional($0.id)) } }.labelsHidden() }
        }
    }
}
private extension RuleIssue {
    var ruleID: RuleID { switch self { case .emptyPattern(let id), .patternHasSpaces(let id), .prefixNotParseable(let id), .missingSpace(let id), .containsIsSubstring(let id): id; case .duplicateOf(let id, _): id } }
    var message: String { switch self {
    case .emptyPattern: "Enter a pattern."
    case .patternHasSpaces: "Patterns cannot contain spaces."
    case .prefixNotParseable: "Enter a valid URL prefix."
    case .missingSpace: "Choose an existing Space."
    case .duplicateOf(_, let index): "Duplicates rule \(index + 1)."
    case .containsIsSubstring: "Host contains matches substrings: google.com also matches notgoogle.com."
    } }
}
