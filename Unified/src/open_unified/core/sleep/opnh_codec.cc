// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/core/sleep/opnh_codec.h"

#include <cstring>
#include <utility>

namespace open_unified {

namespace {

void AppendUint32LE(std::vector<uint8_t>* out, uint32_t value) {
  out->push_back(static_cast<uint8_t>(value & 0xffu));
  out->push_back(static_cast<uint8_t>((value >> 8) & 0xffu));
  out->push_back(static_cast<uint8_t>((value >> 16) & 0xffu));
  out->push_back(static_cast<uint8_t>((value >> 24) & 0xffu));
}

uint32_t ReadUint32LE(base::span<const uint8_t> bytes, size_t offset) {
  return static_cast<uint32_t>(bytes[offset]) |
         (static_cast<uint32_t>(bytes[offset + 1]) << 8) |
         (static_cast<uint32_t>(bytes[offset + 2]) << 16) |
         (static_cast<uint32_t>(bytes[offset + 3]) << 24);
}

}  // namespace

OpnhError ValidateOpnh(const OpnhContainer& container) {
  const size_t count = container.entries.size();
  if (count < 1 || count > kOpnhMaxEntries) {
    return OpnhError::kInvalidCount;
  }
  if (container.current_index >= count) {
    return OpnhError::kInvalidIndex;
  }
  size_t total = kOpnhHeaderBytes + count * 4;
  for (const auto& entry : container.entries) {
    if (entry.empty()) {
      return OpnhError::kInvalidLength;
    }
    if (entry.size() > kOpnhMaxBytes || total > kOpnhMaxBytes - entry.size()) {
      return OpnhError::kTooLarge;
    }
    total += entry.size();
  }
  if (total > kOpnhMaxBytes) {
    return OpnhError::kTooLarge;
  }
  return OpnhError::kNone;
}

bool EncodeOpnh(const OpnhContainer& container,
                std::vector<uint8_t>* out,
                OpnhError* error_out) {
  OpnhError err = ValidateOpnh(container);
  if (err != OpnhError::kNone) {
    if (error_out) *error_out = err;
    return false;
  }
  size_t total = kOpnhHeaderBytes + container.entries.size() * 4;
  for (const auto& entry : container.entries) {
    total += entry.size();
  }
  std::vector<uint8_t> bytes;
  bytes.reserve(total);

  // Bytes 0..3: "OPNH"
  bytes.insert(bytes.end(), std::begin(kOpnhMagic), std::end(kOpnhMagic));
  // Bytes 4..7: version = 1
  AppendUint32LE(&bytes, kOpnhVersion);
  // Bytes 8..11: entryCount
  AppendUint32LE(&bytes, static_cast<uint32_t>(container.entries.size()));
  // Bytes 12..15: currentIndex
  AppendUint32LE(&bytes, container.current_index);
  // Byte 16: flags (bit 0 = hasPageState), Bytes 17..19: reserved zeros
  bytes.push_back(container.has_page_state ? 0x01u : 0x00u);
  bytes.push_back(0x00u);
  bytes.push_back(0x00u);
  bytes.push_back(0x00u);

  for (const auto& entry : container.entries) {
    AppendUint32LE(&bytes, static_cast<uint32_t>(entry.size()));
    bytes.insert(bytes.end(), entry.begin(), entry.end());
  }

  *out = std::move(bytes);
  if (error_out) *error_out = OpnhError::kNone;
  return true;
}

bool DecodeOpnh(base::span<const uint8_t> data,
                OpnhContainer* out,
                OpnhError* error_out) {
  auto fail = [&](OpnhError e) {
    if (error_out) *error_out = e;
    return false;
  };
  if (data.size() > kOpnhMaxBytes) {
    return fail(OpnhError::kTooLarge);
  }
  if (data.size() < kOpnhHeaderBytes) {
    return fail(OpnhError::kInvalidHeader);
  }
  if (std::memcmp(data.data(), kOpnhMagic, sizeof(kOpnhMagic)) != 0) {
    return fail(OpnhError::kInvalidHeader);
  }
  if ((data[16] & 0xfeu) != 0 || data[17] != 0 || data[18] != 0 ||
      data[19] != 0) {
    return fail(OpnhError::kInvalidHeader);
  }
  if (ReadUint32LE(data, 4) != kOpnhVersion) {
    return fail(OpnhError::kInvalidHeader);
  }
  uint32_t count = ReadUint32LE(data, 8);
  uint32_t index = ReadUint32LE(data, 12);
  if (count < 1 || count > kOpnhMaxEntries) {
    return fail(OpnhError::kInvalidCount);
  }
  if (index >= count) {
    return fail(OpnhError::kInvalidIndex);
  }

  size_t offset = kOpnhHeaderBytes;
  OpnhContainer result;
  result.current_index = index;
  result.has_page_state = (data[16] == 0x01u);
  result.entries.reserve(count);

  for (uint32_t i = 0; i < count; ++i) {
    if (data.size() - offset < 4) {
      return fail(OpnhError::kInvalidLength);
    }
    uint32_t length = ReadUint32LE(data, offset);
    offset += 4;
    if (length == 0 || length > kOpnhMaxBytes ||
        length > data.size() - offset) {
      return fail(OpnhError::kInvalidLength);
    }
    auto slice = data.subspan(offset, length);
    result.entries.emplace_back(slice.begin(), slice.end());
    offset += length;
  }

  if (offset != data.size()) {
    return fail(OpnhError::kInvalidLength);
  }

  OpnhError check = ValidateOpnh(result);
  if (check != OpnhError::kNone) {
    return fail(check);
  }

  *out = std::move(result);
  if (error_out) *error_out = OpnhError::kNone;
  return true;
}

bool CaptureOpnhWithFallback(
    uint32_t current_index,
    const std::function<std::vector<std::vector<uint8_t>>()>& default_entries_fn,
    const std::function<std::vector<std::vector<uint8_t>>()>&
        excluding_page_state_fn,
    OpnhContainer* out,
    OpnhError* error_out) {
  OpnhContainer primary;
  primary.entries = default_entries_fn();
  primary.current_index = current_index;
  primary.has_page_state = true;
  OpnhError err = ValidateOpnh(primary);
  if (err == OpnhError::kNone) {
    *out = std::move(primary);
    if (error_out) *error_out = OpnhError::kNone;
    return true;
  }
  if (err != OpnhError::kTooLarge) {
    if (error_out) *error_out = err;
    return false;
  }
  OpnhContainer fallback;
  fallback.entries = excluding_page_state_fn();
  fallback.current_index = current_index;
  fallback.has_page_state = false;
  err = ValidateOpnh(fallback);
  if (err != OpnhError::kNone) {
    if (error_out) *error_out = err;
    return false;
  }
  *out = std::move(fallback);
  if (error_out) *error_out = OpnhError::kNone;
  return true;
}

}  // namespace open_unified
