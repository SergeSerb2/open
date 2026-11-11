// Window-only ScreenCaptureKit recorder. Our source, no Arc resources.
import AppKit
import ScreenCaptureKit
import CoreImage
import ImageIO
import AVFoundation

@available(macOS 15.0, *)
final class Sink: NSObject, SCStreamOutput, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
  let directory: URL
  let context = CIContext()
  let lock = NSLock()
  var frames: [[String: Any]] = []
  var errors: [String] = []
  let movie: Bool
  var recordingFinished = false
  init(_ directory: URL, movie: Bool) { self.directory = directory; self.movie = movie }
  func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
    lock.lock(); recordingFinished = true; lock.unlock()
  }
  func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
    lock.lock(); errors.append(error.localizedDescription); recordingFinished = true; lock.unlock()
  }
  func finished() -> Bool { lock.lock(); defer { lock.unlock() }; return recordingFinished }
  func stream(_ stream: SCStream, didStopWithError error: Error) {
    lock.lock(); errors.append(error.localizedDescription); lock.unlock()
  }
  func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen, sample.isValid,
          let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
          let raw = attachments.first?[.status] as? Int, raw == SCFrameStatus.complete.rawValue,
          let buffer = sample.imageBuffer else { return }
    let started = CACurrentMediaTime()
    let name = String(format: "%04d.png", frames.count)
    if !movie {
      let image = CIImage(cvPixelBuffer: buffer)
      guard let cg = context.createCGImage(image, from: image.extent, format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return }
      let url = directory.appendingPathComponent(name)
      guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
      CGImageDestinationAddImage(dest, cg, nil)
      guard CGImageDestinationFinalize(dest) else { return }
    }
    let ended = CACurrentMediaTime()
    lock.lock()
    frames.append(["frame": name, "start": started, "end": ended,
      "presentation_seconds": sample.presentationTimeStamp.seconds,
      "display_time": attachments.first?[.displayTime] as? UInt64 ?? 0,
      "uncertainty": (ended - started) / 2])
    lock.unlock()
  }
  func receipt(_ start: Double, _ fps: Int, _ duration: Double, _ interrupted: Bool) -> [String: Any] {
    lock.lock(); defer { lock.unlock() }
    let times = frames.compactMap { $0["presentation_seconds"] as? Double }
    let span = (times.last ?? 0) - (times.first ?? 0)
    return ["method": movie ? "ScreenCaptureKit own-window movie; decode required" : "ScreenCaptureKit own-window stream", "requested_fps": fps,
      "movie": movie ? "capture.mov" : "",
      "duration": duration, "started_monotonic": start, "interrupted": interrupted,
      "effective_fps": span > 0 ? Double(times.count - 1) / span : 0,
      "frames": frames.map { row in var r = row; r["elapsed"] = (row["start"] as! Double) - start; return r },
      "errors": errors,
      "qualification": "Presentation timestamps are capture-stream observations, not physical display scanout. Static frames may be coalesced."]
  }
}

@main struct CaptureBurst {
  @MainActor static func main() async throws {
    guard #available(macOS 15.0, *) else { exit(2) }
    let a = CommandLine.arguments
    let pid = Int32(a[1])!, number = UInt32(a[2])!, directory = URL(fileURLWithPath: a[3])
    let fps = min(120, max(1, Int(a[4])!)), duration = min(5, Double(a[5])!), scale = Double(a[6])!
    let movie = a.count > 7 && a[7] == "movie"
    guard CGPreflightScreenCaptureAccess(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
          ["company.thebrowser.Browser", "io.github.sergeserb2.open"].contains(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "") else { exit(3) }
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    guard let window = content.windows.first(where: { $0.windowID == number && $0.owningApplication?.processID == pid }) else { exit(3) }
    let config = SCStreamConfiguration()
    config.width = Int(window.frame.width * scale); config.height = Int(window.frame.height * scale)
    config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
    config.queueDepth = 8; config.showsCursor = false; config.capturesAudio = false
    config.ignoreShadowsSingleWindow = true
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.colorSpaceName = CGColorSpace.sRGB
    let sink = Sink(directory, movie: movie), queue = DispatchQueue(label: "open.capture.owned-window")
    let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: sink)
    try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: queue)
    var recording: SCRecordingOutput?
    if movie {
      let output = SCRecordingOutputConfiguration()
      output.outputURL = directory.appendingPathComponent("capture.mov")
      output.videoCodecType = output.availableVideoCodecTypes.contains(.hevc) ? .hevc : .h264
      output.outputFileType = .mov
      let writer = SCRecordingOutput(configuration: output, delegate: sink)
      try stream.addRecordingOutput(writer)
      recording = writer
    }
    try await stream.startCapture()
    let start = CACurrentMediaTime()
    try Data("ready".utf8).write(to: directory.appendingPathComponent("ready"))
    var interrupted = false
    while CACurrentMediaTime() - start < duration {
      if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { interrupted = true; break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try await stream.stopCapture()
    if movie {
      let deadline = CACurrentMediaTime() + 3
      while !sink.finished() && CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(10)) }
      if !sink.finished() { exit(5) }
    }
    withExtendedLifetime(recording) {}
    queue.sync {}
    let receipt = sink.receipt(start, fps, duration, interrupted)
    try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("timestamps.json"))
    if interrupted { exit(4) }
  }
}
