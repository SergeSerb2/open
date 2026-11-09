#if OPEN_AUTOMATION && DEBUG
import AppKit
import Darwin
import OpenEngine

extension AutomationController {
  /// Process-owned counters only. No debugger, heap walk, or external task read.
  func adBlockMemory(_ args: [String: Any]) async throws -> [String: Any] {
    let action = args["action"] as? String ?? "snapshot"
    let adapter = app.adBlockEngineAdapter
    switch action {
    case "snapshot": break
    case "resume", "unload", "pause-updates":
      guard let raw = args["profile"] as? String,
        let profile = app.model.profiles.first(where: { $0.id.description == raw }),
        let store = app.stores.existingAdBlock else { throw Failure(message: "expected an open fixture Profile") }
      switch action {
      case "resume":
        for context in adapter.contexts(for: profile.id) { adapter.contextCreated(context, profileID: profile.id) }
      case "unload":
        for context in adapter.contexts(for: profile.id) {
          context.isAdBlockEnabled = false
          context.adBlockListDirectory = nil
        }
      default:
        // Cancel the fixture's update timer outside the measured interval.
        // Reopen through the real Store and production adapter; no binding override.
        try store.closeProfile(profile.id)
        try await store.openProfile(profile.id,
          directory: app.directories.adBlockDirectory(dataDirectoryName: profile.dataDirectoryName), scheduleUpdates: false)
      }
    default: throw Failure(message: "unknown ad-block memory action")
    }
    var addresses: UnsafeMutablePointer<vm_address_t>?
    var count: UInt32 = 0
    let result = malloc_get_all_zones(mach_task_self_, nil, &addresses, &count)
    var rows: [[String: Any]] = []
    if result == KERN_SUCCESS, let addresses {
      for index in 0..<Int(count) {
        guard let zone = UnsafeMutablePointer<malloc_zone_t>(bitPattern: UInt(addresses[index])) else { continue }
        var stats = malloc_statistics_t()
        malloc_zone_statistics(zone, &stats)
        rows.append(["name": zone.pointee.zone_name.map { String(cString: $0) } ?? "",
          "blocksInUse": stats.blocks_in_use, "sizeInUse": stats.size_in_use,
          "maxSizeInUse": stats.max_size_in_use, "sizeAllocated": stats.size_allocated])
      }
    }
    var info = task_vm_info_data_t()
    var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let measured = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size)
      }
    }
    return ["pid": Int(getpid()), "uptime": ProcessInfo.processInfo.systemUptime,
      "footprint": measured == KERN_SUCCESS ? info.phys_footprint : 0,
      "taskInfoResult": measured, "mallocResult": result, "mallocZones": rows,
      "stores": app.model.profiles.map { profile in
        ["profile": profile.id.description,
          "ready": app.stores.existingAdBlock?.isProfileOpen(profile.id) ?? false,
          "updating": app.stores.existingAdBlock?.isUpdating(profile.id) ?? false] as [String: Any]
      }]
  }
}
#endif
