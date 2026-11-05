#if OPEN_AUTOMATION
import AppKit
import QuartzCore
import OpenFeatures
import OpenModel
import Darwin

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
            return ["id": split.split?.id.description ?? "", "orientation": split.split?.orientation.rawValue ?? "",
                "fractions": split.split?.fractions ?? [], "focused": split.focusedTab?.id.description ?? "",
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
                return menu.items.map { ["title": $0.title, "enabled": $0.isEnabled] }
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
            var single: [Double] = [], multiple: [Double] = [], singleNative: [Double] = [], multipleNative: [Double] = []
            func select(_ id: ItemID) async throws -> Double {
                let start = CACurrentMediaTime()
                _ = controller.sidebar(controller.sidebar, didRequest: .select(nodeID: id, space: space.id))
                controller.contentView.layoutSubtreeIfNeeded(); CATransaction.flush()
                let native = (CACurrentMediaTime() - start) * 1000
                let focused = factory.model.node(id: id)?.split?.focusedPaneID ?? id
                guard let page = factory.hosts[focused]?.content,
                      try await page.evaluateJavaScript("!document.hidden") as? Bool == true else {
                    throw Failure(message: "selected benchmark page is not visible in the renderer")
                }
                return native
            }
            // Warm hosts first. Measured scope: production selection through native layout
            // and focused renderer visibility acknowledgement, excluding socket transport
            // and physical presentation. This is the plan's live focused-pane budget.
            for id in ids { _ = try await select(id) }
            for _ in 0..<40 {
                for (target, isSplit) in [(ids[1], false), (ids[2], true)] {
                    _ = try await select(ids[0]); let start = CACurrentMediaTime(); let native = try await select(target)
                    let ms = (CACurrentMediaTime() - start) * 1000
                    if isSplit { multiple.append(ms); multipleNative.append(native) }
                    else { single.append(ms); singleNative.append(native) }
                }
            }
            _ = try await select(selected)
            return ["single": single, "split": multiple, "singleNative": singleNative, "splitNative": multipleNative]
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
private final class SplitDraggingInfo: NSObject, @MainActor NSDraggingInfo {
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
