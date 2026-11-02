// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef OPEN_BROWSER_MEMORY_OPEN_NAVIGATION_HISTORY_H_
#define OPEN_BROWSER_MEMORY_OPEN_NAVIGATION_HISTORY_H_

#include <cstdint>
#include <vector>

#include "cef/include/cef_navigation_history.h"

namespace open_engine {

// Limits shared with OpenEngine's OPNH v1 container
// (docs/plans/memory-fork.md §7.1): at most 512 entries, and the packed
// container (20-byte header + 4 bytes per entry + the entries) is at most
// 2 MiB, so a captured history always fits one container.
inline constexpr int kMaxHistoryEntries = 512;
inline constexpr size_t kMaxHistoryBytes = 2 * 1024 * 1024;

// Bytes the OPNH v1 container needs for |entries| (header, lengths, data).
size_t PackedHistorySize(const std::vector<std::vector<uint8_t>>& entries);

// CefNavigationHistory: immutable, so every method is safe on any thread.
class OpenNavigationHistory : public CefNavigationHistory {
 public:
  OpenNavigationHistory(std::vector<std::vector<uint8_t>> entries,
                        int current_index,
                        bool has_page_state,
                        CefString current_url,
                        CefString title,
                        CefString favicon_url);
  OpenNavigationHistory(const OpenNavigationHistory&) = delete;
  OpenNavigationHistory& operator=(const OpenNavigationHistory&) = delete;

  // CefNavigationHistory:
  int GetEntryCount() override;
  CefRefPtr<CefBinaryValue> GetEntryAt(int index) override;
  int GetCurrentIndex() override;
  CefString GetCurrentURL() override;
  CefString GetTitle() override;
  CefString GetFaviconURL() override;
  bool HasPageState() override;

 private:
  ~OpenNavigationHistory() override;

  const std::vector<std::vector<uint8_t>> entries_;
  const int current_index_;
  const bool has_page_state_;
  const CefString current_url_;
  const CefString title_;
  const CefString favicon_url_;

  IMPLEMENT_REFCOUNTING(OpenNavigationHistory);
};

}  // namespace open_engine

#endif  // OPEN_BROWSER_MEMORY_OPEN_NAVIGATION_HISTORY_H_
