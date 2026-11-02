// OENavigationHistory: the OPNH v1 container around the fork's
// CefNavigationHistory (docs/plans/memory-fork.md §7.1). The layout and its
// checks match OpenSleep's SleepHistoryContainer byte for byte.

#import "OEInternal.h"

#include <cstdint>
#include <cstring>
#include <utility>
#include <vector>

#include "include/cef_navigation_history.h"

namespace {

constexpr size_t kHeaderBytes = 20;
constexpr size_t kMaxBytes = 2 * 1024 * 1024;
constexpr uint32_t kMaxEntries = 512;
constexpr uint8_t kMagic[4] = {0x4f, 0x50, 0x4e, 0x48};  // "OPNH"

void AppendUInt32(std::vector<uint8_t>& out, uint32_t value) {
  for (int i = 0; i < 4; ++i) {
    out.push_back(static_cast<uint8_t>(value >> (8 * i)));
  }
}

// Little-endian read with explicit shifts: no unaligned loads.
uint32_t ReadUInt32(const uint8_t* p) {
  return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) |
         (uint32_t(p[3]) << 24);
}

}  // namespace

@implementation OENavigationHistory {
  // The entries, for restore. Parsed from or packed into `container`.
  std::vector<std::vector<uint8_t>> _entries;
}

- (nullable instancetype)initWithContainer:(NSData*)container {
  const size_t size = container.length;
  if (size < kHeaderBytes || size > kMaxBytes) {
    return nil;
  }
  const uint8_t* bytes = static_cast<const uint8_t*>(container.bytes);
  if (memcmp(bytes, kMagic, 4) != 0 || ReadUInt32(bytes + 4) != 1 ||
      (bytes[16] & 0xfe) != 0 || bytes[17] || bytes[18] || bytes[19]) {
    return nil;
  }
  const uint32_t count = ReadUInt32(bytes + 8);
  const uint32_t index = ReadUInt32(bytes + 12);
  if (count < 1 || count > kMaxEntries || index >= count) {
    return nil;
  }
  std::vector<std::vector<uint8_t>> entries;
  entries.reserve(count);
  size_t offset = kHeaderBytes;
  for (uint32_t i = 0; i < count; ++i) {
    if (size - offset < 4) {
      return nil;
    }
    const uint32_t length = ReadUInt32(bytes + offset);
    offset += 4;
    if (length == 0 || length > size - offset) {
      return nil;
    }
    entries.emplace_back(bytes + offset, bytes + offset + length);
    offset += length;
  }
  if (offset != size) {
    return nil;  // Trailing bytes.
  }
  if ((self = [super init])) {
    _container = [container copy];
    _entries = std::move(entries);
    _entryCount = count;
    _currentIndex = index;
    _hasPageState = bytes[16] == 1;
    _title = @"";
  }
  return self;
}

- (nullable instancetype)initOEWithCefHistory:
    (CefRefPtr<CefNavigationHistory>)history {
  if (!history) {
    return nil;
  }
  const int count = history->GetEntryCount();
  const int index = history->GetCurrentIndex();
  if (count < 1 || count > static_cast<int>(kMaxEntries) || index < 0 ||
      index >= count) {
    return nil;
  }
  std::vector<std::vector<uint8_t>> entries;
  entries.reserve(count);
  size_t total = kHeaderBytes + 4 * static_cast<size_t>(count);
  for (int i = 0; i < count; ++i) {
    CefRefPtr<CefBinaryValue> value = history->GetEntryAt(i);
    const size_t length = value ? value->GetSize() : 0;
    if (length == 0 || length > kMaxBytes - total) {
      return nil;
    }
    total += length;
    std::vector<uint8_t> entry(length);
    if (value->GetData(entry.data(), length, 0) != length) {
      return nil;
    }
    entries.push_back(std::move(entry));
  }
  std::vector<uint8_t> out;
  out.reserve(total);
  out.insert(out.end(), kMagic, kMagic + 4);
  AppendUInt32(out, 1);
  AppendUInt32(out, static_cast<uint32_t>(count));
  AppendUInt32(out, static_cast<uint32_t>(index));
  const bool page_state = history->HasPageState();
  out.insert(out.end(), {static_cast<uint8_t>(page_state ? 1 : 0), 0, 0, 0});
  for (const auto& entry : entries) {
    AppendUInt32(out, static_cast<uint32_t>(entry.size()));
    out.insert(out.end(), entry.begin(), entry.end());
  }
  if ((self = [super init])) {
    _container = [NSData dataWithBytes:out.data() length:out.size()];
    _entries = std::move(entries);
    _entryCount = count;
    _currentIndex = index;
    _hasPageState = page_state;
    _currentURL = OEURL(history->GetCurrentURL());
    _title = OEString(history->GetTitle());
    _faviconURL = OEURL(history->GetFaviconURL());
  }
  return self;
}

- (CefRefPtr<CefNavigationHistory>)oe_cefHistory {
  CefRefPtr<CefListValue> list = CefListValue::Create();
  list->SetSize(_entries.size());
  for (size_t i = 0; i < _entries.size(); ++i) {
    list->SetBinary(i, CefBinaryValue::Create(_entries[i].data(),
                                              _entries[i].size()));
  }
  return CefNavigationHistory::Create(list, static_cast<int>(_currentIndex),
                                      _hasPageState);
}

- (NSString*)description {
  return [NSString stringWithFormat:@"<OENavigationHistory %p %ld entries, "
                                    @"current %ld, %lu bytes%@>",
                                    self, (long)_entryCount,
                                    (long)_currentIndex,
                                    (unsigned long)_container.length,
                                    _hasPageState ? @", page state" : @""];
}

@end
