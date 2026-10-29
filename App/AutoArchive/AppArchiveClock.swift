import Foundation

@MainActor
final class AppArchiveClock {
    func now() -> Date {
        #if OPEN_AUTOMATION
        Date().addingTimeInterval(offsetSeconds)
        #else
        Date()
        #endif
    }
    #if OPEN_AUTOMATION
    private(set) var offsetSeconds: TimeInterval = 0
    func setOffsetSeconds(_ seconds: TimeInterval) throws {
        guard seconds.isFinite else {
            throw AutomationController.Failure(message: "invalid archive clock offset")
        }
        offsetSeconds = seconds
    }
    func setNowForAutomation(_ date: Date) throws {
        guard date.timeIntervalSince1970.isFinite else { throw AutomationController.Failure(message: "invalid archive date") }
        let realNow = Date()
        try setOffsetSeconds(date.timeIntervalSince(realNow))
    }
    func resetForAutomation() { offsetSeconds = 0 }
    #endif
}
