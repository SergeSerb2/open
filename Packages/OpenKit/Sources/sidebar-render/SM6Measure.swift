import AppKit
import Darwin
import OpenModel
import OpenSidebar

/// Shared with the existing wall-clock check. No fixture creation is measured.
@MainActor
enum SM6Fixture {
    struct Measurement {
        let manager: SpaceManagerView
        let host: ScaledWindow
        let before: SM6Counters.ProcessSample
        let after: SM6Counters.ProcessSample
        let wallMS: Double
        let mainCPUMS: Double
    }

    static func makeModel() -> BrowserModel {
        let model = Synthetic.model(), profile = model.profiles[0]
        model.spaces = (0..<10).map { i in
            let space = Space(title: "Space \(i + 1)", icon: .emoji("📚"), profileID: profile.id)
            Synthetic.fillBulk(space, rows: 100)
            return space
        }
        model.windows[0].focusedSpaceID = model.spaces[0].id
        model.rebuildIndex()
        return model
    }

    /// Exactly the old SM6 body, including SidebarContext and all three settle passes.
    static func firstLayout(model: BrowserModel, preferences: UserDefaults = .standard) -> (SpaceManagerView, ScaledWindow) {
        let manager = SpaceManagerView(context: SidebarContext(model: model, windowID: model.windows[0].id,
                                                              previewPreferences: preferences))
        manager.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let host = OffscreenRenderer.host(manager, scale: 1)
        return (manager, host)
    }

    static func measure(model: BrowserModel, preferences: UserDefaults = .standard) throws -> Measurement {
        let before = try SM6Counters.process()
        let cpuStart = try SM6Counters.mainCPU()
        let wallStart = CACurrentMediaTime()
        let (manager, host) = firstLayout(model: model, preferences: preferences)
        let wallEnd = CACurrentMediaTime()
        // Install cleanup before any fallible post-layout read. The caller owns
        // the host only after every counter is valid.
        var transferred = false
        defer { if !transferred { host.contentView = nil; host.close() } }
        let cpuEnd = try SM6Counters.mainCPU()
        let after = try SM6Counters.process()
        guard after.instructions > before.instructions, after.cycles > before.cycles, cpuEnd >= cpuStart else {
            throw CLIError(description: "SM6 counter delta is zero/backward: instructions \(before.instructions) → \(after.instructions), cycles \(before.cycles) → \(after.cycles)")
        }
        transferred = true
        return Measurement(manager: manager, host: host, before: before, after: after,
                           wallMS: (wallEnd - wallStart) * 1000, mainCPUMS: (cpuEnd - cpuStart) * 1000)
    }
}

/// Public Darwin counters only. Failures never fall back to CPU or wall time.
enum SM6Counters {
    struct ProcessSample: Codable {
        let instructions: UInt64
        let cycles: UInt64
    }

    struct ThreadSample: Codable {
        let id: UInt64
        let name: String
        let cpuNS: UInt64
    }

    static func process() throws -> ProcessSample {
        var info = rusage_info_v4()
        let status = withUnsafeMutableBytes(of: &info) { bytes in
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4,
                            bytes.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
        }
        guard status == 0 else { throw CLIError(description: "SM6 proc_pid_rusage failed: errno \(errno)") }
        guard info.ri_instructions > 0, info.ri_cycles > 0 else {
            throw CLIError(description: "SM6 process counters are zero/unavailable")
        }
        return ProcessSample(instructions: info.ri_instructions, cycles: info.ri_cycles)
    }

    static func mainCPU() throws -> Double {
        var value = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) == 0 else {
            throw CLIError(description: "SM6 main-thread CPU read failed: errno \(errno)")
        }
        return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
    }

    /// Outside the instruction/wall window. Releases both the thread rights and array.
    static func threads() throws -> [ThreadSample] {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        let status = task_threads(mach_task_self_, &list, &count)
        guard status == KERN_SUCCESS, let list else {
            throw CLIError(description: "SM6 task_threads failed: \(status)")
        }
        defer {
            for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[index]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        guard count <= 256 else { throw CLIError(description: "SM6 unexpected thread count: \(count)") }
        return try (0..<Int(count)).map { index in
            var identity = thread_identifier_info_data_t()
            var identityCount = mach_msg_type_number_t(MemoryLayout.size(ofValue: identity) / MemoryLayout<integer_t>.stride)
            let idStatus = withUnsafeMutablePointer(to: &identity) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(identityCount)) {
                    thread_info(list[index], thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identityCount)
                }
            }
            var info = thread_extended_info_data_t()
            var infoCount = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.stride)
            let infoStatus = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(list[index], thread_flavor_t(THREAD_EXTENDED_INFO), $0, &infoCount)
                }
            }
            guard idStatus == KERN_SUCCESS, infoStatus == KERN_SUCCESS else {
                throw CLIError(description: "SM6 thread_info failed: id=\(idStatus) extended=\(infoStatus)")
            }
            let name = withUnsafeBytes(of: info.pth_name) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            return ThreadSample(id: identity.thread_id, name: name, cpuNS: info.pth_user_time + info.pth_system_time)
        }.sorted { $0.id < $1.id }
    }
}

