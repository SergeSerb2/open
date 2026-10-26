import AppKit
import OpenDesign
import OpenModel
import OpenStore

struct CLIError: Error, CustomStringConvertible { var description: String }

@MainActor
enum RenderCLI {
    static func run(_ args: [String]) throws {
        guard let cmd = args.first else { throw CLIError(description: usage) }
        let rest = Array(args.dropFirst())
        switch cmd {
        case "theme": try theme(rest)
        case "probe": try probe(rest)
        default: throw CLIError(description: usage)
        }
    }

    static let usage = """
    usage:
      sidebar-render theme --snapshot DIR --space N --size WxH [--inactive] [--scale S] --out FILE.png
      sidebar-render probe --out FILE.png
    """

    static func value(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func size(_ s: String?) -> CGSize? {
        guard let s, let x = s.firstIndex(of: "x"), let w = Double(s[..<x]), let h = Double(s[s.index(after: x)...]) else { return nil }
        return CGSize(width: w, height: h)
    }

    static func loadModel(_ dir: String) throws -> BrowserModel {
        let store = SnapshotStore(root: URL(fileURLWithPath: dir))
        guard let model = try store.load() else { throw CLIError(description: "no snapshot in \(dir)") }
        return model
    }

    /// Renders only the theme background for a Space at a window size.
    static func theme(_ args: [String]) throws {
        guard let dir = value(args, "--snapshot"), let out = value(args, "--out"),
              let sz = size(value(args, "--size")) else { throw CLIError(description: usage) }
        let model = try loadModel(dir)
        let index = Int(value(args, "--space") ?? "0") ?? 0
        let space = model.spaces[index]
        let view = ThemeBackgroundView(frame: CGRect(origin: .zero, size: sz))
        view.style = SpaceThemeStyle(theme: space.theme, system: .dark)
        view.isWindowActive = !args.contains("--inactive")
        let scale = CGFloat(Double(value(args, "--scale") ?? "1") ?? 1)
        view.renderScale = scale
        let image = OffscreenRenderer().render(view, scale: scale)
        OffscreenRenderer.writePNG(image, to: URL(fileURLWithPath: out))
        print("wrote \(out) \(image.width)x\(image.height)")
    }

    /// Checks windowless rendering of drawn text and an outline view.
    static func probe(_ args: [String]) throws {
        guard let out = value(args, "--out") else { throw CLIError(description: usage) }
        let root = ProbeRoot(frame: CGRect(x: 0, y: 0, width: 228, height: 300))
        let image = OffscreenRenderer().render(root, scale: 2)
        func dump(_ l: CALayer, _ d: Int) {
            print(String(repeating: "  ", count: d) + "\(type(of: l)) frame=\(l.frame) contents=\(l.contents != nil) delegate=\(l.delegate.map { String(describing: type(of: $0)) } ?? "-") hidden=\(l.isHidden)")
            for s in l.sublayers ?? [] { dump(s, d + 1) }
        }
        dump(root.layer!, 0)
        OffscreenRenderer.writePNG(image, to: URL(fileURLWithPath: out))
        print("wrote \(out) rows=\(root.outline.numberOfRows) rowViews=\(root.visibleRowViews())")
    }
}

@MainActor
final class ProbeRoot: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = NSOutlineView()
    let scroll = NSScrollView()
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemOrange.cgColor
        let label = ProbeLabel(frame: CGRect(x: 10, y: 10, width: 200, height: 20))
        addSubview(label)
        scroll.frame = CGRect(x: 0, y: 40, width: 228, height: 260)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        let col = NSTableColumn(identifier: .init("c"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.rowHeight = 41
        outline.dataSource = self
        outline.delegate = self
        scroll.documentView = outline
        addSubview(scroll)
        outline.reloadData()
    }
    required init?(coder: NSCoder) { fatalError() }
    func visibleRowViews() -> Int { var n = 0; outline.enumerateAvailableRowViews { _, _ in n += 1 }; return n }
    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { item == nil ? 20 : 0 }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { "Row \(index)" as NSString }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let l = ProbeLabel(frame: .zero); l.text = item as! String; return l
    }
}

@MainActor
final class ProbeLabel: NSView {
    var text = "Hello Open — Search or Enter URL…"
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black])
            .draw(at: NSPoint(x: 4, y: 2))
    }
}
