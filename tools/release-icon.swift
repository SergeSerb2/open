// File metadata only. No app activation, mouse, keyboard or Finder scripting.
import AppKit
import UniformTypeIdentifiers

// Fixed 128 px RGBA readback: 65,536 bytes per bitmap. Inputs are local build artifacts.
func bitmap(_ image: NSImage) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 512, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128), from: .zero,
               operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
    let x = a.bitmapData!, y = b.bitmapData!
    return (0..<(128 * 128 * 4)).reduce(0.0) { $0 + abs(Double(x[$1]) - Double(y[$1])) } / Double(128 * 128 * 4)
}
let args = CommandLine.arguments
// `bounds PATH`: opaque bounds (alpha > 50 %) of a PNG, or of the system's icon for an app bundle, drawn at 1024 px.
// One 1024 px RGBA bitmap: 4 MiB. Prints JSON [minX, minY, maxX, maxY] (exclusive max, top-left origin).
if args.count == 3 && args[1] == "bounds" {
    let image = args[2].hasSuffix(".png") ? NSImage(contentsOfFile: args[2]) : NSWorkspace.shared.icon(forFile: args[2])
    guard let image else { print("FAIL: cannot read \(args[2])"); exit(1) }
    let side = 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.bitmapData!
    var minX = side, minY = side, maxX = 0, maxY = 0
    for y in 0..<side { for x in 0..<side where data[(y * side + x) * 4 + 3] > 128 {
        minX = min(minX, x); maxX = max(maxX, x + 1); minY = min(minY, y); maxY = max(maxY, y + 1) } }
    print("[\(minX), \(minY), \(maxX), \(maxY)]")
    exit(0)
}
func fail(_ message: String) -> Never { print("FAIL: \(message)"); exit(1) }
guard (args.count == 4 || args.count == 5), let expected = NSImage(contentsOfFile: args[3]) else { fail("usage: release-icon set|check|compare path icon.icns [proof.png]") }
if args[1] == "set" {
    guard NSWorkspace.shared.setIcon(expected, forFile: args[2], options: []) else { fail("NSWorkspace.setIcon") }
} else if args[1] != "check" && args[1] != "compare" { fail("unknown operation") }
let actualImage: NSImage
if args[1] == "compare" {
    guard let loaded = NSImage(contentsOfFile: args[2]) else { fail("cannot read icon image") }
    actualImage = loaded
} else { actualImage = NSWorkspace.shared.icon(forFile: args[2]) }
let actual = bitmap(actualImage)
let generic = bitmap(NSWorkspace.shared.icon(for: .application))
let delta = difference(actual, bitmap(expected)), genericDelta = difference(actual, generic)
if args.count == 5 {
    try actual.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[4]))
}
let origin = args[1] == "compare" ? "Native app icon pixels" : "NSWorkspace icon"
print("\(origin): expected mean pixel delta=\(delta); generic application delta=\(genericDelta)")
guard (args[1] == "compare" ? delta == 0 : delta < 3), genericDelta > 5 else { fail("icon does not match Open artwork or is the generic app icon") }
print("PASS: \(origin) verified")
