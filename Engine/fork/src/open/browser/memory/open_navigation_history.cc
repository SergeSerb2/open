// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Capture and restore of a browser's navigation history for tab sleeping
// (docs/plans/memory-fork.md §5.3). The format of each entry is Chromium's
// session pickle (sessions::SerializedNavigationEntry), the same bytes
// Chrome's session restore writes.

#include "open/browser/memory/open_navigation_history.h"

#include <limits>
#include <utility>

#include "base/containers/span.h"
#include "base/logging.h"
#include "base/pickle.h"
#include "cef/include/cef_values.h"
#include "cef/libcef/browser/browser_host_base.h"
#include "cef/libcef/browser/thread_util.h"
#include "components/sessions/content/content_serialized_navigation_builder.h"
#include "components/sessions/core/serialized_navigation_entry.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/restore_type.h"
#include "content/public/browser/visibility.h"
#include "content/public/browser/web_contents.h"

namespace open_engine {

namespace {

using Builder = sessions::ContentSerializedNavigationBuilder;

content::WebContents* WebContentsFor(CefRefPtr<CefBrowser> browser) {
  auto host = CefBrowserHostBase::FromBrowser(browser);
  return host ? host->GetWebContents() : nullptr;
}

// True for a controller that never had a navigation: only the initial
// NavigationEntry (or nothing), and no pending entry.
bool IsUnused(content::NavigationController& controller) {
  const int count = controller.GetEntryCount();
  if (controller.GetPendingEntry()) {
    return false;
  }
  return count == 0 ||
         (count == 1 && controller.GetEntryAtIndex(0)->IsInitialEntry());
}

}  // namespace

size_t PackedHistorySize(const std::vector<std::vector<uint8_t>>& entries) {
  size_t total = 20 + 4 * entries.size();
  for (const auto& entry : entries) {
    total += entry.size();
  }
  return total;
}

OpenNavigationHistory::OpenNavigationHistory(
    std::vector<std::vector<uint8_t>> entries,
    int current_index,
    bool has_page_state,
    CefString current_url,
    CefString title,
    CefString favicon_url)
    : entries_(std::move(entries)),
      current_index_(current_index),
      has_page_state_(has_page_state),
      current_url_(std::move(current_url)),
      title_(std::move(title)),
      favicon_url_(std::move(favicon_url)) {}

OpenNavigationHistory::~OpenNavigationHistory() = default;

int OpenNavigationHistory::GetEntryCount() {
  return static_cast<int>(entries_.size());
}

CefRefPtr<CefBinaryValue> OpenNavigationHistory::GetEntryAt(int index) {
  if (index < 0 || index >= GetEntryCount()) {
    return nullptr;
  }
  const auto& entry = entries_[index];
  return CefBinaryValue::Create(entry.data(), entry.size());
}

int OpenNavigationHistory::GetCurrentIndex() {
  return current_index_;
}

CefString OpenNavigationHistory::GetCurrentURL() {
  return current_url_;
}

CefString OpenNavigationHistory::GetTitle() {
  return title_;
}

CefString OpenNavigationHistory::GetFaviconURL() {
  return favicon_url_;
}

bool OpenNavigationHistory::HasPageState() {
  return has_page_state_;
}

}  // namespace open_engine

// static
CefRefPtr<CefNavigationHistory> CefNavigationHistory::Create(
    CefRefPtr<CefListValue> entries,
    int current_index,
    bool has_page_state) {
  if (!entries) {
    return nullptr;
  }
  const size_t count = entries->GetSize();
  if (count < 1 || count > open_engine::kMaxHistoryEntries ||
      current_index < 0 || static_cast<size_t>(current_index) >= count) {
    return nullptr;
  }
  std::vector<std::vector<uint8_t>> bytes;
  bytes.reserve(count);
  size_t packed = 20 + 4 * count;
  for (size_t i = 0; i < count; ++i) {
    if (entries->GetType(i) != VTYPE_BINARY) {
      return nullptr;
    }
    CefRefPtr<CefBinaryValue> value = entries->GetBinary(i);
    const size_t size = value ? value->GetSize() : 0;
    // Check before copying: the packed total bounds every allocation here.
    if (size == 0 || size > open_engine::kMaxHistoryBytes - packed) {
      return nullptr;
    }
    packed += size;
    std::vector<uint8_t> entry(size);
    if (value->GetData(entry.data(), size, 0) != size) {
      return nullptr;
    }
    bytes.push_back(std::move(entry));
  }
  return new open_engine::OpenNavigationHistory(
      std::move(bytes), current_index, has_page_state, CefString(),
      CefString(), CefString());
}

