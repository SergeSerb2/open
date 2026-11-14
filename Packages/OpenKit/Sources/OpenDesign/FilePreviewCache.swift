import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Visible consumers only read the cache. Metadata, file icons and QuickLook
/// thumbnails are resolved asynchronously; completed versions are revalidated
/// on the next request, never by a polling timer.
@MainActor
public final class FilePreviewCache {
    public static let shared = FilePreviewCache()
    private let images = NSCache<NSString, NSImage>()
    private var checked: [String:Double] = [:]
    private var pending: [String:[@MainActor () -> Void]] = [:]
    /// Requests that arrived while all 16 slots were busy. A row configured then keeps its
    /// callback here instead of losing it (it would show the placeholder until reconfigured).
    private var waiting: [String:(url:URL,callbacks:[@MainActor () -> Void])] = [:]
    private var waitingOrder: [String] = []
    private let placeholder = NSImage(systemSymbolName:"doc",accessibilityDescription:nil) ?? NSImage()
    private init() { images.countLimit = 128; images.totalCostLimit = 16*1024*1024 }
    public func warmPlaceholder() {
        var rect = CGRect(x:0,y:0,width:64,height:64)
        _ = placeholder.cgImage(forProposedRect:&rect,context:nil,hints:nil)
    }
    public func image(for url:URL,onReady:@escaping @MainActor () -> Void) -> NSImage {
        let key = url.path, cached = images.object(forKey:url.path as NSString)
        if pending[key] != nil {
            if pending[key]!.count < 32 { pending[key]!.append(onReady) }
            return cached ?? placeholder
        }
        if cached != nil, ProcessInfo.processInfo.systemUptime-(checked[key] ?? 0)<2 { return cached! }
        guard pending.count < 16 else {
            if waiting[key] == nil { waiting[key] = (url,[]); waitingOrder.append(key) }
            if waiting[key]!.callbacks.count < 32 { waiting[key]!.callbacks.append(onReady) }
            if waitingOrder.count > 256 { waiting[waitingOrder.removeFirst()] = nil }
            return cached ?? placeholder
        }
        start(key:key,url:url,callbacks:[onReady])
        return cached ?? placeholder
    }
    private func start(key:String,url:URL,callbacks:[@MainActor () -> Void]) {
        pending[key] = callbacks
        Task { [weak self] in
            let preview = await Task.detached(priority:.utility) { () -> CGImage? in
                let values = try? url.resourceValues(forKeys:[.contentTypeKey,.fileSizeKey])
                let type = values?.contentType ?? UTType(filenameExtension:url.pathExtension)
                if let type,(type.conforms(to:.image) || type.conforms(to:.pdf)),(values?.fileSize ?? 0)<=256*1024*1024 {
                    let request = QLThumbnailGenerator.Request(fileAt:url,size:CGSize(width:128,height:128),scale:1,representationTypes:.thumbnail)
                    let thumbnail: CGImage? = await withCheckedContinuation { continuation in
                        QLThumbnailGenerator.shared.generateBestRepresentation(for:request) { representation,_ in continuation.resume(returning:representation?.cgImage) }
                    }
                    if let thumbnail { return thumbnail }
                }
                let icon = NSWorkspace.shared.icon(forFile:url.path)
                var rect = CGRect(x:0,y:0,width:64,height:64)
                return icon.cgImage(forProposedRect:&rect,context:nil,hints:nil)
            }.value
            guard let self else { return }
            self.checked[key] = ProcessInfo.processInfo.systemUptime
            if let preview { self.images.setObject(NSImage(cgImage:preview,size:CGSize(width:preview.width,height:preview.height)),forKey:key as NSString,cost:preview.bytesPerRow*preview.height) }
            let callbacks = self.pending.removeValue(forKey:key) ?? []
            for callback in callbacks { callback() }
            if self.checked.count>512 { self.checked = [:] }
            self.startWaiting()
        }
    }
    /// Newest first: the rows the user scrolled to last are the ones on screen.
    private func startWaiting() {
        while pending.count < 16, let key = waitingOrder.popLast() {
            guard let entry = waiting.removeValue(forKey:key) else { continue }
            if pending[key] != nil { pending[key]! += entry.callbacks.prefix(max(0,32-pending[key]!.count)); continue }
            if images.object(forKey:key as NSString) != nil, ProcessInfo.processInfo.systemUptime-(checked[key] ?? 0)<2 { entry.callbacks.forEach { $0() }; continue }
            start(key:key,url:entry.url,callbacks:entry.callbacks)
        }
    }
}
