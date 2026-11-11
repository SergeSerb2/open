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
let fieldNames = ["AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXIdentifier", "AXHelp", "AXPlaceholderValue", "AXMenuItemCmdChar", "AXEnabled", "AXFocused", "AXSelected", "AXExpanded", "AXMain", "AXMinimized", "AXMenuItemCmdModifiers", "AXValue", "AXPosition", "AXSize", "AXFont", "AXMenuItemMarkChar", "AXURL"]
func fields(_ e: AXUIElement) -> [String: AnyObject] {
  var result: CFArray?
  AXUIElementCopyMultipleAttributeValues(e, fieldNames as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &result)
  var values: [String: AnyObject] = [:]
  for (key, value) in zip(fieldNames, result as? [AnyObject] ?? []) {
    if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { continue }
    values[key] = value
  }
  return values
}
func describe(_ v: [String: AnyObject]) -> [String: Any] {
  var d: [String: Any] = [:]
  for (key, name) in [("role", "AXRole"), ("subrole", "AXSubrole"), ("title", "AXTitle"), ("desc", "AXDescription"), ("id", "AXIdentifier"), ("help", "AXHelp"), ("placeholder", "AXPlaceholderValue"), ("key", "AXMenuItemCmdChar")] { if let value = v[name] as? String { d[key] = String(value.prefix(2048)) } }
  for (key, name) in [("enabled", "AXEnabled"), ("focused", "AXFocused"), ("selected", "AXSelected"), ("expanded", "AXExpanded"), ("main", "AXMain"), ("minimized", "AXMinimized"), ("keyModifiers", "AXMenuItemCmdModifiers")] { if let value = v[name] as? NSNumber { d[key] = value } }
  if let value = v["AXValue"], CFGetTypeID(value) != AXUIElementGetTypeID() { d["value"] = String(describing: value).prefix(500).description }
  if let value = v["AXURL"] as? URL { d["url"] = String(value.absoluteString.prefix(2048)) }
  if let value = v["AXMenuItemMarkChar"] as? String { d["mark"] = value }
  if let value = v["AXFont"] as? [String: Any] { d["font"] = value.mapValues { String(describing: $0) } }
  if let pv = v["AXPosition"], let sv = v["AXSize"], CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() {
    var p = CGPoint.zero; var s = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &p); AXValueGetValue(sv as! AXValue, .cgSize, &s)
    d["frame"] = [p.x, p.y, s.width, s.height]
  }
  return d
}
struct AXCapture {
  var rows: [[String: Any]] = []
  var elements: [AXUIElement] = []
  var parents: [Int?] = []
  var partial = false
  var elapsed: Double = 0
  var windowQueryError: Int32 = 0
  var depthCap = 12
  var json: [String: Any] {
    var data = rows
    var roots: [[String: Any]] = []
    for i in data.indices.reversed() {
      if let parent = parents[i] {
        var children = data[parent]["children"] as? [[String: Any]] ?? []
        children.insert(data[i], at: 0); data[parent]["children"] = children
      } else { roots.insert(data[i], at: 0) }
    }
    return ["role": "AXApplication", "children": roots, "partial": partial, "elapsed": elapsed, "nodes": rows.count, "depthCap": depthCap, "nodeCap": 1500, "secondsCap": 5, "windowQueryError": windowQueryError]
  }
}
func capture(_ app: AXUIElement, windows: Bool, menus: Bool, shallow: Bool = false, depthCap: Int = 12) -> AXCapture {
  AXUIElementSetMessagingTimeout(app, 2.0)
  let start = ProcessInfo.processInfo.systemUptime
  var queue: [(AXUIElement, Int?, Int)] = []
  var result = AXCapture(), cursor = 0
  result.depthCap = depthCap
  if windows {
    var raw: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &raw)
    result.windowQueryError = status.rawValue
    if status != .success { result.partial = true }
    queue += ((raw as? [AXUIElement]) ?? []).map { ($0, nil, 0) }
  }
  if menus, let menu = attr(app, "AXMenuBar"), CFGetTypeID(menu) == AXUIElementGetTypeID() { queue.append((menu as! AXUIElement, nil, 0)) }
  while cursor < queue.count {
    if result.rows.count >= 1500 || ProcessInfo.processInfo.systemUptime - start >= 5 { result.partial = true; break }
    let (element, parent, depth) = queue[cursor]; cursor += 1
    AXUIElementSetMessagingTimeout(app, Float(min(2, max(0.01, 5 - (ProcessInfo.processInfo.systemUptime - start)))))
    let values = fields(element)
    var row = describe(values)
    row["depth"] = depth
    let index = result.rows.count
    result.rows.append(row); result.elements.append(element); result.parents.append(parent)
    if row["role"] == nil { result.rows[index]["unavailable"] = "AX attributes unavailable"; result.partial = true; continue }
    if row["role"] as? String == "AXWebArea" { result.rows[index]["captureScope"] = "native UI; page descendants omitted"; continue }
    if shallow { continue }
    if depth >= depthCap { result.rows[index]["partialChildren"] = true; result.partial = true; continue }
    if ProcessInfo.processInfo.systemUptime - start >= 5 { result.partial = true; break }
    AXUIElementSetMessagingTimeout(app, Float(min(2, max(0.01, 5 - (ProcessInfo.processInfo.systemUptime - start)))))
    if let children = attr(element, "AXChildren") as? [AXUIElement] {
      let limit = min(children.count, max(0, 1500 - queue.count))
      if limit < children.count { result.partial = true }
      queue += children.prefix(limit).map { ($0, index, depth + 1) }
    }
  }
  result.elapsed = ProcessInfo.processInfo.systemUptime - start
  return result
}
func matches(_ row: [String: Any], _ predicate: [String: Any]) -> Bool {
  for (rawKey, expected) in predicate where rawKey != "index" {
    let key = rawKey == "identifier" ? "id" : rawKey
    let actual = row[key].map { String(describing: $0) } ?? ""
    let wanted = String(describing: expected)
    if wanted.hasPrefix("re:") {
      if actual.range(of: String(wanted.dropFirst(3)), options: [.regularExpression, .caseInsensitive]) == nil { return false }
    } else if actual != wanted { return false }
  }
  return true
}
let a = CommandLine.arguments
switch a[1] {
case "screen-permission":
  emit(["screenRecording": CGPreflightScreenCaptureAccess()])
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
case "ax", "ax-windows", "window-info", "ax-depth":
  let app = AXUIElementCreateApplication(Int32(a[2])!)
  let started = ProcessInfo.processInfo.systemUptime
  let depth = a[1] == "ax-depth" ? min(12, max(0, Int(a[3])!)) : 12
  var result = capture(app, windows: true, menus: a[1] == "ax", shallow: a[1] == "window-info", depthCap: depth).json
  if a[1] == "window-info" {
    let remaining = 5 - (ProcessInfo.processInfo.systemUptime - started)
    if remaining > 0 {
      AXUIElementSetMessagingTimeout(app, Float(min(2, remaining)))
      var main: CFTypeRef?
      let status = AXUIElementCopyAttributeValue(app, "AXMainWindow" as CFString, &main)
      result["mainWindowQueryError"] = status.rawValue
      if status == .cannotComplete { result["partial"] = true }
      let remaining = 5 - (ProcessInfo.processInfo.systemUptime - started)
      if remaining > 0, let main, CFGetTypeID(main) == AXUIElementGetTypeID() {
        AXUIElementSetMessagingTimeout(app, Float(min(2, remaining)))
        result["mainWindow"] = describe(fields(main as! AXUIElement))
      }
    } else { result["partial"] = true }
    result["elapsed"] = ProcessInfo.processInfo.systemUptime - started
  }
  emit(result)
case "clipboard-save":
  let board = NSPasteboard.general
  let published = board.pasteboardItems ?? []
  guard published.count <= 32 else { emit(["error":"clipboard exceeds32 items"]); exit(3) }
  var items: [[String:String]] = [], total = 0
  for item in published {
    guard item.types.count <= 64 else { emit(["error":"clipboard exceeds64 types per item"]); exit(3) }
    var row: [String:String] = [:]
    for type in item.types {
      guard type.rawValue.utf8.count <= 512 else { exit(3) }
      if let bytes = item.data(forType:type) {
        // NSPasteboard materializes a provider's Data before it exposes size.
        // Refuse over12 MiB before making base64/JSON copies (at most16 MiB).
        guard bytes.count <= 12*1024*1024-total else { emit(["error":"clipboard exceeds12 MiB"]); exit(3) }
        total += bytes.count; row[type.rawValue] = bytes.base64EncodedString()
      }
    }
    items.append(row)
  }
  let data = try JSONSerialization.data(withJSONObject: items)
  guard data.count <= 16 * 1024 * 1024 else { emit(["error":"clipboard exceeds private preservation limit"]); exit(3) }
  try data.write(to: URL(fileURLWithPath: a[2]), options: [.atomic])
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: a[2])
  emit(["saved":true])
