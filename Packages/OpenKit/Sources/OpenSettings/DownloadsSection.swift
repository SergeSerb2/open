import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OpenModel

public struct DownloadsSection:View {
    @Bindable var model:LibraryViewModel
    public init(model:LibraryViewModel){self.model=model}
    public var body:some View {
        if model.downloadItems.isEmpty {LibraryEmptyState(title:"No downloads",message:"Files you download appear here.",symbol:"arrow.down.circle")}
        else {List(selection:$model.selectedIDs){ForEach(model.downloadItems){item in
            HStack(spacing:12) {
                Image(nsImage:NSWorkspace.shared.icon(for:UTType(filenameExtension:URL(fileURLWithPath:item.fileName).pathExtension) ?? .data)).resizable().frame(width:32,height:32)
                VStack(alignment:.leading,spacing:3) {
                    Text(item.fileName).font(.system(size:13)).lineLimit(1)
                    Text(status(item)).font(.system(size:11)).foregroundStyle(item.state == .failed ? Color.red:Color.secondary).lineLimit(1)
                    if item.state == .inProgress || item.state == .paused {GeometryReader {g in ZStack(alignment:.leading){Capsule().fill(.quaternary);Capsule().fill(Color.accentColor).frame(width:g.size.width*(item.progress ?? 0.05))}}.frame(height:3).accessibilityLabel("Download progress").accessibilityValue("\(Int((item.progress ?? 0)*100)) percent")}
                }
                Spacer(minLength:4)
                HStack(spacing:10) {
                    if item.state == .inProgress {icon("pause.fill",help:"Pause"){model.actions.pauseDownload(id:item.id)};icon("xmark",help:"Cancel"){model.actions.cancelDownload(id:item.id)}}
                    if item.state == .paused {icon("play.fill",help:"Resume"){model.actions.resumeDownload(id:item.id)};icon("xmark",help:"Cancel"){model.actions.cancelDownload(id:item.id)}}
                    if item.state == .failed {icon("arrow.clockwise",help:"Retry"){model.retryDownload(item)}}
                    if item.state == .completed {icon("magnifyingglass",help:"Show in Finder"){model.revealDownload(item)}.disabled(!model.fileAvailable(item))}
                }
            }.frame(height:52).tag(item.id).listRowInsets(.init(top:0,leading:8,bottom:0,trailing:8)).onTapGesture(count:2){if item.state == .completed {model.revealDownload(item)}}
            .contextMenu {if item.state == .completed {Button("Open"){model.actions.openDownload(id:item.id)}.disabled(!model.fileAvailable(item));Button("Show in Finder"){model.revealDownload(item)}.disabled(!model.fileAvailable(item))};Button("Remove from List"){model.actions.removeDownload(id:item.id)}}
        }}.listStyle(.plain)}
    }
    private func icon(_ symbol:String,help:String,action:@escaping ()->Void)->some View {Button(action:action){Image(systemName:symbol).font(.system(size:12))}.buttonStyle(.plain).help(help)}
    private func bytes(_ value:Int64)->String {ByteCountFormatter.string(fromByteCount:value,countStyle:.file)}
    private func status(_ item:DownloadItemSnapshot)->String {switch item.state {
    case .failed:return "Failed — \(item.errorDescription ?? "Download error")"
    case .completed:return model.fileAvailable(item) ? "Completed · \(model.downloadLocation(item))":"File moved or deleted."
    case .cancelled:return "Cancelled"
    case .paused:return "Paused — \(bytes(item.receivedBytes))\(item.totalBytes.map{" of "+bytes($0)} ?? "")"
    case .inProgress:
        var value="\(bytes(item.receivedBytes))\(item.totalBytes.map{" of "+bytes($0)} ?? "")"
        if item.bytesPerSecond > 0 {if let total=item.totalBytes {let seconds=max(0,(total-item.receivedBytes)/item.bytesPerSecond);value += " — \(max(1,seconds/60)) min left"} else {value += " — \(bytes(item.bytesPerSecond))/s"}}
        return value
    }}
}
