// Copyright 2026 The Open Authors. All rights reserved.
// Cross-platform lowercase UUID v4 helper backed by Chromium //base.

#ifndef OPEN_UNIFIED_CORE_MODEL_UUID_UTIL_H_
#define OPEN_UNIFIED_CORE_MODEL_UUID_UTIL_H_

#include <optional>
#include <string>
#include <string_view>

namespace open_unified {

// Generates a canonical lowercase RFC 4122 version 4 UUID string.
std::string GenerateUuidV4();

// Returns true if |text| is a valid UUID in any case.
bool IsValidUuid(std::string_view text);

// Parses |text| as a UUID and returns its canonical lowercase string,
// or std::nullopt if invalid.
std::optional<std::string> NormalizeUuid(std::string_view text);

}  // namespace open_unified

#endif  // OPEN_UNIFIED_CORE_MODEL_UUID_UTIL_H_
