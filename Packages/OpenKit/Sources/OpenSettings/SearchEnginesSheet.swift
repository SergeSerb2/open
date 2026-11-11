import SwiftUI
import OpenModel
import OpenDesign

public struct SearchEnginesSheet:View {
    @Bindable var model:ProfilesViewModel
    @State private var selectedID:String?
    @State private var name=""
    @State private var keyword=""
    @State private var template=""
    @State private var editing=false
    public init(model:ProfilesViewModel,editingEngineID:String?=nil) {
        self.model=model
        if let engine=model.profile?.settings.customSearchEngines.first(where:{$0.id == editingEngineID}) {
            _selectedID=State(initialValue:engine.id);_name=State(initialValue:engine.name)
            _keyword=State(initialValue:engine.keywords.first ?? "");_template=State(initialValue:engine.searchURLTemplate);_editing=State(initialValue:true)
        }
    }
    private var valid:Bool {model.engineIssue(name:name,keyword:keyword,template:template) == nil}
    private var selectedCustom:SearchEngine? {model.profile?.settings.customSearchEngines.first{$0.id == selectedID}}
    public var body:some View {VStack(alignment:.leading,spacing:12) {
        Text("Search Engines").font(.title2)
        HStack {Text("Default engine");Spacer();SettingsPopUp("Default engine",selection:$model.searchEngineID,width:185,entries:model.engines.map{.option($0.name,$0.id)})}
        List(selection:$selectedID) {ForEach(model.engines){engine in HStack {
            VStack(alignment:.leading,spacing:3) {Text(engine.name);Text(engine.searchURLTemplate).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)}
            Spacer();Text(engine.id.hasPrefix("custom-") || model.profile?.settings.customSearchEngines.contains(where:{$0.id == engine.id}) == true ? engine.keywords.joined(separator:", "):"Built-in").font(.system(size:11)).foregroundStyle(.secondary)
        }.tag(engine.id)}}.listStyle(.plain).frame(minHeight:120).overlay(RoundedRectangle(cornerRadius:8).stroke(Color(nsColor:SettingsStyle.hairline.nsColor)))
        if editing {
            HStack {Text("Name").frame(width:60,alignment:.leading);TextField("Name",text:$name).accessibilityLabel("Engine name")}
            HStack {Text("Keyword").frame(width:60,alignment:.leading);TextField("Keyword (no spaces)",text:$keyword).accessibilityLabel("Engine keyword")}
            HStack {Text("URL").frame(width:60,alignment:.leading);TextField("Search URL containing %s",text:$template).accessibilityLabel("Engine URL")}
            if !valid {Text("Enter a name, keyword, and URL containing %s.").font(.caption).foregroundStyle(.red)}
        }
        SettingsError(text:model.errorText)
        HStack(spacing:8) {
            if editing {
                Button("Cancel Edit"){editing=false}
                Button("Save engine"){if model.saveEngine(id:selectedID,name:name,keyword:keyword,template:template){editing=false}}.keyboardShortcut(.defaultAction).buttonStyle(OpenSettingsButtonStyle()).disabled(!valid)
            } else {
                Button("Add"){selectedID=nil;name="";keyword="";template="";editing=true}
                Button("Edit"){if let engine=selectedCustom {name=engine.name;keyword=engine.keywords.first ?? "";template=engine.searchURLTemplate;editing=true}}.disabled(selectedCustom == nil)
                Button("Remove"){if let selectedID {model.removeEngine(selectedID);self.selectedID=nil}}.disabled(selectedCustom == nil)
            }
            Spacer(minLength:0)
            Button("Restore built-ins"){model.restoreBuiltins();selectedID=nil;editing=false}
            Button("Done"){model.root.showsSearchEngines=false}
        }
    }.padding(24).frame(width:520,height:editing ? 540:420).controlSize(.regular).settingsSheet()}
}
