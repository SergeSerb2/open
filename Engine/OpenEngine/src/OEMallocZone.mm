// Early malloc zone registration for PartitionAlloc (docs/engine-fork.md,
// "PartitionAlloc and the launch race").
//
// Adapted from Chromium's base/allocator/early_zone_registration_apple.cc
// (Copyright 2021 The Chromium Authors; BSD-style license, Chromium's
// LICENSE file), which Chrome calls first thing in main().
//
// Why: Chromium Embedded Framework uses PartitionAlloc as malloc. Its load-time
// constructor makes PartitionAlloc the default malloc zone. Without a
// delegating zone in place it does so with an unregister/register pair, and
// between the two the system's zone is not registered: a free() on another
// thread then finds no owner zone and crashes ("Oops! No zone found",
// allocator_shim_apple.cc). Open loads the framework only after AppKit has
// started and the first window is on screen, so other threads exist; a launch
// crashed this way on a CoreSpotlight queue (Open-2026-10-26-110130.ips).
//
// The fix is Chrome's: while the process is still single-threaded, install a
// zone that forwards every allocation to the system zone and owns nothing.
// PartitionAlloc recognizes it by name and replaces it in one step, so the
// system zone stays registered throughout.

#include <malloc/malloc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>

#include <cstdio>
#include <cstring>
#include <cstdlib>

