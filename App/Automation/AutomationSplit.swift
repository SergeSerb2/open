#if OPEN_AUTOMATION
import AppKit
import QuartzCore
import OpenFeatures
import OpenModel
import Darwin
import OpenEngine

extension AutomationController {
    /// Real App surfaces, separate from the legacy `split` toggle used by older suites.
    func splitCommand(_ args: [String: Any], _ factory: EngineWebContentHostFactory) async throws -> Any {
        guard let controller = factory.controller, let window = controller.window else { throw Failure(message: "no browser window") }
        let split = controller.splitController, container = controller.container
        func frame(_ view: NSView) -> [Double] {
            let r = view.convert(view.bounds, to: nil)
            return [r.minX, window.frame.height - r.maxY, r.width, r.height]
        }
        switch args["op"] as? String ?? "state" {
        case "state":
            window.layoutIfNeeded()
            let editor = window.firstResponder as? NSTextView
            let field = editor?.delegate as? NSTextField
            let rename: [String:Any] = field.map { ["text":$0.stringValue,"placeholder":$0.placeholderString ?? "",
                "selection":[editor?.selectedRange().location ?? 0,editor?.selectedRange().length ?? 0]] } ?? [:]
            return ["id": split.split?.id.description ?? "", "orientation": split.split?.orientation.rawValue ?? "",
                "rowPresentation":split.split.flatMap { controller.sidebar.splitRowPresentation(splitID:$0.id) } ?? [:],
                "renameEditor":rename, "fractions": split.split?.fractions ?? [], "focused": split.focusedTab?.id.description ?? "",
                "selected": controller.context.window?.selectedNodeBySpace[controller.context.window!.focusedSpaceID]?.description ?? "",
                "maximized": split.maximizedPaneID?.description ?? "", "container": frame(container), "retainedSlots": container.retainedSlotCount,
                "sidebarURL": controller.sidebar.urlFieldText, "sidebarText": controller.sidebar.displayedURLText, "title": window.title,
                "sidebarCurrent": split.split.map { controller.sidebar.isCurrentRow(nodeID: $0.id) } ?? false,
                "panes": container.slots.map { slot -> [String: Any] in
                    ["id": slot.tabID.description, "frame": frame(slot), "hidden": slot.isHidden,
                     "ring": !slot.focusRing.isHidden, "bar": slot.paneChrome != nil,
                     "host": container.host(for: slot.tabID) != nil]
                }, "dividers": (0..<max(0, container.slots.count - 1)).compactMap { container.divider(at: $0).map(frame) }] as [String: Any]
        case "menu", "plus":
            guard let menu = args["op"] as? String == "plus" ? controller.sidebar.plusMenu() : split.menu() else { throw Failure(message: "no split menu") }
            guard let title = args["item"] as? String else {
                return menu.items.map { ["title": $0.title, "enabled": $0.isEnabled, "separator": $0.isSeparatorItem, "key": $0.keyEquivalent] as [String: Any] }
            }
            guard let index = menu.items.firstIndex(where: { $0.title == title }), menu.items[index].isEnabled else {
                throw Failure(message: "split menu item missing or disabled")
            }
            menu.performActionForItem(at: index)
            return true
        case "drop":
            guard let raw = args["node"] as? String, UUID(uuidString: raw) != nil,
                  let point = args["point"] as? [Double], point.count == 2, point.allSatisfy(\.isFinite) else {
                throw Failure(message: "invalid split drop")
            }
            // NSOutlineView.mouseDown tracks native drag input synchronously. The socket's
            // virtual pointer does not run the WindowServer drag loop. Exercise the actual
            // destination callbacks with the real sidebar pasteboard format instead.
            let info = SplitDraggingInfo(window: window, source: controller.sidebar,
                point: NSPoint(x: point[0], y: window.frame.height - point[1]), node: raw)
            defer { info.draggingPasteboard.releaseGlobally() }
            let entered = container.draggingEntered(info)
            let updated = container.draggingUpdated(info)
            let overlayShown = !container.dropOverlay.isHidden
            let accepted: Bool
            if args["cancel"] as? Bool == true {
                container.draggingExited(info); accepted = false
            } else {
                accepted = container.prepareForDragOperation(info) && container.performDragOperation(info)
                container.concludeDragOperation(info)
            }
            return ["entered": entered.rawValue, "updated": updated.rawValue, "overlayShown": overlayShown,
                "accepted": accepted, "overlayHidden": container.dropOverlay.isHidden,
                "path": "NSDraggingInfo destination callbacks; no WindowServer drag session"] as [String: Any]
        case "bench":
            guard let raw = args["nodes"] as? [String], raw.count == 3,
                  let space = split.space, let selected = split.selected?.id else { throw Failure(message: "bench needs two single tabs and a split") }
            let ids = try raw.map { value -> ItemID in
                guard let uuid = UUID(uuidString: value), factory.model.node(id: ItemID(rawValue: uuid)) != nil else { throw Failure(message: "unknown bench node") }
                return ItemID(rawValue: uuid)
            }
            var samples = Dictionary(uniqueKeysWithValues: ["single", "split", "singleNative", "splitNative",
                "singleSynchronous", "splitSynchronous", "singleRenderer", "splitRenderer", "singleAcknowledged", "splitAcknowledged"].map { ($0, [Double]()) })
            func pages(_ id: ItemID) throws -> [OEWebContent] {
                let tabs = factory.model.node(id: id)?.split?.panes.map(\.id) ?? [id]
                return try tabs.map { tab in
                    guard let page = factory.hosts[tab]?.content else { throw Failure(message: "benchmark host is missing") }
                    return page
                }
            }
            func focusedPage(_ id: ItemID) throws -> OEWebContent {
                let tab = factory.model.node(id: id)?.split?.focusedPaneID ?? id
                guard let page = factory.hosts[tab]?.content else { throw Failure(message: "focused benchmark host is missing") }
                return page
            }
            let read = "({hidden:document.hidden,sequence:window.__openSplitVisible.sequence,painted:window.__openSplitVisible.painted,callback:window.__openSplitVisible.callback})"
            for id in ids {
                for page in try pages(id) {
                    let before = Date().timeIntervalSince1970 * 1000
                    let epoch = try await page.evaluateJavaScript("""
                        (() => {
                          const probe = window.__openSplitVisible = {sequence:0,painted:0,callback:0};
                          document.addEventListener('visibilitychange', () => {
                            if (!document.hidden) {
                              const sequence = ++probe.sequence;
                              probe.painted = 0;
                              requestAnimationFrame(time => {
                                if (!document.hidden && probe.sequence === sequence) {
                                  probe.painted = performance.timeOrigin + time;
                                  probe.callback = performance.timeOrigin + performance.now();
                                }
                              });
                            }
                          });
                          return performance.timeOrigin + performance.now();
                        })()
                        """) as? Double
                    let after = Date().timeIntervalSince1970 * 1000
                    guard let epoch, epoch >= before - 1, epoch <= after + 1 else { throw Failure(message: "renderer/native clocks do not share the measured epoch") }
                }
            }
            func show(_ id: ItemID) -> Double {
                let start = CACurrentMediaTime()
                _ = controller.sidebar(controller.sidebar, didRequest: .select(nodeID: id, space: space.id))
                controller.contentView.layoutSubtreeIfNeeded(); CATransaction.flush()
                return (CACurrentMediaTime() - start) * 1000
            }
            func select(_ id: ItemID) async throws {
                _ = show(id)
                guard try await focusedPage(id).evaluateJavaScript("!document.hidden") as? Bool == true else {
                    throw Failure(message: "selected benchmark page is not visible in the renderer")
                }
            }
            for id in ids { try await select(id) }
            if args["motionOnly"] as? Bool == true {
                func animations() throws -> [[String: Any]] {
                    var result: [[String: Any]] = []
                    var roles: [ObjectIdentifier: String] = [:]
                    for (index, slot) in controller.container.slots.enumerated() {
                        roles[ObjectIdentifier(slot.focusRing)] = "pane\(index).focusRing"
                        if let layer = slot.layer { roles[ObjectIdentifier(layer)] = "pane\(index).slot" }
                        if let layer = slot.paneChrome?.layer { roles[ObjectIdentifier(layer)] = "pane\(index).chrome" }
                    }
                    func collect(_ layer: CALayer?, _ path: String, _ depth: Int) throws {
                        guard let layer else { return }
                        guard depth < 64, result.count < 256 else { throw Failure(message: "motion probe layer limit exceeded") }
                        for key in layer.animationKeys() ?? [] {
                            if let animation = layer.animation(forKey: key) {
                                result.append(["layer": roles[ObjectIdentifier(layer)] ?? path, "key": key,
                                    "keyPath": (animation as? CAPropertyAnimation)?.keyPath ?? "",
                                    "duration": animation.duration, "beginTime": animation.beginTime,
                                    "repeatCount": animation.repeatCount])
                            }
                        }
                        for (index, child) in (layer.sublayers ?? []).enumerated() { try collect(child, path + ".\(index)", depth + 1) }
                    }
                    try collect(controller.container.layer, "container", 0)
                    return result
                }
                var proof: [[String: Any]] = []
                for wrapped in [false, true] {
                    for (target, path) in [(ids[1], "single"), (ids[2], "split")] {
                        try await select(ids[0]); try await Task.sleep(for: .milliseconds(350))
                        if wrapped { CATransaction.begin() }
                        _ = show(target)
                        if wrapped { CATransaction.commit(); CATransaction.flush() }
                        proof.append(["path": path, "addedTransaction": wrapped, "animations": try animations()])
                        try await Task.sleep(for: .milliseconds(350))
                    }
                }
                try await select(selected)
                return ["motion": proof]
            }
            for _ in 0..<40 {
                for (target, prefix) in [(ids[1], "single"), (ids[2], "split")] {
                    try await select(ids[0])
                    let targetPages = try pages(target)
                    var previous: [Double] = []
                    for page in targetPages {
                        guard let value = try await page.evaluateJavaScript(read) as? [String: Any],
                              value["hidden"] as? Bool == true, let sequence = value["sequence"] as? Double else {
                            throw Failure(message: "every benchmark target pane must be hidden before selection")
                        }
                        previous.append(sequence)
                    }
                    let start = CACurrentMediaTime(), epoch = Date().timeIntervalSince1970 * 1000
                    // show() returns after native layout and its existing CA flush.
                    // Do not add a transaction: its completion block waits for animations.
                    let synchronous = show(target)
                    guard try await focusedPage(target).evaluateJavaScript("!document.hidden") as? Bool == true else {
                        throw Failure(message: "focused benchmark page did not become visible")
                    }
                    let acknowledged = (CACurrentMediaTime() - start) * 1000
                    var frames: [Double] = []
                    while true {
                        frames.removeAll(keepingCapacity: true)
                        for (index, page) in targetPages.enumerated() {
                            if let value = try await page.evaluateJavaScript(read) as? [String: Any],
                               value["hidden"] as? Bool == false, let next = value["sequence"] as? Double, next > previous[index],
                               let frame = value["painted"] as? Double, frame > 0,
                               let callback = value["callback"] as? Double, callback >= epoch - 1, frame <= callback + 1 {
                                frames.append(frame)
                            }
                        }
                        if frames.count == targetPages.count { break }
                        guard CACurrentMediaTime() - start < 2 else { throw Failure(message: "missing fresh pane rAF") }
                        try await Task.sleep(for: .milliseconds(1))
                    }
                    let native = synchronous
                    let ready = max(native, frames.max()! - epoch)
                    samples[prefix]!.append(ready); samples[prefix + "Native"]!.append(native)
                    samples[prefix + "Synchronous"]!.append(synchronous); samples[prefix + "Renderer"]!.append(frames.max()! - epoch)
                    samples[prefix + "Acknowledged"]!.append(acknowledged)
                }
            }
            try await select(selected)
            return samples
        case "observe", "idle":
            guard ProcessInfo.processInfo.environment["OPEN_IDLE_OWNER"] == "split" else { throw Failure(message: "split idle observer ownership is not configured") }
            typealias Action = @convention(c) () -> Void
            typealias Watch = @convention(c) (UnsafeMutableRawPointer) -> Void
            typealias Count = @convention(c) (Int32) -> UInt64
            typealias Ready = @convention(c) () -> Int32
            func symbol<T>(_ name: String, _: T.Type) throws -> T {
                guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { throw Failure(message: "split idle observer missing: \(name)") }
                return unsafeBitCast(address, to: T.self)
            }
            let begin = try symbol("open_idle_begin", Action.self), reset = try symbol("open_idle_reset_events", Action.self)
            let end = try symbol("open_idle_end", Action.self), watch = try symbol("open_idle_watch_view", Watch.self)
            let count = try symbol("open_idle_count", Count.self)
            if args["op"] as? String == "observe" { begin(); return true }
            guard try symbol("open_idle_ready", Ready.self)() != 0 else { throw Failure(message: "start split observation before the drag") }
            defer { end() }
            watch(Unmanaged.passUnretained(container).toOpaque())
            controller.contentView.layoutSubtreeIfNeeded(); CATransaction.flush()
            try await Task.sleep(for: .milliseconds(300))
            func animations(_ layer: CALayer?) -> Int {
                guard let layer else { return 0 }
                return (layer.animationKeys()?.count ?? 0) + (layer.sublayers ?? []).reduce(0) { $0 + animations($1) }
            }
            let before = (0..<10).map { count(Int32($0)) }
            let animationsBefore = animations(container.layer)
            reset(); let start = CACurrentMediaTime()
            try await Task.sleep(for: .seconds(5))
            let after = (0..<10).map { count(Int32($0)) }
            return ["before": before, "after": after, "animationsBefore": animationsBefore,
                "animationsAfter": animations(container.layer), "unownedDisplayLinks": count(10),
                "seconds": CACurrentMediaTime() - start] as [String: Any]
        default: throw Failure(message: "unknown split operation")
        }
    }
}

/// The only substituted object is drag transport. The live App's pasteboard decoding,
/// zone hit testing, overlay, model mutation, host ownership and persistence all run.
@MainActor
final class SplitDraggingInfo: NSObject, @MainActor NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingSource: Any?
    let draggingLocation: NSPoint
    let draggingPasteboard = NSPasteboard.withUniqueName()
    let draggingSourceOperationMask: NSDragOperation = .move
    let draggingSequenceNumber = 1
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(window: NSWindow, source: NSView, point: NSPoint, node: String) {
        draggingDestinationWindow = window; draggingSource = source; draggingLocation = point
        super.init()
        draggingPasteboard.setString(node, forType: .init("com.open.sidebar.node"))
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
#endif
