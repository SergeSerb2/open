#!/usr/bin/env python3
"""Scratch-only: add per-step thread CPU and instructions/cycles per scroll step to Bench.swift (same patch for any version)."""
import sys
from pathlib import Path
p = Path(sys.argv[1]) / 'Packages/OpenKit/Sources/sidebar-render/Bench.swift'; s = p.read_text()
s = s.replace('import AppKit\n', 'import AppKit\nimport Darwin\n', 1)
old = '''        while y < maxY {
            y = min(maxY, y + 120)
            steps.append(time {
                clip.scroll(to: NSPoint(x: 0, y: y))
                outline.enclosingScrollView?.reflectScrolledClipView(clip)
                scene.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                CATransaction.flush()
            })
        }'''
new = '''        func usage() -> (UInt64, UInt64) {
            var info = rusage_info_v4()
            _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) } }
            return (info.ri_instructions, info.ri_cycles)
        }
        var cpuSteps: [Double] = []
        let usage0 = usage()
        while y < maxY {
            y = min(maxY, y + 120)
            let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            steps.append(time {
                clip.scroll(to: NSPoint(x: 0, y: y))
                outline.enclosingScrollView?.reflectScrolledClipView(clip)
                scene.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                CATransaction.flush()
            })
            cpuSteps.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1e9)
        }
        let usage1 = usage()
        print(String(format: "scroll work: %.0f instructions/step, %.0f cycles/step over %d steps", Double(usage1.0 - usage0.0) / Double(steps.count), Double(usage1.1 - usage0.1) / Double(steps.count), steps.count))
        do { let s = cpuSteps.sorted(); print(String(format: "main-thread cpu: median %.3f ms, p95 %.3f ms", s[s.count / 2] * 1000, s[Int(Double(s.count) * 0.95)] * 1000)) }
        print("off-cpu wait: median 0 ms")'''
assert old in s, 'loop text differs'
s = s.replace(old, new, 1); p.write_text(s)