case "clipboard-set":
  guard a[2].utf8.count <= 2048 else { exit(3) }
  let board = NSPasteboard.general
  board.clearContents(); board.setString(a[2], forType: .string)
  emit(["changeCount":board.changeCount])
case "clipboard-check":
  let board = NSPasteboard.general
  let matches = board.string(forType:.string) == a[2]
  emit(["changeCount":board.changeCount, "matchesExpected":matches])
case "clipboard-restore":
  let board = NSPasteboard.general
  guard board.changeCount == Int(a[3]) else { emit(["restored":false,"reason":"clipboard changed after our paste","currentCount":board.changeCount,"expectedCount":a[3]]); exit(3) }
  let size = try FileManager.default.attributesOfItem(atPath:a[2])[.size] as? NSNumber
  guard let size, size.intValue <= 16*1024*1024 else { emit(["restored":false,"reason":"private clipboard file size unavailable or over limit"]); exit(3) }
  let data = try Data(contentsOf: URL(fileURLWithPath:a[2]))
  guard data.count <= 16 * 1024 * 1024 else { exit(3) }
  guard let rows = try JSONSerialization.jsonObject(with:data) as? [[String:String]], rows.count <= 32 else { emit(["restored":false,"reason":"private clipboard structure invalid"]); exit(3) }
  var items: [NSPasteboardItem] = [], total = 0
  for row in rows {
    guard row.count <= 64 else { exit(3) }
    let item = NSPasteboardItem()
    for (type,value) in row {
      guard type.utf8.count <= 512, let bytes = Data(base64Encoded:value), bytes.count <= 12*1024*1024-total else { exit(3) }
      total += bytes.count; item.setData(bytes,forType:NSPasteboard.PasteboardType(type))
    }
    items.append(item)
  }
  board.clearContents(); if !items.isEmpty { board.writeObjects(items) }
  emit(["restored":true])
