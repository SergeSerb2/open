import AppKit
import ImageIO
import OpenWeb

/// One transient copy of page pixels, below native pane controls. It keeps its
/// original size while the live viewport behind it receives its closing width.
@MainActor
struct LibraryMotionSnapshot {
    let source: NSView
    let frame: CGRect
    let image: CGImage

    func install() -> NSView? {
        guard let parent = source.superview, source.frame == frame else { return nil }
        let view = LibraryMotionSnapshotView(frame: frame)
        view.wantsLayer = true
        view.layer?.contents = image
        view.layer?.contentsGravity = .resize
        view.layer?.contentsScale = source.window?.backingScaleFactor ?? 1
        view.layer?.allowsGroupOpacity = false
        parent.addSubview(view, positioned: .above, relativeTo: source)
        return view
    }
}

@MainActor
private final class LibraryMotionSnapshotView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class LibrarySnapshotReply {
    var continuation: CheckedContinuation<Data?, Never>?
    var deadline: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<Data?, Never>) { self.continuation = continuation }
    func finish(_ data: Data?) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel(); deadline = nil
        continuation.resume(returning: data)
    }
}

extension WebContentContainer {
    /// No window-server capture or permission request. Chromium supplies its
    /// own visible pixels; native chrome stays live above these temporary views.
    func prepareLibraryMotionSnapshots() async -> [LibraryMotionSnapshot]? {
        guard !librarySnapshotReadInFlight else { librarySnapshotStatus = "busy"; return nil }
        librarySnapshotStatus = "preflight"
        let originalBounds = bounds
        let deadline = CACurrentMediaTime() + 0.25
        var snapshots: [LibraryMotionSnapshot] = []
        var pixels = 0
        var decodedBytes = 0
        for slot in slots {
            guard let host = host(for: slot.tabID), let view = slot.contentHostView,
                  !view.isHiddenOrHasHiddenAncestor,
                  let content = (host as? WebContentProviding)?.webContent else { continue }
            let frame = view.frame, url = host.currentURL
            let scale = view.window?.backingScaleFactor ?? 1
            let expectedWidth = ceil(view.bounds.width * scale), expectedHeight = ceil(view.bounds.height * scale)
            guard expectedWidth > 0, expectedHeight > 0, expectedWidth <= 8192, expectedHeight <= 8192,
                  expectedWidth * expectedHeight <= Double(16 * 1024 * 1024 - pixels) else { return nil }
            let remaining = deadline - CACurrentMediaTime()
            guard remaining > 0 else { librarySnapshotStatus = "deadline"; return nil }
            guard let png = await librarySnapshotPNG(content, deadline: remaining) else { return nil }
            librarySnapshotStatus = "geometry"
            guard !Task.isCancelled,
                  bounds == originalBounds, self.host(for: slot.tabID) === host,
                  view === slot.contentHostView, view.frame == frame, host.currentURL == url else { return nil }
            librarySnapshotStatus = "image"
            guard png.count <= 64 * 1024 * 1024,
                  let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                  let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
                  width > 0, height > 0, width <= 8192, height <= 8192,
                  width * height <= 16 * 1024 * 1024 - pixels,
                  let image = CGImageSourceCreateImageAtIndex(source, 0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  image.bitsPerPixel <= 32, image.bytesPerRow * image.height <= 64 * 1024 * 1024 - decodedBytes
            else { return nil }
            // At most 16M decoded pixels across all panes, 64 MiB at 32 bpp.
            // The usual 1200x800 pt, 2x page uses less than 15 MiB.
            pixels += width * height
            decodedBytes += image.bytesPerRow * image.height
            // Bake the pane's rounded clip into stationary pixels. Closing can
            // then move a plain image instead of a rounded, masked subtree.
            guard let rounded = libraryRoundedImage(image, view: view) else { return nil }
            snapshots.append(.init(source: view, frame: frame, image: rounded))
        }
        guard bounds == originalBounds, snapshots.allSatisfy({
            $0.source.frame == $0.frame && $0.source.isDescendant(of: self) && !$0.source.isHiddenOrHasHiddenAncestor
        }) else { return nil }
        librarySnapshotStatus = "ready"
        return snapshots
    }

    private func libraryRoundedImage(_ image: CGImage, view: NSView) -> CGImage? {
        guard let clip = view.superview, let layer = clip.layer,
              layer.masksToBounds, layer.cornerRadius > 0 else { return image }
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: CGFloat(image.width) / view.bounds.width,
                        y: CGFloat(image.height) / view.bounds.height)
        let pane = clip.bounds.offsetBy(dx: -view.frame.minX, dy: -view.frame.minY)
        context.addPath(CGPath(roundedRect: pane, cornerWidth: layer.cornerRadius,
                              cornerHeight: layer.cornerRadius, transform: nil))
        context.clip()
        context.draw(image, in: view.bounds)
        return context.makeImage()
    }

    private func librarySnapshotPNG(_ content: any WebContent, deadline: Double) async -> Data? {
        guard !librarySnapshotReadInFlight else { return nil }
        librarySnapshotReadInFlight = true
        librarySnapshotStatus = "capture"
        return await withCheckedContinuation { continuation in
            let reply = LibrarySnapshotReply(continuation)
            Task { @MainActor [weak self] in
                let png: Data?
                do { png = try await content.snapshotPNG() }
                catch { self?.librarySnapshotStatus = "engine"; png = nil }
                self?.librarySnapshotReadInFlight = false
                reply.finish(png)
            }
            // A slow/unresponsive page gets an immediate close instead of an
            // unbounded animation preparation. Only one engine read may remain
            // in flight, even after this deadline or an interrupted close.
            reply.deadline = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(deadline)) } catch { return }
                self.librarySnapshotStatus = "timeout"
                reply.finish(nil)
            }
        }
    }
}
