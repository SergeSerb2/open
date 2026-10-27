import AppKit
import OpenDesign
import OpenModel
import OpenSpaceEditor
import ImageIO

/// §17.4: private captures enter only this real render/compare command.
@MainActor
enum SessionTwoPadCompare {
    private static let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    private static let sidebar = CGRect(x: 30, y: 820, width: 170, height: 200)
    private static let panelOrigin = CGPoint(x: 228, y: 9)

    struct Row {
        var name: String
        var delta: Double?
        var position: Double?
        var spread: Double?
        var spatialError: Double?
        var spatialLimit: Double = 0
        var note: String
        var passed: Bool { (delta ?? 0) <= 2 && (position ?? 0) <= 1 && (spread ?? 0) <= 0.3 && (spatialError ?? 0) <= spatialLimit }
    }
    @MainActor struct Captures {
        let folders: [URL]
        init(root: URL) throws {
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsSubdirectoryDescendants) else {
                throw CLIError(description: "cannot enumerate capture root")
            }
            var found: [URL] = [], numbers = Set<Int>(), count = 0
            for case let entry as URL in entries {
                count += 1
                guard count <= CaptureLimits.entries else { throw CLIError(description: "capture root exceeds 512 entries") }
                let name = entry.lastPathComponent
                guard name.count > 4, name.dropFirst(4).first == "-", let number = Int(name.prefix(4)),
                      try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
                guard numbers.insert(number).inserted else { throw CLIError(description: "duplicate capture frame number") }
                found.append(entry)
            }
            folders = found.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        func image(_ number: Int, window: String) throws -> Bitmap {
            let image = try CaptureLimits.image(url(number, window: window))
            let result = Bitmap(image: image, colorSpace: p3)
            print("Input F\(String(format: "%04d", number)) accepted: \(image.width)x\(image.height), decoded \(image.bytesPerRow * image.height) bytes")
            return result
        }
        /// The capture's embedded display profile.
        func colorSpace(_ number: Int, window: String) throws -> CGColorSpace {
            guard let space = try CaptureLimits.image(url(number, window: window)).colorSpace else {
                throw CLIError(description: "capture frame \(number) has no color space")
            }
            return space
        }
        private func url(_ number: Int, window: String) throws -> URL {
            guard let folder = folders.first(where: { $0.lastPathComponent.hasPrefix(String(format: "%04d-", number)) }) else {
                throw CLIError(description: "missing session-2 gate frame \(number)")
            }
            let name = "win-\(window)"
            var url = folder.appendingPathComponent(name + ".png")
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(name + ".same").path),
                      let previous = folders.last(where: { $0.lastPathComponent < folder.lastPathComponent && FileManager.default.fileExists(atPath: $0.appendingPathComponent(name + ".png").path) }) else {
                    throw CLIError(description: "missing gate image for frame \(number), window \(window)")
                }
                url = previous.appendingPathComponent(name + ".png")
            }
            return url
        }
        func panel(_ number: Int) throws -> Bitmap {
            let input = try image(number, window: "70352")
            return EditorCompare.crop(input, rect: CGRect(origin: panelOrigin, size: CGSize(width: 382, height: 534)))
        }
    }
    static func srgb(_ value: [Double]) -> [Double] {
        let c = ThemeColorMath.toExtendedSRGB(P3(value[0] / 255, value[1] / 255, value[2] / 255))
        return [c.red * 255, c.green * 255, c.blue * 255]
    }
    static func delta(_ a: [Double], _ b: [Double]) -> Double { ColorMath.deltaE2000(srgb(a), srgb(b)) }
    static func components(_ color: P3) -> [Double] { [color.r * 255, color.g * 255, color.b * 255] }
    static func stats(_ image: Bitmap) -> (mean: [Double], sd: Double) {
        let (x0, y0, x1, y1) = image.clamp(sidebar)
        var sum = 0.0, squares = 0.0, count = 0.0
        for y in y0..<y1 { for x in x0..<x1 {
            let c = image.pixel(x, y)
            func linear(_ n: Double) -> Double { let n = n / 255; return n <= 0.04045 ? n / 12.92 : pow((n + 0.055) / 1.055, 2.4) }
            let luminance = 0.22897456 * linear(c[0]) + 0.69173852 * linear(c[1]) + 0.07928691 * linear(c[2])
            let l = luminance > 216.0 / 24389 ? 116 * cbrt(luminance) - 16 : 24389.0 / 27 * luminance
            sum += l; squares += l * l; count += 1
        } }
        return (image.mean(sidebar), sqrt(max(0, squares / count - pow(sum / count, 2))))
    }
    /// Largest connected white component is the primary knob's ring. Mode/Add
    /// glyphs are much smaller; no copied or fitted Arc outline is used.
    static func ringCenter(_ image: Bitmap) throws -> CGPoint {
        let region = CGRect(x: 21, y: 21, width: 340, height: 340)
        let (x0, y0, x1, y1) = image.clamp(region)
        var visited = Set<Int>(), best: [Int] = []
        func white(_ i: Int) -> Bool {
            let c = image.pixel(i % image.width, i / image.width)
            return c.min()! >= 240 && c.max()! - c.min()! < 8
        }
        for y in y0..<y1 { for x in x0..<x1 {
            let index = y * image.width + x
            guard !visited.contains(index), white(index) else { continue }
            visited.insert(index); var component = [index], cursor = 0
            while cursor < component.count {
                let i = component[cursor]; cursor += 1
                let px = i % image.width, py = i / image.width
                for (nx, ny) in [(px - 1, py), (px + 1, py), (px, py - 1), (px, py + 1)] where nx >= x0 && nx < x1 && ny >= y0 && ny < y1 {
                    let next = ny * image.width + nx
                    if !visited.contains(next) && white(next) { visited.insert(next); component.append(next) }
                }
            }
            if component.count > best.count { best = component }
        } }
        guard best.count > 150 else { throw CLIError(description: "no primary white knob ring") }
        let xs = best.map { $0 % image.width }, ys = best.map { $0 / image.width }
        let left = Double(xs.min()!), right = Double(xs.max()! + 1), top = Double(ys.min()!), bottom = Double(ys.max()! + 1)
        guard (20...52).contains(right - left), (40...52).contains(bottom - top) else {
            throw CLIError(description: "white component is not a primary knob ring")
        }
        // The rightmost ring is clipped by the pad, so infer its center from
        // the full left edge plus the measured 22 pt primary radius.
        let cx = right >= 360 ? left + 22 : (left + right) / 2
        return CGPoint(x: cx, y: (top + bottom) / 2)
    }
    static func run(_ args: [String]) throws {
        var flags = Set<String>()
        guard args.count % 2 == 0, (6...10).contains(args.count) else {
            throw CLIError(description: "session2-pad requires --spec, --capture-root, and --out, with optional --renderer and --blend")
        }
        for index in stride(from: 0, to: args.count, by: 2) {
            guard ["--spec", "--capture-root", "--out", "--renderer", "--blend"].contains(args[index]), flags.insert(args[index]).inserted,
                  !args[index + 1].isEmpty else { throw CLIError(description: "unknown or duplicate session2-pad option") }
        }
        // Diagnostics: a real window composited by the window server on this
        // Mac's display, and #120's precomputed P3 mix for A/B tables.
        let renderer = RenderCLI.value(args, "--renderer") ?? "offscreen", blend = RenderCLI.value(args, "--blend") ?? "display"
        guard ["offscreen", "onscreen"].contains(renderer), ["display", "fixed-p3"].contains(blend) else {
            throw CLIError(description: "session2-pad --renderer offscreen|onscreen, --blend display|fixed-p3")
        }
        guard let root = RenderCLI.value(args, "--capture-root"), let output = RenderCLI.value(args, "--out") else {
            throw CLIError(description: "compare --spec session2-pad --capture-root SESSION17 --out .re/DIR")
        }
        let out = URL(fileURLWithPath: output).standardizedFileURL
        guard out.path.contains("/.re/") else { throw CLIError(description: "session2-pad output must stay under .re") }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let captures = try Captures(root: URL(fileURLWithPath: root))
        var rows: [Row] = []
        // The main-window capture shows Greyscale 7 at F0039 and again at
        // F0041. The extra window image lags this tap; use win-70352 throughout.
        for (frame, preset) in [(27, 36), (29, 37), (31, 38), (33, 39), (35, 40), (37, 41),
                                (39, 42), (41, 42), (43, 43), (45, 44), (65, 7)] {
            let scene = try EditorScene(style: nil)
            scene.controller.apply(.selectPreset(index: preset))
            scene.controller.apply(.setPresetPage(preset / 9))
            let ownURL = out.appendingPathComponent("preset-\(frame).png")
            OffscreenRenderer.writePNG(scene.snapshot(), to: ownURL)
            let predicted = try ringCenter(Bitmap(path: ownURL.path, colorSpace: p3))
            let panel = try captures.panel(frame)
            let measured = try ringCenter(panel)
            let core = panel.mean(CGRect(x: measured.x - 4, y: measured.y - 4, width: 8, height: 8))
            rows.append(Row(name: String(format: "Knob %@ F%04d", SpaceStylePresets.all[preset].name, frame),
                position: hypot(predicted.x - measured.x, predicted.y - measured.y),
                note: String(format: "Open (%.2f, %.2f); capture (%.2f, %.2f) panel pt; captured core P3 %.1f/%.1f/%.1f", predicted.x, predicted.y, measured.x, measured.y, core[0], core[1], core[2])))
            scene.controller.close()
        }
        // Select Brand 8 through the same reducer as the real editor. Its open
        // range/saturation then survive every drag and intensity action.
        var state = ThemeEditorState()
        state.apply(.selectPreset(index: 7))
        let centerAngle = 337.1 * Double.pi / 180
        let points: [(Int, CGPoint)] = [(92, CGPoint(x: 0.004 * cos(centerAngle), y: 0.004 * sin(centerAngle))),
                                      (93, CGPoint(x: 0.485, y: -0.003)), (98, CGPoint(x: 0.932, y: -0.004))]
        var styles: [Int: SpaceStyle] = [:]
        for (frame, point) in points {
            state.apply(.dragKnob(to: point, relative: false)); state.apply(.endDrag)
            let color = ThemeColorMath.toP3(state.style!.keyColor)
            let panel = try captures.panel(frame)
            let position = CGPoint(x: 191 + point.x * 170, y: 191 + point.y * 170)
            let actual = panel.mean(CGRect(x: position.x - 5, y: position.y - 5, width: 10, height: 10))
            rows.append(Row(name: "Key F\(String(format: "%04d", frame))", delta: delta(actual, components(color)),
                note: String(format: "P3 capture %.1f/%.1f/%.1f; Open %.1f/%.1f/%.1f", actual[0], actual[1], actual[2], color.r * 255, color.g * 255, color.b * 255)))
            styles[frame] = state.style!
        }
        func render(_ style: SpaceStyle, frame: Int, name: String) throws -> (Bitmap, Bitmap) {
            let arc = try captures.image(frame, window: "70352")
            let data = try JSONEncoder().encode(style), json = String(decoding: data, as: UTF8.self)
            // The exact style, so other Macs can render the same window.
            try data.write(to: out.appendingPathComponent(name + ".style.json"))
            let scene = try RenderCLI.scene(model: RenderCLI.fixtureModel(), args: ["--style", json] + (blend == "fixed-p3" ? ["--fixed-p3-blend"] : []),
                                            size: CGSize(width: arc.width, height: arc.height))
            let ownURL = out.appendingPathComponent(name + ".png")
            if renderer == "onscreen" {
                OffscreenRenderer.writePNG(try OffscreenRenderer.onscreen(scene), to: ownURL)
            } else {
                scene.background.renderScale = 1
                // Composite in the capture's display space, as that display did.
                OffscreenRenderer.writePNG(OffscreenRenderer().render(scene, scale: 1, colorSpace: try captures.colorSpace(frame, window: "70352")), to: ownURL)
            }
            return (arc, try Bitmap(path: ownURL.path, colorSpace: p3))
        }
        for (frame, key, intensity) in [(92, 92, 0.8), (93, 93, 0.8), (95, 98, 0.8), (98, 98, 0.0), (100, 98, 0.495), (102, 98, 1.0), (65, 65, 0.8)] {
            var style = key == 65 ? SpaceStylePresets.all[7].style : styles[key]!
            style.intensityFactor = intensity; style.noiseFactor = 0
            let (arc, own) = try render(style, frame: frame, name: "window-\(frame)")
            let a = arc.mean(sidebar), o = own.mean(sidebar)
            rows.append(Row(name: String(format: "Sidebar F%04d i=%.3f", frame, intensity), delta: delta(a, o),
                note: String(format: "P3 capture %.1f/%.1f/%.1f; Open %.1f/%.1f/%.1f", a[0], a[1], a[2], o[0], o[1], o[2])))
        }
        for (frame, texture, target) in [(112, SpaceStyleTexture.grain, 2.02), (114, .sand, 1.53), (116, .denim, 1.28), (118, .tweed, 0.92)] {
            var style = styles[98]!
            style.intensityFactor = 1; style.noiseFactor = 0.8; style.texture = texture
            let (arc, own) = try render(style, frame: frame, name: "texture-\(texture.rawValue)")
            let a = stats(arc), o = stats(own)
            rows.append(Row(name: "Texture \(texture.rawValue)", delta: delta(a.mean, o.mean), spread: abs(o.sd - target),
                note: String(format: "L* sd capture %.3f; Open %.3f; target %.2f ±0.3", a.sd, o.sd, target)))
            let captured = TexturePatternMetrics(arc, region: sidebar), rendered = TexturePatternMetrics(own, region: sidebar)
            // Open's own art for all four textures matches the captured scale,
            // direction, and neighbour correlation (§17.3); skew is reported.
            rows.append(Row(name: "Pattern scale \(texture.rawValue)",
                spatialError: TexturePatternMetrics.error(captured.boxRatios, rendered.boxRatios), spatialLimit: 0.1,
                note: "Box-2/4/8 sd ratios: capture \(TexturePatternMetrics.text(captured.boxRatios)); Open \(TexturePatternMetrics.text(rendered.boxRatios)); tolerance ±0.1"))
            rows.append(Row(name: "Pattern direction \(texture.rawValue)",
                spatialError: TexturePatternMetrics.error(captured.directionSD, rendered.directionSD), spatialLimit: 0.15,
                note: "Column/row/diagonal mean L* sd: capture \(TexturePatternMetrics.text(captured.directionSD)); Open \(TexturePatternMetrics.text(rendered.directionSD)); tolerance ±0.15"))
            rows.append(Row(name: "Pattern correlation \(texture.rawValue)",
                spatialError: TexturePatternMetrics.error(captured.correlation, rendered.correlation), spatialLimit: 0.15,
                note: "Lag-1 H/V/D1/D2 correlation: capture \(TexturePatternMetrics.text(captured.correlation)); Open \(TexturePatternMetrics.text(rendered.correlation)); tolerance ±0.15. Skew (reported) capture \(String(format: "%.3f", captured.skew)); Open \(String(format: "%.3f", rendered.skew))"))
        }
        var mode = ThemeEditorState(style: SpaceStylePresets.all[7].style)
        // Independent decoded Brand-8 range; do not derive the expectation
        // from the state under test (§17.4).
        let t = (ThemeColorMath.hsl(ThemeColorMath.toP3(mode.style!.keyColor)).l - 0.4167) / 0.5
        for (appearance, lo, span) in [(SpaceStyleAppearance.dark, 0.01, 0.415), (.light, 0.575, 0.395)] {
            mode.apply(.setAppearance(appearance))
            let l = ThemeColorMath.hsl(ThemeColorMath.toP3(mode.style!.keyColor)).l
            rows.append(Row(name: "Mode remap \(appearance.rawValue)", delta: delta(components(ThemeColorMath.toP3(mode.style!.keyColor)), components(ThemeColorMath.rgb(h: 200.5 / 360, s: 0.5176, l: lo + span * t))), note: String(format: "L %.6f, expected %.6f", l, lo + span * t)))
        }
        let empty = ThemeEditorState()
        rows.append(Row(name: "Empty open", delta: empty.range == 0.01...0.97 && empty.saturation == 1 ? 0 : .infinity,
            note: "Range 0.01…0.97; saturation 1.0; transient state only"))
        // F0137's first key is an independent stored capture value, not the
        // pointer fed into the color law above.
        let firstKey = ThemeColorMath.toP3(EditorScene.capturedStyle.keyColor)
        let firstKnob = ThemeColorMath.knob(for: firstKey, range: empty.range)
        rows.append(Row(name: "Empty first color F0137", position: abs(hypot(firstKnob.x, firstKnob.y) * 170 - 45.26), note: "Captured ring radius 45.26 pt; empty-open range"))
        let heading = "| Gate | ΔE00 | Position pt | L* sd error | Spatial error | Result | Evidence |\n|---|---|---|---|---|---|---|\n"
        func number(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "—" }
        let table = heading + rows.map { "| \($0.name) | \(number($0.delta)) | \(number($0.position)) | \(number($0.spread)) | \(number($0.spatialError)) | \($0.passed ? "PASS" : "FAIL") | \($0.note) |" }.joined(separator: "\n") + "\n"
        try table.write(to: out.appendingPathComponent("table.md"), atomically: true, encoding: .utf8)
        print(table)
        if rows.contains(where: { !$0.passed }) { throw CLIError(description: "session2-pad gate failed") }
    }
}