case "focused":
  let app = AXUIElementCreateApplication(Int32(a[2])!)
  AXUIElementSetMessagingTimeout(app, 2.0)
  if let raw = attr(app, "AXFocusedUIElement"), CFGetTypeID(raw) == AXUIElementGetTypeID() {
    emit(describe(fields(raw as! AXUIElement)))
  } else { emit(["unavailable": "no focused UI element"]) }
case "manual-accessibility":
  let app = AXUIElementCreateApplication(Int32(a[2])!)
  AXUIElementSetMessagingTimeout(app, 1)
  var setSucceeded = false
  if a.count > 3 {
    guard ["true","false"].contains(a[3]) else { exit(3) }
    let result = AXUIElementSetAttributeValue(app,"AXManualAccessibility" as CFString,a[3] == "true" ? kCFBooleanTrue : kCFBooleanFalse)
    guard result == .success else { emit(["error":result.rawValue]); exit(3) }
    setSucceeded = true
  }
  if let value = attr(app,"AXManualAccessibility") as? NSNumber {
    emit(["value":value.boolValue,"readable":true,"setSucceeded":setSucceeded,"verification":"read-back"])
  } else {
    emit(["value":NSNull(),"readable":false,"setSucceeded":setSucceeded,"original":"unreadable (write-only)","verification":setSucceeded ? "AXSetAttributeValue success" : "getter unreadable"])
  }
