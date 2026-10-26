import SwiftUI
import OpenModel

public struct SearchEnginesSheet: View {
    @Bindable var model: ProfilesViewModel
    @State private var selectedID: String?
    @State private var name = ""
    @State private var keyword = ""
    @State private var template = ""
    @State private var editing = false
    public init(model: ProfilesViewModel) { self.model = model }
    private var valid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !keyword.isEmpty && !keyword.contains(where: \.isWhitespace) && template.contains("%s") }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search Engines").font(.title2)
            Picker("Default engine", selection: $model.searchEngineID) { ForEach(model.engines) { Text($0.name).tag($0.id) } }
            List(selection: $selectedID) { ForEach(model.profile?.settings.customSearchEngines ?? []) { engine in
                VStack(alignment: .leading) { HStack { Text(engine.name); Spacer(); Text(engine.keywords.joined(separator: ", ")).foregroundStyle(.secondary) }; Text(engine.searchURLTemplate).font(.caption).lineLimit(1) }.tag(engine.id)
            } }.frame(minHeight: 90)
            HStack {
                Button("Add") { selectedID = nil; name = ""; keyword = ""; template = ""; editing = true }
                Button("Edit") { if let engine = model.profile?.settings.customSearchEngines.first(where: { $0.id == selectedID }) { name = engine.name; keyword = engine.keywords.first ?? ""; template = engine.searchURLTemplate; editing = true } }.disabled(selectedID == nil)
                Button("Remove") { if let selectedID { model.removeEngine(selectedID); self.selectedID = nil } }.disabled(selectedID == nil)
                Spacer(); Button("Restore built-ins") { model.restoreBuiltins(); selectedID = nil }
            }
            if editing {
                TextField("Name", text: $name); TextField("Keyword (no spaces)", text: $keyword); TextField("Search URL containing %s", text: $template)
                HStack { if !valid { Text("Enter a name, keyword, and URL containing %s.").font(.caption).foregroundStyle(.red) }; Spacer(); Button("Save") { if model.saveEngine(id: selectedID, name: name, keyword: keyword, template: template) { editing = false } }.disabled(!valid) }
            }
            SettingsError(text: model.errorText)
            HStack { Spacer(); Button("Done") { model.root.showsSearchEngines = false }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 472, height: 372)
    }
}
