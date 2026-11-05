import SwiftUI
import AppKit
import OpenModel
import OpenStore

public struct HistorySection:View {
    @Bindable var model:LibraryViewModel
    public init(model:LibraryViewModel){self.model=model}
    private var days:[Date] {Set(model.historyRows.map{Calendar.current.startOfDay(for:$0.lastVisit)}).sorted(by:>)}
    public var body:some View {VStack(spacing:12) {
        HStack {
            Spacer()
            Button("Delete Selected…",role:.destructive) { model.requestDeleteHistory(model.historyRows.filter { model.selectedIDs.contains($0.url.absoluteString) }.map(\.url)) }.disabled(model.selectedIDs.isEmpty)
            Button("Clear History…") { model.confirmsClearHistory = true }.disabled(model.historyRows.isEmpty)
        }.buttonStyle(SettingsButtonStyle())
        if model.historyRows.isEmpty {LibraryEmptyState(title:"No history",message:"Pages you visit appear here.",symbol:"clock")}
        else {List(selection:$model.selectedIDs){ForEach(days,id:\.self){day in Section(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) {
            ForEach(model.historyRows.filter{Calendar.current.isDate($0.lastVisit,inSameDayAs:day)},id:\.url){row in HStack(spacing:12) {
                Text(row.lastVisit.formatted(date:.omitted,time:.shortened)).font(.system(size:11)).foregroundStyle(.secondary).frame(width:65,alignment:.trailing)
                if let image=model.historyFaviconImages[row.url]{Image(nsImage:image).resizable().frame(width:16,height:16)}else{Image(systemName:"globe").frame(width:16).foregroundStyle(.secondary)}
                Text(row.title.isEmpty ? row.url.host() ?? "Page":row.title).lineLimit(1);Spacer();Text(row.url.host() ?? "").font(.system(size:11)).foregroundStyle(.secondary)
            }.frame(height:38).frame(maxWidth:.infinity).overlay(alignment:.bottom){Rectangle().fill(.quaternary).frame(height:1)}.listRowSeparator(.hidden).listRowInsets(.init(top:0,leading:10,bottom:0,trailing:10)).tag(row.url.absoluteString).contentShape(Rectangle()).onTapGesture(count:2){model.actions.openHistoryItem(url:row.url)}.contextMenu { Button("Delete",role:.destructive) { model.requestDeleteHistory([row.url]) } }
            }
        }}}.listStyle(.plain).onDeleteCommand { model.requestDeleteHistory(model.historyRows.filter { model.selectedIDs.contains($0.url.absoluteString) }.map(\.url)) }}
    }
    .confirmationDialog("Delete selected history?",isPresented:Binding(get:{!model.pendingHistoryDeletes.isEmpty},set:{if !$0 {model.pendingHistoryDeletes=[]}})) {
        Button("Delete",role:.destructive) { Task { await model.deleteHistoryConfirmed() } }
    }
    .confirmationDialog("Clear all history for this Profile?",isPresented:$model.confirmsClearHistory) {
        Button("Clear History",role:.destructive) { Task { await model.clearHistoryConfirmed() } }
    } }
}
