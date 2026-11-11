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
        guard pending.count < 16 else { return cached ?? placeholder }
        pending[key] = [onReady]
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
        }
        return cached ?? placeholder
    }
}
