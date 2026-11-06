import AppKit
import CoreText
import OpenDesign
import OpenModel
import OpenSpaceEditor
import OpenStore

@MainActor
enum PickerScene {
    static func make(target: IconTarget = .space, current: SpaceIcon? = .named("planet"), light: Bool = false,
                     onPick: @escaping @MainActor (SpaceIcon?) -> Void = { _ in }) throws -> (NSWindow, IconPickerController) {
        let owner = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 900, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        let picker = IconPickerController(target: target, current: current, window: owner,
                                          anchor: CGRect(x: 20, y: 500, width: 20, height: 20), onPick: onPick)
        picker.panel.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        picker.show()
        let deadline = Date(timeIntervalSinceNow: 5)
        while picker.view.entries.isEmpty, Date() < deadline { settle(0.01) }
        guard !picker.view.entries.isEmpty else { picker.close(); owner.close(); throw CLIError(description: "picker emoji index did not load") }
        OffscreenRenderer.settle(picker.view)
        picker.panel.orderBack(nil) // Entirely outside every screen; enables native AppKit control hit testing.
        return (owner, picker)
    }
    static func render(_ args: [String]) throws {
        guard let output = RenderCLI.value(args, "--out"),
              let page = RenderCLI.value(args, "--page"), ["emoji", "icons"].contains(page),
              let target = IconTarget(rawValue: RenderCLI.value(args, "--target") ?? "space") else { throw CLIError(description: "picker --page emoji|icons --target space|tab|folder --out FILE") }
        let (owner, picker) = try make(target: target, light: RenderCLI.value(args, "--appearance") == "light")
        defer { picker.close(); owner.close() }
        picker.view.selectPage(page == "icons" ? .icons : .emoji)
        picker.view.wantsLayer = true
        picker.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        OffscreenRenderer.settle(picker.view)
        let scale = Double(RenderCLI.value(args, "--scale") ?? "2") ?? 2
        guard [1.0, 2.0].contains(scale) else { throw CLIError(description: "invalid picker scale") }
        let image = OffscreenRenderer().snapshot(picker.view, scale: scale)
        OffscreenRenderer.writePNG(image, to: URL(fileURLWithPath: output))
        print("picker \(page) \(target.rawValue) rendered \(image.width)x\(image.height)")
    }
    static func click(_ picker: IconPickerController, control: String, index: Int = 0, flags: NSEvent.ModifierFlags = []) {
        guard let rect = picker.view.controlFrame(control, index: index) else { return }
        let point = picker.view.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: picker.panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            picker.panel.sendEvent(event)
        }
    }
    static func key(_ picker: IconPickerController, _ text: String, code: UInt16 = 0) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: picker.panel.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                                    isARepeat: false, keyCode: code)!
        picker.panel.sendEvent(event)
    }
    static func settle(_ seconds: Double = 0.12) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }
    static func check() throws {
        let model = try RenderCLI.fixtureModel()
        let space = model.spaces[0]
        let undo = UndoManager(); undo.groupsByEvent = false; model.undoManager = undo
        let (owner, picker) = try make(current: .named("planet")) { model.setSpaceIcon(id: space.id, icon: $0) }
        defer { picker.close(); owner.close() }
        Checks.check(picker.view.page == .emoji && picker.panel.frame.size == CGSize(width: 246, height: 300), "I1 Space defaults to Emoji; panel 246x300")
        Checks.check(NamedSpaceIcons.order.count == 55 && Set(NamedSpaceIcons.order) == Set(NamedSpaceIcons.symbols.keys), "I1 all 55 icons retain mapping source order")
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 20, nil)
        let shown = picker.view.entries.flatMap { [$0.value] + $0.variants }
        let unsupported = shown.filter { value in
            let text = NSAttributedString(string: value, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
            let runs = CTLineGetGlyphRuns(CTLineCreateWithAttributedString(text)) as! [CTRun]
            guard runs.count == 1, let run = runs.first, CTRunGetGlyphCount(run) == 1,
                  let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName],
                  CFGetTypeID(runFont as CFTypeRef) == CTFontGetTypeID() else { return true }
            return CTFontCopyPostScriptName(runFont as! CTFont) as String != "AppleColorEmoji"
        }
        Checks.check(!shown.isEmpty && unsupported.isEmpty, "I1 picker exposes only single AppleColorEmoji glyphs (shown \(shown.count), unsupported \(unsupported.count))")
        click(picker, control: "icons")
        Checks.check(picker.view.page == .icons, "I1 real segmented-control click opens Icons")
        let selected = picker.view.collection.item(at: IndexPath(item: 31, section: 0))?.view.accessibilityValue() as? String
        Checks.check(selected == "Selected", "I1 current named icon has its selected plate and accessibility state")
        click(picker, control: "item", index: 0); settle()
        Checks.check(space.icon == .named("star") && picker.isClosed, "I1 native grid click stores named icon and closes")
        undo.undo(); Checks.check(space.icon != .named("star"), "I1 named pick participates in model undo")

        let (emojiOwner, emoji) = try make(current: nil) { model.setSpaceIcon(id: space.id, icon: $0) }
        defer { emoji.close(); emojiOwner.close() }
        key(emoji, "grinning face"); settle()
        Checks.check(emoji.view.search.stringValue == "grinning face" && !emoji.view.visibleEntries.isEmpty
                     && emoji.view.visibleEntries.allSatisfy { $0.name.contains("grinning") && $0.name.contains("face") }, "I1 typing enters search; debounced name filter")
        key(emoji, "", code: 125); key(emoji, "\r", code: 36); settle()
        Checks.check(space.icon == .emoji("😀") && emoji.isClosed, "I1 arrows and Return pick the exact emoji sequence")
        let snapshot = SnapshotMapper.dto(from: model)
        let restored = SnapshotMapper.model(from: snapshot)
        Checks.check(restored.space(id: space.id)?.icon == .emoji("😀"), "I1 emoji survives durable snapshot mapping")

        let (emptyOwner, empty) = try make(current: nil)
        defer { empty.close(); emptyOwner.close() }
        key(empty, "noemojiresultxyz"); settle()
        Checks.check(empty.view.visibleEntries.isEmpty && !empty.view.message.isHidden, "I1 empty search has an explicit empty state")
        key(empty, "\u{1B}", code: 53)
        Checks.check(empty.isClosed, "I1 Escape closes from search focus")

        let (folderOwner, folder) = try make(target: .folder, current: .emoji("😀")) { model.setSpaceIcon(id: space.id, icon: $0) }
        defer { folder.close(); folderOwner.close() }
        Checks.check(folder.view.page == .icons && !folder.view.remove.isHidden, "I1 folder defaults to Icons and exposes Remove")
        click(folder, control: "remove"); settle()
        Checks.check(space.icon == nil && folder.isClosed, "I1 Remove stores nil and closes")
        let (toneOwner, tone) = try make(current: nil) { model.setSpaceIcon(id: space.id, icon: $0) }
        defer { tone.close(); toneOwner.close() }
        key(tone, "thumbs up"); settle()
        click(tone, control: "item", flags: .control)
        Checks.check(tone.toneCount == 6, "I1 Control-click opens six native tone buttons")
        tone.toneButton(at: 5)?.performClick(nil); settle()
        Checks.check(space.icon == .emoji("👍🏿") && tone.isClosed, "I1 native tone button stores the exact modified sequence")
        let (closeOwner, closePicker) = try make()
        closeOwner.close(); settle()
        Checks.check(closePicker.isClosed, "I1 owner window close dismisses the picker")
        let index = try EmojiIndex.load()
        Checks.check(index.entries.count + index.entries.reduce(0) { $0 + $1.variants.count } == 3944, "I1 complete pinned fully-qualified Unicode corpus loads")
        let hand = index.entries.first { $0.value == "👍" }
        Checks.check(hand?.tones == ["👍", "👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿"], "I1 six exact Unicode skin-tone sequences")
    }
}
