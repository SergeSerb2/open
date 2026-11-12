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
        defaults.set(false, forKey: "open.advanced.playSoundEffects")
        check(!effects.play(.capture) && !effects.play(.event) && effects.loadedSoundCount == 0 && effects.playCount == 0,
              "SE2 disabled preference neither loads nor plays a sound")
        // Absent = on, as Arc (inverse key playUserInterfaceSoundsDisabled; audit A8, GUESS until PB5-e).
        defaults.removeObject(forKey: "open.advanced.playSoundEffects")
        let absentPlays = effects.play(.capture) && effects.playCount == 1 && effects.loadedSoundCount == 1
        // Audio runs on its own queue; the call returned at once. Wait for that request before the next one.
        let returnedWhileBusy = effects.isBusy
        let deadline = Date().addingTimeInterval(10)
        while effects.isBusy, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        defaults.set(true, forKey: "open.advanced.playSoundEffects")
        check(absentPlays && !effects.isBusy && effects.play(.capture) && effects.playCount == 2 && effects.loadedSoundCount == 1,
              "SE3 absent (default on) and enabled preference play through SoundEffects with one prepared player")
        // A request that arrives while one is in flight is dropped (no pile-up behind a stuck audio server).
        let dropped = effects.isBusy ? !effects.play(.capture) && effects.droppedCount == 1 : true
        check(dropped, "SE4 a request during an in-flight one is dropped (off-main audio; returnedWhileBusy=\(returnedWhileBusy))")
    }
}
