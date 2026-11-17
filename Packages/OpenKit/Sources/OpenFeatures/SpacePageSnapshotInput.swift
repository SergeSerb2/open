import AppKit
import ImageIO
import OpenDesign

/// One bounded preparation capture. No display link or per-frame snapshot.
@MainActor
struct SpacePageSnapshotInput {
    struct Page { let host: any WebContentHost; let frame: CGRect }
    let context: CGContext
    let pages: [Page]

    func capture() async -> CGImage? {
        guard pages.count <= 4 else { return nil }
        // The caller has drawn the opaque theme and native chrome once. A
        // failed remote-surface capture refuses this entry; no hole is cached.
        for page in pages {
            guard !Task.isCancelled, !page.host.isLoading,
                  let content = (page.host as? any WebContentProviding)?.webContent,
                  let data = try? await content.motionSnapshotPNG(),
                  !Task.isCancelled, data.count <= 64 * 1024 * 1024 else { return nil }
            // PNG decode is preparation work on a worker, not a motion tick on
            // the main actor. Output is RGBA8, at most 16M×4 = 64MiB.
            guard let image = await Task.detached(priority: .userInitiated, operation: {
                Self.decode(data)
            }).value, !Task.isCancelled else { return nil }
            context.saveGState()
            context.addPath(CGPath(roundedRect: page.frame, cornerWidth: PanelMetrics.cornerRadius,
                                   cornerHeight: PanelMetrics.cornerRadius, transform: nil))
            context.clip(); context.draw(image, in: page.frame); context.restoreGState()
        }
        return context.makeImage()
    }

    private nonisolated static func decode(_ data: Data) -> CGImage? {
        guard data.count <= 64 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let depth = properties[kCGImagePropertyDepth] as? Int, depth <= 8,
              width > 0, height > 0, width <= 8192, height <= 8192,
              width <= 16 * 1024 * 1024 / height,
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCache: false] as CFDictionary), image.bitsPerPixel <= 32,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
