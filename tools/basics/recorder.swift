// Basics clip recorder: one Open window region, ScreenCaptureKit, native scale,
// into a ProRes 422 HQ movie plus per-frame host-clock timestamps. Our source only.
// It never posts input, moves windows or activates apps. Run through the fixed,
// already approved pixel launcher on the M1 (tools/capture/pixels.sh).
//
//   recorder PID WINDOW_NUMBER OUT_DIR SECONDS SCALE X Y W H
//   (X Y W H: points in the window, top-left origin)
import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

final class Sink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  let writer: AVAssetWriter
  let input: AVAssetWriterInput
  private let lock = NSLock()
  private var started = false
  private var frames: [[String: Double]] = []
  private var failure: String?
  init(url: URL, width: Int, height: Int) throws {
    writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.proRes422HQ, AVVideoWidthKey: width, AVVideoHeightKey: height])
    input.expectsMediaDataInRealTime = true
    writer.add(input)
    super.init()
  }
  func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen, sample.isValid,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    lock.lock(); defer { lock.unlock() }
    if !started { writer.startWriting(); writer.startSession(atSourceTime: pts); started = true }
    if input.isReadyForMoreMediaData {
      if input.append(sample) { frames.append(["hostSeconds": pts.seconds]) }
      else { failure = writer.error.map { "\($0)" } ?? "append failed" }
    } else { frames.append(["hostSeconds": pts.seconds, "dropped": 1]) }
  }
  func stream(_ stream: SCStream, didStopWithError error: any Error) { lock.lock(); failure = "\(error)"; lock.unlock() }
  private func snapshot() -> (Bool, [[String: Double]], String?) {
    lock.withLock { (started, frames, failure) }
  }
  func finish() async -> ([[String: Double]], String?) {
    if snapshot().0 { input.markAsFinished(); await writer.finishWriting() }
    let (_, frames, failure) = snapshot()
    return (frames, failure ?? (writer.status == .failed ? "\(String(describing: writer.error))" : nil))
  }
}

@main struct BasicsRecorder {
  @MainActor static func main() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let a = CommandLine.arguments
    guard a.count == 10, let pid = Int32(a[1]), let number = UInt32(a[2]), let seconds = Double(a[4]), let scale = Double(a[5]),
      let x = Double(a[6]), let y = Double(a[7]), let w = Double(a[8]), let h = Double(a[9]), seconds <= 30 else {
      FileHandle.standardError.write(Data("usage: recorder PID WINDOW OUT SECONDS SCALE X Y W H\n".utf8)); exit(2)
    }
    let directory = URL(fileURLWithPath: a[3])
    guard CGPreflightScreenCaptureAccess(),
      NSRunningApplication(processIdentifier: pid)?.bundleIdentifier?.hasPrefix("io.github.sergeserb2.open") == true else { exit(3) }
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    guard let window = content.windows.first(where: { $0.windowID == number && $0.owningApplication?.processID == pid }) else { exit(3) }
    // A display filter with this app's windows only, cropped to the browser
    // window: tooltips and popovers (their own windows) show as on screen, and
    // transparent child windows (the sidebar drop rails) cannot shift the frame.
    guard let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)) }) else { exit(3) }
    let config = SCStreamConfiguration()
    config.sourceRect = CGRect(x: window.frame.minX - display.frame.minX + x, y: window.frame.minY - display.frame.minY + y, width: w, height: h)
    config.width = Int(w * scale); config.height = Int(h * scale)
    config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    config.queueDepth = 8; config.showsCursor = false; config.capturesAudio = false
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.colorSpaceName = CGColorSpace.sRGB
    config.backgroundColor = .clear
    let sink = try Sink(url: directory.appendingPathComponent("capture.mov"), width: config.width, height: config.height)
    guard let app = content.applications.first(where: { $0.processID == pid }) else { exit(3) }
    let stream = SCStream(filter: SCContentFilter(display: display, including: [app], exceptingWindows: []), configuration: config, delegate: sink)
    try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "open.basics.recorder"))
    try await stream.startCapture()
    let start = CACurrentMediaTime()
    try Data("\(start)".utf8).write(to: directory.appendingPathComponent("ready"))
    try await Task.sleep(for: .seconds(seconds))
    try? await stream.stopCapture()
    let (frames, failure) = await sink.finish()
    let receipt: [String: Any] = ["startHostSeconds": start, "seconds": seconds, "scale": scale,
      "sourceRect": [x, y, w, h], "pixels": [config.width, config.height], "frames": frames,
      "failure": failure ?? NSNull(), "clock": "CMClock host time (mach absolute), same as CACurrentMediaTime"]
    try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
      .write(to: directory.appendingPathComponent("timestamps.json"))
    exit(failure == nil && !frames.isEmpty ? 0 : 4)
  }
}
