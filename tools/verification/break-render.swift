import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Negative proof only: change the output of the real renderer, never a reference.
guard CommandLine.arguments.count == 3 else { fputs("usage: break-render.swift FILE pixel|color\n", stderr); exit(2) }
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width <= 8192, image.height <= 8192, image.bitsPerPixel == 32,
      image.bitsPerComponent == 8, let space = image.colorSpace,
      let data = image.dataProvider?.data else { fputs("unsupported proof PNG\n", stderr); exit(1) }
var bytes = [UInt8](data as Data)
let firstAlpha = [CGImageAlphaInfo.first, .premultipliedFirst, .noneSkipFirst].contains(image.alphaInfo)
let channel = firstAlpha ? 1 : 0
var changed = 0
switch CommandLine.arguments[2] {
case "pixel":
    let offset = (image.height / 2) * image.bytesPerRow + (image.width / 2) * 4 + channel
    guard offset < bytes.count else { exit(1) }
    bytes[offset] ^= 1
    changed = 1
case "color":
    // One sampled fill: URL field, top-left image coordinates, 120 × 4 pixels.
    for y in 48..<52 { for x in 60..<180 {
        let offset = y * image.bytesPerRow + x * 4 + channel
        guard offset < bytes.count else { exit(1) }
        bytes[offset] = bytes[offset] <= 249 ? bytes[offset] + 6 : bytes[offset] - 6
        changed += 1
    } }
default: exit(2)
}
guard let provider = CGDataProvider(data: Data(bytes) as CFData),
      let altered = CGImage(width: image.width, height: image.height, bitsPerComponent: 8,
                            bitsPerPixel: 32, bytesPerRow: image.bytesPerRow, space: space,
                            bitmapInfo: image.bitmapInfo, provider: provider, decode: nil,
                            shouldInterpolate: false, intent: image.renderingIntent),
      let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(destination, altered, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
print("negative render proof: \(changed) rendered pixels changed; \(CommandLine.arguments[2])")
