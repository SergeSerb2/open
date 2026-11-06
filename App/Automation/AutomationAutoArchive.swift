#if OPEN_AUTOMATION
import AppKit
import OpenModel
import OpenFeatures
import OpenSidebar

extension AutomationController {
    private func archiveDate(_ value: Any?) throws -> Date {
        guard let raw = value as? String else { throw Failure(message: "expected ISO archive date") }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw), date.timeIntervalSince1970.isFinite else {
            throw Failure(message: "invalid archive date")
        }
        return date
    }
    private func archiveISO(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    private func changeArchiveClock(_ args: [String: Any], required: Bool) throws {
        let keys = Set(args.keys)
        guard keys.isSubset(of: ["now", "offsetSeconds", "reset"]), keys.count <= 1, !required || keys.count == 1 else {
            throw Failure(message: "expected exactly one archive clock argument")
        }
        if let value = args["now"] { try app.archiveClock.setNowForAutomation(archiveDate(value)) }
        else if let value = args["offsetSeconds"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw Failure(message: "invalid archive clock offset") }
            try app.archiveClock.setOffsetSeconds(number.doubleValue)
        } else if let value = args["reset"] {
            guard let flag = value as? Bool, flag, let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw Failure(message: "reset must be true") }
            app.archiveClock.resetForAutomation()
        }
    }
    func archiveState() -> [String: Any] {
        guard let scheduler = app.expirySweeper else { return ["running": false] }
        let state = scheduler.state, report = app.todayAutoArchive?.lastReport
        return ["now": archiveISO(app.archiveClock.now()), "offsetSeconds": app.archiveClock.offsetSeconds,
                "running": state.running, "nextExpiry": state.nextExpiry.map(archiveISO) ?? NSNull(),
                "timerArmed": state.timerArmed, "armedTimerCount": state.armedTimerCount,
                "timerGeneration": state.timerGeneration, "sweepCount": state.sweepCount,
                "countsByReason": state.countsByReason, "lastReason": state.lastReason?.rawValue ?? NSNull(),
                "lastSweep": report.map { ["now": archiveISO($0.now), "archivedCount": $0.archivedCount,
                                          "affectedSpaces": $0.affectedSpaceIDs.map(\.description).sorted()] as [String: Any] } ?? NSNull(),
                "educationRequested": app.todayAutoArchive?.educationRequested ?? false]
    }
    private func archiveBannerController(_ args: [String: Any]) throws -> BrowserWindowController {
        if let raw = args["window"] {
            guard let id = raw as? String, let controller = app.windowControllers.first(where: { $0.windowID.description == id }) else { throw Failure(message: "unknown banner window") }
            return controller
        }
        guard let controller = app.frontWindowController else { throw Failure(message: "no browser window") }
        return controller
    }
    private func archiveBannerState(_ controller: BrowserWindowController) -> [String: Any] {
        controller.sidebar.refreshAutoArchiveBanner(); controller.contentView.layoutSubtreeIfNeeded()
        let banner = controller.sidebar.autoArchiveBanner
        let frame = banner.map { controller.contentView.convert($0.bounds, from: $0) }
        return ["visible": banner != nil, "title": banner == nil ? "" : "We cleaned up!",
                "message": banner?.message ?? "", "threshold": banner?.thresholdText ?? "",
                "requested": controller.context.autoArchiveBannerRequested,
                "eligible": UserDefaults.standard.object(forKey: "open.sidebar.autoArchiveBannerEligible") as? Bool ?? true,
                "dismissed": UserDefaults.standard.bool(forKey: "open.sidebar.autoArchiveBannerDismissed"),
                "frame": frame.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? []]
    }
    func runArchiveCommand(_ cmd: String, _ args: [String: Any]) async throws -> Any {
        switch cmd {
        case "archive-state":
            guard args.isEmpty else { throw Failure(message: "archive-state takes no arguments") }
            return archiveState()
        case "archive-clock", "archive-sweep":
            try changeArchiveClock(args, required: cmd == "archive-clock")
            if cmd == "archive-clock" { app.expirySweeper?.rearm(); return archiveState() }
            let count = app.expirySweeper?.fire(reason: .automation) ?? 0
            var result = archiveState()
            result["archivedCount"] = count
            result["affectedSpaces"] = app.todayAutoArchive?.lastReport?.affectedSpaceIDs.map(\.description).sorted() ?? []
            return result
        case "archive-wake":
            guard Set(args.keys).isSubset(of: ["now"]) else { throw Failure(message: "archive-wake accepts only now") }
            try changeArchiveClock(args, required: false)
            let count = app.expirySweeper?.state.countsByReason["wake", default: 0] ?? 0
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            // The observer queues exactly one main-actor job; do not call the sweep here.
            for _ in 0..<20 {
                if (app.expirySweeper?.state.countsByReason["wake", default: 0] ?? 0) > count { break }
                await Task.yield()
            }
            guard (app.expirySweeper?.state.countsByReason["wake", default: 0] ?? 0) > count else { throw Failure(message: "wake observer did not run") }
            return archiveState()
        case "profile-archive-setting":
            guard Set(args.keys) == ["profile", "interval", "scope"], let raw = args["profile"] as? String,
                  let uuid = UUID(uuidString: raw), let profile = app.model.profile(id: ProfileID(rawValue: uuid)),
                  let value = args["interval"] as? String, let interval = AutoArchiveInterval(rawValue: value),
                  let scope = args["scope"] as? String, ["profile", "all"].contains(scope) else { throw Failure(message: "invalid Profile archive setting") }
            let settings = app.settingsPresenter.settings
            settings.profiles.select(profile.id); settings.profiles.proposeArchive(interval); settings.profiles.applyArchive(all: scope == "all")
            // Yield to the real Observation callback before returning diagnostics.
            await Task.yield(); await Task.yield()
            return ["profiles": app.model.profiles.filter { scope == "all" || $0.id == profile.id }.map {
                ["id": $0.id.description, "interval": $0.settings.autoArchiveAfter.rawValue]
            }, "state": archiveState()] as [String: Any]
        case "archive-list":
            guard Set(args.keys).isSubset(of: ["profile", "limit"]) else { throw Failure(message: "invalid archive-list arguments") }
            let profile: Profile
            if let raw = args["profile"] {
                guard let id = raw as? String, let uuid = UUID(uuidString: id), let found = app.model.profile(id: ProfileID(rawValue: uuid)) else { throw Failure(message: "unknown archive Profile") }
                profile = found
            } else {
                guard let found = app.frontWindowController?.context.focusedSpace.flatMap({ app.model.profile(id: $0.profileID) }) ?? app.model.defaultProfile else { throw Failure(message: "no Profile") }
                profile = found
            }
            var limit = 1000
            if let raw = args["limit"] {
                guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let integer = raw as? Int, (1...1000).contains(integer) else { throw Failure(message: "invalid archive limit") }
                limit = integer
            }
            let store = app.archiveSink.store(for: profile.id)
            let count = await store.count(), rows = await store.recent(limit: limit)
            return ["count": count, "rows": rows.map { ["id": $0.id.description, "kind": $0.kind.rawValue,
                "reason": $0.reason.rawValue, "space": $0.spaceID?.description ?? "", "profile": $0.profileID?.description ?? "",
                "archivedAt": archiveISO($0.archivedAt), "originalLocation": $0.originalLocation,
                "url": $0.url.absoluteString, "title": $0.title] as [String: Any] }] as [String: Any]
        case "archive-banner-state":
            guard Set(args.keys).isSubset(of: ["window"]) else { throw Failure(message: "invalid banner-state arguments") }
            return archiveBannerState(try archiveBannerController(args))
        case "archive-banner-action":
            guard Set(args.keys).isSubset(of: ["action", "window"]) else { throw Failure(message: "invalid banner-action arguments") }
            let controller = try archiveBannerController(args)
            controller.sidebar.refreshAutoArchiveBanner()
            guard let action = args["action"] as? String, ["got-it", "settings"].contains(action),
                  let banner = controller.sidebar.autoArchiveBanner else { throw Failure(message: "no visible archive banner or invalid action") }
            if action == "got-it" { banner.dismissButton.performClick(nil) }
            else {
                let index = (banner.messageView.string as NSString).range(of: "Settings").location
                _ = banner.textView(banner.messageView, clickedOnLink: "open-profile-settings", at: index)
            }
            await Task.yield()
            return archiveBannerState(controller)
        default: throw Failure(message: "unknown archive command")
        }
    }
}
#endif
