import OpenFeatures

extension AppDelegate {
    func startAutoArchiveIfNeeded() {
        guard expirySweeper == nil else { return }
        let clock = archiveClock
        let today = TodayAutoArchiveController(model: model)
        let sweeper = ExpirySweeper(now: { clock.now() }, nextExpiry: { [weak self, weak today] now in
            [today?.nextExpiry(now: now), self?.littleOpenCoordinator?.nextExpiry(now: now)].compactMap { $0 }.min()
        }, sweep: { [weak self, weak today] now in
            let todayCount = today?.sweep(now: now) ?? 0
            return todayCount + (self?.littleOpenCoordinator?.archiveExpired(now: now) ?? 0)
        })
        today.onScheduleInvalidated = { [weak self, weak sweeper] in
            sweeper?.rearm(); self?.scheduleSave()
        }
        today.onDidSweep = { [weak self] report in
            guard report.archivedCount > 0 else { return }
            self?.scheduleSave()
            for controller in self?.windowControllers ?? [] { controller.sidebar.refreshAutoArchiveBanner() }
        }
        todayAutoArchive = today; expirySweeper = sweeper
        today.startObserving(); sweeper.start()
    }
    func stopAutoArchive() {
        todayAutoArchive?.stopObserving(); expirySweeper?.stop()
    }
    func dismissAutoArchiveEducation() {
        todayAutoArchive?.dismissEducation()
        for controller in windowControllers { controller.sidebar.refreshAutoArchiveBanner() }
    }
}
