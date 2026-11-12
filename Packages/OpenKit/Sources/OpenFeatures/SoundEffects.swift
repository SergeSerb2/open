import AVFoundation
import Foundation
import os

/// Open's generated effects. No resource or audio player is loaded at launch.
/// Audio work (player creation, `play`) runs on a private serial queue, never on the main thread: with sounds on
/// by default a slow or stuck audio server must not block the App (seen on a VM: `AVAudioPlayer.play` blocked the
/// main thread for more than 120 s). While one request is in flight, later requests are dropped, so nothing piles up.
@MainActor
public final class SoundEffects {
    public enum Effect: String, CaseIterable, Sendable { case capture, event }
    public static let shared = SoundEffects()
    private let defaults: UserDefaults
    /// Players live on `queue` only.
    private final class Players: @unchecked Sendable { var byEffect: [Effect: AVAudioPlayer] = [:] }
    private let players = Players()
    private let queue = DispatchQueue(label: "open.sound-effects", qos: .userInitiated)
    private var requested: Set<Effect> = []
    /// Set on the main actor, cleared by the audio queue when the request finished.
    private let inFlight = OSAllocatedUnfairLock(initialState: false)
    /// Requests handed to the audio queue.
    public private(set) var playCount = 0
    /// Requests dropped because an earlier one had not finished.
    public private(set) var droppedCount = 0
    /// Effects whose player was requested (each is created once, on the audio queue).
    public var loadedSoundCount: Int { requested.count }

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public static func resourceURL(for effect: Effect) -> URL? {
        Bundle.module.url(forResource: "open-\(effect.rawValue)", withExtension: "caf", subdirectory: "Sounds")
    }

    /// Reads the existing app preference at use. Default **on**, as Arc: its key is the inverse
    /// `playUserInterfaceSoundsDisabled` (absent = sounds on). GUESS — capture PB5-e pending (fresh Arc data folder);
    /// LEAD 11:40, AUDIT-2026-11-12 A8. Capture C9 (2026-11-12): of thirteen actions tested in Arc, only Capture
    /// plays a sound (docs/re/features-advanced.md SE-2), so `.capture` on Capture is Open's only UI sound. The
    /// general `.event` effect keeps no production caller: its Arc trigger is still unknown (untested actions: GUESS).
    /// Returns true when the effect was handed to the audio queue (enabled, resource present, queue free).
    @discardableResult
    public func play(_ effect: Effect) -> Bool {
        guard defaults.object(forKey: "open.advanced.playSoundEffects") as? Bool ?? true,
              let url = Self.resourceURL(for: effect) else { return false }
        guard !inFlight.withLock({ $0 }) else { droppedCount += 1; return false }
        inFlight.withLock { $0 = true }; requested.insert(effect); playCount += 1
        let players = players, inFlight = inFlight
        queue.async {
            let player: AVAudioPlayer?
            if let loaded = players.byEffect[effect] { player = loaded }
            else {
                player = try? AVAudioPlayer(contentsOf: url)
                player?.prepareToPlay()
                // Retain the two small prepared players for repeat playback.
                players.byEffect[effect] = player
            }
            player?.currentTime = 0
            player?.play()
            inFlight.withLock { $0 = false }
        }
        return true
    }

    /// True while a request is on the audio queue (checks wait on this).
    public var isBusy: Bool { inFlight.withLock { $0 } }
}
