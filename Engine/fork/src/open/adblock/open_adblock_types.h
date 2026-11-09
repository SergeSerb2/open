// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_ADBLOCK_OPEN_ADBLOCK_TYPES_H_
#define OPEN_ADBLOCK_OPEN_ADBLOCK_TYPES_H_

#include <cstdint>
#include <string>
#include <vector>

namespace open_engine {

// Why a request was stopped. Counted separately (adblock-fork §7.5) but
// summed for the Site Control Center's single number.
enum class AdBlockStopKind { kBlocked, kRedirected };

// How one LoadFromDirectory() ended; its |done| callback always gets one
// (review R2-5).
enum class AdBlockLoadResult {
  // The new engine is installed.
  kLoaded,
  // The load failed; the old engine stays (see AdBlockStatus::last_error).
  kFailed,
  // A newer load started first; this result was dropped.
  kStale,
  // The service shut down, or was destroyed, before the result arrived.
  kCancelled,
};

// A snapshot of one Profile's ad-block state for OpenEngine (the panel and
// "Copy AdBlock debug info"). A value type: no pointers into the engine, no
// page URLs, no list contents (adblock-fork §6.4).
struct AdBlockStatus {
  AdBlockStatus();
  AdBlockStatus(const AdBlockStatus&);
  AdBlockStatus& operator=(const AdBlockStatus&);
  ~AdBlockStatus();

  // The master switch for this Profile.
  bool enabled = false;
  // An engine (from the DAT or from text) is installed.
  bool engine_loaded = false;
  // The last successful load used the generation's engine.dat.
  bool engine_from_dat = false;
  // The generation the current engine came from (0: none).
  int64_t generation = 0;
  // Lists the current engine was built from.
  uint32_t list_count = 0;
  // Serialized size of the current engine (0: unknown).
  uint64_t dat_size_bytes = 0;
  // Wall time of the last build or load, in ms (-1: never).
  int64_t last_build_ms = -1;
  // The last failure: an operation and a file name, never page data.
  std::string last_error;
  // The engine is shared with another Profile that has the same lists
  // (adblock-fork §6.6).
  bool engine_shared = false;
  // "dat" when the lists can be cached as engine.dat, else "text-only"
  // ($removeparam or :remove*() rules, which a DAT drops).
  std::string dat_policy;
  std::vector<std::string> lossy_kinds;
  // Resources ($redirect stubs) in the engine, and the first 12 hex digits
  // of their SHA-256 ("" when none).
  uint32_t resources_loaded = 0;
  std::string resources_version;
  // §7.7: the match cap, and the checks whose URL was longer.
  uint32_t match_cap_bytes = 0;
  uint64_t checks = 0;
  uint64_t checks_truncated = 0;
  uint64_t cold_holds = 0;
  uint64_t cold_hold_max_ms = 0;
  // Cosmetic output v1 does not apply, summed over every cosmetic and
  // generic-selector query since the service started (adblock-fork §5.2,
  // lead ruling 6, review R3-4).
  uint64_t cosmetic_dropped_procedural = 0;
  uint64_t cosmetic_dropped_unsafe = 0;
  uint64_t cosmetic_dropped_style = 0;
  uint64_t cosmetic_dropped_remove = 0;
  uint64_t cosmetic_dropped_scriptlet = 0;
  uint64_t cosmetic_dropped_over_cap = 0;
  // Sorted.
  std::vector<std::string> excluded_domains;
};

}  // namespace open_engine

#endif  // OPEN_ADBLOCK_OPEN_ADBLOCK_TYPES_H_
