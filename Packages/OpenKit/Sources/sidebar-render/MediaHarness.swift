import AppKit
import OpenMedia
import OpenModel
import OpenSidebar
import OpenWeb

/// Engine-free host used by the composed sidebar CLI; every delivered action is recorded.
@MainActor final class FakeSidebarMediaHost: WebMediaHost {
    enum Call: Equatable { case action(WebMediaAction), volume(Double), enterPiP, exitPiP(Bool) }
    let tab: Tab
    let context: SidebarContext
    var mediaState: WebMediaState
    var calls: [Call] = []
    init(tab: Tab, context: SidebarContext, state: WebMediaState) {
        self.tab = tab; self.context = context; mediaState = state
    }
    func publish() {
        context.media?.update(tabID: tab.id, windowID: context.windowID, state: mediaState,
                              isMuted: tab.isMuted, isCapturing: tab.live.isCapturing)
    }
    func perform(_ action: WebMediaAction) {
        calls.append(.action(action))
        switch action {
        case .play: mediaState.playback = .playing
        case .pause: mediaState.playback = .paused
        case .toggleMicrophone: mediaState.microphoneMuted = !(mediaState.microphoneMuted ?? false)
        case .toggleCamera: mediaState.cameraOn = !(mediaState.cameraOn ?? true)
        default: break
        }
        publish()
    }
    func setVolume(_ volume: Double) { calls.append(.volume(volume)); mediaState.volume = volume; publish() }
    func requestPictureInPicture() async -> Bool {
        calls.append(.enterPiP); mediaState.isPictureInPicture = true; publish(); return true
    }
    func exitPictureInPicture(pausing: Bool) {
        calls.append(.exitPiP(pausing)); mediaState.isPictureInPicture = false
        if pausing { mediaState.playback = .paused }; publish()
    }
}

@MainActor final class MediaHarnessDelegate: SidebarDelegate {
    let context: SidebarContext
    var hosts: [ItemID: FakeSidebarMediaHost] = [:]
    var intents: [MediaIntent] = []
    init(context: SidebarContext) { self.context = context }
    @discardableResult func sidebar(_ sidebar: SidebarView, didRequest intent: SidebarIntent) -> Bool {
        guard case .media(let media) = intent else { return ModelSidebarActions(context: context).perform(intent) }
        intents.append(media)
        switch media {
        case .play(let id): hosts[id]?.perform(.play)
        case .pause(let id): hosts[id]?.perform(.pause)
        case .previousTrack(let id): hosts[id]?.perform(.previousTrack)
        case .nextTrack(let id): hosts[id]?.perform(.nextTrack)
        case .toggleMicrophone(let id): hosts[id]?.perform(.toggleMicrophone)
        case .toggleCamera(let id): hosts[id]?.perform(.toggleCamera)
        case .toggleMute(let id):
            if let tab = context.model.tab(id: id) { context.model.setMuted(tabID: id, muted: !tab.isMuted); hosts[id]?.publish() }
        case .setVolume(let id, let value): hosts[id]?.setVolume(value)
        case .toggleVolumeDrawer(let id):
            if context.mediaDrawers.contains(id) { context.mediaDrawers.remove(id) } else { context.mediaDrawers.insert(id) }
        case .openPictureInPicture(let id):
            if let host = hosts[id] { Task { _ = await host.requestPictureInPicture() } }
        case .close(let id): hosts[id]?.perform(.pause); context.media?.dismiss(tabID: id)
        case .backToTab(let id): context.displayedTabIDs.insert(id)
        }
        return true
    }
    @discardableResult func add(tab: Tab, state: WebMediaState) -> FakeSidebarMediaHost {
        let host = FakeSidebarMediaHost(tab: tab, context: context, state: state)
        hosts[tab.id] = host; host.publish(); return host
    }
}
