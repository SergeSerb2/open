import Darwin
import Foundation

/// Harness only. Each sample executes the same standalone span used for calibration.
@MainActor
enum SM6CostGate {
    private struct Fixtures: Decodable {
        let version: Int
        let span: String
        let machines: [Baseline]
    }

    private struct Baseline: Decodable {
        let cpuBrand: String
        let osBuild: String
        let acceptedMedian: UInt64
        let discardedWarmup: UInt64
        let samples: [UInt64]

        var limit: UInt64 { (acceptedMedian * 11 + 9) / 10 }
    }

    private struct Report: Decodable {
        let mainThreadBefore: SM6ThreadInstructions.Sample?
        let mainThreadAfter: SM6ThreadInstructions.Sample?
        let mainThreadInstructions: UInt64?
        let mainThreadStatus: String
        let cleanup: Bool
    }

    static func run(_ args: [String] = []) throws {
        guard args.isEmpty || args == ["--fail-child-after-host"] else {
            throw CLIError(description: "usage: sidebar-render sm6-cost [--fail-child-after-host]")
        }
        let fixtures = try loadFixtures()
        let cpu = try systemString("machdep.cpu.brand_string"), os = try systemString("kern.osversion")
        let baseline = fixtures.machines.first { $0.cpuBrand == cpu && $0.osBuild == os }
        print("  INFO SM6 cost fixture v\(fixtures.version), CPU=\(cpu), macOS build=\(os)")
        print("  INFO SM6 cost: discard exactly one warm-up process, then measure five fresh processes")
        var counts: [UInt64] = []
        var unavailable = false
        for index in 0...5 {
            let report = try sample(index: index, failAfterHost: !args.isEmpty)
            if let before = report.mainThreadBefore, let after = report.mainThreadAfter,
               let count = report.mainThreadInstructions, before.instructions > 0,
               after.instructions > before.instructions, after.cycles > before.cycles,
               count == after.instructions - before.instructions, report.mainThreadStatus == "available" {
                print("  INFO SM6 cost process \(index)\(index == 0 ? " discarded warm-up" : " measured"): \(count) instructions")
                if index > 0 { counts.append(count) }
            } else {
                print("  INFO SM6 cost unavailable: \(report.mainThreadStatus)")
                unavailable = true
                break
            }
        }
        guard !unavailable, counts.count == 5 else {
            if baseline != nil { throw CLIError(description: "SM6 known-machine cost counter unavailable; no fallback") }
            print("  INFO SM6 unknown machine: no accepted cost fixture; cost was not checked")
            return
        }
        let median = counts.sorted()[2]
        print("  INFO SM6 cost five-process median=\(median); raw=\(counts); range/median=\(Double(counts.max()! - counts.min()!) / Double(median))")
        guard let baseline else {
            print("  INFO SM6 unknown machine: measured median \(median); no accepted cost fixture; cost was not checked")
            return
        }
        let passed = median <= baseline.limit
        Checks.check(passed,
                     "SM6 cost median \(median) <= \(baseline.limit) instructions (accepted \(baseline.acceptedMedian), ceil × 1.10)")
        if !passed { throw CLIError(description: "SM6 cost gate failed") }
    }

