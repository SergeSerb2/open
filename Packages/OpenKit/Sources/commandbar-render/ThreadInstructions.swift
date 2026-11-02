import Darwin
import Foundation

/// Optional harness-only SPI probe; never linked into an OpenKit library or App. Same as
/// sitecontrol-render/ThreadInstructions.swift (executables cannot share sources).
/// ABI: Apple XNU xnu-12377.1.9, bsd/sys/resource_private.h lines 36–74, 107–108:
/// https://github.com/apple-oss-distributions/xnu/blob/xnu-12377.1.9/bsd/sys/resource_private.h
/// THSC_CPI=1; thsc_cpi is { uint64_t instructions; uint64_t cycles; };
/// int thread_selfcounts(uint32_t kind, void *dst, size_t size).
@MainActor
enum ThreadInstructions {
    struct Sample: Codable {
        var instructions: UInt64 = 0
        var cycles: UInt64 = 0
    }

    struct Read {
        let sample: Sample?
        let status: String
    }

    private typealias Function = @convention(c) (UInt32, UnsafeMutableRawPointer?, size_t) -> Int32
    private static let function: Function? = {
        guard let handle = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW | RTLD_LOCAL) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "thread_selfcounts") else { return nil }
        // libSystem remains loaded for the lifetime of this executable.
        return unsafeBitCast(symbol, to: Function.self)
    }()

    static func read() -> Read {
        guard let function else { return Read(sample: nil, status: "unavailable: thread_selfcounts symbol missing") }
        guard Thread.isMainThread else { return Read(sample: nil, status: "unavailable: caller is not main thread") }
        var sample = Sample()
        // Verify the explicit C ABI before supplying the buffer.
        guard MemoryLayout<Sample>.size == 16, MemoryLayout<Sample>.alignment == 8,
              MemoryLayout<Sample>.offset(of: \.instructions) == 0,
              MemoryLayout<Sample>.offset(of: \.cycles) == 8 else {
            return Read(sample: nil, status: "unavailable: thsc_cpi layout mismatch")
        }
        let result = withUnsafeMutableBytes(of: &sample) { bytes in
            function(1, bytes.baseAddress, size_t(bytes.count))
        }
        guard result == 0 else { return Read(sample: nil, status: "unavailable: thread_selfcounts errno \(errno)") }
        guard sample.instructions > 0, sample.cycles > 0 else { return Read(sample: nil, status: "unavailable: zero thread counters") }
        return Read(sample: sample, status: "available")
    }
}
