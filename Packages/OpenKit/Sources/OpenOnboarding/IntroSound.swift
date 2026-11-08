import AppKit
import AVFoundation
import CoreAudio
import QuartzCore

/// AVAudioPlayer ownership transfers once from the preparation worker to main.
private final class PreparedIntroPlayer: @unchecked Sendable {
    let player: AVAudioPlayer
    let readyHostTime: Double
    init(_ player: AVAudioPlayer) { self.player = player; readyHostTime = CACurrentMediaTime() }
}

@MainActor
public final class IntroSound {
    public enum Mode: String, Sendable { case normal, off, silent, failDevice = "fail-device" }
    public private(set) var decision = "pending"
    public private(set) var reason = ""
    public private(set) var events: [[String: Any]] = []
    public private(set) var audioStartHostTime: Double?
    public private(set) var playerWasCreated = false
    private var player: AVAudioPlayer?
    private var preparation: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var resolved = false
    private var onPrepared: (@MainActor () -> Void)?
    private let mode: Mode
    private let muteReason: String?
    public var playerCreated: Bool { player != nil }
    public static var resourceURL: URL? {
        Bundle.module.url(forResource: "open-intro", withExtension: "m4a", subdirectory: "Onboarding")
    }
    public static var referenceURL: URL? {
        Bundle.module.url(forResource: "open-intro-reference", withExtension: "json", subdirectory: "Onboarding")
    }

    public init(mode: Mode = .normal, defaults: UserDefaults = .standard) {
        self.mode = mode
        // Silent is an explicit offline automation playback route. It bypasses
        // output-mute/UI-effects checks, but still respects the app preference.
        if mode == .off { muteReason = "launch-option" }
        else if defaults.object(forKey: "open.onboarding.introSoundEnabled") as? Bool == false { muteReason = "setting" }
        else if mode != .silent, (UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? NSNumber ?? UserDefaults(suiteName: UserDefaults.globalDomain)?.object(forKey: "com.apple.sound.uiaudio.enabled") as? NSNumber)?.intValue == 0 { muteReason = "ui-sounds" }
        else { muteReason = nil }
    }

    /// Completes once, within 300 ms. Late preparation is discarded and released.
    public func prepare(_ completion: @escaping @MainActor () -> Void) {
        if resolved { completion(); return }
        onPrepared = completion
        guard preparation == nil else { return }
        if let muteReason { resolve("muted", muteReason); prepared(); return }
        if mode == .failDevice { resolve("failed", "no-output-device"); prepared(); return }
        if mode != .silent, let problem = Self.outputProblem() {
            resolve(problem == "no-output-device" ? "failed" : "muted", problem); prepared(); return
        }
        guard let url = Self.resourceURL, FileManager.default.fileExists(atPath: url.path) else {
            resolve("failed", "file-missing"); prepared(); return
        }
        let silent = mode == .silent
        let prepareDeadline = CACurrentMediaTime()+IntroTimeline.beat("soundDeadline").end
        let worker = Task.detached(priority: .userInitiated) { () -> PreparedIntroPlayer? in
                guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
                // Set before prepare/play, so no automated run can emit a sample.
                player.volume = silent ? 0 : 0.5
                guard player.prepareToPlay() else { return nil }
                return PreparedIntroPlayer(player)
        }
        preparation = Task { [weak self] in
            let result = await worker.value
            guard let self, !resolved else { result?.player.stop(); return }
            deadline?.cancel(); deadline = nil
            guard let result else { resolve("failed", "prepare"); prepared(); return }
            guard result.readyHostTime <= prepareDeadline else {
                result.player.stop(); resolve("failed", "timeout"); prepared(); return
            }
            player = result.player; playerWasCreated = true; resolved = true
            prepared()
        }
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, prepareDeadline-CACurrentMediaTime())), tolerance: .zero)
            guard !Task.isCancelled, let self, !resolved else { return }
            resolve("failed", "timeout"); prepared()
        }
    }
    private func prepared() { let completion = onPrepared; onPrepared = nil; completion?() }

    /// deviceCurrentTime and CA time are sampled together; both schedules share
    /// one lead. The receipt records their actual host-clock conversion.
    public func start(animationHostTime: Double) {
        guard let player else { return }
        let host = CACurrentMediaTime(), device = player.deviceCurrentTime
        let deviceStart = device + max(0, animationHostTime - host)
        guard player.play(atTime: deviceStart) else {
            player.stop(); self.player = nil; resolve("failed", "play"); return
        }
        audioStartHostTime = host + deviceStart - device
        resolve("played", mode == .silent ? "silent" : "output")
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(player.duration + IntroTimeline.beat("syncLead").end), tolerance: .zero)
            guard !Task.isCancelled else { return }; self?.stop()
        }
    }

    public func fadeOut() {
        guard let player else { return }
        let duration = IntroTimeline.beat("handoffSound").end
        player.setVolume(0, fadeDuration: duration)
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration), tolerance: .zero)
            guard !Task.isCancelled else { return }; self?.stop()
        }
    }
    public func stop() {
        resolved = true; deadline?.cancel(); deadline = nil
        onPrepared = nil
        preparation?.cancel(); preparation = nil
        releaseTask?.cancel(); releaseTask = nil
        player?.stop(); player = nil
    }
    private func resolve(_ decision: String, _ reason: String) {
        resolved = true; self.decision = decision; self.reason = reason
        events.append(["decision": decision, "reason": reason, "hostTime": CACurrentMediaTime()])
    }
    public var state: [String: Any] {
        ["decision": decision, "reason": reason, "events": events,
         "playerCreated": playerCreated, "playerWasCreated": playerWasCreated,
         "audioStartHostTime": audioStartHostTime as Any? ?? NSNull()]
    }

    /// Read-only, fixed-size CoreAudio queries. Missing controls are normal on
    /// digital/aggregate devices; only a successful muted/zero query mutes.
    private static func outputProblem() -> String? {
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return "no-output-device" }
        address = .init(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var mute: UInt32 = 0; size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &address), AudioObjectGetPropertyData(device, &address, 0, nil, &size, &mute) == noErr, mute != 0 { return "device-muted" }
        address.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        var volume: Float32 = 1; size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectHasProperty(device, &address), AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr, volume <= 0 { return "zero-volume" }
        return nil
    }
}
