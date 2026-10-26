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
  // Sorted.
  std::vector<std::string> excluded_domains;
};

}  // namespace open_engine

#endif  // OPEN_ADBLOCK_OPEN_ADBLOCK_TYPES_H_
