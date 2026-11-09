import AppKit
import AVFoundation
import CoreAudio
import QuartzCore
import Synchronization
#if DEBUG || OPEN_AUTOMATION
import os.signpost
#endif

private struct IntroPreparedInfo: Sendable {
    let readyHostTime: Double
    let duration: Double
}

/// The worker publishes readiness before it queues any main-actor callback.
/// No audio API is called under this lock, or by the main thread.
private final class IntroAudioMailbox: Sendable {
    enum Phase: Sendable { case pending, ready(IntroPreparedInfo), failed, cancelled }
    struct State: Sendable {
        var phase: Phase = .pending
        #if DEBUG || OPEN_AUTOMATION
        var workerReady: Double?
        var prepareStart: Double?
        #endif
    }
    let value = Mutex(State())
    func read() -> State { value.withLock { $0 } }
}

/// The player stays on one worker executor, including its first hardware start.
private actor IntroAudioWorker {
    struct Scheduled: Sendable {
        let hostTime: Double
        #if DEBUG || OPEN_AUTOMATION
        let returnedAt: Double
        let playhead: Double
        let deviceLead: Double
        #endif
    }
    private let mailbox: IntroAudioMailbox
    private var player: AVAudioPlayer?
    private var cancelled = false
    init(mailbox: IntroAudioMailbox) { self.mailbox = mailbox }

    func prepare(url: URL, silent: Bool) {
        guard !cancelled else { return }
        let prepared: AVAudioPlayer?
        do {
            #if DEBUG || OPEN_AUTOMATION
            let log = OSLog(subsystem: "io.github.sergeserb2.open", category: "IntroPacing")
            let id = OSSignpostID(log: log)
            os_signpost(.begin, log: log, name: "IntroAudioPlayerInit", signpostID: id)
            defer { os_signpost(.end, log: log, name: "IntroAudioPlayerInit", signpostID: id) }
            #endif
            prepared = try? AVAudioPlayer(contentsOf: url)
        }
        guard let value = prepared else { publishFailure(); return }
        value.volume = silent ? 0 : 0.5
        let ready: Bool
        do {
            #if DEBUG || OPEN_AUTOMATION
            let log = OSLog(subsystem: "io.github.sergeserb2.open", category: "IntroPacing")
            let id = OSSignpostID(log: log)
            os_signpost(.begin, log: log, name: "IntroAudioPrepare", signpostID: id)
            defer { os_signpost(.end, log: log, name: "IntroAudioPrepare", signpostID: id) }
            #endif
            ready = value.prepareToPlay()
        }
        guard ready else { publishFailure(); return }
        let info = IntroPreparedInfo(readyHostTime: CACurrentMediaTime(), duration: value.duration)
        let accepted = mailbox.value.withLock { state in
            #if DEBUG || OPEN_AUTOMATION
            state.workerReady = info.readyHostTime
            #endif
            if case .cancelled = state.phase { return false }
            state.phase = .ready(info); return true
        }
        if accepted { player = value } else { value.stop() }
    }
    private func publishFailure() {
        mailbox.value.withLock { state in
            if case .cancelled = state.phase { return }
            state.phase = .failed
        }
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
    private var animationT0HostTime: Double?
    private var decisionHostTime: Double?
    #endif
    public private(set) var audioStartHostTime: Double?
    public private(set) var playerWasCreated = false
    private let mailbox: IntroAudioMailbox
    private let worker: IntroAudioWorker
    private var hasPlayer = false
    private var duration = 0.0
    private var preparation: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var playback: Task<Void, Never>?
    private var preparationStarted = false
    private var stopped = false
    private var onStart: (@MainActor (Double) -> Void)?
    private var startRequestHostTime: Double?
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
        let mailbox = IntroAudioMailbox()
        self.mailbox = mailbox; worker = IntroAudioWorker(mailbox: mailbox)
        self.mode = mode
        if mode == .off { muteReason = "launch-option" }
        else if defaults.object(forKey: "open.onboarding.introSoundEnabled") as? Bool == false { muteReason = "setting" }
        else if mode != .silent, (UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? NSNumber ?? UserDefaults(suiteName: UserDefaults.globalDomain)?.object(forKey: "com.apple.sound.uiaudio.enabled") as? NSNumber)?.intValue == 0 { muteReason = "ui-sounds" }
        else { muteReason = nil }
    }

    /// Preparation can overlap synchronous engine startup. Its completion is
    /// published under a lock even while the main actor is unable to run.
    public func prepare() {
        #if DEBUG || OPEN_AUTOMATION
        let pacingRegion = IntroPacingTrace.begin("sound.prepare.main")
        defer { pacingRegion?.end() }
        #endif
        guard !preparationStarted, !stopped else { return }
        preparationStarted = true
        if let muteReason { resolve("muted", muteReason); return }
        if mode == .failDevice { resolve("failed", "no-output-device"); return }
        if mode != .silent, let problem = Self.outputProblem() {
            resolve(problem == "no-output-device" ? "failed" : "muted", problem); return
        }
        guard let url = Self.resourceURL, FileManager.default.fileExists(atPath: url.path) else {
            resolve("failed", "file-missing"); return
        }
        #if DEBUG || OPEN_AUTOMATION
        mailbox.value.withLock { $0.prepareStart = CACurrentMediaTime() }
        #endif
        let silent = mode == .silent, audioWorker = worker
        let resultTask = Task.detached(priority: .userInitiated) {
            await audioWorker.prepare(url: url, silent: silent)
        }
        preparation = Task { [weak self] in
            await resultTask.value
            guard !Task.isCancelled, let self, !stopped else { return }
            decideReadiness()
        }
    }

    /// Called at the proposed animation gate after engine startup settles.
    /// The 300 ms wait starts here, never before synchronous engine startup.
    public func scheduleStart(_ completion: @escaping @MainActor (Double) -> Void) {
        guard !stopped, startRequestHostTime == nil else { return }
        prepare()
        startRequestHostTime = CACurrentMediaTime(); onStart = completion
        decideReadiness()
        guard onStart != nil, let startRequestHostTime else { return }
        deadline = Task { [weak self] in
            let end = startRequestHostTime+IntroTimeline.beat("soundDeadline").end
            try? await Task.sleep(for: .seconds(max(0, end-CACurrentMediaTime())), tolerance: .zero)
            guard !Task.isCancelled, let self, !stopped else { return }
            // Read the worker's timestamp, not delivery order of main tasks.
            decideReadiness(deadlineReached: true)
        }
    }
    private func decideReadiness(deadlineReached: Bool = false) {
        guard let completion = onStart, let startRequestHostTime, !stopped else { return }
        if decision != "pending" { onStart = nil; completion(CACurrentMediaTime()); return }
        switch mailbox.read().phase {
        case .ready(let info):
            guard info.readyHostTime <= startRequestHostTime+IntroTimeline.beat("soundDeadline").end else {
                failStart(completion, reason: "timeout"); return
            }
            onStart = nil; deadline?.cancel(); deadline = nil
            duration = info.duration; hasPlayer = true; playerWasCreated = true
            schedulePlayback(completion)
        case .failed: failStart(completion, reason: "prepare")
        case .cancelled: break
        case .pending:
            if deadlineReached { failStart(completion, reason: "timeout") }
        }
    }
    private func failStart(_ completion: @MainActor (Double) -> Void, reason: String) {
        onStart = nil; deadline?.cancel(); deadline = nil
        resolve("failed", reason); cancelWorker(); completion(CACurrentMediaTime())
    }
    private func schedulePlayback(_ completion: @escaping @MainActor (Double) -> Void) {
        playback = Task { [weak self, worker] in
            let scheduled = await worker.schedule()
            guard !Task.isCancelled, let self, !stopped, self.hasPlayer else { await worker.stop(); return }
            guard let scheduled, scheduled.hostTime > CACurrentMediaTime() else {
                hasPlayer = false; resolve("failed", "start-deadline"); cancelWorker()
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
    #if DEBUG || OPEN_AUTOMATION
    public func animationWillStart(at hostTime: Double) {
        animationT0HostTime = hostTime
    }
    #endif
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
    private func cancelWorker() {
        mailbox.value.withLock { $0.phase = .cancelled }
        Task { [worker] in await worker.stop() }
    }
    public func stop() {
        stopped = true; deadline?.cancel(); deadline = nil; onStart = nil
        preparation?.cancel(); preparation = nil; playback?.cancel(); playback = nil
        releaseTask?.cancel(); releaseTask = nil
        hasPlayer = false; cancelWorker()
    }
    private func resolve(_ decision: String, _ reason: String) {
        self.decision = decision; self.reason = reason
        let host = CACurrentMediaTime()
        #if DEBUG || OPEN_AUTOMATION
        decisionHostTime = host
        #endif
        events.append(["decision": decision, "reason": reason, "hostTime": host])
    }
    public var state: [String: Any] {
        var result: [String: Any] = ["decision": decision, "reason": reason, "events": events,
         "playerCreated": playerCreated, "playerWasCreated": playerWasCreated,
         "audioStartHostTime": audioStartHostTime as Any? ?? NSNull()]
        #if DEBUG || OPEN_AUTOMATION
        let prepared = mailbox.read()
        result["scheduleReturnedHostTime"] = audioScheduleReturnedHostTime as Any? ?? NSNull()
        result["scheduledPlayhead"] = scheduledPlayhead
        result["scheduledDeviceLeadMS"] = scheduledDeviceLead*1000
        result["musicStarted"] = musicHasStarted
        result["timing"] = ["prepareStart": prepared.prepareStart as Any? ?? NSNull(),
            "workerReady": prepared.workerReady as Any? ?? NSNull(),
            "startRequest": startRequestHostTime as Any? ?? NSNull(),
            "t0": animationT0HostTime as Any? ?? NSNull(), "decision": decisionHostTime as Any? ?? NSNull()]
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
