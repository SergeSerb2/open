// Space-switch frame statistics for one Open window region. Our source only.
// ScreenCaptureKit display capture of this app only, cropped to a region of
// the page (macOS may mark the shared window over its traffic lights; that is
// outside the region). It writes numbers only, one
// JSON line per complete frame, never pixels, and sends no input.
//
//   space-frames PID WINDOW_NUMBER OUT_FILE SECONDS X Y W H
//   (X Y W H: points in the window, top-left origin)
//
// Per frame: host time (mach, seconds), mean and standard deviation of luma
// (0-255), the fraction of near-white pixels, and inkX: the first column, in
// points from the region's left edge, with a dark text pixel (luma < 100).
import AppKit
import CoreMedia
import ScreenCaptureKit

final class Sink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  let handle: FileHandle
  let scale: Double
  private let lock = NSLock()
  private var failure: String?
  init(handle: FileHandle, scale: Double) { self.handle = handle; self.scale = scale }
  func emit(_ value: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
    lock.withLock { handle.write(data); handle.write(Data("\n".utf8)) }
  }
  func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen, sample.isValid,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
      let pixel = CMSampleBufferGetImageBuffer(sample) else { return }
    CVPixelBufferLockBaseAddress(pixel, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixel) else { return }
    let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel), row = CVPixelBufferGetBytesPerRow(pixel)
    var sum = 0.0, squares = 0.0, white = 0, count = 0, ink = Int.max
    for y in stride(from: 0, to: height, by: 2) {
      let line = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self)
      for x in stride(from: 0, to: width, by: 2) {
        let p = line + x * 4  // BGRA
        let luma = 0.0722 * Double(p[0]) + 0.7152 * Double(p[1]) + 0.2126 * Double(p[2])
        sum += luma; squares += luma * luma; count += 1
        if luma > 250 { white += 1 }
        if luma < 100, x < ink { ink = x }
      }
    }
    guard count > 0 else { return }
    let mean = sum / Double(count)
    emit(["host": CMSampleBufferGetPresentationTimeStamp(sample).seconds, "mean": mean,
      "std": max(0, squares / Double(count) - mean * mean).squareRoot(),
      "white": Double(white) / Double(count), "inkX": ink == Int.max ? NSNull() : Double(ink) / scale as Any])
  }
  func stream(_ stream: SCStream, didStopWithError error: any Error) { lock.withLock { failure = "\(error)" } }
  var error: String? { lock.withLock { failure } }
}

@main struct SpaceFrames {
  @MainActor static func main() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let a = CommandLine.arguments
    guard a.count == 9, let pid = Int32(a[1]), let number = UInt32(a[2]), let seconds = Double(a[4]),
      let x = Double(a[5]), let y = Double(a[6]), let w = Double(a[7]), let h = Double(a[8]),
      seconds > 0, seconds <= 10, w >= 4, h >= 4 else {
      FileHandle.standardError.write(Data("usage: space-frames PID WINDOW OUT SECONDS X Y W H\n".utf8)); exit(2)
    }
    guard CGPreflightScreenCaptureAccess() else { exit(3) }
    FileManager.default.createFile(atPath: a[3], contents: nil)
    guard let handle = FileHandle(forWritingAtPath: a[3]) else { exit(2) }
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    guard let window = content.windows.first(where: { $0.windowID == number && $0.owningApplication?.processID == pid }),
      let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)) })
    else { exit(3) }
    let scale = NSScreen.screens.first(where: { $0.frame.width == display.frame.width })?.backingScaleFactor ?? 2
    let config = SCStreamConfiguration()
    config.sourceRect = CGRect(x: window.frame.minX - display.frame.minX + x, y: window.frame.minY - display.frame.minY + y, width: w, height: h)
    config.width = Int(w * scale); config.height = Int(h * scale)
    config.minimumFrameInterval = .zero
    config.queueDepth = 8; config.showsCursor = false; config.capturesAudio = false
    config.pixelFormat = kCVPixelFormatType_32BGRA; config.colorSpaceName = CGColorSpace.sRGB
    let sink = Sink(handle: handle, scale: scale)
    // "Excluding every other app" drops Open's own window on the M5; "including
    // this app" shows it on both Macs.
    let stream = SCStream(filter: SCContentFilter(display: display, including: content.applications.filter { $0.processID == pid },
      exceptingWindows: []),
      configuration: config, delegate: sink)
    try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "open.space-frames"))
    try await stream.startCapture()
    sink.emit(["event": "ready", "host": CACurrentMediaTime(), "scale": scale])
    try await Task.sleep(for: .seconds(seconds))
    try? await stream.stopCapture()
    sink.emit(["event": "done", "error": sink.error ?? NSNull()])
    try? handle.close()
    exit(sink.error == nil ? 0 : 4)
  }
}
