import AppKit
import AVFoundation
import CoreAudio
import QuartzCore
#if DEBUG || OPEN_AUTOMATION
import os.signpost
#endif

/// The player stays on one worker executor, including its first hardware start.
private actor IntroAudioWorker {
    struct Prepared: Sendable { let ready: Double; let duration: Double }
    struct Scheduled: Sendable {
        let hostTime: Double
        #if DEBUG || OPEN_AUTOMATION
        let returnedAt: Double
        let playhead: Double
        let deviceLead: Double
        #endif
    }
    private var player: AVAudioPlayer?
    private var cancelled = false

    func prepare(url: URL, silent: Bool) -> Prepared? {
        guard !cancelled else { return nil }
        #if DEBUG || OPEN_AUTOMATION
        let log = OSLog(subsystem: "io.github.sergeserb2.open", category: "IntroPacing")
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "IntroAudioPrepare", signpostID: id)
        defer { os_signpost(.end, log: log, name: "IntroAudioPrepare", signpostID: id) }
        #endif
        guard let value = try? AVAudioPlayer(contentsOf: url) else { return nil }
        value.volume = silent ? 0 : 0.5
        guard value.prepareToPlay() else { return nil }
        player = value
        return Prepared(ready: CACurrentMediaTime(), duration: value.duration)
    }
    func schedule() -> Scheduled? {
        guard !cancelled, let player else { return nil }
        #if DEBUG || OPEN_AUTOMATION
        let log = OSLog(subsystem: "io.github.sergeserb2.open", category: "IntroPacing")
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "IntroAudioFirstStart", signpostID: id)
        defer { os_signpost(.end, log: log, name: "IntroAudioFirstStart", signpostID: id) }
        #endif
        let device = player.deviceCurrentTime, host = CACurrentMediaTime()
        let lead = IntroTimeline.beat("syncLead").end
        guard player.play(atTime: device+lead) else { return nil }
        let returned = CACurrentMediaTime()
        guard returned < host+lead else { player.stop(); return nil }
        #if DEBUG || OPEN_AUTOMATION
        return Scheduled(hostTime: host+lead, returnedAt: returned, playhead: player.currentTime, deviceLead: device+lead-player.deviceCurrentTime)
        #else
        return Scheduled(hostTime: host+lead)
        #endif
    }
    func fade(duration: Double) { player?.setVolume(0, fadeDuration: duration) }
    func stop() { cancelled = true; player?.stop(); player = nil }
}

@MainActor
public final class IntroSound {
    public enum Mode: String, Sendable { case normal, off, silent, failDevice = "fail-device" }
    public private(set) var decision = "pending"
    public private(set) var reason = ""
    public private(set) var events: [[String: Any]] = []
    #if DEBUG || OPEN_AUTOMATION
    public private(set) var scheduledPlayhead = 0.0
    public private(set) var scheduledDeviceLead = 0.0
    public private(set) var audioScheduleReturnedHostTime: Double?
    #endif
    public private(set) var audioStartHostTime: Double?
    public private(set) var playerWasCreated = false
    private let worker = IntroAudioWorker()
    private var hasPlayer = false
    private var duration = 0.0
    private var preparation: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var resolved = false
    private var onPrepared: (@MainActor () -> Void)?
    private let mode: Mode
    private let muteReason: String?
    public var playerCreated: Bool { hasPlayer }
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
        #if DEBUG || OPEN_AUTOMATION
        let pacingRegion = IntroPacingTrace.begin("sound.prepare.main")
        defer { pacingRegion?.end() }
        #endif
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
        let audioWorker = worker
        let resultTask = Task.detached(priority: .userInitiated) {
            await audioWorker.prepare(url: url, silent: silent)
        }
        preparation = Task { [weak self, worker] in
            let result = await resultTask.value
            guard let self, !resolved else { await worker.stop(); return }
            deadline?.cancel(); deadline = nil
            guard let result else { resolve("failed", "prepare"); prepared(); return }
            guard result.ready <= prepareDeadline else {
                await worker.stop(); resolve("failed", "timeout"); prepared(); return
            }
            duration = result.duration; hasPlayer = true; playerWasCreated = true; resolved = true
            prepared()
        }
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, prepareDeadline-CACurrentMediaTime())), tolerance: .zero)
            guard !Task.isCancelled, let self, !resolved else { return }
            resolve("failed", "timeout"); prepared()
        }
    }
    private func prepared() { let completion = onPrepared; onPrepared = nil; completion?() }

    /// Schedule on the audio executor, then return the common future t=0.
    /// Main never initializes or starts an audio device.
    public func scheduleStart(_ completion: @escaping @MainActor (Double) -> Void) {
        guard hasPlayer else { completion(CACurrentMediaTime()); return }
        preparation = Task { [weak self, worker] in
            let scheduled = await worker.schedule()
            guard !Task.isCancelled, let self, self.hasPlayer else { await worker.stop(); return }
            guard let scheduled, scheduled.hostTime > CACurrentMediaTime() else {
                await worker.stop(); hasPlayer = false; resolve("failed", "start-deadline")
                completion(CACurrentMediaTime()); return
            }
            #if DEBUG || OPEN_AUTOMATION
            scheduledPlayhead = scheduled.playhead; scheduledDeviceLead = scheduled.deviceLead
            audioScheduleReturnedHostTime = scheduled.returnedAt
            #endif
            audioStartHostTime = scheduled.hostTime
            resolve("played", mode == .silent ? "silent" : "output")
            completion(scheduled.hostTime)
            releaseTask = Task { [weak self, duration] in
                try? await Task.sleep(for: .seconds(duration + IntroTimeline.beat("syncLead").end), tolerance: .zero)
                guard !Task.isCancelled else { return }; self?.stop()
            }
        }
    }
    public var musicHasStarted: Bool { audioStartHostTime.map { CACurrentMediaTime() >= $0 } ?? false }

    public func fadeOut() {
        guard hasPlayer else { return }
        let duration = IntroTimeline.beat("handoffSound").end
        Task { [worker] in await worker.fade(duration: duration) }
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
        hasPlayer = false
        Task { [worker] in await worker.stop() }
    }
    private func resolve(_ decision: String, _ reason: String) {
        resolved = true; self.decision = decision; self.reason = reason
        events.append(["decision": decision, "reason": reason, "hostTime": CACurrentMediaTime()])
    }
    public var state: [String: Any] {
        var result: [String: Any] = ["decision": decision, "reason": reason, "events": events,
         "playerCreated": playerCreated, "playerWasCreated": playerWasCreated,
         "audioStartHostTime": audioStartHostTime as Any? ?? NSNull()]
        #if DEBUG || OPEN_AUTOMATION
        result["scheduleReturnedHostTime"] = audioScheduleReturnedHostTime as Any? ?? NSNull()
        result["scheduledPlayhead"] = scheduledPlayhead
        result["scheduledDeviceLeadMS"] = scheduledDeviceLead*1000
        result["musicStarted"] = musicHasStarted
        #endif
        return result
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
