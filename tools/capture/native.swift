// Our own read-only AX/state helper. No Arc code or resources.
import AppKit
import ApplicationServices

func emit(_ value: Any) {
  let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  FileHandle.standardOutput.write(data)
}
func attr(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
  var value: CFTypeRef?
  return AXUIElementCopyAttributeValue(e, key as CFString, &value) == .success ? value : nil
}
var nodeBudget = 1800
func node(_ e: AXUIElement, _ depth: Int = 0) -> [String: Any] {
  nodeBudget -= 1
  guard nodeBudget >= 0 else { return ["truncated": "native AX node budget"] }
  AXUIElementSetMessagingTimeout(e, 0.2)
  var d: [String: Any] = [:]
  for (key, name) in [("role", "AXRole"), ("subrole", "AXSubrole"), ("title", "AXTitle"), ("desc", "AXDescription"), ("id", "AXIdentifier"), ("help", "AXHelp"), ("placeholder", "AXPlaceholderValue"), ("key", "AXMenuItemCmdChar")] {
    if let value = attr(e, name) as? String { d[key] = value }
  }
  for (key, name) in [("enabled", "AXEnabled"), ("focused", "AXFocused"), ("selected", "AXSelected"), ("expanded", "AXExpanded"), ("main", "AXMain"), ("minimized", "AXMinimized"), ("keyModifiers", "AXMenuItemCmdModifiers")] {
    if let value = attr(e, name) as? NSNumber { d[key] = value }
  }
  if let value = attr(e, "AXValue"), CFGetTypeID(value) != AXUIElementGetTypeID() { d["value"] = String(describing: value).prefix(500).description }
  if ["AXStaticText", "AXTextField", "AXTextArea"].contains(d["role"] as? String ?? ""),
     let value = attr(e, "AXFont") as? [String: Any] { d["font"] = value.mapValues { String(describing: $0) } }
  if let pv = attr(e, "AXPosition"), let sv = attr(e, "AXSize"), CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() {
    var p = CGPoint.zero; var s = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &p); AXValueGetValue(sv as! AXValue, .cgSize, &s)
    d["frame"] = [p.x, p.y, s.width, s.height]
  }
  if d["role"] as? String == "AXWebArea" { d["captureScope"] = "native UI; page descendants omitted" }
  else if depth < 30, nodeBudget > 0, let children = attr(e, "AXChildren") as? [AXUIElement] { d["children"] = children.prefix(1000).map { node($0, depth + 1) } }
  return d
}
let a = CommandLine.arguments
switch a[1] {
case "state":
  let front = NSWorkspace.shared.frontmostApplication
  let p = CGEvent(source: nil)?.location ?? .zero
  let screens = NSScreen.screens.map { s -> [String: Any] in
    let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
    let mode = CGDisplayCopyDisplayMode(id)
    let profile = s.colorSpace?.iccProfileData
    return ["id": id, "name": s.localizedName, "frame": [s.frame.minX, s.frame.minY, s.frame.width, s.frame.height], "scale": s.backingScaleFactor, "refreshHz": mode?.refreshRate ?? 0, "colorSpace": s.colorSpace?.localizedName ?? "unknown", "iccBase64": profile?.base64EncodedString() ?? ""]
  }
  emit(["frontmostPID": front?.processIdentifier ?? 0, "frontmostBundle": front?.bundleIdentifier ?? "", "pointer": [p.x, p.y], "screens": screens, "trusted": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess()])
case "activate", "quit":
  guard let pid = Int32(a[2]), let app = NSRunningApplication(processIdentifier: pid) else { exit(2) }
  if a[1] == "quit" { guard app.bundleIdentifier == "company.thebrowser.Browser" else { exit(3) }; emit(["requested": app.terminate()]) }
  else { emit(["requested": app.activate()]) }
case "ax", "ax-windows":
  let app = AXUIElementCreateApplication(Int32(a[2])!)
  AXUIElementSetMessagingTimeout(app, 0.2)
  if a[1] == "ax-windows" {
    emit(((attr(app, "AXWindows") as? [AXUIElement]) ?? []).map { node($0) })
  } else {
    var children = ((attr(app, "AXWindows") as? [AXUIElement]) ?? []).map { node($0) }
    if let menu = attr(app, "AXMenuBar"), CFGetTypeID(menu) == AXUIElementGetTypeID() { children.append(node(menu as! AXUIElement)) }
    emit(["role": "AXApplication", "children": children])
  }
case "set-frame":
  let pid = Int32(a[2])!
  guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "company.thebrowser.Browser",
        let window = attr(AXUIElementCreateApplication(pid), "AXFocusedWindow"),
        CFGetTypeID(window) == AXUIElementGetTypeID() else { exit(3) }
  let target = window as! AXUIElement
  guard (attr(target, "AXSubrole") as? String) == "AXStandardWindow" else { exit(3) }
  var p = CGPoint(x: Double(a[3])!, y: Double(a[4])!)
  var s = CGSize(width: Double(a[5])!, height: Double(a[6])!)
  let sizeResult = AXUIElementSetAttributeValue(target, "AXSize" as CFString, AXValueCreate(.cgSize, &s)!)
  let positionResult = AXUIElementSetAttributeValue(target, "AXPosition" as CFString, AXValueCreate(.cgPoint, &p)!)
  emit(["sizeResult": sizeResult.rawValue, "positionResult": positionResult.rawValue])
case "windows":
  let pid = Int(a[2])!
  let rows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
  emit(rows.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }.map { w in
    ["number": w[kCGWindowNumber as String] ?? 0, "bounds": w[kCGWindowBounds as String] ?? [:], "onscreen": w[kCGWindowIsOnscreen as String] ?? false, "layer": w[kCGWindowLayer as String] ?? 0]
  })
default: exit(2)
}