namespace {

// Must match PartitionAlloc's kDelegatingZoneName and kZoneVersion
// (partition_alloc/shim/early_zone_registration_utils_apple.h). PartitionAlloc
// compares the name's text. A rebase that changes either is in the rebase
// watch list (docs/engine-fork.md).
constexpr char kDelegatingZoneName[] = "DelegatingDefaultZoneForPartitionAlloc";
constexpr char kPartitionAllocZoneName[] = "PartitionAlloc";
constexpr unsigned kZoneVersion = 13;

// Static storage: libmalloc keeps the pointers.
malloc_zone_t g_delegating_zone;
malloc_introspection_t g_delegating_zone_introspect;
malloc_zone_t* g_default_zone;

bool GetZones(vm_address_t** zones, unsigned* count) {
  return malloc_get_all_zones(mach_task_self(), nullptr, zones, count) ==
         KERN_SUCCESS;
}

bool IsZoneRegistered(const char* name) {
  vm_address_t* zones = nullptr;
  unsigned count = 0;
  if (!GetZones(&zones, &count)) {
    return false;
  }
  for (unsigned i = 0; i < count; ++i) {
    const auto* zone = reinterpret_cast<malloc_zone_t*>(zones[i]);
    if (zone->zone_name && std::strcmp(zone->zone_name, name) == 0) {
      return true;
    }
  }
  return false;
}

malloc_zone_t* DefaultZone() {
  vm_address_t* zones = nullptr;
  unsigned count = 0;
  if (!GetZones(&zones, &count) || count == 0) {
    return nullptr;
  }
  // malloc_default_zone() returns the initial zone, not the current default:
  // the default is the first registered zone.
  return reinterpret_cast<malloc_zone_t*>(zones[0]);
}

// Chrome aborts where this logs: Open must still start, but a failed
// install must show in the logs (the launch race is back then).
void LogSkipped(const char* why) {
  fprintf(stderr, "OpenEngine: early malloc zone registration skipped: %s\n",
          why);
}

// Before main() and before AppKit, in the app and in every helper (all link
// OpenEngine). Chrome makes the same call at the start of main().
__attribute__((constructor)) void OERegisterDelegatingMallocZone() {
  // Timestamp our only pre-main constructor without Objective-C, timers or
  // Foundation initialization. This bounds the engine wrapper's static work.
  const char* value = std::getenv("OPEN_SPEED_TRACE");
  const bool trace = value && std::strcmp(value, "1") == 0;
  struct TraceEnd {
    bool enabled;
    ~TraceEnd() {
      if (enabled) fprintf(stderr, "OpenSpeed engine allocatorZoneEnd %llu\n",
                           (unsigned long long)mach_continuous_time());
    }
  } trace_end{trace};
  if (trace) fprintf(stderr, "OpenSpeed engine allocatorZoneBegin %llu\n",
                     (unsigned long long)mach_continuous_time());
  // Another library got there first: leave the zones alone.
  if (IsZoneRegistered(kDelegatingZoneName)) {
    LogSkipped(
        "a delegating zone is already registered (another copy installed it)");
    return;
  }
  if (IsZoneRegistered(kPartitionAllocZoneName)) {
    LogSkipped(
        "PartitionAlloc is already a malloc zone (the engine loaded first)");
    return;
  }
  malloc_zone_t* purgeable_zone = malloc_default_purgeable_zone();
  g_default_zone = DefaultZone();
  if (!g_default_zone) {
    LogSkipped(
        "the malloc zones could not be read; PartitionAlloc will install "
        "itself on its racy path");
    return;
  }

  // Allocation calls go to the real system zone. The system zone's pointer
  // is a larger struct, so pass g_default_zone, never our zone.
  g_delegating_zone.malloc = [](malloc_zone_t*, size_t size) {
    return g_default_zone->malloc(g_default_zone, size);
  };
  g_delegating_zone.calloc = [](malloc_zone_t*, size_t count, size_t size) {
    return g_default_zone->calloc(g_default_zone, count, size);
  };
  g_delegating_zone.valloc = [](malloc_zone_t*, size_t size) {
    return g_default_zone->valloc(g_default_zone, size);
  };
  g_delegating_zone.realloc = [](malloc_zone_t*, void* ptr, size_t size) {
    return g_default_zone->realloc(g_default_zone, ptr, size);
  };
  g_delegating_zone.batch_malloc = [](malloc_zone_t*, size_t size,
                                      void** results, unsigned requested) {
    return g_default_zone->batch_malloc(g_default_zone, size, results,
                                        requested);
  };
  g_delegating_zone.memalign = [](malloc_zone_t*, size_t alignment,
                                  size_t size) {
    return g_default_zone->memalign(g_default_zone, alignment, size);
  };

  // The zone owns nothing, so free() skips it. Some CoreFoundation code calls
  // malloc_zone_free(zone, ptr) directly; forward those.
  g_delegating_zone.size = [](malloc_zone_t*, const void*) -> size_t {
    return 0;
  };
  g_delegating_zone.free = [](malloc_zone_t*, void* ptr) {
    g_default_zone->free(g_default_zone, ptr);
  };
  g_delegating_zone.free_definite_size = [](malloc_zone_t*, void* ptr,
                                            size_t size) {
    g_default_zone->free_definite_size(g_default_zone, ptr, size);
  };
  g_delegating_zone.batch_free = [](malloc_zone_t*, void** to_be_freed,
                                    unsigned count) {
    g_default_zone->batch_free(g_default_zone, to_be_freed, count);
  };
  if (g_default_zone->version >= 13 && g_default_zone->try_free_default) {
    g_delegating_zone.try_free_default = [](malloc_zone_t*, void* ptr) {
      g_default_zone->try_free_default(g_default_zone, ptr);
    };
  }
  g_delegating_zone.pressure_relief = [](malloc_zone_t*, size_t) -> size_t {
    return 0;
  };

  // Introspection: nothing to enumerate, count or lock (the real zone is
  // still registered and does all of that; locking it twice before fork()
  // would deadlock).
  g_delegating_zone_introspect.enumerator =
      [](task_t, void*, unsigned, vm_address_t, memory_reader_t,
         vm_range_recorder_t) -> kern_return_t { return KERN_SUCCESS; };
  g_delegating_zone_introspect.good_size = [](malloc_zone_t*, size_t size) {
    return g_default_zone->introspect->good_size(g_default_zone, size);
  };
  g_delegating_zone_introspect.check = [](malloc_zone_t*) -> boolean_t {
    return true;
  };
  g_delegating_zone_introspect.print = [](malloc_zone_t*, boolean_t) {};
  g_delegating_zone_introspect.log = [](malloc_zone_t*, void*) {};
  g_delegating_zone_introspect.force_lock = [](malloc_zone_t*) {};
  g_delegating_zone_introspect.force_unlock = [](malloc_zone_t*) {};
  g_delegating_zone_introspect.reinit_lock = [](malloc_zone_t*) {};
  g_delegating_zone_introspect.statistics = [](malloc_zone_t*,
                                               malloc_statistics_t*) {};
  g_delegating_zone_introspect.zone_locked = [](malloc_zone_t*) -> boolean_t {
    return false;
  };
  g_delegating_zone_introspect.enable_discharge_checking =
      [](malloc_zone_t*) -> boolean_t { return false; };
  g_delegating_zone_introspect.disable_discharge_checking =
      [](malloc_zone_t*) {};
  g_delegating_zone_introspect.discharge = [](malloc_zone_t*, void*) {};

  g_delegating_zone.version = kZoneVersion;
  g_delegating_zone.introspect = &g_delegating_zone_introspect;
  g_delegating_zone.zone_name = kDelegatingZoneName;

  // register appends; unregister swaps the last zone into the freed slot.
  // 1. |default|...|delegating|
  // 2. |delegating|...|          (the default zone is out for an instant,
  //                               but no other thread exists yet)
  // 3. |delegating|...|default|
  malloc_zone_register(&g_delegating_zone);
  malloc_zone_unregister(g_default_zone);
  malloc_zone_register(g_default_zone);
  // Keep the purgeable zone after the default one.
  malloc_zone_unregister(purgeable_zone);
  malloc_zone_register(purgeable_zone);

  // Upstream's final check, logged instead of fatal.
  if (DefaultZone() != &g_delegating_zone) {
    const malloc_zone_t* first = DefaultZone();
    fprintf(stderr,
            "OpenEngine: early malloc zone registration failed: zone 0 is "
            "\"%s\", not the delegating zone; PartitionAlloc will install "
            "itself on its racy path\n",
            first && first->zone_name ? first->zone_name : "?");
  }
}

}  // namespace
