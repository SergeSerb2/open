import Foundation
import OpenModel
import OpenWeb

public enum AutoPiPPolicy {
    public enum LeaveEvent: Sendable {
        case selection, space, split, minimize, occlusion, appHide, appSwitch, close, splitFocus, peek
        public var isLeave: Bool { switch self { case .selection, .space, .split: true; default: false } }
    }
    public enum Decision: Sendable, Equatable {
        case open, notLeave, settingOff, noPlayingVideo, tooSmall, inaudible, disallowed, hostDisabled, snoozed, manualPiP, videoDisabled, chromiumAutoPiP
    }
    /// A1–A8 and D-4. The caller supplies actual audibility; tab mute does not replace it.
    @MainActor public static func decide(tabID: ItemID, url: URL, state: WebMediaState, audible: Bool,
        event: LeaveEvent, settings: MediaSettings, rules: PiPSiteRules, session: PiPSession,
        disablePictureInPicture: Bool = false, privateSession: MediaSettings.PrivateHosts? = nil) -> Decision {
        guard event.isLeave else { return .notLeave }
        guard settings.automaticPiPEnabled else { return .settingOff }
        guard state.hasVideo && state.playback == .playing else { return .noPlayingVideo }
        guard state.largestVideoArea >= 160 * 90 else { return .tooSmall }
        guard audible || rules.configuration(for: url)?.activatesWhenInaudible == true else { return .inaudible }
        guard !rules.isDisallowed(url) else { return .disallowed }
        guard !settings.disabledHosts(privateSession: privateSession).contains(url.host?.lowercased() ?? "") else { return .hostDisabled }
        guard !session.snoozed.contains(tabID) else { return .snoozed }
        if let other = session.activeSource, other.tabID != tabID && !other.automatic { return .manualPiP }
        guard !disablePictureInPicture else { return .videoDisabled }
        guard !state.actions.contains(.enterAutoPictureInPicture) else { return .chromiumAutoPiP }
        return .open
    }
}