case "fixture-web":
  let app = AXUIElementCreateApplication(Int32(a[2])!), expected = a[3]
  guard let expectedURL = URL(string:expected), ["127.0.0.1","localhost"].contains(expectedURL.host ?? ""), expectedURL.scheme == "http" else { exit(3) }
  AXUIElementSetMessagingTimeout(app, 0.3)
  let start = ProcessInfo.processInfo.systemUptime
  guard let root = attr(app,"AXMainWindow"), CFGetTypeID(root) == AXUIElementGetTypeID() else { exit(3) }
  var queue: [(AXUIElement,Int?,Int)] = [(root as! AXUIElement,nil,0)], cursor = 0
  var selected: AXUIElement?, rows: [[String:Any]] = [], parents: [Int?] = []
  var visited = 0, partial = false
  while cursor < queue.count {
    guard visited < 3000, ProcessInfo.processInfo.systemUptime-start < 3 else { partial = true; break }
    let (element,parent,depth) = queue[cursor]; cursor += 1; visited += 1
    AXUIElementSetMessagingTimeout(app,Float(min(0.3,max(0.01,3-(ProcessInfo.processInfo.systemUptime-start)))))
    let values = fields(element), row = describe(values)
    if selected == nil {
      if row["role"] as? String == "AXWebArea" {
        // Never descend into another tab/page, even when it shares this window.
        guard row["url"] as? String == expected else { continue }
        selected = element; queue = [(element,nil,0)]; cursor = 0; continue
      }
    } else {
      var saved = row; saved["depth"] = depth
      rows.append(saved); parents.append(parent)
    }
    if depth >= 30 { partial = true; continue }
    if let children = attr(element,"AXChildren") as? [AXUIElement] {
      let remaining = max(0,3000-visited-(queue.count-cursor)), count = min(children.count,remaining)
      if count < children.count { partial = true }
      let nextParent = selected == nil ? nil : rows.count-1
      queue += children.prefix(count).map { ($0,nextParent,depth+1) }
    }
  }
  guard let selected, describe(fields(selected))["url"] as? String == expected else { emit(["error":"active synthetic AXWebArea unavailable"]); exit(3) }
  var roots: [[String:Any]] = []
  for i in rows.indices.reversed() {
    if let parent = parents[i] { var children = rows[parent]["children"] as? [[String:Any]] ?? []; children.insert(rows[i],at:0); rows[parent]["children"] = children }
    else { roots.insert(rows[i],at:0) }
  }
  emit(["children":roots,"partial":partial,"visited":visited,"elapsed":ProcessInfo.processInfo.systemUptime-start,"depthCap":30,"nodeCap":3000,"secondsCap":3])
