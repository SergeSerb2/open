import AppKit
import OpenDesign
import OpenFeatures

/// R-X1 (page-platform §8.1): the translate popover in its offer, translated, and error states,
/// and its Options menu, on the real `TranslatePopoverView`. `features-render translate` writes
/// the three states as PNGs.
@MainActor
enum TranslateChecks {
    static let languages = [TranslateLanguageOption(id: "en", name: "English"), TranslateLanguageOption(id: "de", name: "German"),
                            TranslateLanguageOption(id: "es", name: "Spanish")]
    static let states: [(String, TranslatePopoverContent)] = [
        ("offer", TranslatePopoverContent(mode: .offer, title: "Translate this page to English?", languages: languages, currentTarget: "en")),
        ("translated", TranslatePopoverContent(mode: .translated, title: "Translated from French.", languages: languages, currentTarget: "en")),
        ("error", TranslatePopoverContent(mode: .offer, title: "Translate this page to English?", error: "Translation error (Unable to Translate)",
                                          languages: languages, currentTarget: "en")),
    ]

    static func make(_ content: TranslatePopoverContent, appearance: NSAppearance.Name = .aqua) -> TranslatePopoverView {
        let view = TranslatePopoverView(content: content)
        view.usesMaterial = false
        view.appearance = NSAppearance(named: appearance)
        view.frame = CGRect(origin: .zero, size: view.preferredSize)
        view.layoutSubtreeIfNeeded()
        return view
    }

    static func run(_ check: (Bool, String) -> Void) {
        let m = TranslateMetrics.self
        var heights: [String: CGFloat] = [:]
        for (name, content) in states {
            let view = make(content)
            let host = OffscreenRenderer.host(view, scale: 1); defer { host.contentView = nil; host.close() }
            OffscreenRenderer.settle(view)
            heights[name] = view.bodyHeight
            let body = view.bodyFrame
            let expectedButtons = content.mode == .translated ? ["Show Original", "Options"] : ["Translate", "Options"]
            check(body.width == m.width && view.titleText == content.title && view.buttonTitles == expectedButtons
                  && view.primaryFrame.minX == body.minX + m.padding && view.primaryFrame.height == m.buttonHeight
                  && view.errorText == content.error,
                  "R-X1 \(name): width 300, padding 16, title \"\(content.title)\", buttons \(view.buttonTitles), primary \(view.primaryFrame)")
            // Pixels: the primary button's fill is Core.brandBlue (sampled away from its text).
            let image = OffscreenRenderer().render(view, scale: 1)
            let p = view.primaryFrame
            let sample = pixel(image, x: Int(p.minX + 4), y: Int(p.midY))
            let blue = Core.brandBlue.resolved(.light)
            let target = srgb(blue)
            let delta = zip(sample, target).map { abs($0 - $1) }.max() ?? 255
            check(delta <= 6, "R-X1 \(name): primary fill \(sample) ≈ brandBlue \(target) (max channel delta \(delta) ≤ 6)")
        }
        check((heights["error"] ?? 0) > (heights["offer"] ?? 0), "R-X1 error: the inline error line adds height (\(heights["offer"] ?? 0) → \(heights["error"] ?? 0))")

        let view = make(states[0].1)
        let menu = view.optionsMenu()
        let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        let sub = menu.items.first?.submenu?.items ?? []
        check(titles == ["Choose Another Language", "Never Translate This Site", "—", "Language Settings…"]
              && sub.map(\.title) == ["English", "German", "Spanish"] && sub.map(\.state) == [.on, .off, .off],
              "R-X1 Options menu in order \(titles); languages \(sub.map(\.title)) with the current target checked")
        var actions: [TranslatePopoverAction] = []
        view.onAction = { actions.append($0) }
        _ = view.press(.translate); _ = view.press(.showOriginal); _ = view.press(.chooseLanguage("de")); _ = view.press(.neverTranslate); _ = view.press(.languageSettings)
        check(actions == [.translate, .chooseLanguage("de"), .neverTranslate, .languageSettings],
              "R-X1 offer: Translate, a language, Never Translate This Site, Language Settings… reach the owner; Show Original is not offered (\(actions))")
        let translated = make(states[1].1)
        var tActions: [TranslatePopoverAction] = []
        translated.onAction = { tActions.append($0) }
        _ = translated.press(.translate); _ = translated.press(.showOriginal)
        check(tActions == [.showOriginal], "R-X1 translated: the primary is Show Original (\(tActions))")
        let busy = make(TranslatePopoverContent(mode: .translating, title: "Translate this page to English?"))
        var bActions: [TranslatePopoverAction] = []
        busy.onAction = { bActions.append($0) }
        check(!busy.press(.translate) && bActions.isEmpty, "R-X1 translating: the primary is disabled")
    }

    static func render(_ args: [String]) throws {
        guard let out = RenderCLI.value(args, "--out") else { throw CLIError(description: "--out DIR required") }
        let scale = CGFloat(Double(RenderCLI.value(args, "--scale") ?? "2") ?? 2)
        let dark = RenderCLI.value(args, "--appearance") == "dark"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        for (name, content) in states {
            let view = make(content, appearance: dark ? .darkAqua : .aqua)
            let host = OffscreenRenderer.host(view, scale: scale); defer { host.contentView = nil; host.close() }
            OffscreenRenderer.settle(view)
            let url = URL(fileURLWithPath: out).appendingPathComponent("translate-\(name)\(dark ? "-dark" : "").png")
            OffscreenRenderer.writePNG(OffscreenRenderer().render(view, scale: scale), to: url)
            print("rendered \(url.path)")
        }
    }

    private static func srgb(_ c: RGBA) -> [Int] {
        let converted = c.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
        return (converted?.components ?? [0, 0, 0]).prefix(3).map { Int(round($0 * 255)) }
    }
    private static func pixel(_ image: CGImage, x: Int, y: Int) -> [Int] {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        guard let data = ctx.data else { return [] }
        let p = data.assumingMemoryBound(to: UInt8.self)
        return [Int(p[0]), Int(p[1]), Int(p[2])]
    }
}
