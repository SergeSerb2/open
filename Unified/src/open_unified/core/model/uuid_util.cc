// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/core/model/uuid_util.h"

#include "base/uuid.h"

namespace open_unified {

std::string GenerateUuidV4() {
  return base::Uuid::GenerateRandomV4().AsLowercaseString();
}

bool IsValidUuid(std::string_view text) {
  return base::Uuid::ParseCaseInsensitive(text).is_valid();
}

std::optional<std::string> NormalizeUuid(std::string_view text) {
  base::Uuid uuid = base::Uuid::ParseCaseInsensitive(text);
  if (!uuid.is_valid()) {
    return std::nullopt;
  }
  return uuid.AsLowercaseString();
}

}  // namespace open_unified
