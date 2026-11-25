// Copyright 2026 The Open Authors. All rights reserved.
// Exact OPNH v1 binary container encoder/decoder matching
// Packages/OpenKit/Sources/OpenSleep/SleepEngine.swift (SleepHistoryContainer).

#ifndef OPEN_UNIFIED_CORE_SLEEP_OPNH_CODEC_H_
#define OPEN_UNIFIED_CORE_SLEEP_OPNH_CODEC_H_

#include <cstddef>
#include <cstdint>
#include <functional>
#include <vector>

#include "base/containers/span.h"

namespace open_unified {

inline constexpr uint8_t kOpnhMagic[4] = {0x4f, 0x50, 0x4e, 0x48};  // "OPNH"
inline constexpr uint32_t kOpnhVersion = 1;
inline constexpr size_t kOpnhHeaderBytes = 20;
inline constexpr size_t kOpnhMaxEntries = 512;
inline constexpr size_t kOpnhMaxBytes = 2 * 1024 * 1024;  // 2 MiB

enum class OpnhError {
  kNone,
  kInvalidHeader,
  kInvalidCount,
  kInvalidIndex,
  kInvalidLength,
  kTooLarge,
};

struct OpnhContainer {
  std::vector<std::vector<uint8_t>> entries;
  uint32_t current_index = 0;
  bool has_page_state = false;

  bool operator==(const OpnhContainer&) const = default;
};

// Validates |container| against OPNH v1 invariants (1..512 non-empty entries,
// valid current_index, total encoded size <= 2 MiB).
OpnhError ValidateOpnh(const OpnhContainer& container);

// Encodes |container| into exact OPNH v1 little-endian binary bytes.
bool EncodeOpnh(const OpnhContainer& container,
                std::vector<uint8_t>* out,
                OpnhError* error_out = nullptr);

// Strictly decodes OPNH v1 binary bytes, verifying magic, version == 1,
// entry count 1..512, current_index < count, flags bit 0 only, reserved zero
// bytes, non-empty length-prefixed payloads, exact trailing boundary, and
// <= 2 MiB total size.
bool DecodeOpnh(base::span<const uint8_t> data,
                OpnhContainer* out,
                OpnhError* error_out = nullptr);

// Attempts to build a container with page state via |default_entries_fn|; if
// that exceeds 2 MiB, retries using |excluding_page_state_fn| with
// has_page_state = false.
bool CaptureOpnhWithFallback(
    uint32_t current_index,
    const std::function<std::vector<std::vector<uint8_t>>()>& default_entries_fn,
    const std::function<std::vector<std::vector<uint8_t>>()>&
        excluding_page_state_fn,
    OpnhContainer* out,
    OpnhError* error_out = nullptr);

}  // namespace open_unified

#endif  // OPEN_UNIFIED_CORE_SLEEP_OPNH_CODEC_H_
