import AppKit
import OpenEasel

/// Offscreen frames of the Easel canvas on synthetic documents (look reviews).
/// usage: easel-render --out DIR [--scale 2] [--size 906x780]
MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let args = Array(CommandLine.arguments.dropFirst())
    func value(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    guard let out = value("--out") else { FileHandle.standardError.write(Data("usage: easel-render --out DIR [--size WxH]\n".utf8)); exit(2) }
    let parts = (value("--size") ?? "906x780").split(separator: "x").compactMap { Double($0) }
    let size = CGSize(width: parts.first ?? 906, height: parts.last ?? 780)
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

    func doc() -> EaselDocument {
        var d = EaselDocument(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        d.objects = [
            EaselObject(frame: CGRect(x: 120, y: 260, width: 260, height: 200), zIndex: 1,
                        content: .shape(kind: .rectangle, color: .lightGreen, arrow: nil, points: nil)),
            EaselObject(frame: CGRect(x: 470, y: 230, width: 200, height: 200), zIndex: 2,
                        content: .shape(kind: .circle, color: .red, arrow: nil, points: nil)),
            EaselObject(frame: CGRect(x: 690, y: 300, width: 220, height: 140), zIndex: 3,
                        content: .shape(kind: .arrow, color: .lightBlue, arrow: (EaselPoint(x: 0.1, y: 0.85), EaselPoint(x: 0.9, y: 0.15)), points: nil)),
            EaselObject(frame: CGRect(x: 150, y: 520, width: 300, height: 120), zIndex: 4,
                        content: .shape(kind: .freehand, color: .black, arrow: nil,
                                        points: (0...40).map { i in let t = Double(i) / 40; return EaselPoint(x: t, y: 0.5 + 0.4 * sin(t * 12)) })),
            EaselObject(frame: CGRect(x: 520, y: 520, width: 330, height: 60), zIndex: 5,
                        content: .text(EaselText(string: "Ideas for the trip", fontFamily: .clean, paragraphStyle: .h2))),
            EaselObject(frame: CGRect(x: 520, y: 590, width: 330, height: 60), zIndex: 6,
                        content: .text(EaselText(string: "Pack light, take the morning train, and keep a day free.", fontFamily: .clean, paragraphStyle: .body))),
        ]
        return d
    }

    let scenes: [(String, () -> EaselDocument, (EaselCanvasView) -> Void)] = [
        ("empty", { EaselDocument(id: UUID()) }, { _ in }),
        ("shapes", doc, { _ in }),
        ("rect-selected", doc, { c in c.setSelection([c.document.objects[0].id]) }),
        ("text-editing", { EaselDocument(id: UUID()) }, { c in
            let id = c.insert(EaselObject(frame: CGRect(x: 360, y: 300, width: 309, height: 31), zIndex: 0, content: .text(EaselText())))
            c.setSelection([id]); c.beginTextEditing(id)
        }),
        ("tool-hover-text", { EaselDocument(id: UUID()) }, { c in c.select(tool: .rectangle) }),
        ("zoom-50", doc, { c in c.setZoom(0.5) }),
    ]
    for appearance in ["light", "dark"] {
        for (name, make, setup) in scenes {
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            let canvas = EaselCanvasView(document: make())
            canvas.frame = CGRect(origin: .zero, size: size)
            window.contentView = canvas
            canvas.layoutSubtreeIfNeeded()
            setup(canvas)
            canvas.layoutSubtreeIfNeeded()
            canvas.displayIfNeeded()
            guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { continue }
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            let path = "\(out)/easel-\(name)-\(appearance).png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print(path)
        }
    }
}
