#if OPEN_AUTOMATION
  import AppKit
  import OpenEngine

  /// PNG snapshots of OUR windows only, taken inside the app (no
  /// screen-recording permission needed).
  ///
  /// The window server returns our own AppKit drawing, but on macOS 26+ it
  /// leaves out layers that the Chromium GPU process draws into our window.
  /// So the page area of every visible web view is pasted in from a DevTools
  /// Page.captureScreenshot. For true on-screen pixels use
  /// `tools/openctl shot`, which runs `screencapture -l <our window id>`.
  @MainActor
  enum WindowSnapshot {
    private typealias CreateFromArray = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?

    static func capture(_ window: NSWindow, to url: URL) async throws -> String {
      var base: NSImage
      var method: String
      if let image = windowServerImage(window), !isBlank(image) {
        base = NSImage(cgImage: image, size: window.frame.size)
        method = "windowserver+devtools"
      } else if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        base = NSImage(size: view.bounds.size)
        base.addRepresentation(rep)
        method = "appkit+devtools"
      } else {
        throw AutomationController.Failure(message: "cannot capture window")
      }
      var overlays: [(NSRect, NSImage)] = []
      for content in OEEngine.shared.allWebContents
      where content.view.window === window && !content.view.isHiddenOrHasHiddenAncestor && content.isLive {
        // A page that never painted (for example chrome://extensions in an
        // Alloy page) never answers; skip it after a short wait.
        guard let png = await pagePNG(content, timeout: 3), let page = NSImage(data: png) else { continue }
        // Window base coordinates cover the whole frame, origin bottom-left.
        overlays.append((content.view.convert(content.view.bounds, to: nil), page))
      }
      let size = window.frame.size
      let out = NSImage(size: size)
      out.lockFocus()
      base.draw(in: NSRect(origin: .zero, size: size))
      for (frame, page) in overlays {
        page.draw(in: frame)
      }
      out.unlockFocus()
      guard let tiff = out.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
      else { throw AutomationController.Failure(message: "PNG encoding failed") }
      try png.write(to: url)
      return method
    }

    @MainActor
    private final class Once {
      var done = false
    }

    private static func pagePNG(_ content: OEWebContent, timeout: Double) async -> Data? {
      await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
        let once = Once()
        content.takeSnapshot { png, _ in
          guard !once.done else { return }
          once.done = true
          continuation.resume(returning: png)
        }
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(timeout))
          guard !once.done else { return }
          once.done = true
          continuation.resume(returning: nil)
        }
      }
    }

    private static func windowServerImage(_ window: NSWindow) -> CGImage? {
      guard let lib = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
        let sym = dlsym(lib, "CGWindowListCreateImageFromArray")
      else { return nil }
      let create = unsafeBitCast(sym, to: CreateFromArray.self)
      let numbers = [window.windowNumber] + (window.childWindows ?? []).filter(\.isVisible).map(\.windowNumber)
      var pointers = numbers.map { UnsafeRawPointer(bitPattern: UInt($0)) }
      guard let array = CFArrayCreate(nil, &pointers, pointers.count, nil) else { return nil }
      // kCGWindowImageBoundsIgnoreFraming (1 << 0) | kCGWindowImageBestResolution (1 << 3)
      return create(.null, array, (1 << 0) | (1 << 3))?.takeRetainedValue()
    }

    /// True if every sampled pixel is fully transparent (denied capture).
    private static func isBlank(_ image: CGImage) -> Bool {
      guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return true }
      let length = CFDataGetLength(data)
      let bpp = max(image.bitsPerPixel / 8, 1)
      var opaque = 0
      var offset = 0
      let step = max(length / 4096 / bpp * bpp, bpp)
      while offset + bpp <= length {
        if bytes[offset + (image.alphaInfo == .premultipliedFirst ? 0 : bpp - 1)] != 0 { opaque += 1 }
        offset += step
      }
      return opaque < 16
    }

  }
#endif