    private static func loadFixtures() throws -> Fixtures {
        guard let url = Bundle.module.url(forResource: "sm6-cost-baselines", withExtension: "json") else {
            throw CLIError(description: "SM6 cost fixture missing")
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (1...8192).contains(size) else { throw CLIError(description: "SM6 fixture exceeds 8192 bytes") }
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
        guard fixtures.version == 1, fixtures.span == "fresh-process-10x100-900x700-scale1-settle3-v1",
              fixtures.machines.count <= 16 else { throw CLIError(description: "SM6 fixture version/span/count invalid") }
        var keys = Set<String>()
        for machine in fixtures.machines {
            guard !machine.cpuBrand.isEmpty, machine.cpuBrand.utf8.count <= 128,
                  !machine.osBuild.isEmpty, machine.osBuild.utf8.count <= 64,
                  // Legacy fixtures have five fresh-process samples. The lead's
                  // 2026-11-08 ruling uses ten run medians (five unchanged-main
                  // pairs); each run still discards one child and measures five.
                  [5, 10].contains(machine.samples.count), machine.samples.allSatisfy({ $0 > 0 }),
                  machine.discardedWarmup > 0, median(machine.samples) == machine.acceptedMedian,
                  machine.acceptedMedian <= (UInt64.max - 9) / 11,
                  keys.insert(machine.cpuBrand + "\n" + machine.osBuild).inserted else {
                throw CLIError(description: "SM6 invalid/duplicate accepted fixture")
            }
        }
        return fixtures
    }

    private static func median(_ values: [UInt64]) -> UInt64 {
        let sorted = values.sorted(), middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        let lower = sorted[middle - 1], upper = sorted[middle]
        return lower + (upper - lower) / 2 + (upper - lower) % 2
    }

    private static func systemString(_ name: String) throws -> String {
        var bytes = [CChar](repeating: 0, count: 256), size = 256
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0, size > 1, size <= bytes.count,
              bytes[size - 1] == 0 else { throw CLIError(description: "SM6 machine key unavailable: \(name)") }
        return String(decoding: bytes.prefix(size - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func sample(index: Int, failAfterHost: Bool) throws -> Report {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("open-sm6-child-\(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let result = Result { try sampleChild(index: index, failAfterHost: failAfterHost, root: root) }
        // The child's defer has reaped it before its files are removed, even on failure.
        do { try files.removeItem(at: root) }
        catch { throw CLIError(description: "SM6 child temporary-root cleanup failed: \(error)") }
        return try result.get()
    }

    private static func sampleChild(index: Int, failAfterHost: Bool, root: URL) throws -> Report {
        let files = FileManager.default
        let home = root.appendingPathComponent("home"), temporary = root.appendingPathComponent("tmp")
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        try files.createDirectory(at: temporary, withIntermediateDirectories: true)
        let job = Process(), pipe = Pipe()
        job.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        job.arguments = ["sm6-measure", "--thread-instructions"] + (failAfterHost ? ["--fail-after-host"] : [])
        job.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = home.path
        environment["TMPDIR"] = temporary.path + "/"
        job.environment = environment
        job.standardInput = FileHandle.nullDevice
        job.standardOutput = pipe
        job.standardError = pipe
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else { throw CLIError(description: "SM6 pipe setup failed") }
        try job.run()
        let pid = job.processIdentifier
        defer {
            // Process retains the unreaped child: this PID cannot name another job.
            if job.isRunning {
                job.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 2
                while job.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.01) }
                if job.isRunning { kill(pid, SIGKILL) }
            }
            job.waitUntilExit()
            print("  INFO SM6 child process \(index) pid=\(pid) reaped; temporary root removed on return")
        }
        try pipe.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        // At most 65536 output bytes plus one 4096-byte read buffer. No unbounded pipe read.
        var output = Data(), buffer = [UInt8](repeating: 0, count: 4096), eof = false
        while !eof {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CLIError(description: "SM6 child exceeded 15 seconds") }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard output.count + count <= 65536 else { throw CLIError(description: "SM6 child output exceeds 65536 bytes") }
                output.append(contentsOf: buffer.prefix(count))
            } else if count == 0 { eof = true }
            else if errno == EAGAIN || errno == EINTR { Thread.sleep(forTimeInterval: 0.01) }
            else { throw CLIError(description: "SM6 child output read failed: \(errno)") }
        }
        while job.isRunning {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CLIError(description: "SM6 child exceeded 15 seconds") }
            Thread.sleep(forTimeInterval: 0.01)
        }
        job.waitUntilExit()
        guard let text = String(data: output, encoding: .utf8) else { throw CLIError(description: "SM6 child output is not UTF-8") }
        print(text, terminator: "")
        guard job.terminationStatus == 0 else { throw CLIError(description: "SM6 child failed with exit \(job.terminationStatus)") }
        let lines = text.split(separator: "\n").filter { $0.hasPrefix("SM6_JSON ") }
        guard lines.count == 1 else { throw CLIError(description: "SM6 child must return exactly one report") }
        let report = try JSONDecoder().decode(Report.self, from: Data(lines[0].dropFirst(9).utf8))
        guard report.cleanup else { throw CLIError(description: "SM6 child did not close its hosts") }
        return report
    }
}
