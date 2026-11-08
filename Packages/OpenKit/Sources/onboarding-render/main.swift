import AppKit
import AVFoundation
import OpenOnboarding

@MainActor
func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--check-sound"] {
        guard let url = IntroSound.resourceURL,
              let referenceURL = IntroSound.referenceURL else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.length <= 965_000, file.processingFormat.channelCount == 2,
              file.processingFormat.sampleRate == 48_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
        let referenceData = try Data(contentsOf: referenceURL)
        guard referenceData.count <= 16_384,
              let reference = try JSONSerialization.jsonObject(with: referenceData) as? [String: Any],
              let expected = reference["rmsDBFS"] as? [Double], expected.count == 40 else { throw CocoaError(.fileReadCorruptFile) }
        var curve: [Double] = [], peak = 0.0, tail = 0.0
        let count = Int(buffer.frameLength)
        for begin in stride(from: 0, to: count, by: 24_000) {
            var energy = 0.0
            for i in begin..<min(count, begin+24_000) {
                for channel in 0..<2 {
                    let sample = Double(channels[channel][i]); energy += sample*sample
                    peak = max(peak, abs(sample)); if i >= 936_000 { tail = max(tail, abs(sample)) }
                }
            }
            curve.append(20*log10(max(1e-9, sqrt(energy/Double(min(24_000, count-begin)*2)))))
        }
        let delta = zip(curve.prefix(39), expected.prefix(39)).map { abs($0.0-$0.1) }.max() ?? .infinity
        let ok = abs(Double(count)/48_000-20) <= 0.02 && curve.count == 40 && delta <= 1.5 && tail <= 8.0/32768
        let report: [String: Any] = ["ok": ok, "duration": Double(count)/48_000, "rmsDBFS": curve, "peakDBFS": 20*log10(peak), "maxCurveDeltaDB": delta, "silentTailPeak": tail, "pcmSHA256": reference["pcmSHA256"] ?? ""]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        if !ok { exit(1) }; return
    }
    guard arguments.count == 2, arguments[0] == "--out", !arguments[1].isEmpty, arguments[1].utf8.count <= 4096 else {
        FileHandle.standardError.write(Data("usage: onboarding-render --out DIR | --check-sound\n".utf8)); exit(64)
    }
    let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
    // An unshown window supplies the same AppKit backing and native button.
    // It never activates, orders front, reads another window or plays audio.
    for reduce in [false, true] {
        let view = IntroView(reduceMotion: reduce, scale: 2)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        for time in reduce ? [10.2] : [0.5, 1.5, 2.6, 3.5, 5.0, 6.5, 8.0, 10.2] {
            let name = reduce ? "intro-reduce-motion-final@2x.png" : String(format: "intro-%04.1f@2x.png", time)
            try view.renderPNG(at: time, scale: 2, to: output.appendingPathComponent(name))
            print(output.appendingPathComponent(name).path)
        }
        window.close()
    }
}

do { try MainActor.assumeIsolated { try run() } }
catch { FileHandle.standardError.write(Data("onboarding-render: \(error)\n".utf8)); exit(1) }
