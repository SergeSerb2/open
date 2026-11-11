// Instrumented uidrive for authorized Arc PERFORMANCE capture only.
// Source: the shared uidrive.swift; only ownership guard and timestamps added.
// uidrive: post mouse and keyboard events for the Arc capture session (user-approved, 2026-10-26).
// Coordinates are global screen points, top-left origin (the same space as arcwins/axframes "screen" frames).
// Usage:
//   uidrive trusted
//   uidrive pos
//   uidrive move X Y
//   uidrive click X Y [left|right] [count]
//   uidrive drag X1 Y1 X2 Y2 [steps]
//   uidrive key NAME [cmd,shift,opt,ctrl]      NAME: return tab space escape delete left right up down home end pageup pagedown f1..f12 or a single character
//   uidrive type TEXT
//   uidrive scroll DY [DX] [X Y]                 line units; positive DY scrolls content down (wheel toward user)
//   uidrive flags MODS DOWN|UP                   hold or release modifier keys (e.g. "opt down")
import ApplicationServices
import AppKit
import Foundation
import Darwin.Mach
func refuse(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(77)
}
var inputEvents: [[String: Any]] = []
let ownedPID = ProcessInfo.processInfo.environment["OPEN_PERF_ARC_PID"].flatMap(Int32.init)
guard let ownedPID, NSRunningApplication.runningApplications(withBundleIdentifier: "company.thebrowser.Browser").contains(where: { $0.processIdentifier == ownedPID && $0.isActive }) else { refuse("Exact owned Arc must be active") }
guard AXIsProcessTrusted() else { refuse("Accessibility preflight denied; no prompt requested") }


let src = CGEventSource(stateID: .hidSystemState)

func post(_ e: CGEvent?) {
    guard let e else { return }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ownedPID else {
        refuse("Owned Arc lost foreground; no further input posted")
    }
    let stamp = mach_absolute_time()
    e.post(tap: .cghidEventTap)
    inputEvents.append(["ticks": stamp, "event_type": e.type.rawValue, "event_timestamp_ns": e.timestamp])
}
func pause(_ s: Double) { usleep(useconds_t(s * 1_000_000)) }

func mods(_ s: String?) -> CGEventFlags {
    var f: CGEventFlags = []
    for m in (s ?? "").split(separator: ",") {
        switch m.lowercased() {
        case "cmd", "command": f.insert(.maskCommand)
        case "shift": f.insert(.maskShift)
        case "opt", "option", "alt": f.insert(.maskAlternate)
        case "ctrl", "control": f.insert(.maskControl)
        default: break
        }
    }
    return f
}

let keyCodes: [String: CGKeyCode] = [
    "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "esc": 53,
    "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
    "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
    "n": 45, "m": 46, ".": 47, "`": 50,
]

func point(_ x: String, _ y: String) -> CGPoint { CGPoint(x: Double(x) ?? 0, y: Double(y) ?? 0) }

func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton, clicks: Int64 = 1, flags: CGEventFlags = []) {
    let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button)
    e?.setIntegerValueField(.mouseEventClickState, value: clicks)
    if !flags.isEmpty { e?.flags = flags }
    post(e)
}

let a = CommandLine.arguments
guard a.count >= 2 else { print("see header"); exit(2) }
switch a[1] {
case "trusted":
    print(AXIsProcessTrusted() ? "trusted" : "NOT trusted")
case "pos":
    let p = CGEvent(source: nil)?.location ?? .zero
    print("\(Int(p.x)) \(Int(p.y))")
case "move":
    mouse(.mouseMoved, point(a[2], a[3]), .left)
case "click":
    let p = point(a[2], a[3])
    let right = a.count > 4 && a[4] == "right"
    let count = a.count > 5 ? Int(a[5]) ?? 1 : 1
    let flags = mods(a.count > 6 ? a[6] : nil)
    mouse(.mouseMoved, p, .left, flags: flags); pause(0.05)
    for i in 1...count {
        mouse(right ? .rightMouseDown : .leftMouseDown, p, right ? .right : .left, clicks: Int64(i), flags: flags); pause(0.04)
        mouse(right ? .rightMouseUp : .leftMouseUp, p, right ? .right : .left, clicks: Int64(i), flags: flags); pause(0.06)
    }
case "hoverclick":
    // Rest on the target first (menus highlight on hover), then click with longer holds.
    let p = point(a[2], a[3])
    let right = a.count > 4 && a[4] == "right"
    mouse(.mouseMoved, CGPoint(x: p.x - 3, y: p.y), .left); pause(0.15)
    mouse(.mouseMoved, p, .left); pause(0.35)
    mouse(.mouseMoved, CGPoint(x: p.x + 1, y: p.y), .left); pause(0.15)
    mouse(right ? .rightMouseDown : .leftMouseDown, p, right ? .right : .left); pause(0.12)
    mouse(right ? .rightMouseUp : .leftMouseUp, p, right ? .right : .left)
case "down":
    let p = point(a[2], a[3]); mouse(.mouseMoved, p, .left); pause(0.05); mouse(.leftMouseDown, p, .left)
case "dragto":
    // Continue a held left-button drag from the current position to X Y in STEPS steps over SECONDS.
    let p2 = point(a[2], a[3]); let steps = a.count > 4 ? Int(a[4]) ?? 20 : 20; let secs = a.count > 5 ? Double(a[5]) ?? 1 : 1
    let p1 = CGEvent(source: nil)?.location ?? p2
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        mouse(.leftMouseDragged, CGPoint(x: p1.x + (p2.x - p1.x) * t, y: p1.y + (p2.y - p1.y) * t), .left); pause(secs / Double(steps))
    }
