import Foundation
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
    let replacement = session.request(tabID: other, automatic: true); session.didEnter(tabID: other)
    check("AP8 automatic replaces", decision() == .open && replacement?.reason == .replaced && replacement?.pause == false)
    _ = session.close(.sourceGone)
    check("AP9 disablePictureInPicture", decision(disabled: true) == .videoDisabled)
    for event: AutoPiPPolicy.LeaveEvent in [.minimize, .occlusion, .appHide, .appSwitch, .close, .splitFocus, .peek] {
        check("AP10 no leave \(event)", decision(event: event) == .notLeave)
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
    check("MS1 displayed, split, peek and PiP excluded", store.visibleSources(windowID: window, displayed: [displayed, split, peek]).map(\.tabID) == [minimized])
    store.update(tabID: other, windowID: WindowID(), state: video, isMuted: false, isCapturing: false)
    check("MS2 other window excluded; same window Space included", !store.visibleSources(windowID: window, displayed: []).contains { $0.tabID == other } && store.visibleSources(windowID: window, displayed: []).contains { $0.tabID == minimized })
    let ordering = MediaSourceStore(clock: { now }), ids = (0..<4).map { _ in ItemID() }
    for id in ids { ordering.update(tabID: id, windowID: window, state: video, isMuted: false, isCapturing: false) }
    check("MS3 newest three", ordering.visibleSources(windowID: window, displayed: []).map(\.tabID) == Array(ids.reversed().prefix(3)))
    ordering.noteInteraction(tabID: ids[0])
    check("MS3 interaction promotes", ordering.visibleSources(windowID: window, displayed: []).first?.tabID == ids[0])
    let pausedStore = MediaSourceStore(clock: { now })
    var paused = video; paused.playback = .paused
    pausedStore.update(tabID: tab, windowID: window, state: paused, isMuted: false, isCapturing: false)
    check("MS5 one paused work item", pausedStore.pendingWorkItemCount == 1 && pausedStore.pendingDismissDeadline == now.addingTimeInterval(3600))
    now.addTimeInterval(59 * 60)
    check("MS4 59 min visible", pausedStore.visibleSources(windowID: window, displayed: []).count == 1)
    pausedStore.noteInteraction(tabID: tab)
    let extendedDeadline = now.addingTimeInterval(3600)
    now.addTimeInterval(60)
    check("MS4 interaction restarts deadline", pausedStore.visibleSources(windowID: window, displayed: []).count == 1 && pausedStore.pendingDismissDeadline == extendedDeadline)
    now.addTimeInterval(59 * 60)
    check("MS4 60 min hidden", pausedStore.visibleSources(windowID: window, displayed: []).isEmpty)
    pausedStore.update(tabID: tab, windowID: window, state: video, isMuted: false, isCapturing: false)
    check("MS5 no paused work item", pausedStore.pendingWorkItemCount == 0)
    pausedStore.dismiss(tabID: tab); pausedStore.update(tabID: tab, windowID: window, state: paused, isMuted: false, isCapturing: false)
    check("dismissed until next play", pausedStore.visibleSources(windowID: window, displayed: []).isEmpty)
    pausedStore.update(tabID: tab, windowID: window, state: video, isMuted: false, isCapturing: false)
    check("replay restores card", pausedStore.visibleSources(windowID: window, displayed: []).count == 1)
    pausedStore.update(tabID: tab, windowID: window, state: WebMediaState(), isMuted: false, isCapturing: false)
    check("ended source removed", pausedStore.sources[tab] == nil)
    check("SR1 twitch subdomain", rules.configuration(for: URL(string: "https://www.twitch.tv")!)?.hide == ["play", "scrub", "skip"])
    check("SR1 suffix attack rejected", rules.configuration(for: URL(string: "https://twitch.tv.evil.com")!) == nil)
    check("MN1 hostless menu", PiPMenuEntry.entries(url: URL(string: "about:blank"), muted: false, keepOnTop: true, disabledHosts: []).map(\.title) == ["Keep Window on Top", "", "Mute"])
    check("MN1 host menu order", PiPMenuEntry.entries(url: URL(string: "https://example.com/path"), muted: true, keepOnTop: false, disabledHosts: ["example.com"]).map(\.title) == ["Keep Window on Top", "", "Picture-in-picture on example.com:", "Open automatically", "Turn off", "", "Copy URL", "Unmute"])
    print("media-demo OK: \(passed) checks passed, \(failed) failed")
    if failed != 0 { throw NSError(domain: "media-demo", code: failed) }
}
