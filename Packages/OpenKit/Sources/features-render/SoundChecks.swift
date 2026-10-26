import AVFoundation
import Foundation
import OpenFeatures

@MainActor
enum SoundChecks {
    static func run(_ check: (Bool, String) -> Void) throws {
        for effect in SoundEffects.Effect.allCases {
            guard let url = SoundEffects.resourceURL(for: effect) else { throw CLIError(description: "SE1 missing \(effect) sound resource") }
            let player = try AVAudioPlayer(contentsOf: url)
            let file = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                throw CLIError(description: "SE1 sound buffer unavailable")
            }
            try file.read(into: buffer)
            guard let samples = buffer.floatChannelData else { throw CLIError(description: "SE1 sound samples unavailable") }
            var peak = 0.0
            for channel in 0..<Int(buffer.format.channelCount) {
                for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(Double(samples[channel][index]))) }
            }
            let duration = effect == .capture ? 0.45 : 1.1
            let expectedPeak = pow(10, (effect == .capture ? -6.0 : -8.0) / 20)
            check(abs(player.duration - duration) <= duration * 0.05 && abs(peak - expectedPeak) <= expectedPeak * 0.05
                  && file.processingFormat.sampleRate == 48_000,
                  String(format: "SE1 %@ loads from bundle: %.3f s, peak %.3f dBFS", effect.rawValue, player.duration, 20 * log10(peak)))
        }
        let suite = "open.sound-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let effects = SoundEffects(defaults: defaults)
        let absent = !effects.play(.capture) && !effects.play(.event)
        defaults.set(false, forKey: "open.advanced.playSoundEffects")
        check(absent && !effects.play(.capture) && !effects.play(.event) && effects.loadedSoundCount == 0 && effects.playCount == 0,
              "SE2 disabled/absent preference neither loads nor plays a sound")
        defaults.set(true, forKey: "open.advanced.playSoundEffects")
        check(effects.play(.capture) && effects.playCount == 1 && effects.loadedSoundCount == 1,
              "SE3 enabled preference plays once through SoundEffects and loads one prepared player")
    }
}