/// Bounds only this new private-capture entry point; existing comparison
/// defaults are unchanged. Worst allowed image: 4096² RGBA16 = 128 MiB for
/// the source, 64 MiB for our RGBA8 destination. Both are below 2^31 − 2 MiB.
@MainActor private enum CaptureLimits {
    static let entries = 512
    static let bytes = 64 * 1024 * 1024
    static let side = 4096
    static let chunks = 4096
    static func image(_ url: URL) throws -> CGImage {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw CLIError(description: "capture PNG is empty") }
        guard size <= bytes else { throw CLIError(description: "capture PNG exceeds 67108864 bytes") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= bytes, data.count >= 8, Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10] else {
            throw CLIError(description: "invalid capture PNG signature or size")
        }
        func u32(_ at: Int) -> Int { (0..<4).reduce(0) { ($0 << 8) | Int(data[at + $1]) } }
        var offset = 8, count = 0, header = false, ended = false
        while offset <= data.count - 12 {
            count += 1
            guard count <= chunks else { throw CLIError(description: "capture PNG exceeds 4096 chunks") }
            let length = u32(offset)
            guard length <= data.count - offset - 12 else { throw CLIError(description: "truncated capture PNG chunk") }
            let type = String(bytes: data[(offset + 4)..<(offset + 8)], encoding: .ascii)
            if type == "IHDR" {
                guard !header, offset == 8, length == 13 else { throw CLIError(description: "invalid capture PNG header") }
                let width = u32(offset + 8), height = u32(offset + 12), depth = data[offset + 16]
                guard width >= 610, height >= 1020, width <= side, height <= side else {
                    throw CLIError(description: "capture PNG dimensions outside 610...4096 by 1020...4096")
                }
                guard depth == 8 || depth == 16 else { throw CLIError(description: "capture PNG must be 8-bit or 16-bit") }
                header = true
            }
            offset += length + 12
            if type == "IEND" {
                guard length == 0, offset == data.count else { throw CLIError(description: "capture PNG has trailing data after IEND") }
                ended = true; break
            }
        }
        guard header, ended else { throw CLIError(description: "incomplete capture PNG") }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.bitsPerPixel <= 64,
              image.bytesPerRow <= (128 * 1024 * 1024) / image.height else {
            throw CLIError(description: "capture PNG decoded image exceeds 128 MiB or is invalid")
        }
        return image
    }
}
