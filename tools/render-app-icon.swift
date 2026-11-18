// render-app-icon APP OUT.png SCALE LIFT: the system's icon for an application bundle (NSWorkspace, so IconServices
// draws the squircle, rim, glass and shadow), as a 1024 px RGBA PNG, scaled by SCALE about the centre and moved up
// LIFT px. Used by tools/generate-app-icons.sh only.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 5, let scale = Double(arguments[3]), let lift = Double(arguments[4]) else {
  print("usage: render-app-icon APP OUT.png SCALE LIFT"); exit(64)
}
let image = NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: arguments[1]).standardizedFileURL.path)
let side = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
// IconServices fills an icon asynchronously: draw once, let it finish, then draw the image that is kept.
image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
RunLoop.main.run(until: Date().addingTimeInterval(1))
NSColor.clear.set()
NSRect(x: 0, y: 0, width: side, height: side).fill(using: .copy)
let drawn = Double(side) * scale, inset = (Double(side) - drawn) / 2
// AppKit's origin is bottom-left: a positive y moves the icon up.
image.draw(in: NSRect(x: inset, y: inset + lift, width: drawn, height: drawn), from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
// A bundle LaunchServices does not see as an application renders as a document: refuse that.
let data = rep.bitmapData!
let alpha = { (x: Int, y: Int) in Int(data[(y * side + x) * 4 + 3]) }
guard alpha(side / 2, side / 2) == 255, alpha(140, side / 2) == 255, alpha(side - 141, side / 2) == 255 else {
  print("FAIL: \(arguments[1]) did not render as an application icon"); exit(1)
}
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
print("rendered \(arguments[2])")
