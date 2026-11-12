import Foundation
import Observation
import OpenModel
import OpenMedia
import OpenWeb

/// Real CLI over the shared policy, registry, defaults and session; only time is injected (§8.1).
@MainActor func runMediaDemo(args: [String]) async throws {
    guard args.isEmpty else { throw NSError(domain: "media-demo", code: 2, userInfo: [NSLocalizedDescriptionKey: "usage: openkit media-demo"]) }
    var passed = 0, failed = 0
    func check(_ id: String, _ okay: Bool) { print("\(okay ? "PASS" : "FAIL") \(id)"); if okay { passed += 1 } else { failed += 1 } }
    let domain = "Open.MediaDemo." + UUID().uuidString
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let settings = MediaSettings(defaults: defaults), rules = try PiPSiteRules.bundled(), session = PiPSession()
    let tab = ItemID(), other = ItemID(), window = WindowID()
    let video = WebMediaState(playback: .playing, isControllable: true, hasVideo: true, largestVideoArea: 640 * 360, actions: [.play, .pause, .seekTo, .enterPictureInPicture])
    func decision(_ url: String = "https://example.com", _ state: WebMediaState? = nil, audible: Bool = true,
                  event: AutoPiPPolicy.LeaveEvent = .selection, disabled: Bool = false, privateHosts: MediaSettings.PrivateHosts? = nil) -> AutoPiPPolicy.Decision {
        AutoPiPPolicy.decide(tabID: tab, url: URL(string: url)!, state: state ?? video, audible: audible, event: event,
                            settings: settings, rules: rules, session: session, disablePictureInPicture: disabled, privateSession: privateHosts)
    }
    check("AP1 audible allowed video", decision() == .open)
    check("defaults before registration", settings.automaticPiPEnabled && settings.keepOnTop && settings.autoDisabledHosts.isEmpty)
    settings.automaticPiPEnabled = false; check("AP2 settingOff", decision() == .settingOff); settings.automaticPiPEnabled = true
    check("AP3 inaudible", decision(audible: false) == .inaudible)
    check("AP3 youtube", decision("https://www.youtube.com", audible: false) == .open)
    var tiny = video; tiny.largestVideoArea = 160 * 90 - 1
    check("AP4 tiny video", decision("https://example.com", tiny) == .tooSmall)
    for host in ["meet.google.com", "slack.com", "teams.microsoft.com", "www.slack.com"] {
        check("AP5 \(host)", decision("https://" + host) == .disallowed)
    }
    settings.autoDisabledHosts = ["EXAMPLE.COM"]
    check("AP6 persisted host", decision() == .hostDisabled && MediaSettings(defaults: defaults).autoDisabledHosts == ["example.com"])
    settings.autoDisabledHosts = []
    let privateHosts = MediaSettings.PrivateHosts()
    settings.setAutomatic(false, host: "EXAMPLE.COM", privateSession: privateHosts)
    check("AP6 private host isolated", decision(privateHosts: privateHosts) == .hostDisabled && decision() == .open && settings.autoDisabledHosts.isEmpty)
    session.request(tabID: tab, automatic: true); session.didEnter(tabID: tab); _ = session.close(.userClosed)
    check("AP7 snoozed", decision() == .snoozed)
    _ = session.displayed(tabID: tab); check("AP7 displayed clears", decision() == .open)
    session.request(tabID: other, automatic: false); session.didEnter(tabID: other)
    check("AP8 manual blocks", decision() == .manualPiP)
    _ = session.close(.sourceGone)
    session.request(tabID: other, automatic: true); session.didEnter(tabID: other)
    check("AP8 automatic can be replaced", decision() == .open)
    let replacement = session.request(tabID: tab, automatic: true)
    check("AP8 replacement names A, session names T", replacement?.tabID == other && replacement?.reason == .replaced && replacement?.pause == false && session.state == .requesting(tabID: tab, automatic: true))
    let requesting = session.state
    check("same-tab requesting policy blocks", decision() == .alreadyInPictureInPicture)
    check("same-tab requesting is idempotent", session.request(tabID: tab, automatic: true) == nil && session.state == requesting)
    session.didEnter(tabID: tab)
    let active = session.state
    check("same-tab active policy blocks", decision() == .alreadyInPictureInPicture)
    check("same-tab active is idempotent", session.request(tabID: tab, automatic: false) == nil && session.state == active)
    _ = session.close(.sourceGone)
    var enginePiP = video; enginePiP.isPictureInPicture = true
    check("engine PiP policy blocks", decision("https://example.com", enginePiP) == .alreadyInPictureInPicture)
    check("AP9 disablePictureInPicture", decision(disabled: true) == .videoDisabled)
    for event: AutoPiPPolicy.LeaveEvent in [.appSwitch, .close, .splitFocus, .peek] {
        check("AP10 no leave \(event)", decision(event: event) == .notLeave)
    }
    for event: AutoPiPPolicy.LeaveEvent in [.minimize, .occlusion, .appHide] {
        check("AP10 window hidden is a leave \(event)", decision(event: event) == .open)
    }
    for automatic in [true, false] {
        for reason: PiPSession.Reason in [.userClosed, .minimized, .backToTab, .sourceGone, .failed, .replaced] {
            let s = PiPSession(); s.request(tabID: tab, automatic: automatic); s.didEnter(tabID: tab)
            let effect = s.close(reason)
            let expected: PiPSession.State = reason == .minimized ? .minimized(tabID: tab) : .closed(tabID: tab, reason: reason)
            check("AP11 \(automatic ? "auto" : "manual") \(reason)", effect?.pause == (reason == .userClosed) && s.state == expected
                  && s.snoozed.contains(tab) == (automatic && (reason == .userClosed || reason == .minimized)))
        }
        let s = PiPSession(); s.request(tabID: tab, automatic: automatic); s.didEnter(tabID: tab)
        let beforeSettingChange = s.state
        settings.automaticPiPEnabled = false
        check("AP11 setting off leaves session", s.state == beforeSettingChange && s.activeSource?.tabID == tab)
        settings.automaticPiPEnabled = true
        let effect = s.displayed(tabID: tab)
        check("AP11 source shown \(automatic)", automatic ? (effect?.pause == false && s.state == .closed(tabID: tab, reason: .sourceShown)) : (effect == nil && s.state == .active(tabID: tab, automatic: false)))
    }
    var now = Date(timeIntervalSince1970: 100_000)
    let store = MediaSourceStore(clock: { now })
    let displayed = ItemID(), split = ItemID(), peek = ItemID(), pip = ItemID(), minimized = ItemID()
    for id in [displayed, split, peek, pip, minimized] { store.update(tabID: id, windowID: window, state: video, isMuted: false, isCapturing: false) }
    store.setPiP(tabID: pip, .active(auto: true)); store.setPiP(tabID: minimized, .minimized)
    check("MS1 displayed, split, peek and PiP excluded", store.visibleSources(windowID: window, displayed: [displayed, split, peek]).compactMap(\.tabID) == [minimized])
    store.update(tabID: other, windowID: WindowID(), state: video, isMuted: false, isCapturing: false)
    check("MS2 other window excluded; same window Space included", !store.visibleSources(windowID: window, displayed: []).contains { $0.tabID == other } && store.visibleSources(windowID: window, displayed: []).contains { $0.tabID == minimized })
    let ordering = MediaSourceStore(clock: { now }), ids = (0..<4).map { _ in ItemID() }
    for id in ids { ordering.update(tabID: id, windowID: window, state: video, isMuted: false, isCapturing: false) }
    check("MS3 newest three", ordering.visibleSources(windowID: window, displayed: []).compactMap(\.tabID) == Array(ids.reversed().prefix(3)))
    ordering.noteInteraction(tabID: ids[0])
    check("MS3 interaction promotes", ordering.visibleSources(windowID: window, displayed: []).first?.tabID == ids[0])
    let scheduled = MediaDemoScheduler()
    let pausedStore = MediaSourceStore(clock: { now }, scheduler: scheduled)
    var paused = video; paused.playback = .paused
    pausedStore.update(tabID: tab, windowID: window, state: paused, isMuted: false, isCapturing: false)
    check("MS5 one paused work item", pausedStore.pendingWorkItemCount == 1 && scheduled.pendingCount == 1 && pausedStore.pendingDismissDeadline == now.addingTimeInterval(3600))
    now.addTimeInterval(59 * 60)
    check("MS4 59 min visible", pausedStore.visibleSources(windowID: window, displayed: []).count == 1)
    pausedStore.noteInteraction(tabID: tab)
    let extendedDeadline = now.addingTimeInterval(3600)
    now.addTimeInterval(60)
    check("MS4 interaction restarts deadline", pausedStore.visibleSources(windowID: window, displayed: []).count == 1 && pausedStore.pendingDismissDeadline == extendedDeadline)
    now.addTimeInterval(59 * 60)
    await scheduled.waitForFire()
    check("MS5 real scheduled callback fired", scheduled.firedCount == 1 && scheduled.pendingCount == 0 && pausedStore.pendingWorkItemCount == 0)
    check("MS4 60 min hidden", pausedStore.visibleSources(windowID: window, displayed: []).isEmpty)
    pausedStore.noteInteraction(tabID: tab)
    check("expired source interaction restores card", pausedStore.visibleSources(windowID: window, displayed: []).count == 1 && pausedStore.sleepProtectedTabIDs(windowID: window, displayed: []).contains(tab))
    pausedStore.update(tabID: tab, windowID: window, state: video, isMuted: false, isCapturing: false)
    check("MS5 no paused work item", pausedStore.pendingWorkItemCount == 0)
    pausedStore.dismiss(tabID: tab); pausedStore.update(tabID: tab, windowID: window, state: paused, isMuted: false, isCapturing: false)
    pausedStore.noteInteraction(tabID: tab)
    check("dismissed until next play", pausedStore.visibleSources(windowID: window, displayed: []).isEmpty)
    pausedStore.update(tabID: tab, windowID: window, state: video, isMuted: false, isCapturing: false)
    check("replay restores card", pausedStore.visibleSources(windowID: window, displayed: []).count == 1)
    pausedStore.update(tabID: tab, windowID: window, state: WebMediaState(), isMuted: false, isCapturing: false)
    check("ended source removed", pausedStore.sources[tab] == nil)
    check("SR1 twitch subdomain", rules.configuration(for: URL(string: "https://www.twitch.tv")!)?.hide == ["play", "scrub", "skip"])
    check("SR1 suffix attack rejected", rules.configuration(for: URL(string: "https://twitch.tv.evil.com")!) == nil)
    check("MN1 hostless menu", PiPMenuEntry.entries(url: URL(string: "about:blank"), muted: false, keepOnTop: true, disabledHosts: []).map(\.title) == ["Keep Window on Top", "", "Mute"])
    check("MN1 host menu order", PiPMenuEntry.entries(url: URL(string: "https://example.com/path"), muted: true, keepOnTop: false, disabledHosts: ["example.com"]).map(\.title) == ["Keep Window on Top", "", "Picture-in-picture on example.com:", "Open automatically", "Turn off", "", "Copy URL", "Unmute"])
    // Store honors the engine PiP bit independently of shell session events.
    pausedStore.update(tabID: tab, windowID: window, state: enginePiP, isMuted: false, isCapturing: false)
    check("engine PiP source has no card", pausedStore.visibleSources(windowID: window, displayed: []).isEmpty)

    let auxiliary = MediaSourceStore(clock: { now }), peekPageID = UUID()
    auxiliary.updateAuxiliaryPage(pageID: peekPageID, windowID: window, state: video, isMuted: false, isCapturing: false)
    check("PK-9 auxiliary page has no tab identity or card", auxiliary.sources.isEmpty && auxiliary.auxiliarySources[peekPageID]?.origin == .auxiliaryPage && auxiliary.auxiliarySources[peekPageID]?.tabID == nil && auxiliary.visibleSources(windowID: window, displayed: []).isEmpty)

    let closingScheduler = MediaDemoScheduler(), closing = MediaSourceStore(clock: { now }, scheduler: closingScheduler)
    closing.update(tabID: tab, windowID: window, state: paused, isMuted: false, isCapturing: false)
    check("close fixture has scheduled paused source", closingScheduler.pendingCount == 1)
    closing.remove(tabID: tab)
    check("close without final update clears source and deadline", closing.sources[tab] == nil && closing.visibleSources(windowID: window, displayed: []).isEmpty && closing.pendingDismissDeadline == nil && closing.pendingWorkItemCount == 0 && closingScheduler.pendingCount == 0)
    let movedWindow = WindowID()
    closing.update(tabID: tab, windowID: window, state: video, isMuted: false, isCapturing: false)
    closing.move(tabID: tab, toWindow: movedWindow)
    check("window move without media update", closing.visibleSources(windowID: window, displayed: []).isEmpty && closing.visibleSources(windowID: movedWindow, displayed: []).first?.tabID == tab)

    let observationStore = MediaSourceStore(clock: { now }), windowB = WindowID()
    observationStore.update(tabID: tab, windowID: window, state: video, isMuted: false, isCapturing: false)
    observationStore.update(tabID: other, windowID: windowB, state: video, isMuted: false, isCapturing: false)
    let invalidationsA = MediaDemoInvalidations(), invalidationsB = MediaDemoInvalidations(), dictionaryInvalidations = MediaDemoInvalidations()
    withObservationTracking { _ = observationStore.visibleSources(windowID: window, displayed: []).map(\.playback) } onChange: { invalidationsA.note() }
    withObservationTracking { _ = observationStore.visibleSources(windowID: windowB, displayed: []).map(\.playback) } onChange: { invalidationsB.note() }
    withObservationTracking { _ = observationStore.sources.count } onChange: { dictionaryInvalidations.note() }
    observationStore.update(tabID: tab, windowID: window, state: video, isMuted: false, isCapturing: false)
    check("identical update has no invalidation", invalidationsA.count == 0 && invalidationsB.count == 0 && dictionaryInvalidations.count == 0)
    observationStore.update(tabID: tab, windowID: window, state: paused, isMuted: false, isCapturing: false)
    check("window A update does not invalidate window B", invalidationsA.count == 1 && invalidationsB.count == 0 && dictionaryInvalidations.count == 0)

    let protectionScheduler = MediaDemoScheduler(), protection = MediaSourceStore(clock: { now }, scheduler: protectionScheduler)
    var uncontrollable = video; uncontrollable.isControllable = false
    protection.update(tabID: tab, windowID: window, state: uncontrollable, isMuted: false, isCapturing: false)
    check("uncontrollable playing protected without card", protection.sources[tab] != nil && protection.visibleSources(windowID: window, displayed: []).isEmpty && protection.sleepProtectedTabIDs(windowID: window, displayed: []) == [tab])
    now.addTimeInterval(7200)
    check("uncontrollable playing remains protected", protection.sleepProtectedTabIDs(windowID: window, displayed: []) == [tab])
    uncontrollable.playback = .paused
    protection.update(tabID: tab, windowID: window, state: uncontrollable, isMuted: false, isCapturing: false)
    check("uncontrollable paused protected before expiry", protection.sleepProtectedTabIDs(windowID: window, displayed: []) == [tab])
    let captureWithoutControls = ItemID()
    protection.update(tabID: captureWithoutControls, windowID: window, state: uncontrollable, isMuted: false, isCapturing: true)
    check("uncontrollable recording session has no card", protection.visibleSources(windowID: window, displayed: []).isEmpty && protection.sleepProtectedTabIDs(windowID: window, displayed: []).contains(captureWithoutControls))
    // Step 8 (PP-19): a meeting page plays remote audio through MediaStream players, so it is never
    // controllable; with microphone and camera toggles it still gets a recording card.
    let meeting = ItemID()
    var meetingState = video; meetingState.isControllable = false; meetingState.playback = .playing
    meetingState.actions = [.toggleMicrophone, .toggleCamera, .hangUp]; meetingState.microphoneMuted = true; meetingState.cameraOn = true
    protection.update(tabID: meeting, windowID: window, state: meetingState, isMuted: false, isCapturing: true)
    let meetingCard = protection.visibleSources(windowID: window, displayed: []).first
    check("uncontrollable meeting with toggles has a recording card", meetingCard?.tabID == meeting && meetingCard?.kind == .recording
        && meetingCard?.microphoneOn == false && meetingCard?.cameraOn == true && protection.sleepProtectedTabIDs(windowID: window, displayed: []).contains(meeting))
    protection.update(tabID: meeting, windowID: window, state: meetingState, isMuted: false, isCapturing: false)
    check("meeting card leaves when capture stops", protection.visibleSources(windowID: window, displayed: []).isEmpty)
    protection.remove(tabID: meeting)
    now.addTimeInterval(3600); await protectionScheduler.waitForFire()
    check("uncontrollable paused expires at 60 min", protectionScheduler.firedCount == 1 && protection.sleepProtectedTabIDs(windowID: window, displayed: []).isEmpty && protection.visibleSources(windowID: window, displayed: []).isEmpty)

    let earliestScheduler = MediaDemoScheduler(), earliestStore = MediaSourceStore(clock: { now }, scheduler: earliestScheduler)
    let firstDeadline = now.addingTimeInterval(3600)
    earliestStore.update(tabID: tab, windowID: window, state: paused, isMuted: false, isCapturing: false)
    now.addTimeInterval(10)
    earliestStore.update(tabID: other, windowID: window, state: paused, isMuted: false, isCapturing: false)
    check("MS5 only earliest of two paused deadlines scheduled", earliestScheduler.pendingCount == 1 && earliestStore.pendingWorkItemCount == 1 && earliestStore.pendingDismissDeadline == firstDeadline)
    now = firstDeadline; await earliestScheduler.waitForFire()
    check("MS5 callback hides only expired source and schedules next", earliestScheduler.firedCount == 1 && earliestStore.visibleSources(windowID: window, displayed: []).compactMap(\.tabID) == [other] && earliestScheduler.pendingCount == 1 && earliestStore.pendingDismissDeadline == firstDeadline.addingTimeInterval(10))
    earliestStore.remove(tabID: tab); earliestStore.remove(tabID: other)
    check("MS5 final removal cancels real pending item", earliestScheduler.pendingCount == 0)

    let recordingScheduler = MediaDemoScheduler(), recordingStore = MediaSourceStore(clock: { now }, scheduler: recordingScheduler)
    recordingStore.update(tabID: tab, windowID: window, state: paused, isMuted: false, isCapturing: true)
    check("paused recording visible before expiry", recordingStore.visibleSources(windowID: window, displayed: []).first?.kind == .recording)
    now.addTimeInterval(3600); await recordingScheduler.waitForFire()
    check("paused recording expires at 60 min", recordingScheduler.firedCount == 1 && recordingStore.visibleSources(windowID: window, displayed: []).isEmpty)

    let minimizedSession = PiPSession(); minimizedSession.request(tabID: tab, automatic: true); minimizedSession.didEnter(tabID: tab)
    _ = minimizedSession.close(.minimized)
    let gone = minimizedSession.close(.sourceGone)
    check("minimized sourceGone ends without pause", gone?.tabID == tab && gone?.reason == .sourceGone && gone?.pause == false && minimizedSession.state == .closed(tabID: tab, reason: .sourceGone))
    settings.setAutomatic(false, host: "WWW.Example.COM")
    check("host choice canonicalized", settings.autoDisabledHosts == ["example.com"])
    check("host choice covers root and subdomains", settings.isAutoDisabled(host: "example.com") && settings.isAutoDisabled(host: "www.example.com") && settings.isAutoDisabled(host: "video.example.com") && !settings.isAutoDisabled(host: "example.com.evil.com"))
    check("www menu retains source host in header", PiPMenuEntry.entries(url: URL(string: "https://www.example.com"), muted: false, keepOnTop: true, disabledHosts: settings.autoDisabledHosts).contains { $0.title == "Picture-in-picture on www.example.com:" })
    let hostMenu = PiPMenuEntry.entries(url: URL(string: "https://video.example.com"), muted: false, keepOnTop: true, disabledHosts: settings.autoDisabledHosts)
    check("subdomain menu shows same disabled state", hostMenu.first { $0.action == .turnOff }?.checked == true && hostMenu.first { $0.action == .openAutomatically }?.checked == false)
    check("subdomain policy uses site choice", decision("https://video.example.com") == .hostDisabled)
    settings.setAutomatic(true, host: "video.example.com")
    check("subdomain menu can re-enable matching site", settings.autoDisabledHosts.isEmpty)

    let capped = MediaSourceStore(clock: { now }), cappedIDs = (0..<4).map { _ in ItemID() }
    for id in cappedIDs { capped.update(tabID: id, windowID: window, state: video, isMuted: false, isCapturing: false) }
    let threeCards = Set(cappedIDs.suffix(3))
    check("sleep protection uses only three shown cards", capped.sleepProtectedTabIDs(windowID: window, displayed: []) == threeCards)
    check("displayed source excluded from card protection", capped.sleepProtectedTabIDs(windowID: window, displayed: [cappedIDs[3]]) == Set(cappedIDs.prefix(3)))
    capped.setPiP(tabID: cappedIDs[3], .active(auto: true))
    check("PiP-active source excluded from mediaControls", capped.sleepProtectedTabIDs(windowID: window, displayed: []) == Set(cappedIDs.prefix(3)))

    let dismissalScheduler = MediaDemoScheduler(), dismissalStore = MediaSourceStore(clock: { now }, scheduler: dismissalScheduler)
    dismissalStore.update(tabID: tab, windowID: window, state: paused, isMuted: false, isCapturing: false)
    dismissalStore.dismiss(tabID: tab)
    check("dismissed paused entry keeps cleanup deadline", dismissalStore.pendingDismissDeadline == now.addingTimeInterval(3600) && dismissalScheduler.pendingCount == 1)
    now.addTimeInterval(3600); await dismissalScheduler.waitForFire()
    check("dismissed paused entry expires from registry", dismissalScheduler.firedCount == 1 && dismissalStore.sources[tab] == nil && dismissalScheduler.pendingCount == 0)
    dismissalStore.update(tabID: tab, windowID: window, state: video, isMuted: false, isCapturing: false)
    check("play after dismissed expiry restores card", dismissalStore.visibleSources(windowID: window, displayed: []).first?.tabID == tab)

    let teardownScheduler = MediaDemoScheduler(), teardown = MediaSourceStore(clock: { now }, scheduler: teardownScheduler), destination = WindowID()
    teardown.update(tabID: tab, windowID: window, state: paused, isMuted: false, isCapturing: false)
    teardown.move(tabID: tab, toWindow: destination); teardown.removeWindow(windowID: window)
    check("window teardown after moving only source drops old list", teardown.registeredWindowCount == 1 && teardown.sources[tab]?.windowID == destination)
    now.addTimeInterval(3600); await teardownScheduler.waitForFire()
    check("moved paused source expires without reviving old window", teardown.registeredWindowCount == 1 && teardown.visibleSources(windowID: destination, displayed: []).isEmpty && teardownScheduler.pendingCount == 0)
    teardown.removeWindow(windowID: destination)
    check("last window teardown releases all sources and lists", teardown.registeredWindowCount == 0 && teardown.sources.isEmpty && teardown.pendingDismissDeadline == nil)

    let minimizedReplacement = PiPSession()
    minimizedReplacement.request(tabID: other, automatic: true); minimizedReplacement.didEnter(tabID: other); _ = minimizedReplacement.close(.minimized)
    let replacedMinimized = minimizedReplacement.request(tabID: tab, automatic: false)
    check("request replaces minimized session", replacedMinimized?.tabID == other && replacedMinimized?.reason == .replaced && replacedMinimized?.pause == false && minimizedReplacement.state == .requesting(tabID: tab, automatic: false))

    let earlyScheduler = MediaDemoScheduler(), earlyStore = MediaSourceStore(clock: { now }, scheduler: earlyScheduler)
    earlyStore.update(tabID: tab, windowID: window, state: paused, isMuted: false, isCapturing: false)
    await earlyScheduler.waitForFire()
    check("early delivery keeps exactly one pending item", earlyScheduler.firedCount == 1 && earlyScheduler.pendingCount == 1 && earlyStore.pendingWorkItemCount == 1 && earlyStore.visibleSources(windowID: window, displayed: []).count == 1)
    now.addTimeInterval(3600); await earlyScheduler.waitForFire()
    check("second wait requires fresh expiry delivery", earlyScheduler.firedCount == 1 && earlyScheduler.pendingCount == 0 && earlyStore.visibleSources(windowID: window, displayed: []).isEmpty)

    print("media-demo \(failed == 0 ? "OK" : "FAIL"): \(passed) checks passed, \(failed) failed")
    if failed != 0 { throw NSError(domain: "media-demo", code: failed) }
}


/// Uses the production DispatchWorkItem delivery path with short wall-clock delays.
/// The clock still advances in domain time; only actual dispatch can fire these callbacks.
@MainActor private final class MediaDemoScheduler: MediaDismissScheduling {
    private let dispatch = DispatchMediaDismissScheduler(delay: { _ in 0.01 })
    private var scheduled: [any MediaDismissTask] = []
    private(set) var firedCount = 0
    var pendingCount: Int { scheduled.filter(\.isPending).count }
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> any MediaDismissTask {
        let task = dispatch.schedule(after: delay) { [weak self] in self?.firedCount += 1; action() }
        scheduled.append(task); return task
    }
    func waitForFire() async {
        firedCount = 0 // Each wait requires a new actual delivery, even after an early fire.
        for _ in 0..<100 {
            if firedCount > 0 { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class MediaDemoInvalidations: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func note() { lock.lock(); defer { lock.unlock() }; value += 1 }
}
