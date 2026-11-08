import AVFoundation
import Foundation

/// Open's generated effects. No resource or audio player is loaded at launch.
@MainActor
public final class SoundEffects {
    public enum Effect: String, CaseIterable, Sendable { case capture, event }
    public static let shared = SoundEffects()
    private let defaults: UserDefaults
    private var players: [Effect: AVAudioPlayer] = [:]
    public private(set) var playCount = 0
    public var loadedSoundCount: Int { players.count }

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public static func resourceURL(for effect: Effect) -> URL? {
        Bundle.module.url(forResource: "open-\(effect.rawValue)", withExtension: "caf", subdirectory: "Sounds")
    }

    /// Reads the existing app preference at use. The default remains off (lead Q6).
    /// The general event effect has no production caller until its trigger is captured.
    @discardableResult
    public func play(_ effect: Effect) -> Bool {
        guard defaults.object(forKey: "open.advanced.playSoundEffects") as? Bool == true else { return false }
        let player: AVAudioPlayer
        if let loaded = players[effect] { player = loaded }
        else {
            guard let url = Self.resourceURL(for: effect), let loaded = try? AVAudioPlayer(contentsOf: url) else { return false }
            loaded.prepareToPlay()
            // Retain the two small prepared players for repeat playback.
            players[effect] = loaded; player = loaded
        }
        player.currentTime = 0
        guard player.play() else { return false }
        playCount += 1
        return true
    }
}