@MainActor
enum SM6Measure {
    private struct ThreadDelta: Codable {
        let id: UInt64
        let name: String
        let main: Bool
        let born: Bool
        let cpuMS: Double
    }

    private struct Result: Codable {
        let instructions: UInt64
        let cycles: UInt64
        let before: SM6Counters.ProcessSample
        let after: SM6Counters.ProcessSample
        let wallMS: Double
        let mainCPUMS: Double
        let load1: Double
        let censusWallMS: Double
        let threadsBefore: [SM6Counters.ThreadSample]
        let threadsAfter: [SM6Counters.ThreadSample]
        let threadDeltas: [ThreadDelta]
        let exitedThreadIDs: [UInt64]
        let builtColumns: Int
        var cleanup = false
    }

    /// One fresh process, one fixed construction, no run-loop turn until clocks stop.
    /// No instruction budget exists yet; the default check keeps its 120 ms gate.
    static func run(_ args: [String]) throws {
        guard args.isEmpty || args == ["--fail-after-host"] else {
            throw CLIError(description: "usage: sidebar-render sm6-measure [--fail-after-host]")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("open-sm6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Set before NSApplication/UserDefaults initialization. The proof driver also
        // supplies a fresh launch-time CFFIXED_USER_HOME/TMPDIR for system caches.
        setenv("CFFIXED_USER_HOME", root.path, 1)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let suite = "com.open.sm6.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suite) else {
            throw CLIError(description: "SM6 cannot create disposable preferences")
        }
        defer { preferences.removePersistentDomain(forName: suite) }
        SidebarHaptics.defaults = preferences
        let model = SM6Fixture.makeModel()
        var mainID: UInt64 = 0
        guard pthread_threadid_np(nil, &mainID) == 0 else { throw CLIError(description: "SM6 main thread ID unavailable") }
        let load = Checks.loadAverage1()
        let censusStart = CACurrentMediaTime()
        let threadsBefore = try SM6Counters.threads()
        let measured = try SM6Fixture.measure(model: model, preferences: preferences)
        let manager = measured.manager, host = measured.host
        var cleaned = false
        func closeHost() {
            guard !cleaned else { return }
            host.contentView = nil
            host.close()
            cleaned = true
            print("SM6 cleanup hosts=\(NSApp.windows.filter { $0.contentView != nil }.count) visible=\(NSApp.windows.filter(\.isVisible).count)")
        }
        defer { closeHost() }
        let threadsAfter = try SM6Counters.threads()
        let censusEnd = CACurrentMediaTime()
        if args == ["--fail-after-host"] { throw CLIError(description: "SM6 forced failure after host") }
        let previous = Dictionary(uniqueKeysWithValues: threadsBefore.map { ($0.id, $0) })
        let deltas = try threadsAfter.map { thread in
            let old = previous[thread.id]
            guard thread.cpuNS >= (old?.cpuNS ?? 0) else { throw CLIError(description: "SM6 backward thread CPU for \(thread.id)") }
            return ThreadDelta(id: thread.id, name: thread.name, main: thread.id == mainID, born: old == nil,
                               cpuMS: Double(thread.cpuNS - (old?.cpuNS ?? 0)) / 1_000_000)
        }
        var result = Result(instructions: measured.after.instructions - measured.before.instructions,
                            cycles: measured.after.cycles - measured.before.cycles,
                            before: measured.before, after: measured.after, wallMS: measured.wallMS,
                            mainCPUMS: measured.mainCPUMS, load1: load,
                            censusWallMS: (censusEnd - censusStart) * 1000,
                            threadsBefore: threadsBefore, threadsAfter: threadsAfter, threadDeltas: deltas,
                            exitedThreadIDs: threadsBefore.filter { old in !threadsAfter.contains { $0.id == old.id } }.map(\.id),
                            builtColumns: manager.builtColumnIDs.count)
        print(String(format: "SM6 first layout instructions %llu; cycles %llu; wall %.3f ms, main-thread CPU %.3f ms, load1 %.2f (diagnostic; budget pending M5)",
                     result.instructions, result.cycles, result.wallMS, result.mainCPUMS, result.load1))
        for delta in deltas {
            print(String(format: "SM6 thread id=%llu name=%@ main=%@ born=%@ cpu=%.3f ms (census interval)",
                         delta.id, delta.name.isEmpty ? "<unnamed>" : delta.name,
                         String(delta.main), String(delta.born), delta.cpuMS))
        }
        Checks.check((1...4).contains(manager.builtColumnIDs.count), "SM6 isolated first layout builds 1...4 visible columns (\(manager.builtColumnIDs.count))")
        SpaceManagerChecks.checkLargeManagerUpdates(model: model, manager: manager)
        closeHost()
        guard !host.isVisible, host.contentView == nil, !NSApp.windows.contains(where: \.isVisible) else {
            throw CLIError(description: "SM6 host/window cleanup failed")
        }
        result.cleanup = true
        let encoded = try JSONEncoder().encode(result)
        print("SM6_JSON \(String(decoding: encoded, as: UTF8.self))")
        guard Checks.failures == 0 else { throw CLIError(description: "SM6 structural checks failed") }
    }
}