case "act":
  let pid = Int32(a[2])!, app = AXUIElementCreateApplication(pid)
  let predicate = try! JSONSerialization.jsonObject(with: Data(a[3].utf8)) as! [String: Any]
  let menu = String(describing: predicate["role"] ?? "").hasPrefix("AXMenu")
  let tree = capture(app, windows: !menu, menus: menu, shallow: predicate["role"] as? String == "AXWindow", depthCap: min(12, max(0, predicate["depth"] as? Int ?? 12)))
  var found = tree.rows.indices.filter { matches(tree.rows[$0], predicate) }
  if let index = predicate["index"] as? Int { found = index >= 0 && index < found.count ? [found[index]] : [] }
  guard found.count == 1 else { emit(["ok": false, "matches": found.count, "partial": tree.partial]); exit(4) }
  let action = a[4], bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
  let textQuit = bundle == "com.apple.TextEdit" && action == "AXPress" && predicate["title"] as? String == "Quit TextEdit"
  let textDiscard = bundle == "com.apple.TextEdit" && action == "AXPress" && predicate["role"] as? String == "AXButton"
    && ["Delete", "Don't Save", "Don’t Save"].contains(predicate["title"] as? String ?? "")
  if textQuit || textDiscard {
    let windows = capture(app, windows: true, menus: false)
    let titles = windows.rows.filter { $0["role"] as? String == "AXWindow" }.compactMap { $0["title"] as? String }
    guard !titles.isEmpty && titles.allSatisfy({ $0.lowercased().hasPrefix("open-capture-synthetic-") }),
      !textDiscard || windows.rows.contains(where: { $0["role"] as? String == "AXSheet" }) else { emit(["ok": false, "error": "TextEdit has an unverified document or sheet"]); exit(3) }
  }
  guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
        bundle == "company.thebrowser.Browser" || textQuit || textDiscard else { emit(["ok": false, "error": "frontmost app changed"]); exit(3) }
  let target = tree.elements[found[0]]
  let result: AXError
  if action == "value" { result = AXUIElementSetAttributeValue(target, "AXValue" as CFString, a[5] as CFString) }
  else if action == "focus" { result = AXUIElementSetAttributeValue(target, "AXFocused" as CFString, kCFBooleanTrue) }
  else if action == "selected" { result = AXUIElementSetAttributeValue(target, "AXSelected" as CFString, kCFBooleanTrue) }
  else { result = AXUIElementPerformAction(target, action as CFString) }
  var available: CFArray?; AXUIElementCopyActionNames(target, &available)
  emit(["ok": result == .success, "result": result.rawValue, "target": tree.rows[found[0]], "actions": available as? [String] ?? [], "partial": tree.partial])
  if result != .success { exit(5) }
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
case "point-guard":
  let pid = Int(a[2])!, point = CGPoint(x: Double(a[3])!, y: Double(a[4])!)
  let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
  let desktopRule = a.count > 5 && a[5] == "lead-m1-desktop-rule" && ProcessInfo.processInfo.hostName.lowercased().hasPrefix("m1-")
  let cursorRule = desktopRule && a.contains("lead-m1-cursor-rule")
  let blocked = Set(["com.apple.usernotificationcenter", "com.apple.securityagent", "com.apple.systempreferences", "com.apple.notificationcenterui", "com.apple.coreservicesuiagent", "com.apple.coreservices.uiagent", "com.apple.universalaccessauthwarn", "com.apple.tccd"])
  let blockedNames = Set(["UserNotificationCenter", "CoreServicesUIAgent", "SecurityAgent", "universalAccessAuthWarn", "System Settings", "tccd"])
  var hits: [[String: Any]] = [], systemWindows: [[String: Any]] = [], ignored: [[String: Any]] = []
  var bannerAtPoint = false
  for row in rows {
    let owner = row[kCGWindowOwnerPID as String] as? Int ?? 0
    let bundle = NSRunningApplication(processIdentifier: Int32(owner))?.bundleIdentifier ?? ""
    let number = row[kCGWindowNumber as String] as? Int ?? 0
    let layer = row[kCGWindowLayer as String] as? Int ?? 0
    let name = row[kCGWindowOwnerName as String] as? String ?? ""
    let rawBounds = row[kCGWindowBounds as String] as? NSDictionary
    let rect = rawBounds.flatMap { CGRect(dictionaryRepresentation:$0 as CFDictionary) }
    let info: [String: Any] = ["number": number, "pid": owner, "bundle": bundle, "owner": name, "layer": layer,"bounds":rawBounds ?? [:]]
    let lower = bundle.lowercased()
    if cursorRule, ["Window Server","WindowServer"].contains(name), layer == 2147483630,
       let rect, rect.width>0, rect.height>0, rect.width<=64, rect.height<=64 {
      ignored.append(info); continue
    }
    if desktopRule && (lower == "com.apple.dock" || (lower == "com.apple.notificationcenterui" && layer < 0)
       || (layer < 0 && (lower == "com.apple.windowmanager" || name == "Window Server" || name == "WindowServer"))) {
      ignored.append(info); continue
    }
    if layer >= 0 && (blocked.contains(lower) || blockedNames.contains(name)) { systemWindows.append(info) }
    if let raw = row[kCGWindowBounds as String] as? NSDictionary,
       let rect = CGRect(dictionaryRepresentation: raw as CFDictionary), rect.contains(point),
       (row[kCGWindowAlpha as String] as? Double ?? 1) > 0 {
      hits.append(info)
      if lower == "com.apple.notificationcenterui", layer >= 0 { bannerAtPoint = true }
    }
  }
  let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
  let ok = Int(front) == pid && systemWindows.isEmpty && (hits.first?["pid"] as? Int) == pid
    && NSRunningApplication(processIdentifier: Int32(pid))?.bundleIdentifier == "company.thebrowser.Browser"
  let retryBanner = bannerAtPoint && !systemWindows.isEmpty && systemWindows.allSatisfy { ($0["bundle"] as? String)?.lowercased() == "com.apple.notificationcenterui" }
  emit(["ok": ok, "frontmostPID": front, "hits": hits, "systemWindows": systemWindows, "ignored": ignored, "retryBanner": retryBanner])
  if !ok { exit(3) }