case "up":
    let p = CGEvent(source: nil)?.location ?? .zero; mouse(.leftMouseUp, p, .left)
case "drag":
    let p1 = point(a[2], a[3]), p2 = point(a[4], a[5])
    let steps = a.count > 6 ? Int(a[6]) ?? 20 : 20
    mouse(.mouseMoved, p1, .left); pause(0.05)
    mouse(.leftMouseDown, p1, .left); pause(0.15)
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        mouse(.leftMouseDragged, CGPoint(x: p1.x + (p2.x - p1.x) * t, y: p1.y + (p2.y - p1.y) * t), .left); pause(0.02)
    }
    pause(0.15); mouse(.leftMouseUp, p2, .left)
case "key":
    let name = a[2].lowercased()
    guard let code = keyCodes[name] else { print("unknown key \(name)"); exit(2) }
    let f = mods(a.count > 3 ? a[3] : nil)
    let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true); d?.flags = f; post(d); pause(0.03)
    let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false); u?.flags = f; post(u)
    if !f.isEmpty { pause(0.03); let r = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: false); r?.type = .flagsChanged; r?.flags = []; post(r) }
case "type":
    for ch in a[2...].joined(separator: " ").utf16 {
        var c = ch
        let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true); d?.flags = []; d?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c); post(d)
        let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false); u?.flags = []; u?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c); post(u)
        pause(0.02)
    }
case "scroll":
    let dy = Int32(a[2]) ?? 0
    let dx = a.count > 3 ? Int32(a[3]) ?? 0 : 0
    if a.count > 5 { mouse(.mouseMoved, point(a[4], a[5]), .left); pause(0.05) }
    post(CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 2, wheel1: -dy, wheel2: dx, wheel3: 0))
case "wheel":
    let dy = Int32(a[2]) ?? 0, dx = Int32(a[3]) ?? 0
    let p = point(a[4], a[5])
    let phase = Int64(a[6]) ?? 2
    let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
    e?.location = p
    e?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e?.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    e?.setIntegerValueField(.scrollWheelEventMomentumPhase, value: a.count > 7 ? Int64(a[7]) ?? 0 : 0)
    post(e)
case "wheel-script":
    let bytes = try! Data(contentsOf: URL(fileURLWithPath: a[2]))
    let script = try! JSONSerialization.jsonObject(with: bytes) as! [[String: Any]]
    let start = ProcessInfo.processInfo.systemUptime
    for step in script {
        let at = (step["at_ms"] as! NSNumber).doubleValue / 1000
        let remaining = start + at - ProcessInfo.processInfo.systemUptime
        if remaining > 0 { pause(remaining) }
        let point = step["point"] as! [Double]
        let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
          wheel1: (step["dy"] as! NSNumber).int32Value, wheel2: (step["dx"] as! NSNumber).int32Value, wheel3: 0)
        e?.location = CGPoint(x: point[0], y: point[1])
        e?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e?.setIntegerValueField(.scrollWheelEventScrollPhase, value: (step["phase"] as! NSNumber).int64Value)
        e?.setIntegerValueField(.scrollWheelEventMomentumPhase, value: (step["momentum"] as! NSNumber).int64Value)
        post(e)
    }
case "wheel-sequence":
    let dy = Int32(a[2]) ?? 0, dx = Int32(a[3]) ?? 0, p = point(a[4], a[5])
    let count = Int(a[6]) ?? 180, hz = Double(a[7]) ?? 240
    guard count > 0 && count <= 720 && hz > 0 && hz <= 240 else { exit(2) }
    for i in 0...count {
        let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: i == count ? 0 : dy, wheel2: i == count ? 0 : dx, wheel3: 0)
        e?.location = p
        e?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e?.setIntegerValueField(.scrollWheelEventScrollPhase, value: i == 0 ? 1 : i == count ? 4 : 2)
        post(e); pause(1/hz)
    }
case "flags":
    // Hold or release modifiers by posting flagsChanged with the modifier key codes.
    let f = mods(a[2]); let down = a.count > 3 && a[3].lowercased() == "down"
    let codes: [(CGEventFlags, CGKeyCode)] = [(.maskCommand, 55), (.maskShift, 56), (.maskAlternate, 58), (.maskControl, 59)]
    for (flag, code) in codes where f.contains(flag) {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
        e?.type = .flagsChanged; e?.flags = down ? f : []; post(e)
    }
default:
    print("unknown command"); exit(2)
}

let receipt = try! JSONSerialization.data(withJSONObject: ["events": inputEvents], options: [.sortedKeys])
FileHandle.standardOutput.write(receipt)
FileHandle.standardOutput.write(Data([10]))
