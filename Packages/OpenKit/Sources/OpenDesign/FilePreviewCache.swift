import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Bounded previews shared by Library rows and the completion badge. QuickLook
/// generation runs away from the main actor; only the final NSImage is installed
/// here. A changed modification date never reuses the old file's thumbnail.
@MainActor
public final class FilePreviewCache {
    public static let shared = FilePreviewCache()
    private let images = NSCache<NSString, NSImage>()
    private var pending: [String: [@MainActor () -> Void]] = [:]
    private init() { images.countLimit = 128; images.totalCostLimit = 16 * 1024 * 1024 }

    public func image(for url: URL, onReady: @escaping @MainActor () -> Void) -> NSImage {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .contentTypeKey, .fileSizeKey])
        let key = url.path + "|" + String(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        if let image = images.object(forKey: key as NSString) { return image }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        if pending[key] != nil {
            // At most 32 visible consumers per preview; callbacks capture views weakly.
            if pending[key]!.count < 32 { pending[key]!.append(onReady) }
            return icon
        }
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        guard let type, type.conforms(to: .image) || type.conforms(to: .pdf),
              (values?.fileSize ?? 0) <= 256 * 1024 * 1024 else {
            images.setObject(icon,forKey:key as NSString); return icon
        }
        guard pending.count < 16 else { return icon }
        pending[key] = [onReady]
        Task { [weak self] in
            let preview = await Task.detached(priority: .utility) {
                let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 128, height: 128), scale: 1, representationTypes: .thumbnail)
                return await withCheckedContinuation { continuation in
                    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                        continuation.resume(returning: representation?.cgImage)
                    }
                }
            }.value
            guard let self else { return }
            let callbacks = self.pending.removeValue(forKey:key) ?? []
            if let preview {
                let image = NSImage(cgImage: preview, size: CGSize(width: preview.width, height: preview.height))
                self.images.setObject(image, forKey: key as NSString, cost: preview.bytesPerRow * preview.height)
            } else {
                self.images.setObject(icon,forKey:key as NSString)
            }
            for callback in callbacks { callback() }
        }
        return icon
    }
}