case "image-alpha-bounds":
  guard let data = try? Data(contentsOf: URL(fileURLWithPath: a[2])), let bitmap = NSBitmapImageRep(data: data) else { exit(3) }
  var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
  for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
    for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
      minX = min(minX,x); minY = min(minY,y); maxX = max(maxX,x); maxY = max(maxY,y)
    }
  }
  emit(["pixels": [bitmap.pixelsWide,bitmap.pixelsHigh], "alphaBounds": maxX < 0 ? [] : [minX,minY,maxX-minX+4,maxY-minY+4], "sampleStride": 4])
case "image-change":
  guard let beforeData = try? Data(contentsOf: URL(fileURLWithPath: a[2])),
        let afterData = try? Data(contentsOf: URL(fileURLWithPath: a[3])),
        let before = NSBitmapImageRep(data: beforeData), let after = NSBitmapImageRep(data: afterData),
        before.pixelsWide == after.pixelsWide, before.pixelsHigh == after.pixelsHigh else { exit(3) }
  var sum = 0.0, count = 0
  for y in stride(from: 0, to: before.pixelsHigh, by: 8) {
    for x in stride(from: 0, to: before.pixelsWide, by: 8) {
      guard let b = before.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
            let c = after.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
      sum += Double(abs(b.redComponent - c.redComponent))
      sum += Double(abs(b.greenComponent - c.greenComponent))
      sum += Double(abs(b.blueComponent - c.blueComponent))
      count += 3
    }
  }
  emit(["meanDifference": count > 0 ? sum / Double(count) : 0, "samples": count])
case "windows":
  let pid = Int(a[2])!
  let rows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
  emit(rows.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }.map { w in
    ["number": w[kCGWindowNumber as String] ?? 0, "bounds": w[kCGWindowBounds as String] ?? [:], "onscreen": w[kCGWindowIsOnscreen as String] ?? false, "layer": w[kCGWindowLayer as String] ?? 0]
  })
default: exit(2)
}