CefRefPtr<CefNavigationHistory> CefGetNavigationHistory(
    CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UIT_RETURN(nullptr);
  content::WebContents* web_contents =
      open_engine::WebContentsFor(browser);
  if (!web_contents) {
    return nullptr;
  }
  content::NavigationController& controller = web_contents->GetController();
  const int count = controller.GetEntryCount();
  if (count < 1 || count > open_engine::kMaxHistoryEntries) {
    return nullptr;
  }
  if (count == 1 && controller.GetEntryAtIndex(0)->IsInitialEntry()) {
    // Nothing committed yet: there is no history to keep.
    return nullptr;
  }
  int current = controller.GetCurrentEntryIndex();
  if (current < 0 || current >= count) {
    current = controller.GetLastCommittedEntryIndex();
  }
  if (current < 0 || current >= count) {
    return nullptr;
  }

  // One pass per option set. Page state (scroll and form values for every
  // frame) is the expensive and large part; drop it only when the history
  // does not fit otherwise (memory-fork §5.3 step 4).
  sessions::SerializedNavigationEntry current_entry;
  auto serialize = [&](Builder::SerializationOptions options,
                       std::vector<std::vector<uint8_t>>& out) {
    out.clear();
    out.reserve(count);
    size_t packed = 20 + 4 * static_cast<size_t>(count);
    for (int i = 0; i < count; ++i) {
      content::NavigationEntry* entry = controller.GetEntryAtIndex(i);
      if (!entry) {
        return false;  // No partial history.
      }
      sessions::SerializedNavigationEntry serialized =
          Builder::FromNavigationEntry(i, entry, options);
      // No string limit: WriteToPickle truncates long strings, and a cut URL
      // breaks restore. The total is checked instead.
      base::Pickle pickle;
      serialized.WriteToPickle(std::numeric_limits<int>::max(), &pickle);
      if (pickle.size() == 0 ||
          pickle.size() > open_engine::kMaxHistoryBytes - packed) {
        return false;
      }
      packed += pickle.size();
      out.emplace_back(pickle.data(), pickle.data() + pickle.size());
      if (i == current) {
        current_entry = std::move(serialized);
      }
    }
    return true;
  };

  std::vector<std::vector<uint8_t>> entries;
  bool has_page_state = true;
  if (!serialize(Builder::DEFAULT, entries)) {
    has_page_state = false;
    if (!serialize(Builder::EXCLUDE_PAGE_STATE, entries)) {
      LOG(WARNING) << "Open: navigation history over 2 MiB without page state";
      return nullptr;
    }
  }
  const GURL& favicon = current_entry.favicon_url();
  return new open_engine::OpenNavigationHistory(
      std::move(entries), current, has_page_state,
      current_entry.virtual_url().spec(), current_entry.title(),
      favicon.is_valid() ? favicon.spec() : std::string());
}

bool CefRestoreNavigationHistory(CefRefPtr<CefBrowser> browser,
                                 CefRefPtr<CefNavigationHistory> history) {
  CEF_REQUIRE_UIT_RETURN(false);
  if (!history) {
    return false;
  }
  content::WebContents* web_contents =
      open_engine::WebContentsFor(browser);
  if (!web_contents) {
    return false;
  }
  content::NavigationController& controller = web_contents->GetController();
  if (!open_engine::IsUnused(controller)) {
    LOG(WARNING) << "Open: navigation history restore refused: the page "
                    "already navigated";
    return false;
  }
  const int count = history->GetEntryCount();
  const int current = history->GetCurrentIndex();
  if (count < 1 || count > open_engine::kMaxHistoryEntries || current < 0 ||
      current >= count) {
    return false;
  }

  // Decode everything before touching the controller: a bad entry (for
  // example after a Chromium update) changes nothing.
  std::vector<sessions::SerializedNavigationEntry> serialized(count);
  for (int i = 0; i < count; ++i) {
    CefRefPtr<CefBinaryValue> value = history->GetEntryAt(i);
    const size_t size = value ? value->GetSize() : 0;
    if (size == 0 || size > open_engine::kMaxHistoryBytes) {
      return false;
    }
    std::vector<uint8_t> bytes(size);
    if (value->GetData(bytes.data(), size, 0) != size) {
      return false;
    }
    base::Pickle pickle = base::Pickle::WithUnownedBuffer(bytes);
    base::PickleIterator iterator(pickle);
    if (!serialized[i].ReadFromPickle(&iterator)) {
      LOG(WARNING) << "Open: navigation history entry " << i
                   << " does not decode";
      return false;
    }
  }
  std::vector<std::unique_ptr<content::NavigationEntry>> entries =
      Builder::ToNavigationEntries(serialized,
                                   web_contents->GetBrowserContext());
  if (static_cast<int>(entries.size()) != count) {
    return false;
  }
  controller.Restore(current, content::RestoreType::kRestored, &entries);
  if (controller.GetEntryCount() != count) {
    LOG(ERROR) << "Open: navigation history restore lost entries";
    return false;
  }
  // The first load of the restored entry reports document.wasDiscarded, as
  // after a discard in place. Cleared when that load starts.
  web_contents->SetWasDiscarded(true);
  if (web_contents->GetVisibility() == content::Visibility::VISIBLE) {
    // Already shown: nothing else will make the controller load.
    controller.LoadIfNecessary();
  }
  return true;
}
