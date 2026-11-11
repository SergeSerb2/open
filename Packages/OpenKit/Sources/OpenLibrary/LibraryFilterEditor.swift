import AppKit

struct LibraryFilterChip {
    var id: String
    var title: String
    var selected: Bool
}
struct LibraryFilterGroup {
    var title: String
    var chips: [LibraryFilterChip]
}

@MainActor
final class LibraryFilterEditor: NSView {
    var onDone: (() -> Void)?
    var onToggle: ((String) -> Void)?
    var onClear: (() -> Void)?
    var onHeight: ((CGFloat) -> Void)?
    private let title = LibraryField(labelWithString: "")
    private let done = LibraryControl(title: "Done")
    private let clear = LibraryControl(title: "Clear History…")
    private var groups: [(NSTextField,[LibraryControl])] = []
    private(set) var chips: [String:LibraryControl] = [:]
    private(set) var contentHeight: CGFloat = 56
    private var hasClear = false
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize:15,weight:.bold)
        done.baseAlpha = 0.045; done.onPress = { [weak self] in self?.onDone?() }
        clear.onPress = { [weak self] in self?.onClear?() }
        addSubview(title); addSubview(done); addSubview(clear)
    }
    required init?(coder:NSCoder) { fatalError() }
    func update(title:String,groups:[LibraryFilterGroup],foreground:NSColor,overlay:NSColor,clear:Bool) {
        let focused = chips.first { window?.firstResponder === $0.value }?.key
        self.title.stringValue = title; self.title.textColor = foreground
        for (label,buttons) in self.groups { label.removeFromSuperview(); buttons.forEach { $0.removeFromSuperview() } }
        self.groups = []; chips = [:]; hasClear = clear; self.clear.isHidden = !clear
        for group in groups {
            let label = LibraryField(labelWithString:group.title)
            label.font = .systemFont(ofSize:13,weight:.semibold); label.textColor = foreground.withAlphaComponent(0.68); addSubview(label)
            let buttons = group.chips.map { chip in
                let button = LibraryControl(title:chip.title); button.labelSize = 14; button.baseAlpha = 0.045; button.isChip = true
                button.foreground = foreground; button.overlay = overlay; button.selected = chip.selected
                button.onPress = { [weak self] in self?.onToggle?(chip.id) }
                button.setAccessibilityLabel(chip.title); button.setAccessibilityRole(.checkBox)
                chips[chip.id] = button; addSubview(button); return button
            }
            self.groups.append((label,buttons))
        }
        for button in [done,self.clear] { button.foreground = foreground; button.overlay = overlay }
        needsLayout = true; layoutSubtreeIfNeeded()
        if let focused, let control = chips[focused] { window?.makeFirstResponder(control) }
    }
    override func layout() {
        super.layout()
        title.frame = CGRect(x:12,y:19,width:214,height:20)
        done.frame = CGRect(x:234,y:10,width:59,height:36)
        var y:CGFloat = 62
        for (label,buttons) in groups {
            label.frame = CGRect(x:12,y:y,width:281,height:18); y += 21
            var x:CGFloat = 8
            for button in buttons {
                let width = min(289,(button.title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:14,weight:.semibold)]).width+24)
                if x+width > 297 { x = 8; y += 39 }
                button.frame = CGRect(x:x,y:y,width:width,height:33); x += width+6
            }
            y += 49
        }
        if hasClear { clear.frame = CGRect(x:8,y:y,width:180,height:30); y += 42 }
        if contentHeight != y { contentHeight = y; onHeight?(y) }
    }
    @discardableResult func toggle(_ id:String) -> Bool { guard let chip = chips[id] else { return false }; chip.performClick(nil); return true }
    func state(in root:NSView) -> [[String:Any]] {
        chips.sorted { $0.key < $1.key }.map { id,control in
            let rect = root.convert(control.bounds,from:control)
            return ["id":id,"title":control.title,"selected":control.selected,"frame":[rect.minX,rect.minY,rect.width,rect.height]]
        }
    }
}
