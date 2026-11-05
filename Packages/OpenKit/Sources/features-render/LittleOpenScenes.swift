import AppKit
import OpenFeatures
import OpenModel

@MainActor
enum LittleOpenScenes {
    static func render(_ scene: String, args: [String]) async throws {
        guard ["little-bar", "little-page", "little-picker"].contains(scene) else { throw CLIError(description: "unknown Little Open scene") }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let model = FeatureCLI.synthetic(), factory = FakeWebContentHostFactory()
        model.profiles[0].name = "Home"; model.profiles.append(Profile(name: "Work"))
        model.spaces[0].icon = .emoji("🌿")
        _ = model.createSpace(title: "Reading", profileID: model.profiles[0].id, icon: .emoji("📘"))
        _ = model.createSpace(title: "Studio", profileID: model.profiles[0].id, icon: .emoji("🎨"))
        let little = LittleOpenCoordinator(model: model, archiveSink: nil, screenProvider: { LittleOpenChecks.screen }) { profile in
            factory.makeHost(tabID: ItemID(), profileID: profile, url: nil)! as! FakeWebContentHost
        }
        little.presentWindows = false; little.defaults = FeatureCLI.defaults()
        defer { little.closeAll() }
        little.openBlank(focusURLField: true)
        let controller = little.controllers[little.sessions[0].id]!
        if scene != "little-bar" {
            controller.container.host(for: controller.session.tab.id)!.load(URL(string: "https://www.example.com/library")!)
            try await FeatureCLI.waitForLoads(factory, root: controller.contentView)
        }
        let root: NSView
        if scene == "little-picker" {
            controller.titleBar.chevronButton.performClick(nil)
            root = controller.spacePicker!.view
        } else { root = controller.contentView }
        OffscreenRenderer.settle(root, runLoop: 0.02)
        guard let out = RenderCLI.value(args, "--out") else { throw CLIError(description: "--out required") }
        let scale = CGFloat(Double(RenderCLI.value(args, "--scale") ?? "2") ?? 0)
        guard scale == 1 || scale == 2 else { throw CLIError(description: "scale must be 1 or 2") }
        // Keep the native backing scale when rehosting. A Retina → 1x transition can
        // lose native text backing stores; downsample the complete snapshot for a 1x export.
        let renderScale = max(scale, controller.window?.backingScaleFactor ?? scale)
        // Include the real native window buttons in this offscreen view-only export.
        if scene == "little-page", let window = controller.window {
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                if let button = window.standardWindowButton(kind) {
                    let frame = root.convert(button.bounds, from: button)
                    root.addSubview(button); button.frame = frame
                }
            }
        }
        root.window?.contentView = nil
        let host = OffscreenRenderer.host(root, scale: renderScale)
        defer { host.contentView = nil; host.close() }
        // Rehosting can discard native backing stores. Invalidate after attachment, as
        // commandbar-render's Stage does, before the CARenderer snapshot.
        func redraw(_ view: NSView) { view.needsDisplay = true; view.display(); view.layer?.displayIfNeeded(); view.subviews.forEach(redraw) }
        redraw(root); OffscreenRenderer.settle(root, runLoop: 0.02)
        var image = OffscreenRenderer().snapshot(root, scale: renderScale)
        if renderScale != scale {
            guard let context = CGContext(data: nil, width: Int(root.bounds.width * scale), height: Int(root.bounds.height * scale),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw CLIError(description: "could not create export bitmap")
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
            guard let resized = context.makeImage() else { throw CLIError(description: "could not finish export bitmap") }
            image = resized
        }
        OffscreenRenderer.writePNG(image, to: URL(fileURLWithPath: out))
        print("rendered \(scene) \(Int(root.bounds.width)) × \(Int(root.bounds.height)) to \(out)")
    }
}
